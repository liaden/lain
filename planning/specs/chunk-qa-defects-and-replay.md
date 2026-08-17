# QA defects, and a replay harness that would have caught them

status: in-progress
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds · Jeremy Evans · Sandi Metz · Richard Schneeman · Aaron Patterson

## Intent

The 2026-08-17 manual QA run (`planning/qa-manual-end-to-end.md`) found seven defects, F1–F7.
This chunk fixes all seven and builds the recorded-replay tests that would let a future chunk
notice if any of them came back. Two of the seven are **silent corruption of content-addressed
history** — the assembler splices an abandoned HTTP attempt onto its retry — which is the reason
this chunk exists now rather than after the next milestone.

The research behind every finding is `planning/qa-findings-research-2026-08.md`; read it before
starting a card, because several fixes have a rejected obvious version.

## Grounding

Verified 2026-08-17 against the working tree. Files named here were read, not remembered.

**F7 — measured, not inferred.** Reproduced with fake upstreams that sever a connection
(`SO_LINGER 0`, a hard RST) mid-body:

- `Provider::Ollama#stream_body` (`lib/lain/provider/ollama.rb:238-241`) builds its
  `StreamAssembler` *outside* `@transport.stream`, and faraday-retry lives *inside* that Faraday
  connection. A severed attempt followed by a clean retry returned **`ok`** carrying
  `PARTIAL-alphaPARTIAL-betaPARTIAL-gammaRETRY-one…` — both attempts concatenated. **F7b.**
- `Provider::Anthropic#stream_dispatch` (`anthropic.rb:127-138`) has the same shape but survives
  the simple case, because `on_block_start` (`anthropic/stream_assembler.rb:81-85`) replaces
  `@blocks[index]`. It does **not** survive a retry that opens fewer blocks than the attempt it
  replaced: the orphan survived into the response. **F7c.** `Provider::Bedrock` reuses that exact
  class (`bedrock.rb:116`), so one fix covers both.
- The hang is retry amplification: blocked in `Net::HTTPResponse.read_status_line` awaiting a
  *retry's* headers. `request_timeout` is 300 s (`provider/http/configuration.rb:64` →
  `connection/middleware_stack.rb:43`) and `max_retries` is 3 (`configuration.rb:65`) with `:post`
  explicitly retryable (`middleware_stack.rb:75`), so worst case ≈ 4 × 300 s. Measured: >400 s with **zero output**
  against a 1909 ms control. **F7a.**
- The silence has a cause and it is already written down. `ollama.rb:43-47`: *"deliberately
  absent: a `channel:` — so retries are NOT journaled on this arm… comparing latency across arms
  is why it will not stay so."* Confirmed: only `anthropic.rb:103` and `bedrock.rb:105` set
  `config.retry_block`.

**The hazard is already named one layer down.** `Anthropic::RetryTap`'s docstring:
*"A retried attempt must never share a WAL frame with the one it replaced (the byte-count check
cannot catch two concatenated attempts)."* It is enforced for the response WAL by rotating the
frame on retry, and `retry_block` is the seam that does it. The assembler above never got the
same treatment. **This chunk extends an existing invariant; it does not invent one.**

**F1.** `Tools::WebFetch` streams into a byte buffer and returns it untagged; Faraday hands it back
`ASCII-8BIT`; `Canonical.utf8` raises on any byte ≥ 0x80. Verified that the mempalace ladder
(`references/repos/mempalace/mempalace/format_miner.py:197`) ports to Ruby and handles the exact
failing bytes. Two caveats found by testing it: a mid-character truncation becomes plausible
mojibake (`cafÃ`), and **binary decodes "successfully"** (a PNG becomes `‰PNG`), so a text/binary
decision must precede the decode decision. Why no spec caught it: `spec/lain/tools/web_fetch_spec.rb`
uses a hand-rolled `WebFetchStubConnection`, and a Ruby string literal is UTF-8 — **the stub lies
about encoding**, which is the actual root cause of the miss.

**F3.** `ContextWindow::CONSERVATIVE_FALLBACK = 8_192` (`context_window.rb:78`). Its comment
(`:57-77`) reasons the early-firing through explicitly and accepts it as *"self-correcting, not a
one-shot latch"*. QA showed the gap in that argument: self-correction is per-turn, but each firing
is an **irreversible lossy rewrite** — three of them, at 75–78 % of the real 32768 window.
`Need::ApproachingWindow#fired?` (`compaction/need.rb:90-94`) reads `state.window_tokens` and
cannot tell a probed window from a shipped-table one from a guess — three cases, not two; see T9. `references/ollama/api-show-and-context.md`
already establishes that `/api/ps` is the only endpoint stating the served window and answers only
for **resident** models.

**F4.** `:LainReviewDone` (`runtime/65_review.lua:93-98`) guards on `b:lain_review_generation` **and**
`b:lain_review_epic_slug`, stamped only at `65_review.lua:29-30` — the **epic** surface, protocol 5.
The survey stamps `b:lain_view_generation` (`46_sidebar.lua:86`) and has no epic slug, so the guard
can never pass. The changeset surface's real hand-back is `:LainReviewVerdict {verdict}`
(`46_sidebar.lua:188`, protocol 10). `Review::VERDICTS = %w[approve]`
(`review/vocabulary.rb:84`). Both banners are wrong and identical
(`cli/command/survey.rb:105-106`, `cli/command/review.rb:86-87`), and **no spec asserts on either**
— the coverage gap is real. `plugin/nvim/doc/lain.txt` documents all five command names and
`spec/plugin/nvim_plugin_spec.rb:299` enforces that it does.

**F5.** The literal is a format template, which is why it did not grep:
`MARKED = "%<hunk_key>s is now %<state>s"` (`review/surface/neovim.rb:169`), formatted at `:250`,
echoed with a `lain: ` prefix at `65_review.lua:37`. Pinned by
`spec/lain/review/surface/neovim_spec.rb:315` (exact equality), `:323` (word-boundary),
`spec/support/shared_examples/review_surface.rb:273-285` (every surface), and
`spec/lain/review/surface/text_spec.rb:241-247`.

**F6.** `cli/sessions.rb:65` renders `"#{@name}  #{started}  #{turns.size} turns  #{status}  #{head_short}"`.
Skipping unparseable lines is `Journal.records`' documented contract (a shared fd may carry Rust
tracing spans). Confirmed safe-but-invisible: a torn turn record shows one fewer turn under the
*same* head digest, while forking it refuses precisely. Note `sessions.rb:59-61` already states the
honesty principle for headerless files — this extends it to damaged ones.

**F2.** `Backend::Null = ->(_query) { [] }` (`tools/web_search.rb:32`); `perform` (`:59-61`) cannot
distinguish it from a real backend returning `[]`. Its own comment says it is named so the
"unconfigured" state is "legible in a rendered result" — an intent the code does not achieve.

**Test infrastructure (verified, and it changes the plan).** VCR is **already wired**:
`spec/support/vcr_configuration.rb`, cassettes at `spec/fixtures/vcr_cassettes`,
`hook_into :webmock`, `record: ENV["LAIN_RECORD"] == "1" ? :new_episodes : :none`,
`match_requests_on: %i[method uri]`. `:vcr` has **no filter** — it runs by default. But there is
exactly one cassette (`anthropic_streaming_tool_use.yml`) and one `:vcr` example. Five concrete
blockers to recording ollama, all found by grounding:

1. `spec/support/tags.rb:53-56` — `LAIN_RECORD=1` **raises without `ANTHROPIC_API_KEY`**, so an
   ollama recording trips a guard about a key it does not need.
2. `spec/support/ollama_probe.rb:23-29` registers a global `GET /api/ps` stub in a `config.before`,
   which shadows any cassette-recorded `/api/ps`.
3. `match_requests_on: %i[method uri]` — every ollama turn is `POST /api/chat`, so a multi-turn
   cassette replays the first interaction repeatedly without a sequence or body matcher.
4. `NetworkAccess.permit` (`spec/support/network_access.rb:26-31`) calls
   `VCR.turned_off(ignore_cassettes: true)`, which disables recording outright.
5. `:ollama` gating lives in its own file (`spec/support/ollama_tag.rb`), separate from `tags.rb`.

**The limitation that shapes the whole test half, already documented in this repo.**
`spec/lain/provider/ollama/streamed_failure_spec.rb:5-9` records that WebMock hands a stubbed
body back as **one chunk** (`lain.gemspec:77-80` makes the sibling point about VCR storing a body
as one blob), so a cassette "stores the body as one blob and
replays green forever" over a chunk-splitting bug. **Cassettes therefore cannot catch F7b or F7c.**
That is not a reason to skip them — they pin decode, encoding, context-window and orchestration
behaviour that nothing else covers — but the retry/splice regressions need a real severable socket.
Hence two distinct instruments in this plan: T1 (fake severable upstream) and T3/T13/T14 (cassettes).

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only):
  - `lib/lain.rb` — load-order manifest
  - `lib/lain/cli/backend.rb` — the construction site for providers, the context-window book, and
    the compaction mount. **Only T2 needs a change here** (one line, at `:181`); no card may edit it
    directly.
  - `spec/lain/cli/backend_spec.rb` — 62 KB, and T2 wants a production-path example in it. No other
    card may add one; T9's equivalent example lives in a new seam spec for exactly this reason.
  - `lain.gemspec`, `.rubocop.yml`, `spec/spec_helper.rb`
- **T0 exclusively owns `spec/support/network_access.rb`.** Both T1 and T3 need the narrow network
  permission it provides; neither may edit that file.
- **T3 exclusively owns the VCR support files** (`spec/support/vcr_configuration.rb`,
  `spec/support/tags.rb`, `spec/support/ollama_probe.rb`, `spec/support/ollama_tag.rb`). No other
  card may touch them; T13 and T14 consume what T3 establishes.
- `bin/severing-proxy.rb`, `bin/fake-ollama.rb` and `bin/fake-anthropic.rb` exist in the QA
  scratch directory from the research pass. **T1 is a rewrite for the suite, not a copy** — they
  were throwaway scripts and carry no specs, no frozen-string literals, and no output discipline.

