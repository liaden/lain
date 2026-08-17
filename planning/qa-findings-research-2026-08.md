# Research: addressing the 2026-08-17 QA findings

Status: research, not a plan. No card here is ready to execute — each says what is now *known*,
where a fix would belong, and what is still open.

The manual QA run (`planning/qa-manual-end-to-end.md`, 2026-08-17) produced seven lain findings,
F1–F7. This document is the follow-up pass over them: what the references already said, what new
evidence a day of probing produced, and what the design options actually are.

**Method note.** Everything labelled *measured* was reproduced on this box with a harness kept
beside the findings file; everything labelled *inferred* is a reading of code that has not been
executed. The distinction matters here because the QA run's single most expensive mistake was
believing a plausible mechanism (see F1's "I had assumed truncation first and it was wrong").

---

## F7 is three defects, not one

This was the run's most serious finding and the one that changed most under investigation. The
original write-up said "a model server that dies mid-stream hangs lain past its own timeout". That
is true and it is the least of it.

### The blocking frame, measured

A watchdog thread dumping backtraces mid-hang puts the block in `Net::BufferedIO#rbuf_fill`, via
two different callers depending on when the sever lands:

```
IO#wait_readable            <- net/protocol.rb:233, bounded by read_timeout
Net::BufferedIO#readline
Net::HTTPResponse.read_status_line     <- waiting for a RETRY's response headers
Net::HTTP#transport_request
```

`read_timeout` is per-read, so it does bound each attempt — at `request_timeout`, which is **300 s**
(`provider/http/configuration.rb:64` → `connection/middleware_stack.rb:43`). With
`max_retries: 3` and `:post` explicitly added to the retryable methods
(`middleware_stack.rb:73`), the worst case is **four attempts × 300 s ≈ 20 minutes**, which is why
a 400 s leash still ended in a timeout kill rather than an error.

**F7a — retry amplification.** Each retry re-sends the whole prompt to a model server that is still
generating the abandoned attempt, so the retries queue behind work nobody will read. Measured: the
severed run's second attempt blocked in `read_chunked` with its headers already received — waiting
on a busy server, not on a dead socket.

This is not peculiar to us. [nanobot#2511](https://github.com/HKUDS/nanobot/issues/2511) reports the
same shape from stacked retry layers — "(2+1) × (3+1) = 12 requests", ~12 minutes of silent hanging
— and its remedies are the ones that apply here: collapse the retry layers, bound the read timeout
explicitly, and give the application an `on_retry` callback so the wait is visible.

**Why ours was completely silent** is already written down, in `provider/ollama.rb:43-47`:

> *deliberately absent: a `channel:` — so retries are NOT journaled on this arm. faraday-retry still
> runs (HTTP::Configuration's vendored 3), but no `Telemetry::ProviderRetry` reaches the Journal, so
> a run's record shows one request where three attempts happened. Free/local spend is why that was
> tolerable; comparing latency across arms is why it will not stay so.*

Confirmed by grep: only `anthropic.rb:103` and `bedrock.rb:105` set `config.retry_block`. The
prediction in that comment has come true earlier and harder than expected — it is not latency
comparison that broke, it is a 20-minute invisible stall. **Wiring a channel into
`Ollama#build_config` is the smallest change in this document with the largest effect on
diagnosability.**

### F7b — the Ollama assembler concatenates abandoned attempts · measured, silent corruption

`Provider::Ollama#stream_body` builds the assembler *outside* the transport call, and the retry
middleware lives *inside* the Faraday connection:

```ruby
def stream_body(request)
  assembler = StreamAssembler.new                      # created once
  @transport.stream(encode(request)) { |chunk| assembler.feed(chunk) }   # retries happen in here
  assembler.result
```

Against a deterministic fake upstream that severs attempt 1 mid-stream and serves attempt 2 cleanly,
the provider returned **`ok`** with:

```
PARTIAL-alphaPARTIAL-betaPARTIAL-gammaRETRY-oneRETRY-twoRETRY-three RETRY-four
```

That is worse than the hang. There is no error, the turn commits to a content-addressed Timeline as
permanent history, usage accounts for one turn while two generations were billed, and nothing
anywhere says the content is spliced. Any transient blip mid-stream produces it.

### F7c — the Anthropic assembler retains orphaned blocks · measured, narrower, worse in kind

The same experiment against a fake SSE endpoint came back **clean** — `RETRY-oneRETRY-twoRETRY-three`
— because that assembler is keyed by block index and the retry's `content_block_start` for index 0
*replaces* the partial block (`anthropic/stream_assembler.rb:80-84`, `on_block_start`).

That protection is incidental, and it has a hole. When the abandoned attempt opened a block index the
retry never re-opens, nothing overwrites it:

```
RETRY-oneRETRY-twoRETRY-threeORPHAN-BLOCK-FROM-ABANDONED-ATTEMPT
```

Reported as `ok`, `stop_reason: :end_turn`, usage clean. The realistic version of this is an attempt
that got partway into a `tool_use` block before the reset: the final message then carries a **phantom
tool call** the model never finished asking for.

### The codebase already named this hazard, one layer down

`Provider::Anthropic::RetryTap`'s docstring:

> *A retried attempt must never share a WAL frame with the one it replaced (**the byte-count check
> cannot catch two concatenated attempts**), and the transport must stay digest-blind, so the
> rotation has to live on this side of the transport.*

So "a retry must not be allowed to concatenate onto its predecessor" is an understood invariant here
— it was identified, reasoned about, and enforced **for the response WAL** by rotating the frame on
retry. The `StreamAssembler` that produces the actual `Response` sits one layer up and never got the
same treatment. That is the gap, and `retry_block` is already the seam that would close it.

### Design options

| | what it does | cost |
|---|---|---|
| **A. Reset the assembler on retry** | wire `retry_block` (per-request, as `RetryTap` already does) to reset/rotate the assembler | smallest; fixes F7b and F7c; keeps retries |
| **B. Do not retry a stream that already delivered bytes** | drop `:post` from streaming retries, or refuse retry once the first chunk landed | matches the official SDKs' effective behaviour; loses free recovery from pre-first-byte failures |
| **C. Stall detection** | error out when throughput stays under a floor for a grace window | fixes F7a's silence; orthogonal to B |
| **D. Total deadline across attempts** | one budget for the whole call, not per attempt | caps the 20-minute worst case |

**A and C are the pair I would start with**, because A closes a silent-corruption hole with a seam
that already exists, and C attacks the thing that actually hurt during QA. B is worth taking too, but
note the trade: [Anthropic's own SDK does not auto-retry a premature stream end](https://github.com/anthropics/anthropic-sdk-typescript/issues/842)
— the error surfaces instead, and the documented remedy is an explicit *continuation* request rather
than a blind re-send. That is evidence for B, not against it.

For C, the industry term is **stalled-stream protection** and
[the AWS SDK's design](https://github.com/awslabs/aws-sdk-rust/discussions/956) is a usable template:
minimum throughput **1 byte/s**, grace period **5 s**, checked once per second, adjustable and
disableable. Claude Code itself surfaces an `API Error: Stream idle timeout`, so the pattern is
well-precedented for exactly this workload.

**The one nuance that must not be lost**, from `ollama.rb:49-52`: *"A local model that thinks for six
minutes is a real shape, so the 300s is a live limit rather than a formality."* A naive stall
detector would kill a legitimate long prompt-eval. So the budget before the **first** byte and the
budget **between** bytes are different questions and want different numbers — a long first-byte grace,
a short inter-chunk one. Getting that split wrong turns a resilience feature into a new failure mode.

### Open questions

- Does `Provider::Bedrock` share F7b's or F7c's shape? Not examined.
- Is there a partial-delivery signal the Agent layer could use — i.e. should a torn stream become a
  visible `run_interrupted` rather than a silent splice?
- `Ollama::StreamedFailure` exists as "where a torn stream is supposed to surface". Why did it not
  catch this? Not investigated.

---

## F3 — the cold-start window, and two safety directions that point opposite ways

`references/ollama/api-show-and-context.md` already contains the whole mechanism, written for T9. Its
rule is explicit: `/api/ps` is the only endpoint that states the served window; it lists **only
resident models**; "an empty listing is not 'no cap', it is 'not decided yet'"; and when unknown,
answer nil and let `ContextWindow::CONSERVATIVE_FALLBACK` take over, because
`context_window.rb:74-77` ranks over-estimating as worse than the crash it replaces —
**"under-estimate when unsure; never over-estimate."**

F3 is what that rule costs when it fires. The fallback of 8192 against a real 32768 made turns at
75–78 % occupancy read as 300 %, so `approaching_window` fired and lain **rewrote history three
times**, spending real tokens and latency on compaction that was not needed.

**The finding worth recording is that the two safety directions are opposite.** Under-estimating the
window is the safe direction for *not overflowing the model*. It is the **unsafe** direction for *not
destroying context*, because compaction is itself lossy and irreversible. The reference reasoned
carefully about the first and not at all about the second — reasonably, since it was written for the
provider method, not for the compaction trigger. The consumer is where the two meet.

Candidate directions, none verified:

- **Do not let a provisional window trigger a destructive action.** Distinguish "measured" from
  "fallback" and let `approaching_window` fire only on a measured one. Under-estimation then still
  protects against overflow (the request is smaller than it needed to be) without authorising a
  rewrite. This is the option that respects both directions and is my starting recommendation.
- **Warm the runner before the first turn** so the window is knowable — a cheap request forces load,
  after which `/api/ps` answers. Trades a small startup cost for a real number.
- **Re-read and revise.** The reference already forbids memoizing across turns (~0.3 ms, so per-turn
  is affordable), and the warm Act did show all three surfaces agreeing at 32768 — so revision does
  happen. Worth checking why Act 2's twelve decisions all stayed at 8192 when the model was
  presumably resident by then; that may be a separate bug rather than the documented cold window.

---

## F1 — `web_fetch` on any non-ASCII page

The QA write-up already located this correctly: Faraday hands the body back `ASCII-8BIT`,
`Canonical.utf8` does `encode(UTF_8)`, and that raises on any byte ≥ 0x80. The fix belongs in the
tool, not in `Canonical` — deterministic bytes are `Canonical`'s entire job and encoding must be
pinned or identical characters hash differently.

**Prior art we already vendored.** `references/repos/mempalace/mempalace/format_miner.py:197`,
`decode_robust`: UTF-8 first, CP1252 fallback (legacy smart quotes), UTF-8-with-`replace` as the
final net — *never raises*. The Ruby equivalent, verified against the exact failing bytes:

```ruby
def decode_robust(bytes)
  utf8 = bytes.dup.force_encoding(Encoding::UTF_8)
  return utf8 if utf8.valid_encoding?
  cp = bytes.dup.force_encoding(Encoding::WINDOWS_1252)
  return cp.encode(Encoding::UTF_8) if cp.valid_encoding?
  utf8.scrub
end
```

| input | result | `Canonical.utf8` |
|---|---|---|
| `caf\xC3\xA9` as ASCII-8BIT (the F1 bytes) | `café` | clean |
| `don\x92t` (CP1252 smart quote) | `don’t` | clean |
| `caf\xC3` (cap splits a character) | **`cafÃ`** | clean |
| `\x89PNG\r\n\x1A\n` (binary) | **`‰PNG…`** | clean |

**Two caveats the ladder introduces, and they are the interesting part.** The last two rows never
fail — which is the point of the ladder and also its hazard:

- A **mid-character truncation becomes plausible mojibake** rather than a dropped character, because
  the CP1252 rung accepts it. So the byte cap must truncate on a character boundary *before* the
  ladder sees it, as F1 already suspected.
- **Binary decodes "successfully".** A PDF or image comes back as garbage text instead of a refusal.
  So the tool needs a *text-or-not* decision (Content-Type, with the charset taken from it when
  present) ahead of the *how-to-decode* decision. The ladder is the fallback for text, not a
  substitute for asking whether this is text at all.

**Why no spec caught it** is worth carrying into whatever fix lands: every `web_fetch` spec injects a
stub connection, and a Ruby string literal in a spec is UTF-8, so the ASCII-8BIT tag only ever appears
when a real socket produces the bytes. Both sides of the seam are tested and the seam is not. A fix
without a seam-level spec would be untested in exactly the same way.

---

## F4 — the survey names a command from a different protocol

Root cause found, and it is smaller than the finding suggested.

`:LainReviewDone` (`runtime/65_review.lua:93`) guards on `b:lain_review_generation` **and**
`b:lain_review_epic_slug`, both stamped only at `65_review.lua:29-30` — the **epic** review surface,
protocol version 5. The **survey** stamps `b:lain_view_generation` (`46_sidebar.lua:86`), the generic
rendering stamp, and has no epic slug at all. So the guard can never pass from a survey buffer.

The changeset-review surface's real hand-back is **`:LainReviewVerdict {verdict}`**
(`46_sidebar.lua:188`), added in protocol version 10 and described in `frontend/neovim.rb:91-93` as
"the first ANSWERED verb outside a review buffer".

Both banners advertise the wrong one, in identical strings:

- `cli/command/survey.rb:105-106`
- `cli/command/review.rb:86-87`

This also explains the secondary symptom: `:LainReviewDone approve` gave `E488: Trailing characters`
because that command takes no argument, while the command that should have been named takes exactly
the verdict the human was trying to give.

So the substantive fix is a banner correction in two files. Two things worth doing alongside it:

- **The refusal should be a lain refusal, not a Lua traceback.** F4 noted this and it is a house-style
  point with teeth — everything else in the run refuses by naming the file and the remedy.
- **The duplication is the actual defect.** Two files carry the same instruction string about two
  different surfaces, which is how they drifted from the protocol without anything failing. The
  comment above each says the headline is read from one place "so the two surfaces cannot describe
  the same review differently" — the *gesture* half of that sentence is not enforced the same way.

---

## F2, F5, F6 — smaller, and each has a clean shape

**F2 — the Null search backend answers `ok`.** `tools/web_search.rb:61` returns
`Tool::Result.ok("web_search: no results for ...")` whether a backend searched and found nothing or
no backend is wired at all. The model cannot tell those apart, so it retried six times and then fell
back to `web_fetch`, which is what hit F1. Saying "no search backend is configured" in the unwired
case does not weaken the Null Object — `Sink::Null` satisfies its duck and sends bytes nowhere; it
does not claim to have written them. The question to settle is whether that text belongs in the
result (visible to the model, changes its behaviour) or in a capability declaration (visible before
the call, arguably where a capability question belongs).

**F5 — the mark message blocks nvim.** `lain: unit-content-v1:<64 hex> is now reviewed` is 102
characters into a 40-column pane, so it wraps, so nvim raises its hit-enter prompt, so every mark
stops the review *and* blocks RPC. 78 % of the message is a digest a human cannot act on; the file
name would fit. I could not locate the emitting literal by grep — the mark path runs
`46_sidebar.lua:156` → `review/surface/neovim.rb:282` → the session, and the string is assembled
somewhere I did not find. **Locating it is the first step, not an assumption to carry in.**

**F6 — a damaged session is invisible at rest.** Skipping unparseable lines is `Journal.records`'
documented contract (the fd can be shared with Rust tracing spans, so a reader skips foreign bytes
rather than raising over them). Applied to lain's own torn record, that silently drops a turn while
`cli/sessions.rb:65` still prints the pre-corruption head digest. It is genuinely safe — forking the
damaged session refuses precisely, naming the record index, its role, and both digests — so this is
an observability gap, not a correctness one. A `lain sessions --verify` that re-commits each turn
record and reports the first mismatch, or simply a parsed/skipped line count per row, would close it.
Worth weighing against the fact that nothing wrong can be *built* on the damage.

---

## Cross-cutting

**Three of the seven were already predicted in this repo's own prose.** F7a's silence is
`ollama.rb:43-47` verbatim ("it will not stay so"). F7b/F7c are the hazard `RetryTap` names and
solves one layer down. F3 is the documented consequence of a rule whose second safety direction was
never considered. That is a good sign about the comments and a bad sign about the follow-through:
**the notes correctly identified future problems and nothing converted them into work.** Whatever
chunk comes out of this, the highest-leverage habit to add is a way for a "this will not stay
tolerable" comment to become a tracked item rather than an epitaph.

**The QA run's instrument mattered more than its subject.** The bowling scorer was never produced by
the model, but the oracle set proved its own central claim mechanically: three oracles pass on a
scorer that is 17 points wrong, and the gem's own suite reports `4 examples, 0 failures` against it.
That result transfers to every future run; the scorer does not.

**Suggested sequencing, if this becomes a chunk.** F7b/F7c first — they are silent corruption of
content-addressed history and everything else is recoverable. Then F7a's channel wiring, which is
small and makes the next investigation cheaper. Then F1 (high severity, well understood, needs a seam
spec). F4 is nearly free and unblocks the review flow's last step. F3 needs a design decision before
it needs code. F2, F5, F6 are polish with clear shapes.

---

## Sources

- [nanobot#2511 — stacked retries causing silent multi-minute hangs](https://github.com/HKUDS/nanobot/issues/2511)
- [anthropic-sdk-typescript#842 — streams interrupted without `message_stop`](https://github.com/anthropics/anthropic-sdk-typescript/issues/842)
- [AWS SDK for Rust — stalled-stream protection](https://github.com/awslabs/aws-sdk-rust/discussions/956)
- [Anthropic streaming docs](https://platform.claude.com/docs/en/build-with-claude/streaming)
- `references/ollama/api-show-and-context.md` (in-repo, written for T9)
- `references/repos/mempalace/mempalace/format_miner.py` (vendored)
