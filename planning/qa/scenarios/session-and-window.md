# Scenario: session start, the served window, and occupancy

**What it exercises:** `WindowBook`, `Middleware::ResolveWindow`, `Backend::NumCtx`,
`Backend::Endpoint`, the `provenance` tag, `compaction_decision`, `.lain/state.json`, the HUD's
`ctx N%`, the `options` asymmetry on the ollama wire — and, since 2026-08-18, the two other things a
launch settles before a model is ever asked: **which prices the run will quote** (`PriceBook`, its
freshness lint, and the deliberate zero fallback compaction uses) and **which collapse strategy it
resolved** (`CLI::CompactionStrategy`).

**Cost:** cheap. Most of it is launch-level and needs no model call at all. **Run it first** — it
is the fastest way to tell whether the bench is honest before spending a session on a subject.

**Needs:** `bench.md` up. A project directory. No nvim required.

---

## 1 — Launch-level refusals (no model call, no cockpit)

Every one of these must refuse **by name at construction**, exit 1, and print no backtrace.
`< /dev/null` is the vehicle: the refusal fires before stdin is ever read.

```bash
run(){ out=$(timeout 90 lain chat --provider ollama --model qwen3-coder:30b "$@" < /dev/null 2>&1); echo "[$? ] $*"; echo "$out" | tail -3; }
run --num-ctx 0
run --num-ctx -5
run --num-ctx 999999                 # above the trained maximum
run --num-ctx 262144                 # AT the trained maximum: must be accepted
run --api-base localhost:11434       # the scheme-less typo a human actually makes
run --api-base 'http://'
run --api-base 'http:///x'
run --api-base 'not a uri at all'
run --api-base ''                    # an unset $OLLAMA_HOST
```

Expected shapes (round 4, all passing):

- `--num-ctx must be positive, got 0`
- `--num-ctx 999999 is above the model's trained maximum of 262144; no runner can serve a window larger than the weights were trained for`
- `--api-base "localhost:11434" has no host; a scheme is required, e.g. http://localhost:11434`
- `--api-base "not a uri at all" is not a usable URL`

**The trained maximum must arrive with NOTHING resident** — it rides `/api/show` on the same 2s
probe connection as `/api/ps`, and only when `--num-ctx` is set. Verify residency is empty first, or
this proves nothing.

## 2 — Connect timeout against a blackhole

```bash
time lain chat --provider ollama --model qwen3-coder:30b \
     --api-base http://10.255.255.1:11434 --prompt 'say hi' < /dev/null
LAIN_CONNECT_TIMEOUT=1 <same>
```

Expected: ~26s at the default 5s connect timeout, ~8s at 1s — **not** the ~20 minutes
(`request_timeout` 300s × 4 attempts) this used to take. Retries must render **live** on screen
(`[retry] attempt N, retrying in Xs -- Faraday::ConnectionFailed`), not journal-only.