## Open decisions

- **Cards T1, T3, T13 and T14 are test infrastructure and have no production construction site by
  design.** The reachability rule in the execute-plan lint asks where a capability is built on the
  real path; for these four the answer is "nowhere, deliberately — they exist to exercise the real
  path from outside." Every *other* card names a real construction site.
- **Stall-protection defaults are DECIDED, so T12 is not gated on this** — recorded here because
  the reasoning matters more than the numbers. **Inter-chunk grace: 30 s. First-byte grace:
  unchanged, i.e. the existing 300 s `request_timeout`.** Rationale: `ollama.rb:49-52` warns that
  *"a local model that thinks for six minutes is a real shape"*, and all of that silence falls
  **before** the first token — prompt evaluation. Once tokens are flowing, a 30 s gap from a
  token-streaming server means the stream is dead. Keeping the first-byte budget at today's value
  means this card cannot regress a legitimate slow start; it only bounds the mid-stream case F7
  actually hit. AWS's template uses a 5 s grace, which is right for bulk transfer and too tight for
  token generation — hence 30 s rather than 5 s. T12 escalates only if measurement contradicts
  this, not to choose it.
- **Whether `web_fetch` should refuse binary outright or return a described placeholder (T4).** The
  card decides refuse-with-a-named-reason; cheap to flip.
- **The stall error must be a NEW, non-retryable exception type (T12) — decided, not open.**
  `retry_exceptions` (`middleware_stack.rb:111-116`) contains `Faraday::TimeoutError` and
  `retry_options` retries `:post`, so reusing a listed type would multiply F7a by four instead of
  fixing it.
- **The panel recommended splitting this chunk in two** — defects (T0–T2, T4–T8, T10, T11) and
  replay-plus-policy (T3, T9, T12, T13, T14) — on the grounds that fourteen cards behind one
  instrument is more than a reviewer can hold at merge time. The chunk is kept whole here because
  that was the scope decision taken at interview, but the cut line is recorded so it can be taken
  later without re-planning: it falls cleanly, with no file overlap between the two halves.

## Waves

```
Wave 1: T0, T2, T4, T5, T6, T7, T8, T9    (no unmet deps)
Wave 2: T1 (←T0), T3 (←T0)
Wave 3: T10 (←T1,T2), T11 (←T1), T12 (←T1), T13 (←T3)
Wave 4: T14 (←T13)
Critical path: T0 → T3 → T13 → T14
```

**T0 is a pre-wave in all but name and should be started first.** Five cards depend on it
transitively, and it is the card whose premise the panel falsified: T1's fake socket is currently
unreachable because `spec/network_posture_spec.rb:57-63` proves loopback is refused. If T0 comes
back saying a narrow allowance is impossible, T1/T10/T11/T12 all need re-specifying — and that news
is worth having on day one rather than in wave 3.

**T2 is not a cosmetic wave-1 card.** It sits beside six banner-and-string fixes but its real
deliverable is the retry seam T10 needs, which puts it on the severity-1 path. Size its review
accordingly.

## Tasks

### T0 — Open exactly one loopback port to the suite                   [wave 1] [risk: high]

**Depends on:** none
**Files:** modify `spec/support/network_access.rb`; modify `spec/network_posture_spec.rb`
**Reuse:** `spec/support/network_access.rb:26-31` (`NetworkAccess.permit`, the existing all-or-
nothing opt-in); `spec/support/vcr_configuration.rb:18`
(`allow_http_connections_when_no_cassette = false`, the line that actually enforces the posture);
`spec/network_posture_spec.rb:57-63` (the committed proof that a localhost Ollama call is refused)
**Shared-file wiring:** none — this card exclusively owns `spec/support/network_access.rb`
**Reachable from:** deferred: test infrastructure, see Open decisions

**This card exists because the panel falsified an assumption the rest of the plan rested on.** T1's
whole premise is an in-process `TCPServer` that a real Faraday client connects to. It cannot,
today: WebMock/VCR intercept at the HTTP-client layer, `vcr_configuration.rb:18` sets
`allow_http_connections_when_no_cassette = false`, and `spec/network_posture_spec.rb:57-63` is a
**committed spec** asserting that a call to `localhost:11434` raises
`VCR::Errors::UnhandledHTTPRequestError` from any untagged example. The fake upstream would never
see a byte.

The only existing way out is `NetworkAccess.permit`, and it is too blunt for this: it does
`WebMock.allow_net_connect!` **and** `VCR.turned_off(ignore_cassettes: true)` process-wide for the
block — so it opens the whole network *and* disables cassettes, which is also why T3 cannot record
an ollama cassette (network and an inserted cassette are currently mutually exclusive).

Provide a **narrow** allowance: permit one loopback host:port for the duration of a block, leaving
the posture intact for every other destination and leaving VCR on. Both consumers need it —
T1's harness needs to be reachable, T3's recording needs network *with* a cassette inserted — and
that is why this is one card owning one file rather than two cards racing on it.

**The existing posture must still be proven.** `spec/network_posture_spec.rb` is the file that
makes the guarantee legible; extend it rather than weakening it.

**Acceptance criteria:**

```gherkin
Scenario: a narrowly permitted port is reachable
  Given a local server listening on an ephemeral loopback port
  When a request is made to that port inside the narrow permission
  Then the request reaches the server

Scenario: everything else stays refused
  Given the same narrow permission is in force for one port
  When a request is made to a different host
  Then it raises the unhandled-request error the posture spec already pins

Scenario: the posture is restored afterwards
  Given a narrow permission has been taken and released
  When a request is made to the previously permitted port
  Then it is refused again

Scenario: a cassette can still record while a port is permitted
  Given a cassette is inserted for recording
  And a narrow permission is in force for the upstream's port
  When a request is made
  Then it reaches the upstream and is recorded to the cassette
```
→ spec file: `spec/network_posture_spec.rb`

**Escalation triggers:**
- If a narrow allowance cannot be expressed without `WebMock.allow_net_connect!` (the blunt
  switch), **stop and escalate** — falling back to the blunt switch means every T1-driven example
  runs with the whole network open, which is a suite-wide posture change and the orchestrator's
  call, not this card's.
- If permitting a port requires disabling VCR, stop: that defeats T3's recording case, which is
  half this card's reason to exist.
- `spec/network_posture_spec.rb` is the repo's statement of what cannot leave the machine. If any
  change here would let a request reach a non-loopback address, stop.

---


### T1 — Build a severable fake streaming upstream for specs          [wave 2] [risk: medium]

**Depends on:** T0
**Files:** create `spec/support/streaming_upstream.rb`; create
`spec/lain/seams/streaming_upstream_spec.rb`
**Reuse:** `spec/support/ollama_wire.rb` (serializes a `Lain::Response` into the Ollama
`/api/chat` body — the NDJSON shape to emit); `spec/support/anthropic_sse.rb` (`events`/`body`,
the SSE shape); `spec/support/socket_tmpdir.rb` (an existing real-socket helper for lifecycle
patterns)
**Shared-file wiring:** none — `spec/spec_helper.rb` already globs `spec/support/**/*.rb`
**Reachable from:** deferred: test infrastructure, see Open decisions

A real `TCPServer` that serves a scripted response and can sever the connection mid-body with
`SO_LINGER 0` (a hard RST, not a clean FIN), in both NDJSON and SSE dialects, with per-connection
scripting so attempt 1 and attempt 2 can differ. This is the instrument WebMock cannot be: it
controls chunk boundaries and can die between them.

**It must be usable from a `:seam` example without leaking a thread or a port.** Bind to port 0 and
report the assigned port; stop the server in an `ensure`; the suite runs 12-wide so a fixed port is
a flake.

**Acceptance criteria:**

```gherkin
Scenario: it serves a complete scripted NDJSON stream
  Given a fake upstream scripted with three assistant-content chunks and a done marker
  When a client reads the whole response
  Then all three chunks arrive in order and the stream terminates normally

Scenario: it severs a connection mid-body
  Given a fake upstream scripted to sever after the second chunk
  When a client reads the response
  Then the client observes a connection reset rather than a clean end of stream

Scenario: successive connections can be scripted differently
  Given a fake upstream that severs its first connection mid-body after a whole chunk
  And serves its second connection completely with different content
  When two connections are made in turn
  Then the first ends in a connection reset partway through its scripted body
  And the second delivers its full scripted body

Scenario: it serves SSE as well as NDJSON
  Given a fake upstream in SSE dialect scripted with a message_start and two text deltas
  When a client reads the response
  Then the events arrive as separate SSE frames
```
→ spec file: `spec/lain/seams/streaming_upstream_spec.rb`

The spec lives in `spec/lain/seams/` because it drives a real socket and belongs to no `lib/`
subject — `spec/lain/support/` would mirror a `lib/lain/support/` that does not exist.

**The loopback question is already answered — do not re-derive it.** `spec/network_posture_spec.rb:57-63`
is a committed spec proving a `localhost:11434` call raises `VCR::Errors::UnhandledHTTPRequestError`
from any untagged example, so a real Faraday client pointed at this server would never open a
socket. **T0 provides the narrow permission this harness runs inside**; use it, and do not reach for
`NetworkAccess.permit`, which opens the whole network and turns VCR off.

**Define only, at load.** CLAUDE.md: *"never park the harness in `spec/support/`: `spec_helper.rb`
globs `support/**/*.rb`, so it loads in every worker of every run."* This file is legal there only
if loading it does nothing — no `RSpec.configure`, no thread, no port bind, no `Dir.chdir`. Bind
inside the example, in an `ensure`-protected helper.

**Escalation triggers:**
- If T0's narrow permission turns out not to cover the ephemeral port this server binds (it binds
  port 0 and learns the port afterwards, so the permission must be takeable *after* the bind),
  stop — that is a T0 contract failure and working around it re-opens the whole network.