Count the attempts with a counting TCP listener (see `method.md`) — and then **check the rendered
ordinals against that count**, which is the half T18 changed. The give-up line used to report the
retry budget rather than the attempt that failed, so four real attempts rendered as `1, 2, 3, 3`
(round 4's F16). The last line must now name a **higher** ordinal than the last retrying line:

```
[retry] attempt 3, retrying in 4s -- Faraday::ConnectionFailed
[retry] attempt 4, giving up -- Faraday::ConnectionFailed
```

A repeated ordinal is the regression. Both providers must agree on what "attempt" means, so if the
Anthropic path is exercised in the same round, read its taps too — one provider counting from 1 and
the other from 0 is worse than the original bug.

**Read the backoff FIGURE too, not just the ordinal — this is the only place it renders.** The retry
middleware hands back a raw Float, and it used to be printed whole: `retrying in
0.14368744774438316s`, precision nobody reads at. Four shapes now, and each says something the raw
Float did not:

| backoff | renders | why |
|---|---|---|
| `0.14368744774438316` | `retrying in 0.14s` | two places, which is what a human reads at |
| a whole second | `retrying in 2s` | no decimal tail, so `2.0` cannot masquerade as measured to the millisecond |
| under 0.01s | `retrying in under 0.01s` | a rounded `0s` is indistinguishable from no wait at all, and a real one is happening |
| non-finite | `retrying in a while` | reachable from a misbehaving server's oversized `Retry-After`, which parses to `Float::INFINITY` |

The last row is the one that used to be a **crash** rather than a cosmetic problem: `Float::INFINITY.round(2)`
raises, so a server-supplied `Retry-After` could take the render down where the old code printed
harmlessly. It is not reachable from the blackhole probe above — a connect failure has no header —
so if the round exercises the Anthropic path or a proxy that can forge one, that is where to look.
A long decimal tail on any of these is the regression.

## 3 — Cold start, then warm, in ONE session

Launch cold (nothing resident), drive one trivial turn, then drive a second.

```bash
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next;
  puts "window=#{r["window_tokens"]} used=#{r["used_tokens"].inspect} prov=#{r["provenance"].inspect} sig=#{r["signals"].inspect}" \
    if r["type"]=="compaction_decision"}' "$JOURNAL"
```

Expected, and this is the interesting part:

| turn | residency | window | provenance | signals |
|---|---|---|---|---|
| 1 | cold | fallback (8192) | `guessed` | `[]` — a guess may never authorise a rewrite |
| 2 | resident (turn 1 loaded it) | 32768 | `probed` | as warranted |

**The window must RE-RESOLVE mid-session.** Before round 3's T6 the book was resolved once at launch
and memoized, so it stayed at the fallback for the whole session. A window that never moves off 8192
is that regression returning.

`--num-ctx N` alone resolves a served window **with no server involved**, so it should give an
honest denominator with nothing resident. That is the operator lever; it is otherwise untested.

## 4 — The three readers must agree

Journal `compaction_decision`, `.lain/state.json` `occupancy`, and the HUD's `ctx N%`.
*Disagreement between them is the real failure;* a uniformly wrong number is the known one.

Cross-check the denominator too: `compaction_decision.used_tokens` should equal the matching
`turn_usage.usage.input_tokens` (round 4: both 4515, exactly). Note the token counts are **nested
under `usage`**, not top-level — reading the wrong path makes them look absent.

## 5 — `capability_degraded`

Count the lines in the journal: expect **exactly one**, and expect **nothing on screen** — nothing
renders it, so a driver watching the display will otherwise file a false defect.

```json
{"type":"capability_degraded","capability":"prompt_caching","requirer":"Lain::Context","provider":"Lain::Provider::Ollama"}
```

## 6 — The `options` asymmetry on the wire

The contract is that lain sends **only what was asked for**:

```bash
# with the knob set
LAIN_NUM_BATCH=2048 lain chat ... --prompt hi      # -> extra={"num_batch" => 2048}
# with neither knob
env -u LAIN_NUM_BATCH lain chat ... --prompt hi    # -> extra={}   (NO options key at all)
```

Read it off both the `session` record and every `request_sent`. The `env -u` is required — the
flag's default is `EnvDefaults.numeric("LAIN_NUM_BATCH")`, which `bench.md` exports.

## 7 — `--compact-strategy` resolves, and refuses, at LAUNCH

Four names ship and they compose with `+`. All of this is settled while the `Backend` is built, so
**every check here is one non-interactive launch and no model call** — `< /dev/null` again, and the
refusal fires before stdin is read.

Reuse §1's `run` helper — `< /dev/null` and **no** `--prompt`, so a name that resolves reaches the
REPL, reads EOF and exits without ever dispatching a turn:

```bash
run --compact-strategy nonesuch
run --compact-strategy ''                                    # an unset shell variable, not a name
run --compact-strategy 'elide-tools+'                        # a trailing separator
run --compact-strategy '+elide'                              # a leading one
run --compact-strategy 'elide-tools+summarize-conversation'  # the recommended pair: must LAUNCH
run --compact-strategy 'elide+summarizing'                   # legal to spell, refuses later -- see below
```

Verified against the built binary 2026-08-18 (with `--prompt hi`, which the refusal precedes) — exit
**1**, one line, **zero** backtrace frames:

```
unknown part "nonesuch" in --compact-strategy "nonesuch", expected one of ["summarizing", "elide", "summarize-conversation", "elide-tools"], or several joined by "+"
unknown part "" in --compact-strategy "elide-tools+", expected one of [...], or several joined by "+"
```

Three things to read carefully, because each is a place a driver files the wrong finding:

- **The empty and the trailing-separator cases name the PART and the whole value separately.** A
  refusal reporting `--compact-strategy ""` for input `elide-tools+` would be true about the part and
  false about what was typed; that wording was deliberate, so a report of `""` where `elide-tools+`
  was typed is a regression, not a cosmetic difference.
- **The refusal must list all four names.** The set grew this chunk; a refusal still naming only
  `["summarizing", "elide"]` means the registry and the resolver have drifted apart.
- **`elide+summarizing` is SUPPOSED to launch.** Both claim the whole span, so it raises `Overlap`
  at the first compacting turn instead — refusing at resolve time is a design decision nobody has
  taken. A launch-time refusal here would be the *unexpected* result. (Reaching the actual raise
  needs volume: `rails-blog.md`.)

## 8 — The price table, and the lint that keeps it honest

**No model call, and no `lain ledger` — that command does not exist.** The corrected table (Opus was
3× overstated until 2026-08-18) is reachable three ways: `/ruby` in a live session, `lain friction`
over a recorded one, and `lain bench arms`' cost column. Read it here through `/ruby`, which asks the
process under test rather than the source file:

```bash
# inside any live session -- the cockpit's, or a plain `lain chat --no-nvim`
$QA/drive.sh '/ruby Lain::PriceBook.default.price("claude-opus-5").input * 1_000_000' 6 30 >/dev/null
$QA/peek.sh 6
```

If no session is up yet, the same read off the checkout answers the same question one layer further
from the process under test — say which one you used:

```bash
bundle exec ruby -Ilib -rlain -e 'p Lain::PriceBook.default.price("claude-opus-5")'
```

| model | input | output | cache write | cache read |
|---|---|---|---|---|
| `claude-opus-5` | **5** | **25** | 6.25 | 0.5 |
| `claude-sonnet-5` | 3 | 15 | 3.75 | 0.3 |
| `claude-haiku-4-5` | **1** | **5** | 1.25 | 0.1 |

Per MTok, verified 2026-08-18 against the loaded `PriceBook.default`. **`15/75` on the opus row is
the pre-chunk error returning.** Cache write must stay exactly 1.25× input and cache read exactly
0.1× — a corrected input rate with a stale derived row is the half-fix to watch for.

`claude-fable-5` and `claude-mythos-5` are deliberately **unpriced** and must raise by name:

    no price for model "claude-fable-5"; configure a fallback to degrade

A silent zero there would be the failure the whole object exists to prevent.

**A local model reads as `0.0` on compaction records, and that is deliberate.** `--provider ollama`
prices compaction through `CLI::Backend::COMPACTION_PRICES`, the same table degrading to a zero
fallback, so `cost_saved`/`cost_spent` on a `compaction` record are honest zeros beside a local model
id — not a free compaction and not a defect. The main `PriceBook` still **raises** for the same
model; the two differ on purpose.

**⚠️ Against a PRICED model, every non-zero `cost_saved`/`cost_spent` is now roughly a QUARTER of its
pre-chunk value, and that drop is the fix rather than a defect.** Recorded prominently because a
driver comparing a fresh reading against a round-4 record will otherwise file it as a regression.
The cause: compaction measures its span with a canonical-byte proxy, not a tokenizer, and those
bytes were being fed straight into a per-**token** price — so the dollars overstated by the whole
bytes-per-token ratio. The crossing is now explicit and happens exactly once, at the pricing
boundary, dividing by `Lain::ProxyBytes::BYTES_PER_TOKEN`, which is **4**:

```bash
$QA/drive.sh '/ruby Lain::ProxyBytes::BYTES_PER_TOKEN' 6 30 >/dev/null; $QA/peek.sh 6
```

Two things follow for reading any figure here. The division **truncates**, on purpose: an estimate
that lands in a dollar claim should err low, and a span under one token's worth of bytes is worth
no tokens. And the ratio is an *estimate* — ~4 characters per token is what the major BPE
tokenizers are quoted at for English prose, and canonical bytes are ASCII-dominated JSON of that
prose — so these dollars are the right order of magnitude and not a measurement. A figure matching a
round-4 record exactly is the old arithmetic returning.

The freshness lint is a repo lint (`pre-commit`), not a runtime check, and it runs from the checkout
rather than the sandbox:

```bash
bin/lint-price-freshness; echo "exit=$?"     # exit 0, prints NOTHING, while the marker is < 90 days old
ruby -rdate -e 'load "bin/lint-price-freshness"
  src = File.read("lib/lain/price_book.rb")
  puts PriceFreshnessLinter.check(source: src, path: "lib/lain/price_book.rb", today: Date.today + 200).message'
```

The injected clock is the whole design — a spec pinned to the system clock would pass today and fail
unattended in 91 days — so drive the stale branch that way rather than by editing the marker:

    lib/lain/price_book.rb: price table reviewed-on marker is 2026-08-18 (200 days old; horizon is 90 days) -- re-verify DEFAULTS against the published rates and update the marker

`load`, not `require_relative`: the file has no `.rb` extension. **What wrong looks like:** the lint
exiting 0 with a marker it never found — check that a *deleted* marker fails too, since a regex that
stops matching silently turns the lint into a no-op that passes forever.

## What this scenario does not cover

The **compaction path at scale** — filling the context until a compaction actually fires. Rounds 3
and 4 both failed to reach it (round 3 died to F10, round 4 to the then-per-session iteration
ceiling), which makes it the least-exercised path in the whole QA suite. The ceiling is per-ask since
T14, so the obstacle is now only volume: **`rails-blog.md` §1 is where that act now lives**, and it
carries the precondition (real tool bytes) that a short session cannot satisfy.