- If `WebMock` intercepts the loopback connection despite T0's permission, stop: the harness is not
  measuring what it claims, and every wave-3 card built on it would be measuring nothing.
- If a bound port leaks between examples under `rake pspec`'s 12-way parallelism, stop — a fixed
  port is a flake and a leaked thread is worse.

---

### T2 — Give Ollama the retry seam it lacks                          [wave 1] [risk: medium]

**Depends on:** none
**Files:** modify `lib/lain/provider/ollama.rb`; modify `spec/lain/provider/ollama_spec.rb`
**Reuse:** `lib/lain/provider/anthropic/retry_tap.rb` (the per-request, non-instance-state pattern
and its reasoning about concurrent round trips); `lib/lain/telemetry/provider_retry.rb`;
`lib/lain/provider/anthropic.rb:103` (`config.retry_block = @retries.retry_block`)
**Shared-file wiring:** `lib/lain/cli/backend.rb:181` — pass `channel:` to
`Provider::Ollama.new`, matching the Anthropic construction at `:387`
**Reachable from:** `CLI::Backend#provider` → `Provider::Ollama.new(api_base:, channel:)` at
`cli/backend.rb:181`

Accept a `channel:` and wire `config.retry_block` so a retried attempt pushes a
`Telemetry::ProviderRetry`. Today an Ollama retry is completely invisible, which is why F7's
400-second hang printed nothing at all.

This card delivers observability. It also establishes the hook **T10** needs to reset the
assembler, so the seam must be per-request and reentrant — read `RetryTap`'s docstring on why the
live frame cannot live in instance state, because the same argument applies here.

Update the `deliberately absent: a channel:` note at `ollama.rb:43-47`. It documented a real
decision and that decision is being reversed; leaving it would make the file lie.

**Acceptance criteria:**

```gherkin
Scenario: a retried Ollama request is journaled
  Given an Ollama provider constructed with a recording channel
  And a transport whose first attempt fails with a retryable error and whose second succeeds
  When a completion is requested
  Then a provider-retry telemetry event naming the attempt number is pushed to the channel

Scenario: a provider without a channel still completes
  Given an Ollama provider constructed with no channel
  When a completion is requested over a transport that succeeds
  Then the response is returned and nothing raises

Scenario: the retry hook fires per request rather than per provider
  Given one Ollama provider used for two separate completions
  When each completion retries once
  Then each completion's telemetry names its own attempt, and neither reports the other's

Scenario: the production path actually passes a channel
  Given a backend built for the ollama provider through the normal CLI wiring
  When its provider is constructed
  Then that provider journals a retry to the run's channel
```
→ spec files: `spec/lain/provider/ollama_spec.rb`, `spec/lain/cli/backend_spec.rb`

The last scenario is the one that matters most and is the easiest to skip: the first three pass
against an injected channel whether or not `cli/backend.rb:181` was ever changed. **A card that
adds a keyword with a safe default and never wires it has shipped nothing, greenly.**

**Escalation triggers:**
- `spec/lain/provider/ollama_spec.rb` and `spec/support/shared_examples/provider_parity.rb` may
  assert the current constructor arity or the absence of a channel. A parity shared example that
  pins "ollama journals nothing" is a **deliberate** assertion being reversed — stop and confirm.
- If wiring a channel changes what `lain bench arms` records for the ollama arm, that is a bench
  comparability change, not a bug fix. Stop and report it.

---

### T3 — Make the VCR harness able to record ollama                   [wave 2] [risk: medium]

**Depends on:** T0
**Files:** modify `spec/support/vcr_configuration.rb`, `spec/support/tags.rb`,
`spec/support/ollama_probe.rb`, `spec/support/ollama_tag.rb`; create
`spec/lain/vcr_ollama_posture_spec.rb`
**Reuse:** `spec/support/network_access.rb` (`NetworkAccess.permit`, the only sanctioned network
opt-in); `spec/network_posture_spec.rb` (the existing posture-proving idiom to copy)
**Shared-file wiring:** none — this card exclusively owns the four support files above
**Reachable from:** deferred: test infrastructure, see Open decisions

Clear the five recording blockers found in grounding, and prove each is cleared with a posture
spec rather than by assertion:

1. `tags.rb:53-56` — `LAIN_RECORD=1` must not demand `ANTHROPIC_API_KEY` when what is being
   recorded is a local ollama. Gate the key requirement on the provider being recorded.
2. `ollama_probe.rb` — its global `GET /api/ps` stub must yield to a cassette that has one, and
   keep covering every example that has none. The file's own comment explains the empty
   `{"models":[]}` body was chosen so it "changes no measurement"; preserve that property.
3. `match_requests_on: %i[method uri]` — every ollama turn is `POST /api/chat`, so a multi-turn
   cassette needs sequential playback. Change the matcher **only for ollama cassettes**, not
   globally: `vcr_configuration.rb:32` notes the global choice is deliberate because body parity
   is covered elsewhere by the SDK-oracle diff.
4. `NetworkAccess.permit` disables recording via `VCR.turned_off(ignore_cassettes: true)` — a
   recording path needs network *and* an inserted cassette, which `permit` currently makes
   mutually exclusive.

   > **CORRECTED 2026-08-17 by T0's review — read this before starting.** This card's implied fix
   > is wrong. **`permit_loopback` is a NO-OP on the recording path and buys T3 nothing.** Measured:
   > a `record: :all` cassette records real bytes from a socket with **no permission held at all**,
   > because a recording-mode cassette already sets `VCR.real_http_connections_allowed?` true for
   > **every host**. T3's real work is *removing the call to `.permit`* — whose
   > `VCR.turned_off(ignore_cassettes: true)` was destroying the cassette — not adding a call to
   > `permit_loopback`. Adding it anyway narrows nothing: inside a recording cassette the egress
   > authority is the cassette, and the cassette is unbounded by host. If T3 wants a narrow window
   > it must scope the cassette, not the permission.
   >
   > Two constraints either way: `permit_loopback` covers a **loopback** `OLLAMA_API_BASE` only —
   > the default `http://localhost:11434` qualifies, a remote base does not — and the port must be
   > derived from the base (`URI(OLLAMA_API_BASE).port`), never hardcoded to `11434`.
5. Keep `:ollama` gating where it lives; do not merge `ollama_tag.rb` into `tags.rb` as a
   drive-by.
6. **`vcr_configuration.rb:18` — `allow_http_connections_when_no_cassette = false`.** This, not
   `NetworkAccess.permit`, is the line that actually enforces the offline posture, and it is at the
   top of a file this card owns. **T0 owns the narrow permission**; this card owns making recording
   work with a cassette inserted.

Note blocker #2 is **partly solved already** and the grounding pass nearly missed it:
`ollama_probe.rb:18-22` documents that WebMock matches the **most recently registered** stub first,
so a per-example stub already beats the global one — and that an example asserting the probe was
never made must reset WebMock. Read that comment before rewriting the file.

**Acceptance criteria:**

```gherkin
Scenario: an ollama cassette replays without a real server
  Given a recorded ollama chat cassette
  And no ollama server reachable
  When an example tagged for that cassette runs
  Then the provider returns the recorded response and no network connection is attempted

Scenario: repeated identical requests replay in sequence
  Given a cassette holding two different responses to the same POST /api/chat URI
  When two completions are requested in turn
  Then the first and second recorded responses are returned in that order

Scenario: the process-status probe stub yields to a cassette
  Given a cassette that records a GET /api/ps response naming a served context length
  When a provider asks for its context window inside that cassette
  Then the cassette's value is used rather than the global empty-models stub

Scenario: recording an ollama cassette does not require an Anthropic key
  Given LAIN_RECORD is set and no ANTHROPIC_API_KEY is present
  When the suite boots for an ollama recording
  Then it does not raise about a missing key
```
→ spec file: `spec/lain/vcr_ollama_posture_spec.rb`

**Escalation triggers:**
- `spec/support/tags.rb` gates **eight** tags (nine counting `ollama_tag.rb`). Any change there can silently re-enable an
  excluded tier — `:api_integration` costs money and `:live` costs money. If a change would alter
  which tags run by default, stop and report the exact diff.
- If making the `/api/ps` stub cassette-aware requires reordering `spec/support` loading, note
  that `spec_helper.rb:20` deliberately holds `require "webmock/rspec"` outside `support/` because
  the glob loads alphabetically. Do not move it.
- If `record: :new_episodes` starts appending to the existing Anthropic cassette during an ollama
  recording, stop — that cassette is the only one the suite has and it is filtered for secrets.

---

### T4 — Decode `web_fetch` bodies instead of raising on them          [wave 1] [risk: medium]

**Depends on:** none
**Files:** modify `lib/lain/tools/web_fetch.rb`; modify `spec/lain/tools/web_fetch_spec.rb`
**Reuse:** `references/repos/mempalace/mempalace/format_miner.py:197` (`decode_robust`, the
UTF-8 → CP1252 → scrub ladder, vendored and already read); `lib/lain/canonical.rb` (the `utf8`
contract this must satisfy — do **not** change it)
**Shared-file wiring:** none
**Reachable from:** `CLI::Wiring::BaseTools` constructs `Tools::WebFetch` into the base toolset;
the tool is called on the real turn path with a real Faraday connection

Fix F1: the tool must hand `Tool::Result.ok` a string that `Canonical.utf8` accepts. Three parts,
and the order matters:

1. **Decide whether the body is text at all**, from `Content-Type`. Verified during research: the
   decode ladder never fails, so a PNG becomes `‰PNG` — a binary body must be refused by name, not
   decoded into plausible garbage. (See Open decisions: refuse rather than placeholder.)
2. **Take the charset from the response** when it names one; fall back to the ladder.
3. **Truncate on a character boundary.** The existing cap aborts the read mid-body
   (`web_fetch.rb:79-87`, the `raise Reached` is at `:85`), which can split a multi-byte character; verified that the CP1252 rung
   then turns the split into believable mojibake (`cafÃ`) rather than a visible loss.

**The spec change is the point, not a detail.** `WebFetchStubConnection` returns Ruby string
literals, which are UTF-8, so the current specs cannot reproduce this defect at all. The stub must
hand back `ASCII-8BIT` bytes the way a real socket does — otherwise this card ships green against
the same blind spot that let F1 through.

**And it must hand back MORE THAN ONE chunk**, with at least one boundary splitting a multi-byte
character. `ByteCap` initialises `@bytes = +""` — a UTF-8 String under `# frozen_string_literal:
true` — and appends chunks with `<<`, so the buffer's final encoding already depends on which chunk
carried high bytes and in what order. A single-chunk stub reproduces the tagging bug and **not** the
truncation bug, which would make AC3 pass vacuously.

**Acceptance criteria:**

```gherkin
Scenario: a page containing non-ASCII text is returned as valid UTF-8
  Given a stub connection returning ASCII-8BIT bytes for a page containing "café"
  When web_fetch fetches that page
  Then the result is ok and its text is valid UTF-8 containing "café"

Scenario: the result survives canonicalisation
  Given a stub connection returning ASCII-8BIT bytes containing a CP1252 smart quote
  When web_fetch fetches that page
  Then canonicalising the result does not raise

Scenario: a body truncated at the cap does not split a character
  Given a byte cap that falls in the middle of a multi-byte character
  When web_fetch fetches that page
  Then the returned text is valid UTF-8 and ends at the last whole character

Scenario: a binary body is refused by name
  Given a stub connection returning PNG bytes with an image content type
  When web_fetch fetches that URL
  Then the result is an error naming the content type rather than decoded bytes
```
→ spec file: `spec/lain/tools/web_fetch_spec.rb`

**Escalation triggers:**
- If any fix appears to belong in `Canonical` — stop. `Canonical` refusing non-UTF-8 is the whole
  point of deterministic bytes serving both turn hashing and cache stability; the research
  document is explicit that the tool is what knows it fetched text.
- The boundary truncation belongs inside `ByteCap#accept` (`web_fetch.rb:79-87`), **before** the
  `raise Reached` at `:85` — the cap must round *down* to a character boundary, so the returned byte
  count becomes ≤ the cap rather than == it. If an existing spec asserts an exact byte count, that
  is the assertion this changes; confirm before editing it.

---

### T5 — Name the command the survey actually answers to               [wave 1] [risk: low]

**Depends on:** none
**Files:** modify `lib/lain/cli/command/survey.rb`, `lib/lain/cli/command/review.rb`,
`lib/lain/frontend/neovim/runtime/65_review.lua`, `plugin/nvim/doc/lain.txt`; modify
`spec/lain/cli/command/survey_spec.rb`, `spec/lain/cli/command/review_spec.rb`
**Reuse:** `lib/lain/review/vocabulary.rb:84` (`VERDICTS = %w[approve]` — read the verdict from
there, do not restate it); `lib/lain/frontend/neovim/runtime/46_sidebar.lua:188`
(`:LainReviewVerdict`, the command that actually exists)
**Shared-file wiring:** none
**Reachable from:** `CLI::Command::Survey` prints `OPENED` when a survey opens — the banner a
human reads on the real path

Fix F4. Both banners advertise `:LainReviewDone`, which is a **protocol-5 epic** command whose
guard (`65_review.lua:93-98`) requires `b:lain_review_epic_slug` — a variable the survey never
stamps. The command a survey hand-back needs is `:LainReviewVerdict approve`.

Two things beyond the string:

- **Add specs that pin the banner.** Grounding found that `survey_spec.rb:289-293` asserts only
  `include("lain://review")`, so renaming the command breaks nothing. That gap is why the banner
  drifted from the protocol in the first place.
- **Make `:LainReviewDone`'s refusal a lain refusal.** It currently surfaces as a raw Lua stack
  traceback, which reads as a plugin crash rather than a considered "wrong surface". Compare
  `46_sidebar.lua:188-192`, which already `pcall`s exactly so a refusal becomes the human's answer.

`plugin/nvim/doc/lain.txt` documents all five command names and
`spec/plugin/nvim_plugin_spec.rb:368-375` enforces runtime/helpdoc parity by scanning the runtime
for `define(...)` — so the helpdoc is part of this card, not a follow-up.

**Check the other half of the same sentence.** The banner also says *":LainNote annotates"*, and
`LainNote` is defined in `48_annotate.lua:357` while the epic surface's annotate verb is
`LainAnnotate` (`65_review.lua:64`) — the same protocol-mismatch shape as F4, in the same string.
Either prove `:LainNote` reaches a survey buffer or fix it too; the card may not take it on faith,
because "the duplication is the actual defect" applies to that clause as much as the other.

**Acceptance criteria:**

```gherkin
Scenario: the survey banner names a command the survey can answer
  Given a survey is opened
  When the opening message is rendered
  Then it names :LainReviewVerdict and does not name :LainReviewDone

Scenario: the review banner names the same command
  Given a changeset review is opened
  When the opening message is rendered
  Then it names :LainReviewVerdict

Scenario: the banner names the verdict command with an argument
  Given a survey is opened
  When the opening message is rendered
  Then it names :LainReviewVerdict followed by a verdict drawn from Review::VERDICTS

Scenario: the annotate command in the same banner reaches a survey buffer
  Given a lain://review buffer opened by a survey
  When the annotate command the banner names is invoked
  Then it is accepted rather than refused as belonging to another surface

Scenario: the epic command refuses a survey buffer without a traceback
  Given a lain://review buffer opened by a survey
  When :LainReviewDone is invoked
  Then the human is told which surface the command belongs to, and no Lua stack traceback is shown
```
→ spec files: `spec/lain/cli/command/survey_spec.rb`,
`spec/lain/cli/command/review_spec.rb`, `spec/lain/frontend/neovim_runtime_spec.rb`

**Escalation triggers:**
- The assertion that actually enforces helpdoc/runtime parity is
  **`spec/plugin/nvim_plugin_spec.rb:368-375`**, which scans `define("(\w+)"` out of the runtime
  source — that is what a rename trips. `neovim_runtime_spec.rb:735,762` are **protocol-history**
  assertions (read from `frontend/neovim.rb`'s comment block via `spec/support/protocol_history.rb`),
  not helpdoc ones; `:762` pins protocol 10's `LainReviewMark`/`LainReviewVerdict`. If a
  protocol-history assertion fails, the history comment is in scope — but history may not be
  rewritten to match a change, only appended to.
- `:LainReviewDone` must stay documented for the **epic** surface. This card renames what the
  survey advertises, not what the epic surface offers.
- If the epic review surface turns out to also print one of these banners, the two surfaces need
  different text and this card's "both files say the same thing" premise is wrong. Stop.

---

### T6 — Make a mark acknowledgement readable in a narrow pane         [wave 1] [risk: low]

**Depends on:** none
**Files:** modify `lib/lain/review/surface/neovim.rb`, `lib/lain/review/surface/text.rb`; modify
`spec/lain/review/surface/neovim_spec.rb`, `spec/lain/review/surface/text_spec.rb`
**Reuse:** `lib/lain/review/vocabulary.rb` (`MARK_STATES`); the existing `PARTLY_MARKED` constant
(`neovim.rb:175-176`) as the shape for a human-scaled message
**Shared-file wiring:** `spec/support/shared_examples/review_surface.rb:273-285` — probably none:
the shared example matches only the state word, which the new message keeps. Hand back a one-line
change only if it turns out otherwise
**Reachable from:** `Review::Session#mark` → `@surface.mark` (`review/session.rb:350-356`) →
`Surface::Neovim#mark` (`neovim.rb:250`), echoed at `65_review.lua:37`

Fix F5. `MARKED = "%<hunk_key>s is now %<state>s"` (`neovim.rb:169`) renders to 102 characters,
because the key is a 64-hex-character content digest. The review pane in a three-way cockpit split
is 40 columns, so it wraps, so nvim raises `Press ENTER or type command to continue` — which stops
the review **and blocks RPC** on every single mark.

78 % of that message is a digest a human cannot act on.

**The file name is NOT available here, so do not try to use it.** `Surface::Neovim#mark`
(`neovim.rb:250`) takes `(hunk_key, state)` and `Review::Session#mark` (`session.rb:350-358`) sends
exactly those two — no path carries a file name. Truncating the digest to a short prefix is what
fits and what this card does; routing a file name here is a message-design change and belongs to a
different card.

Keep the state word. `spec/support/shared_examples/review_surface.rb:273-285` word-boundary-matches
it, and that protects a real distinction (`reviewed` vs `unreviewed`). Note it asserts **only** the
state word — nothing about the key, "is now", or exact equality — so any replacement containing
`reviewed`/`unreviewed` satisfies it, and the shared-file hand-back below is probably a no-op. It
binds **two** surfaces, not every one: `neovim_spec.rb:171` and `text_spec.rb:50` include the group;
`null_spec.rb:9` passes `transcript: :no_observation_channel` and skips the example, and
`message_spec.rb` does not include the group at all.

**Acceptance criteria:**

```gherkin
Scenario: a mark acknowledgement fits a narrow pane
  Given a hunk key that is a 64-character content digest
  When the neovim surface acknowledges a mark
  Then the message is under 60 characters

Scenario: the acknowledgement still identifies what was marked and how
  Given a row whose hunk key is a 64-character content digest is marked reviewed
  When the surface acknowledges it
  Then the message contains a leading prefix of that key and the state "reviewed"

Scenario: the text surface stays consistent with the neovim surface
  Given the same mark on the text surface
  Then its acknowledgement names the same file and state
```
→ spec files: `spec/lain/review/surface/neovim_spec.rb`,
`spec/lain/review/surface/text_spec.rb`

**Escalation triggers:**
- `spec/lain/review/surface/neovim_spec.rb:315` asserts **exact equality** on
  `"hunk-content-v1:deadbeef is now reviewed"`. That is a deliberate pin on the whole string;
  changing it is in scope, but if the same string is asserted anywhere that implies a **wire**
  contract rather than a human message, stop.
- If a truncated key is ambiguous between two rows in a real survey, stop and report: a short
  message naming the wrong unit is worse than a long one naming the right unit.
- `Surface::Message` (`spec/lain/review/surface/message_spec.rb`) does not include the shared
  example group. If it also emits a mark acknowledgement, say whether it needs the same treatment
  rather than silently leaving one surface long.

---

### T7 — Let `lain sessions` show that a session is damaged            [wave 1] [risk: low]

**Depends on:** none
**Files:** modify `lib/lain/cli/sessions.rb`; modify `spec/lain/cli/sessions_spec.rb`
**Reuse:** `lib/lain/journal.rb:118-143` (`Journal.parse` / `Journal.records` and the skipping
contract — read the comment before changing any behaviour); `cli/sessions.rb:59-61` (the existing
"listed honestly rather than skipped" principle, which this extends)
**Shared-file wiring:** none
**Reachable from:** `CLI#sessions` → `CLI::Sessions#to_s`, the listing a human reads

Fix F6. A torn `turn` record is silently dropped, so the listing shows one fewer turn under the
**same** head digest, with no indication anything is wrong. This is an observability gap, not a
correctness one — verified that forking a damaged session refuses precisely, naming the record
index and both digests. Nothing wrong can be *built* on the damage; it just cannot be *seen*.

Do not change the skipping contract. `Journal.records` skips foreign bytes because the fd can be
shared with Rust tracing spans, and that reasoning is sound. Report the skip instead of preventing
it.

**Acceptance criteria:**

```gherkin
Scenario: a session with an unparseable line reports how many were skipped
  Given a session file with two unparseable lines among valid records
  When sessions are listed
  Then that session's row names the number of unreadable lines

Scenario: an intact session is not marked
  Given a session file whose every line parses
  When sessions are listed
  Then its row carries no damage indication

Scenario: a damaged session is still listed
  Given a session file with a torn turn record
  When sessions are listed
  Then the session appears with its name and status
```
→ spec file: `spec/lain/cli/sessions_spec.rb`

**Escalation triggers:**
- The count has exactly one legal home: a counting wrapper around the enumerable
  `Journal.records` already walks, or an out-parameter through it. **Do not add a second pass.** The
  current read is lazy (`Journal.records(File.foreach(path))` streams) and a listing that loads
  every session into memory is a worse defect than the one being fixed. If neither shape works
  without changing `Journal.records`' signature for its other callers
  (`Effect::Handler::Recorded.from_journal`, `Ledger::Index.from_journal`), stop and report.
- If any existing spec asserts the exact column layout of a row, adding a column changes it.
  Confirm the format is not parsed by anything downstream before widening it.

---

### T8 — Say when no search backend is configured                      [wave 1] [risk: low]

**Depends on:** none
**Files:** modify `lib/lain/tools/web_search.rb`; modify `spec/lain/tools/web_search_spec.rb`
**Reuse:** `lib/lain/sink/null.rb` (the codebase's Null Object exemplar — the doctrine this must
not weaken)
**Shared-file wiring:** none
**Reachable from:** `CLI::Wiring::BaseTools` constructs `Tools::WebSearch` with its default
`Backend::Null` — the unconfigured state on the real path

Fix F2. `Backend::Null = ->(_query) { [] }` is indistinguishable from a real backend that searched
and found nothing, so the model has no signal that searching is futile. In the QA run it searched
six times, then fell back to `web_fetch`, which is what hit F1.

The Null backend's own comment says it is named so the unconfigured state is "legible in a
rendered result" — this card makes that true. **This strengthens the Null Object, it does not
weaken it:** `Sink::Null` satisfies its duck and sends bytes nowhere; it does not claim to have
written them. A Null search backend that reports "nothing found" is claiming to have looked.

**The shape to build: Null answers a different VALUE, not a different interface.** The duck is
documented as "any object responding to `#call(query)`" (`web_search.rb:35-37`) and `Null` is a
lambda, so "give Null a way to describe itself" means a second method — widening the duck for every
backend — while `@backend.equal?(Backend::Null)` at `perform` is a type check wearing a hat. Both
are rejected. Let `Null` return a distinguishable sentinel result that `render` knows how to speak:
`perform` (`:59-66`) already branches on `results.empty?`, the duck stays one method, and the
decision lives in the value. That is `Sink::Null`'s doctrine intact — the Null Object does its job
**and reports what it did**.

**Acceptance criteria:**

```gherkin
Scenario: an unconfigured backend says so
  Given a web_search tool with no backend wired
  When a search is performed
  Then the result says no search backend is configured

Scenario: a configured backend that finds nothing says that instead
  Given a web_search tool with a backend that returns no results
  When a search is performed
  Then the result reports no results for the query, and does not claim the backend is unconfigured

Scenario: a configured backend with results is unaffected
  Given a web_search tool with a backend returning two results
  When a search is performed
  Then both results are rendered
```
→ spec file: `spec/lain/tools/web_search_spec.rb`

**Escalation triggers:**
- If distinguishing the two cases requires every backend to implement a new method, stop — the duck
  must stay `#call(query)` alone, and a sentinel value is the way to avoid widening it.
- If a real backend could legitimately return the sentinel, it is the wrong sentinel: it must be
  unconstructible by an ordinary backend result.

---

### T9 — Never let a GUESSED window authorise a rewrite                [wave 1] [risk: high]

**Depends on:** none
**Files:** modify `lib/lain/context_window.rb`, `lib/lain/compaction/source.rb`,
`lib/lain/cli/backend/window_book.rb`; modify `spec/lain/context_window_spec.rb`,
`spec/lain/compaction/source_spec.rb`, `spec/lain/cli/backend/window_book_spec.rb`; create
`spec/lain/seams/compaction_window_spec.rb`
**Reuse:** `references/ollama/api-show-and-context.md` (why the window is unknowable before a
runner is resident — this card's rationale); `context_window.rb:57-77` (the reasoning this amends);
`lib/lain/cli/backend/window_book.rb:128-134` (`#book`, the only place a PROBED window is built)
**Shared-file wiring:** none — `cli/backend.rb:259` already calls `WindowBook.new(backend: self).book`
and needs no change; the provenance travels inside the book it already returns
**Reachable from:** `CLI::Backend#context_window` (`cli/backend.rb:259`) → `WindowBook#book` →
`Compaction::Source#window_for` (`compaction/source.rb:296`) → `Need#check` → the compaction mount
at `cli/backend.rb:451`

Fix F3. `CONSERVATIVE_FALLBACK = 8_192` made turns at 75–78 % of the real 32768 window read as
300 %, so `approaching_window` fired and lain **rewrote history three times**.

The existing comment (`context_window.rb:57-77`) reasoned this through and accepted it as
*"self-correcting, not a one-shot latch"*. That argument is about **frequency** and it is correct.
What it does not cover is **damage**: each firing is an irreversible lossy rewrite, so
self-correcting-per-turn still destroys context three times.

**Provenance is THREE-valued, not two.** The panel caught a binary split as a latent regression:
`Provider#context_window_tokens` returns nil (`provider.rb:77-79`) and is overridden **only** by
`ollama.rb:189`, so every Anthropic and Bedrock run reads a `DEFAULTS` table entry. Calling a table
hit "not measured" would stop `:approaching_window` firing for every hosted arm — and
`Compaction::Scheduler#forced?` (`scheduler.rb:248`) reads that same signal, so forcing behaviour
would change silently too.

The three values fall straight out of code that already exists. `ContextWindow#window_tokens`
(`context_window.rb:206-214`) is literally three branches —
`@windows.fetch(name) { matched(name) || @fallback || unknown!(model) }` — and `WindowBook#book`
adds the fourth case above them:

| provenance | where it comes from | fires `approaching_window`? |
|---|---|---|
| **probed** | `WindowBook::Served`, from Ollama's `/api/ps` | **yes** |
| **published** | a `DEFAULTS` hit or `matched(name)` prefix — a real published number | **yes** |
| **guessed** | the `@fallback` branch, i.e. `CONSERVATIVE_FALLBACK` | **no** |

Only the *guess* is suppressed. Anthropic and Bedrock behaviour is unchanged, which is the point.

**Provenance cannot ride inside the number.** `Need#window!` (`need.rb:163-168`) does
`Integer(window_tokens, exception: false)`, which flattens any wrapper, and
`spec/lain/compaction/need_spec.rb:152` pins that `check(window_tokens: "1000")` coerces a String —
so the parameter's type may not change. Carry provenance as its own value alongside the integer
through `Source#window_for` / `#decide`. Note `Need#check` has a second caller outside the CLI path:
`lib/lain/bench/plan_sweep/driver.rb:167`.

Amend the comment at `context_window.rb:57-77`. It is load-bearing and will be half-wrong after this
card.

**Acceptance criteria:**

```gherkin
Scenario: a guessed window does not fire the approaching-window trigger
  Given a context window that fell back because no table entry matched the model
  And usage above the trigger ratio for that fallback
  When the compaction need is evaluated
  Then the approaching-window trigger does not fire

Scenario: a published table window still fires it
  Given a model with a shipped context-window entry
  And usage above the trigger ratio
  When the compaction need is evaluated
  Then the approaching-window trigger fires

Scenario: a probed window still fires it
  Given a served window probed from the provider
  And usage above the trigger ratio
  When the compaction need is evaluated
  Then the approaching-window trigger fires

Scenario: the hard cap is unaffected by provenance
  Given a guessed window and usage above the hard cap
  When the compaction need is evaluated
  Then the hard-cap trigger fires

Scenario: a real backend on an unknown model does not rewrite history
  Given a backend built through the normal CLI wiring whose model matches no shipped entry
  And a provider that reports no served window
  And a turn whose usage exceeds the fallback's trigger ratio
  When the turn is accounted
  Then no approaching-window compaction is journaled
```
→ spec files: `spec/lain/context_window_spec.rb`, `spec/lain/compaction/source_spec.rb`,
`spec/lain/cli/backend/window_book_spec.rb`, `spec/lain/seams/compaction_window_spec.rb`

The last scenario walks the exact path QA broke, end to end, and is the only one that fails if
provenance is computed correctly but never reaches `Need`. It lives in a **new seam spec** rather
than `spec/lain/cli/backend_spec.rb`, deliberately: T2 also writes a production-path example and
that 62 KB file would be a two-card collision in one wave.

**Escalation triggers:**
- `context_window.rb:60-62` argues an over-estimate is "worse than the crash it replaces". This card
  suppresses one trigger; it must never raise the fallback number. If the implementation drifts
  toward raising it, stop.
- If threading provenance through `Source#window_for` and `#decide` turns out to touch more than
  those two methods — in particular if `Need::State` (`need.rb:31`, a `private_constant`) must grow
  a field — stop and report. That is a design change beyond this card.
- `spec/lain/compaction/need_spec.rb` may assert `ApproachingWindow#fired?` is a pure function of
  used and window tokens. Adding provenance changes that contract; confirm before editing it.
- If `WindowBook::Served#window_tokens` (`window_book.rb:86-87`) falling through to `@shipped` for a
  non-matching model makes provenance ambiguous for that model, stop — a Served book answering for
  a model it did not probe is **published**, not **probed**, and getting that backwards re-creates
  the bug in the opposite direction.


### T10 — Stop the Ollama assembler splicing two attempts              [wave 3] [risk: high]

**Depends on:** T1, T2
**Files:** modify `lib/lain/provider/ollama.rb`, `lib/lain/provider/ollama/stream_assembler.rb`;
modify `spec/lain/provider/ollama_streaming_spec.rb`
**Reuse:** T1's `StreamingUpstream` helper; T2's `retry_block` seam on the Ollama config;
`lib/lain/provider/anthropic/retry_tap.rb` (the rotation pattern and its concurrency reasoning);
`spec/lain/provider/anthropic/retry_tap_spec.rb` (how to test a per-request retry hook without
instance state); **`spec/lain/provider/ollama/streamed_failure_spec.rb:5-9`** — read this first: it
already names *"the same handler being replayed by faraday-retry"* as one of the two shapes
unreachable under WebMock. **This bug was anticipated in a spec comment and never chased.**
**Shared-file wiring:** none
**Reachable from:** `Provider::Ollama#complete` → `#stream_body`, on the real streaming path
built at `cli/backend.rb:181`

Fix F7b — **measured silent corruption.** `stream_body` (`ollama.rb:238-241`) builds the assembler
outside `@transport.stream`, and faraday-retry runs inside it, so an abandoned attempt's bytes stay
in the assembler and the retry appends to them. Proven: a severed attempt followed by a clean retry
returned `ok` with both attempts' text concatenated.

Ollama's NDJSON has no `message_start`-equivalent marker, so there is nothing in the protocol to
reset on — unlike SSE, which is why the Anthropic path survives the simple case. The reset must be
driven by the retry hook.

`RetryTap`'s docstring already states the invariant: *"a retried attempt must never share a WAL
frame with the one it replaced… the byte-count check cannot catch two concatenated attempts."*
This card applies that same invariant one layer up.

**Acceptance criteria:**

```gherkin
Scenario: a retried stream returns only the retry's content
  Given a fake upstream that severs its first connection after two content chunks
  And serves its second connection completely with different content
  When a completion is requested
  Then the response contains only the second connection's content

Scenario: a stream that never retries is unchanged
  Given a fake upstream that serves one complete stream
  When a completion is requested
  Then the response contains exactly that stream's content

Scenario: a retry that exhausts the budget raises rather than returning spliced content
  Given a fake upstream that severs every connection
  When a completion is requested
  Then an error is raised and no partial content is returned as a success
```
→ spec file: `spec/lain/provider/ollama_streaming_spec.rb`

**Escalation triggers:**
- If the fix appears to require disabling retries for Ollama entirely, stop and report — that is a
  policy change (the plan chose reset-plus-stall-detection over no-retry) and it belongs to the
  orchestrator, not this card.
- `spec/lain/provider/ollama/streamed_failure_spec.rb:5-9` exists specifically because WebMock
  delivers a body as one chunk. If a new assertion there passes under WebMock, it is not testing
  what this card fixes — use T1's harness.
- If `StreamAssembler` turns out to be shared across concurrent round trips, stop: `RetryTap`'s
  docstring explains why per-provider instance state is wrong for exactly this reason.

---

### T11 — Drop orphaned blocks from a retried Anthropic stream         [wave 3] [risk: high]

**Depends on:** T1
**Files:** modify `lib/lain/provider/anthropic/stream_assembler.rb`; modify
`spec/lain/provider/anthropic/stream_assembler_spec.rb`; **create**
`spec/lain/provider/anthropic_streaming_spec.rb` (it does not exist today — `spec/lain/provider/`
holds `anthropic_spec.rb`, `anthropic_wire_spec.rb`, `anthropic_parity_spec.rb`,
`anthropic_recorded_spec.rb`, `anthropic_reference_spec.rb`, `anthropic_encoding_spec.rb` and
`anthropic/{retry_tap,stream_assembler}_spec.rb`; the name mirrors the existing
`ollama_streaming_spec.rb`)
**Reuse:** T1's `StreamingUpstream` helper in SSE dialect; `spec/support/anthropic_sse.rb`
(existing SSE event shapes); `anthropic/stream_assembler.rb:81-85` (`on_block_start`, the indexed
replacement that already provides partial protection);
`spec/lain/provider/anthropic/retry_tap_spec.rb` (already demonstrates testing per-request
retry-hook behaviour without instance state — the pattern both this card and T10 need)
**Shared-file wiring:** none
**Reachable from:** `Provider::Anthropic#stream_dispatch` (`anthropic.rb:127-138`) and
`Provider::Bedrock#stream_dispatch` (`bedrock.rb:115-118`) — **both**, since Bedrock reuses this
exact class

Fix F7c. The Anthropic assembler survives the simple retry because `on_block_start` replaces
`@blocks[index]`. It does **not** survive a retry that opens fewer blocks than the attempt it
replaced: a block index the retry never re-opens is never overwritten and rides into the response.
Measured — the orphan appeared in the final text with `stop_reason: :end_turn` and clean usage.

The realistic form is worse than duplicated prose: an attempt that got partway into a `tool_use`
block before the reset leaves a **phantom tool call** in the assistant message.

This is one class serving two providers; Bedrock needs no change of its own but **must** be
covered by an acceptance criterion, or the fix's reach is unverified.

**Acceptance criteria:**

```gherkin
Scenario: a block the retry does not reopen is discarded
  Given a fake SSE upstream whose first connection opens two content blocks then severs
  And whose second connection opens only the first block and completes
  When a completion is requested
  Then the response contains only the second connection's block

Scenario: a phantom tool call does not survive a retry
  Given a first connection that opens a tool_use block and severs before completing it
  And a second connection that completes with text only
  When a completion is requested
  Then the response carries no tool_use block

Scenario: a normal multi-block response is unaffected
  Given a single complete stream carrying a text block and a tool_use block
  When a completion is requested
  Then both blocks are present in order

Scenario: the same protection covers Bedrock
  Given a Bedrock provider over a stream that severs and retries with fewer blocks
  When a completion is requested
  Then the response contains only the retry's blocks
```
→ spec files: `spec/lain/provider/anthropic/stream_assembler_spec.rb`,
`spec/lain/provider/anthropic_streaming_spec.rb`

**Escalation triggers:**
- `RetryTap` already rotates the WAL frame on retry. If the assembler reset can be driven from the
  same hook, prefer that — but if doing so would make the frame rotation and the assembler reset
  fire at different times, stop and report, because a WAL that disagrees with the assembler is
  worse than either bug.
- If any spec asserts the assembler accumulates across `add` calls without bound (a streaming
  invariant), confirm the reset does not break resumption within a *single* attempt.

---

### T12 — Error out on a stalled stream instead of waiting             [wave 3] [risk: high]

**Depends on:** T1
**Files:** modify `lib/lain/provider/http/streaming/faraday_handlers.rb` (the `on_data` handler build — the seam),
`lib/lain/provider/http/configuration.rb`,
`lib/lain/provider/http/connection/middleware_stack.rb`; create
`spec/lain/provider/http/stall_protection_spec.rb`
**Reuse:** T1's `StreamingUpstream` helper (it can stop emitting without closing);
`lib/lain/provider/ollama/streamed_failure.rb` (documented as where a torn stream is meant to
surface); `spec/support/zero_retry.rb` (`zero_retry_config`, for isolating stall behaviour from
retry behaviour)
**Shared-file wiring:** none
**Reachable from:** `Provider::HTTP::Streaming::FaradayHandlers.build` is what
`Ollama::Transport#install_on_data` (`ollama/transport.rb:125-139`) and the Anthropic transport both
install, so the clock reaches every streaming provider; the knobs ride the config
`MiddlewareStack#build` already assembles

**The seam is the `on_data` handler, not the middleware stack.** A Faraday *request middleware*
cannot observe inter-chunk gaps: by the time its `call` returns, the body is finished. Chunks arrive
at the handler built by `Provider::HTTP::Streaming::FaradayHandlers.build` and installed at
`ollama/transport.rb:125-139` — that is where "time since last byte" is knowable.
`configuration.rb` and `middleware_stack.rb` carry only the knobs. Building the clock in the
middleware stack will fail, and it will look like the "second HTTP client" prohibition when it is
not.

Fix F7a's hang. Measured: >400 s with zero output against a 1909 ms control, because
`request_timeout` (300 s) bounds each *attempt* and there are four of them.

**A shorter total timeout is the wrong instrument**, and `ollama.rb:49-52` says why: *"A local
model that thinks for six minutes is a real shape, so the 300s is a live limit rather than a
formality."* What distinguishes a stalled stream from a slow one is **time since the last byte**,
not total duration.

The industry pattern is stalled-stream protection; AWS's is a usable template — minimum throughput
1 byte/s, grace period 5 s, checked once per second, adjustable and disableable. Claude Code
surfaces an `API Error: Stream idle timeout` for the same reason.

**The first-byte grace and the inter-chunk grace are different numbers.** Prompt evaluation can be
legitimately silent for a long time before the first token; a mid-stream silence of the same length
is a dead stream. Getting this wrong turns a resilience feature into a new failure mode — which is
why the chosen defaults are an escalation, not a card decision (see Open decisions).

**Acceptance criteria:**

```gherkin
Scenario: a stream that stops emitting errors within the grace period
  Given a fake upstream that sends two chunks and then stops without closing
  When a completion is requested with a short inter-chunk grace
  Then an error naming a stalled stream is raised well before the request timeout

Scenario: a slow but living stream is not killed
  Given a fake upstream emitting one chunk per interval, under the throughput floor but never idle
  When a completion is requested
  Then the completion succeeds

Scenario: a long silence before the first byte is tolerated
  Given a fake upstream that delays past the inter-chunk grace before its first chunk, then streams normally
  When a completion is requested
  Then the completion succeeds

Scenario: stall protection can be disabled
  Given a configuration with stall protection disabled
  And a fake upstream that stops emitting
  When a completion is requested
  Then no stalled-stream error is raised within several times the inter-chunk grace

Scenario: a stalled stream is not retried
  Given a fake upstream that stops emitting on every connection
  When a completion is requested
  Then exactly one connection is made
```
→ spec file: `spec/lain/provider/http/stall_protection_spec.rb`

**Escalation triggers:**
- The defaults are decided in Open decisions (30 s inter-chunk, first-byte unchanged at 300 s).
  Escalate only if a measurement contradicts them — in particular, **if a healthy local generation
  is observed pausing more than 30 s between tokens**, the inter-chunk number is wrong and the
  card must stop rather than lower it to fit.
- If stall detection cannot be implemented inside the vendored Faraday stack without a second HTTP
  client, stop — `ollama/transport.rb:79-90` is explicit that a parallel hand-rolled client is the
  thing the design forbids.
- The stall exception **must not** be a member of `retry_exceptions` (`middleware_stack.rb:111-116`)
  — that list holds `Faraday::TimeoutError` among others, and `retry_options`
  (`middleware_stack.rb:69-77`) retries `:post`. A stall that raises a retryable error multiplies
  F7a by four instead of fixing it. Raise a **new, non-retryable** error type. If that proves
  impossible inside the vendored stack, stop and escalate — this is the card's central design
  decision, not a detail.

---

### T13 — Record ollama at the HTTP boundary                           [wave 3] [risk: medium]

**Depends on:** T3
**Files:** create `spec/fixtures/vcr_cassettes/ollama_chat_streaming.yml`,
`spec/fixtures/vcr_cassettes/ollama_process_status.yml`,
`spec/fixtures/vcr_cassettes/ollama_show.yml`; create
`spec/lain/provider/ollama_recorded_spec.rb`
**Reuse:** `spec/lain/provider/anthropic_recorded_spec.rb` (the one existing `:vcr` example — copy
its shape); T3's sequencing and probe changes; `references/ollama/api-show-and-context.md` (what
each endpoint actually answers, so the cassettes assert the right things)
**Shared-file wiring:** none
**Reachable from:** deferred: test infrastructure, see Open decisions

Record real ollama round trips and replay them offline, so the wire handling that F1, F3 and F7
all touched has a regression test that needs no GPU and no network.

Cover the three endpoints that matter: `POST /api/chat` streaming NDJSON (decode, tool calls,
usage), `GET /api/ps` (the served context window — F3's subject), `POST /api/show` (capabilities).

**State the limitation in the spec file itself**, because a future reader will otherwise trust
these further than they deserve: WebMock hands a stubbed body back as **one chunk**
(`ollama/streamed_failure_spec.rb:5-9`; `lain.gemspec:77-80` for the VCR half), so these cassettes **cannot** catch
a chunk-boundary or retry-splice regression. T10 and T12 own that, over a real socket. A cassette
that appeared to cover F7b would be actively harmful.

Recording requires a real ollama and `LAIN_RECORD=1`; replay must require neither. Note the last
scenario deliberately runs **with** a server up: "passes with network denied" would assert only the
suite's existing posture (`allow_http_connections_when_no_cassette = false`), which T13 does not
build — proving the cassette is *preferred over* a live server is the real claim.

**Acceptance criteria:**

```gherkin
Scenario: a recorded streaming chat decodes offline
  Given the recorded ollama chat cassette
  When a completion is requested with no ollama server running
  Then the response's text, model and usage match what was recorded

Scenario: a recorded tool call decodes offline
  Given a recorded cassette in which the model requested a tool call
  When a completion is requested
  Then the response carries a tool_use block with the recorded name and arguments

Scenario: the served context window is read from the recording
  Given the recorded process-status cassette naming a served context length
  When the provider is asked for its context window
  Then it answers the recorded number

Scenario: replay uses the cassette rather than a live server
  Given every ollama cassette in this card
  And an ollama server is running locally
  When the examples run
  Then the recorded values are returned rather than the live server's
```
→ spec file: `spec/lain/provider/ollama_recorded_spec.rb`

**Escalation triggers:**
- If a recorded cassette contains anything host-specific — a home directory, a hostname, a local
  path — it must be filtered before it is committed. `vcr_configuration.rb:36-42` filters
  Anthropic secrets; ollama needs its own review, and **a cassette is committed to the repo
  forever**.
- If the recorded `/api/ps` cassette cannot override T3's global probe stub, stop — that is T3's
  contract and it has failed, not this card's problem to work around.
- If a cassette exceeds a few hundred kilobytes, stop and report: a large fixture that nobody can
  read is a liability, and a shorter prompt usually fixes it.

---

### T14 — Replay a whole run offline                                   [wave 4] [risk: medium]

**Depends on:** T13
**Files:** create `spec/fixtures/vcr_cassettes/ollama_run_tool_loop.yml`; create
`spec/lain/seams/recorded_run_spec.rb`
**Reuse:** T13's cassettes and recording procedure; `lib/lain/cli/wiring/agent_build.rb` and
`CLI::Backend#compaction_source` (`cli/backend.rb:447-452`) — **the run must be driven through the
real wiring**; `spec/support/mock_recording.rb` (`record_journaled_run`, for its journal-inspection
idiom only); `lib/lain/bench/live_replay.rb` (the session-level replay, for comparison — this card
is the HTTP-level complement, not a replacement)
**Shared-file wiring:** none
**Reachable from:** deferred: test infrastructure, see Open decisions

A small number of whole-run recordings — a multi-turn session that calls a tool and completes —
replayed offline. This is the layer closest to the QA run that found these defects: it exercises
the agent loop, tool dispatch, the journal and compaction accounting together, which no
provider-level cassette reaches.

**Drive it through `Backend`/`AgentBuild`, not by constructing an `Agent` directly.**
`record_journaled_run` builds an `Agent` with an injected toolset and context, which covers the loop
and skips the wiring — and the wiring is exactly where F3 lived. A replay that hand-builds its Agent
cannot honestly claim to cover compaction accounting.

Keep it **small and few**. Whole-run cassettes are brittle to any prompt change, and the plan's
value here is one or two runs that fail loudly when orchestration regresses — not broad coverage.
If a prompt edit in an unrelated chunk breaks these, that is the cost being accepted; say so in the
spec file so the next reader knows re-recording is the expected repair, not a bug hunt.

**Acceptance criteria:**

```gherkin
Scenario: a recorded multi-turn run replays offline
  Given a cassette of a run that calls one tool and then answers
  When the run is replayed with no network
  Then the final assistant message matches the recording

Scenario: the tool actually ran during replay
  Given the same cassette
  When the run is replayed
  Then the journal records the tool call and its result

Scenario: the journal is well formed after replay
  Given the same cassette
  When the run is replayed
  Then every journal line parses and the session records a close
```
→ spec file: `spec/lain/seams/recorded_run_spec.rb`

**Escalation triggers:**
- If replay requires freezing time, a seed, or a uuid to match the recording, stop and report which
  — a run recording that only replays under three frozen globals is more maintenance than it is
  worth, and the plan would rather have one narrower cassette.
- If the run cassette must be re-recorded to make an unrelated card's specs pass, stop: that means
  the cassette is pinning prompt text rather than orchestration behaviour.
- `spec/lain/seams/` is documented as the home for seams belonging to no single subject; if this
  spec turns out to have an obvious single subject, it belongs at that subject's mirror path
  instead.

## What the panel changed

Reviewed 2026-08-17 by the roster above; verdict REQUEST-CHANGES, six blockers, all confirmed
against the tree before being acted on.

- **T0 exists because of the panel.** T1's fake socket was unreachable: `network_posture_spec.rb:57-63`
  is a committed spec proving a loopback call is refused, and `NetworkAccess.permit` — the only way
  out — also disables VCR, which separately blocked T3's recording. One new card, one owner, both
  unblocked.
- **T9 was re-grounded from two-valued to three-valued provenance.** The original binary
  measured/fallback split would have **disabled `approaching_window` compaction for Anthropic and
  Bedrock**, since `context_window_tokens` is overridden only by Ollama and every hosted arm reads a
  `DEFAULTS` entry. Its file list was also wrong by two (`compaction/source.rb`,
  `cli/backend/window_book.rb`), and one AC was unwritable because `ContextWindow::DEFAULT` is
  itself constructed with an explicit `fallback:`.
- **Two same-wave collisions removed**: T2/T9 both wrote `spec/lain/cli/backend_spec.rb`; T1/T3 both
  needed `spec/support/network_access.rb`.
- **T12's seam moved** from the middleware stack to the `on_data` handler — a Faraday request
  middleware cannot observe inter-chunk gaps, so the card as written would have failed and looked
  like the "second HTTP client" prohibition.
- **Ten drifted line citations corrected**, and one misattribution: the WebMock-one-chunk claim is
  at `ollama/streamed_failure_spec.rb:5-9`, not `lain.gemspec:77-80` (which makes the sibling point
  about VCR). The conclusion drawn from it was right.
- Smaller: T6's ACs contradicted its own escalation trigger (no file name exists on the mark path);
  T8's preferred fix and its stop condition were the same move; T5 cited protocol-history specs as
  helpdoc specs and left `:LainNote` in the same banner unchecked; T11 named a spec file that does
  not exist; T4 needed a multi-chunk stub, not just an ASCII-8BIT one.

The panel's own summary of what held up: the substantive grounding claims, and *"the
rejected-alternatives discipline — not fixing F1 in `Canonical`, not shortening the total timeout,
not letting cassettes claim F7b"*.

## Integration checks

Run after the last wave lands:

- `bundle exec rake pspec` — full suite green. **Check the example COUNT against a serial run**,
  not just the failure count: `parallel_tests` reports only surviving examples, so a dead worker
  and a passing run look alike (CLAUDE.md).
- `bundle exec rubocop` — bare, never naming a `.toml` on the command line.
- `cargo test && cargo clippy --all-targets -- -D warnings` — unchanged by this chunk, run anyway.
- `pre-commit run --all-files`. `shellcheck` is known-missing on this box and is the one expected
  failure; anything else is real.
- **Replay-without-network check:** run the new `:vcr` examples with no ollama server running and
  with network denied. They must pass. This is the whole claim of T13 and T14 and it is the one
  thing a normal suite run does not prove, because a developer's ollama is usually up.
- **A recording pass, done once by a human:** `LAIN_RECORD=1` against a real ollama, confirming the
  cassettes regenerate and that nothing host-specific lands in them. Cassettes are committed
  forever; this cannot be automated away.
- **Manual pass on the review surface (F4/F5):** open a survey in the cockpit, mark a row, and hand
  it back with `:LainReviewVerdict approve`. T5 and T6 fix a loop whose failure mode was that the
  human could not complete it — a green suite is not evidence the gesture works.
- **Confirm F7 is actually dead:** re-run the severing-proxy repro from the research pass against
  the fixed tree. Expect a fast, named error and no spliced content, in place of >400 s of silence.

## Execution log

Baseline on `main` at start (cc6449ec): **13402 examples, 0 failures, 14 pendings**, 25 s under
`LAIN_SPEC_WORKERS=12`. No worktrees; 25 pre-existing branches.

**Staleness check, 2026-08-17.** All 32 wave-1 line citations re-verified against the tree. No card
invalidated. Three notes folded into the implementer briefs:

- `WindowBook#book` is at `window_book.rb:129`, not `:128` (cosmetic; T9).
- `spec/support/shared_examples/provider_parity.rb` asserts **nothing** about constructor arity,
  `channel:` or telemetry, so T2's first escalation trigger is moot — its parity coverage is
  net-new, not a reversal of a deliberate assertion.
- **T6's third escalation trigger is answered and needs no investigation.**
  `lib/lain/review/surface/message.rb` is not a surface: it is a ~30-line
  `Message = Data.define(:speaker, :text)` port value object with no `#mark`. The surfaces carrying
  `#mark` are `neovim.rb`, `text.rb` and `null.rb`.

**Harness anomaly: six of eight wave-1 worktrees forked from `ef57db69`, 30 commits behind
`main` (cc6449ec)** — 136 files, ~12.9k insertions of drift. Not a plan defect; the worktree
bases diverged at creation. Correctly based: T2, T9. Stale: T0, T4, T5, T6, T7, T8.

Assessed rather than assumed:

- **T0, T4, T7, T8 touch files that are byte-identical across the gap.** Their edits apply to
  `main` unchanged; the only deficit is that their own suite run missed ~281 newer examples.
- **T5 and T6 touch files that moved** (`survey.rb`, `review.rb`, `survey_spec.rb`,
  `neovim_runtime_spec.rb`, `surface/neovim.rb`). The drift is small and the constants each card
  targets are present at the old base with identical content — `OPENED` byte-identical,
  `MARKED` at `:165` vs `:169`, `#mark` at `:246` vs `:250` — so offsets, not conflicts.
- **Two new discipline specs land in the gap** (`spec/spec_discipline_spec.rb` +806,
  `spec/reply_surface_discipline_spec.rb` +168) and will judge every new spec file this chunk
  writes. No stale agent can see them.

Consequent merge procedure, applied per card: three-way apply of the card's diff onto `main`,
then **the full suite on `main`** before the commit lands. That is the gate the git protocol
already requires after any rebase, and it is what surfaces a discipline-spec violation loudly
instead of silently. Review agents are spawned **without** their own worktree — they only ever
read the card's tree, so a second copy is waste and a second base is confusion.

**What the execution's review panel found that the planning panel did not.** Six-for-six on cards
reviewed, and the recurring shape is that the *tests* were the blind spot rather than the code:

- **T2** — deleting the attempt-threading T10 depends on leaves **578 examples green**. The seam
  whose failure mode is silent corruption of content-addressed history had no coverage at either
  end. Its AC3 also passed against the instance-state design the card explicitly forbids.
- **T0** — host+port matching is correct but **unasserted**: a port-only mutant leaves the posture
  spec at 14 examples, 0 failures, which would make `evil.example.com:<held port>` reachable.
- **T9** — the card's central safety claim ("every Anthropic and Bedrock run resolves through
  `DEFAULTS`") is **false**: `claude-fable-5` and `claude-mythos-5` are current 1M-context families
  that fall through to the 8,192 guess. Verified against the authoritative model catalogue before
  acting, because the fix writes numbers into the published-window table and a wrong entry there is
  the same defect class the card exists to prevent. The hosted-arm tripwire spec omitted both.
- **T6** — a mutation harness showed the two surfaces can silently **disagree** (text=30,
  neovim=24) with zero failures — the one property the deliberate duplication could break.
- **T7** — a mutant collapsing the singular/plural ternary survives the entire suite; and F6 was
  reproduced one branch over, where a torn-header row makes a *positive false claim*.
- **T8** — the sentinel spec asserted `not_to eq([])`, true of every non-Array object in Ruby; and
  `equal?` **is** overridable, so the identity check dispatched on the untrusted value.
- **T4** — the card's own hazard (a PNG decoding to `‰PNG`) is reachable through an **absent**
  `Content-Type`, and the CP1252 rung reinterprets a whole body the server declared UTF-8.

### Carry-forward (out of scope here, real)

- **The window table goes stale at every model launch** — this is the second time it has bitten
  (T9). The Models API exposes `max_input_tokens` per model as a live lookup.
- **`Provider::RetryTap` extraction.** `bedrock.rb:17-20` wrote down that *"a third such arm is what
  would earn that move"*; Ollama is the third, and ~16 of 24 executable lines are copy-paste.
  Deferred deliberately — T10/T11 are high-risk critical-path cards building on this code — with
  `bedrock.rb`'s sentence corrected so the file stops lying.
- **A tally object beside `Journal.records`** answering `records` and `skipped` together, so none of
  the six other readers of that contract has to know subtraction is how you find out (T7).
- **`Tools::WebFetch#fetch` returns `[status, headers, cap]` whose first two elements have two
  sources** — one fact, two providers, the shape "disagreement is unrepresentable" exists to prevent.
- **`Review::Handover` duplicates `PARTLY_MARKED`** and emits one acknowledgement *per hunk* on a
  row, so a multi-hunk row produces N near-identical messages (found while reviewing T6).
- **The flake list in `planning/remaining-work.md` records `neovim/buffers_spec.rb:291`, which has
  drifted to `:329`** — CLAUDE.md is explicit that flakes are recorded by NAME, never line number,
  precisely because a stale number reads as "not a known flake".

### The flake population, recorded BY NAME

CLAUDE.md requires flakes be recorded by name, never line number. `planning/remaining-work.md`
records one as `neovim/buffers_spec.rb:291`, which has since drifted to `:329` — the exact failure
the rule exists to prevent, since a stale number reads as "not a known flake". Four independent
agents converged on this list during the chunk:

- `Lain::Frontend::Neovim user mappings are respected re-attach is idempotent: no duplicate
  commands, and motions/syntax still work`
- `Lain::CLI::Up against a real tmux server --nvim cockpit splits the chat window into an nvim pane
  and a chat pane sharing one socket and one cwd`
- `Lain::CLI::Up against a real tmux server threads -- chat args into the spawned window's command,
  each argument shell-escaped`
- `Lain::Frontend::Neovim the review thread pane following the cursor does not re-place the diff on
  every further move once it is back`

All pass in isolation. The mechanism is visible in the run log — `no server running on
/tmp/tmux-1000/lain-spec-<pid>-<n>` — a real tmux server dying under contention. **They fail far
more often when other agents are running**, which makes the pre-commit hook (which runs the whole
suite) unreliable during a parallel chunk: four consecutive commit attempts for T9 were blocked by
these alone while its own 1069 subject examples were green.

### Toolchain trap found during execution

**`pre-commit` runs without the mise environment.** Both Ruby hooks fail with
`Executable 'bundle' not found` unless the toolchain is exported in the same shell as `git commit`:

```bash
eval "$(mise env -s bash ruby@4.0.6)" && export LD_LIBRARY_PATH=/home/linuxbrew/.linuxbrew/lib && \
  export TMPDIR="$HOME/tmp/lain" && git commit -m "..."
```

The message names `bundle`, not the environment, so it reads as a broken hook. Worth adding to
CLAUDE.md's Toolchain section.

### Wave status

- [x] Wave 1 — **6 of 8 landed**: T6 `9e4b5c4`, T4 `37bc22e`, T7 `d8078ad`, T0 `92564ba`,
      T8 `6c3fffe`, T2 `ec33e7b`. T9 approved + staged (blocked only by the flakes above);
      T5 approved, fix round complete, awaiting merge.
- [ ] Wave 2 — T1, T3 *(in flight)*
- [ ] Wave 3 — T10, T11, T12, T13
- [ ] Wave 4 — T14

Every wave-1 card reached **APPROVE** — five of eight only after a REQUEST-CHANGES or a substantive
fix round. The panel found a real defect in every card it reviewed.
