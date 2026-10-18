# Scenario: session start, the served window, and occupancy

**Round 26 is the re-check** for the round 25 fixes stated in §6 (the `--max-tokens` refusal), §7 and §7a (`--compact-schedule`, the idle tick), §9c (a resume keeps the recorded arms).

**What it exercises:** `WindowBook`, `Middleware::ResolveWindow`, `Backend::NumCtx`,
`Backend::Endpoint`, the `provenance` tag, `compaction_decision`, `.lain/state.json`, the HUD's
`ctx N%`, the `options` asymmetry on the ollama wire — and, since 2026-08-18, the two other things a
launch settles before a model is ever asked: **which prices the run will quote** (`PriceBook`, its
freshness lint, and the deliberate zero fallback compaction uses) and **which collapse strategy it
resolved** (`CLI::CompactionStrategy`) — and, since 2026-09-14, **which context pipeline renders
every request, and whether the session record says so** (`CLI::ContextPipeline`, the header's
`context_pipeline`).

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

**`--non-interactive` draws no alternate screen** (round 22's G-n1 and H-3: it drew the answer on the alternate
screen and wiped it at exit, and the escapes reached a pipe). With `--non-interactive --prompt` on a terminal the
answer or the refusal stays on the scrollback after exit, and redirected to a file stdout carries no `ESC[?1049h`. **This check is for `--non-interactive` only** (A23-a3): an attended chat with stdout redirected, such as `lain chat --prompt ... </dev/null | tail`, still writes `ESC[?1049h`. Record that as the known shape, not as X-1 returning.

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

**Judge this probe by the render and the journal, never by `$?`.** `--prompt` is `first_prompt`, a
REPL seed (`lib/lain/cli/repl.rb:55-58`) consumed by exactly one `prompt.read`, not a batch mode —
`lain chat --prompt` exits **0** whether the ask completed or the endpoint never answered (FG1,
`qa-findings-round6-2026-08-19.md`). So the four exhausted attempts, the ordinals and the timing
above are the only evidence; a driver that gates this act on the process exit code will read a
healthy 0 out of a completely blackholed run.

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
| `0.14368744774438316` | `retrying in 0.14s` | at MOST two places, which is what a human reads at — a trailing zero is dropped, so `0.1` renders `0.1s`, not `0.10s` (round 9 saw both `0.1s` and `0.14s` in one run; neither is the regression) |
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

Journal `compaction_decision`, the status feed's `occupancy`, and the HUD's `ctx N%`.

**The status feed is NOT `.lain/state.json` any more, and this section used to say it was** (round
13). `ProjectDir` retired that path: the feed is now
`$XDG_STATE_HOME/lain/status/<project_hash>/state.json`, and `spec/lain/project_dir_spec.rb` fails
any expression in `lib/` that recomposes the old one. `lain up` prints the resolved path on the
`HUD state:` line at launch — read it from there rather than reconstructing the hash. A driver who
looks for `.lain/state.json` finds nothing and has no reader to cross-check against.
*Disagreement between them is the real failure;* a uniformly wrong number is the known one.

**A fourth reading since 2026-09-14, and the one that used to lie low.** Round 17 found ollama
silently truncating an over-window prompt and every reader believing the truncated count (F90:
50%, then 16%, on a request that had lost its system prompt and tools). Lain now asks ollama not to
truncate, so an over-window prompt is **refused** and journals `window_pressure kind=over_window`
with the server's own `prompt_tokens` and `window_tokens`; that count becomes the run's reading, so
compaction can fire on it (`rails-blog.md` §1b has the driven refusal).

**"`window_pressure` must be absent" is stale as of round 18.** The record is now a *signal* the
compaction path acts on: a refusal on a source that has nothing left to drop triggers the handoff
fallback, so a long session may legitimately carry one followed by a `compaction_cut` of
`kind: handoff` and an answered ask. What is still a finding is a `window_pressure` with nothing
after it, and `input_tokens` falling below the previous turn's with no record explaining it. Two
fields the record gained: `stands_on`, the turn the reading is believed on (so a live reader tags
it the way the agent does instead of inferring it, and nil is legitimate on an empty chain), and
`spawn`, the child whose prompt it was — nil for the run's own ask.

**And the refused count can now VOUCH for the window.** An over-window 400 carries the context the
server actually loaded, so that number is adopted as an authoritative reading rather than being
weighed against a probe — which also corrects a book that probed a stale, smaller runner before
the request reloaded it. The stale-runner case below is therefore narrower than it was: it still
bites before any refusal has happened, and a refusal clears it.

**Known and not a finding:** the window book can keep a stale smaller runner's context
after ollama reloads a bigger one, so occupancy can read near 100% and compaction fire early — a
follow-up the discharging chunk recorded, not this section's defect.

Cross-check the denominator too -- **but mind the LAG, which round 9 measured and which the old
wording here got wrong.** `compaction_decision.used_tokens` equals the **PRECEDING**
`turn_usage.usage.input_tokens`, not the following one: the decision is made *before* the turn and
can only read the last completed turn's measured usage. Over a 29-turn session:

```
decision[i] == turn_usage[i-1]   ->  28/28 pairs
decision[i] == turn_usage[i]     ->   0/29 pairs
decision[0].used_tokens          ->  nil          (cold: nothing measured yet)
```

Read same-index -- which is what this paragraph used to say, on the strength of round 4's "both
4515, exactly" from a session short enough for the pairing to be unambiguous -- and a healthy
session reads 0/29 and looks like a defect. The three readers DO agree; the lag is inherent. Note the token counts are **nested
under `usage`**, not top-level — reading the wrong path makes them look absent.

## 5 — `capability_degraded`

Count the lines in the journal: expect **exactly one**, and expect **nothing on screen** — nothing
renders it, so a driver watching the display will otherwise file a false defect.

```json
{"type":"capability_degraded","capability":"prompt_caching","requirer":"Lain::Context","provider":"Lain::Provider::Ollama"}
```

## 6 — The `options` asymmetry on the wire

**The contract used to be "lain sends only what was asked for", that is now true of the SAMPLER knobs
only, and, since commit `e39dda35`, `num_batch` is no longer one of them.** `temperature`, `seed` and
`num_ctx` are opt-in. An ollama chat sends `num_batch` **2048 by default** (a different `num_batch` re-keys
the shared runner and costs a 26-70 s reload, so the default is the safe one), and a chat on another provider
still sends none of them:

```bash
# ollama, knob unset: the default is on the wire and in the journal
env -u LAIN_NUM_BATCH lain chat --provider ollama ... --prompt hi   # -> extra={"num_batch" => 2048}
# ollama, knob set: the typed value wins
LAIN_NUM_BATCH=1024 lain chat --provider ollama ... --prompt hi      # -> extra={"num_batch" => 1024}
# another provider, neither knob
env -u LAIN_NUM_BATCH lain chat --provider anthropic ... --prompt hi # -> extra={}
```

Read it off both the `session` record and every `request_sent`. **`extra={}` on an ollama chat is now the
defect** (the default lost), and `{"num_batch" => 2048}` there is the expected value; round 20 found this
section still asserting `extra={}`. The `env -u` is still required, the flag's default is
`EnvDefaults.numeric("LAIN_NUM_BATCH")`, which `bench.md` exports.

**`extra` and the wire are two different claims.** The generation cap is not a sampler knob, and it is
unconditional: `Ollama::Encoding#encode_options` seeds the ollama `options` object with `num_predict`,
sourced from `request.max_tokens` rather than from `extra`, on **every** request. Read the two separately,
since neither implies the other:

```bash
env -u LAIN_NUM_BATCH lain chat --provider ollama ... --prompt hi
# -> session / request_sent's extra:    {"num_batch" => 2048}
# -> the encoded wire body's options:  {"num_predict" => <max_tokens>, "num_batch" => 2048}, truncate=false, shift=false
```

Round 20 confirmed this on the wire from four forks (`num_predict` 4096, `num_batch` 2048,
`truncate=false`). Round 25 reads `num_predict` 16384 on the wire now, not 4096. Every request also carries a top-level `shift=false` since round 24, so a reply that fills
the window is cut instead of shifted.

`max_tokens` is never the source of a silent zero here: a non-positive `--max-tokens` is refused at launch
(`--max-tokens must be positive, got 0`) before any request is built, so `num_predict` on the wire is never zero or absent.
The environment variable that used to set it was retired, and exporting one changes nothing.

**Automated by** `spec/e2e/wire_contract_spec.rb`, "sends the launched options on every model call": a chat launched with `--num-batch 1024` puts `num_batch` 1024 and an integer `num_predict` in the `options` of every ollama request, a skill child's included. **Still needs a human:** the 2048 default with the knob unset, `extra={}` on another provider, the `session` and `request_sent` records' `extra`, `truncate=false` and `shift=false`.

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
run --compact-strategy 'elide+summarizing'                   # refused at launch -- see below
run --compact-strategy 'summarizing+elide-tools'             # any other composition: refused too
run --compact-keep 0                                         # refused at launch, one line
run --compact-keep -1
run --compact-keep 1.5                                       # refused: a keep is a whole number (A23-a1)
run --compact-bytes 0                                        # refused: above 0 only (also -1)
run --compact-cap 0
run --compact-schedule nonesuch                              # refused: neither idle nor turn
```

**A refused compaction flag leaves no session file behind, the same as §9.** Count the files around
each refusal (the `count` helper of §9). Round 22 found `--compact-keep 0` and `-1` crashing with a raw
`ArgumentError` and a 4-frame backtrace, and every refused `--compact-strategy` leaving a session file whose
header recorded the refused name (listed by `lain sessions` as `0 turns closed`). Both now refuse before the
session file is opened, in one line with no frames; a file left behind, or a backtrace, is that finding back.

Verified against the built binary 2026-08-18 (with `--prompt hi`, which the refusal precedes) — exit
**1**, one line, **zero** backtrace frames:

```
unknown part "nonesuch" in --compact-strategy "nonesuch", expected one of ["summarizing", "elide", "summarize-conversation", "elide-tools"], or several joined by "+"
unknown part "" in --compact-strategy "elide-tools+", expected one of [...], or several joined by "+"
```

A bad `--compact-schedule` refuses at launch too, before the journal opens, so it leaves no session file
and no backtrace. Exit **1**, one line:

```
--compact-schedule "nonesuch" is not one of idle, turn
```

Three things to read carefully, because each is a place a driver files the wrong finding:

- **The empty and the trailing-separator cases name the PART and the whole value separately.** A
  refusal reporting `--compact-strategy ""` for input `elide-tools+` would be true about the part and
  false about what was typed; that wording was deliberate, so a report of `""` where `elide-tools+`
  was typed is a regression, not a cosmetic difference.
- **The refusal must list all four names.** The set grew this chunk; a refusal still naming only
  `["summarizing", "elide"]` means the registry and the resolver have drifted apart.
- **Every composition except `elide-tools+summarize-conversation` is refused at launch** (round 21 refused
  `elide+summarizing`; round 22 found 6 other overlapping spellings launching and tearing an ask with
  `Overlap`, and they are refused now too). Both parts of `elide+summarizing` claim the whole span, so the refusal
  names the value and points at the pair, as the live wording reads now:
  `--compact-strategy "elide+summarizing" would overlap; the one composable pair is
  elide-tools+summarize-conversation, in either order`. The older quoted sentence ("each claim the whole span ...
  which partition it") is stale. A pair that launches and then
  fails every ask is the round-21 finding back.

### 7a — `--compact-fallback`, and what happens when no cut can make room

**Round 23 K23-1, fixed: the compaction signal counts only what the configured strategy can claim, and the stall line names
the strategy.** `--compact-bytes` and `--compact-cap` measure the droppable head narrowed to the turns the strategy would
collapse, pins excluded. Under `--compact-strategy summarize-conversation` alone, an ask made of tool rounds has nothing
claimable, so no signal fires on those bytes and the decision is not logged as a shrink failure. When the window still fills
with nothing claimable, the decision's reason reads `but summarize-conversation claims none of the droppable turns`, and,
only when the wider arm would claim what it left, ends `use --compact-strategy elide-tools+summarize-conversation, which
claims tool rounds and conversation both, or start a new session`. The old tail, `lower --compact-keep, or start a new
session`, appearing for a strategy that claims nothing is the defect back. Free to check with a short script over
`Compaction::Head` and the `Diagnosis`; live, see `rails-blog.md` section 1.

Round 18 gave the over-window wall a fallback, and a flag that chooses whether to take it. Two
arms, resolved at LAUNCH like everything else here:

```bash
run --compact-fallback nonesuch     # refuses, naming both arms
run --compact-fallback none         # legal: the refusal stands
run --compact-fallback handoff      # legal, and the DEFAULT
```

`handoff` is the default because the alternative is a session that can no longer be spoken to. It
replaces the history before the current ask with **one** state document — written by exactly one
summarizer call — and answers the ask. `none` leaves the provider's refusal standing.

Two launch-level checks, both free:

- **The unknown arm refuses at construction**, naming `handoff, none`, before stdin is read. A
  `--compact-fallback` that silently resolved to `none` would show up only as an ask that died
  where it should have been kept, which is exactly the failure this refusal exists to prevent.
- **The session header records only the compaction flags that were TYPED.** (Round 20's RB-2 changed
  this: the Thor defaults are gone so that an unset flag and a default can be told apart, and a resume
  inherits whatever the header recorded. An untyped RESUME's own header does record `compact_keep` and
  `compact_strategy`, inherited from the session it resumed: the "no key" reading below is for a fresh,
  unflagged launch.) Launch once with no compaction flags and read the header: it has
  **no** `compact_fallback`, `compact_keep`, `compact_bytes`, `compact_cap` or `compact_strategy` key, and
  `Backend` behaves as it always did (`handoff`, keep 20). An older reading of this bullet, "an unflagged
  launch records the default rather than nothing", is stale, so a header carrying `compact_keep: 20` from
  an unflagged launch is the regression (the default is being recorded as if typed, and a resume can no
  longer tell it from a choice). Then launch with `--compact-fallback none --compact-keep 4` and confirm
  exactly those two keys appear, and that `--resume` with **no** flags renders under them
  (`rails-blog.md` 1b drives it with a real handoff).
- **The header records `compact_schedule` whenever compaction is on, typed or not.** This is the one
  exception to the bullet above: the schedule that runs is always written (`idle` for an unflagged
  launch, `turn` when typed so), so a reader can tell the two arms apart. Launch with `--no-compact`
  and the key is absent. A header with no key at all predates the field, and those runs compacted on
  the turn. `lain bench variance` refuses recordings made under different schedules, ending
  `cannot compare runs under different compaction schedules: idle vs turn` (exit 1); a recording
  without the key counts as `turn`.
- **The header also records which STRATEGY ran, as `compact_strategy` — present only when
  `--compact-strategy` was typed.** Like every other compaction key now, an unflagged launch writes no key at
  all rather than a default value; a reader normalizes that absence to the eager control arm
  (`Telemetry::Compaction::EAGER_CONTROL_ARM`, `"eager"`) rather than confusing it with a stated
  `"summarizing"` or similar — the same absent-versus-default distinction §9 draws for
  `context_pipeline`. And `lain bench variance` refuses to compare two recordings whose headers
  name different strategies, ending `cannot compare runs under different compaction arms: elide vs
  summarizing` (exit 1); a recording with no key compares fine against one explicitly naming the
  eager arm, because both ran the same arm.

Reaching the fallback itself needs volume and belongs to `rails-blog.md` §1b, which drives the
handoff end to end and checks it replays byte-identically.

### 7b — the idle tick prepares the cut while you are away

`--compact-schedule idle` (the default) commits the compaction cut during idle time, so the next
line pays no summarizer wait. A fresh chat ticks every 5 seconds, and a prepare runs only once the
chat has sat idle past the provider's cache TTL, or at least 120 seconds where the provider reports none
(ollama reports none). Drive it on ollama with a history already past `--compact-bytes`
(`rails-blog.md` §1 builds one; a low `--compact-bytes` on a short session also reaches it). Use a model whose context window is probed: a guessed window (`:guessed` provenance, e.g. a custom ollama model) withdraws the window-approach signal, so there a prepare happens only past `--compact-bytes`, silently.

1. Leave the chat at `you>` for 2 minutes. Type nothing.
2. Read the journal. `compaction_prepared` appears with the cut it committed:
   `jq -c 'select(.type=="compaction_prepared")' "$JOURNAL"`. Its `cache_state` is `presumed_cold`
   (no response confirmed the cache cold), `idle_seconds` is at least 120, and `cut_digest` matches
   the newest `compaction_cut`. The 120 holds only for a provider with no cache TTL, as ollama is; with a TTL it is just past that TTL. Exactly **1** per head: a second tick over the same head makes no
   second record and no second summarizer call.
3. Type a line. The reply starts with no summarizer wait, and `compaction_applied` follows with the
   same `cut_digest`. `compaction_prepared` then `compaction_applied` is the whole story; a prepared
   cut with no applied record means the chat ended or the head moved before a render sent it.
4. Type a line **while** a prepare is running. The line is not lost and not a note: the reply waits
   only for the rest of that prepare, then answers through the cut. A reply that waits for a second
   full summarizer call is the defect.
5. Repeat with `--compact-schedule turn`: no `compaction_prepared` ever appears, and the cut, when
   one is warranted, commits at the ask.

The window HUD and the StatusFeed show the pre-cut reading until the next reply, so `ctx N%` reads
high after a prepare and drops on the first reply. That over-reports and hides nothing; it is not a
finding.

**Read from the code, not driven live.** This section was not run against a live chat. The 5-second tick, `idle_seconds` of at least 120 for a provider with no TTL, 1 prepare per head, and a mid-prepare line waiting only for the rest of that prepare are stated from the code and its specs. Round 26 drives it.

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

| model | `input` | `output` | `cache_creation` | `cache_read` |
|---|---|---|---|---|
| `claude-opus-5` | **5** | **25** | 6.25 | 0.5 |
| `claude-sonnet-5` | 3 | 15 | 3.75 | 0.3 |
| `claude-haiku-4-5` | **1** | **5** | 1.25 | 0.1 |

Per MTok, verified 2026-08-18 against the loaded `PriceBook.default`. **`15/75` on the opus row is
the pre-chunk error returning.** `cache_creation` must stay exactly 1.25× input and `cache_read`
exactly 0.1× — a corrected input rate with a stale derived row is the half-fix to watch for.

**Those are the literal `Lain::Price` member names, and the columns are spelled that way on
purpose.** `Price.members` is `[:input, :output, :cache_creation, :cache_read]` — there is **no**
`#cache_write`, and typing the older prose name straight into `/ruby` raises `NoMethodError`. Two
separate drivers lost a turn to that on 2026-08-19.

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

(The day count is computed as `today - marker`, so it is not a fixed 200 -- driving this on
2026-08-23 prints **205**. Only the arithmetic is the assertion.)

**The marker's actual text is `Reviewed YYYY-MM-DD`** (`price_book.rb:60`), *not* "reviewed-on" —
that phrase appears only in the failure MESSAGE. Round 10 grepped the document's wording, found
nothing, and built a `gsub` probe that stripped nothing and therefore "passed"; the deleted-marker
case below is worthless unless it removes the real string. Verified 2026-08-23: a genuinely deleted
marker DOES fail (`no "Reviewed YYYY-MM-DD" marker found near the price table`), and the horizon
boundary is exact — 90 days ok, 91 stale.

`load`, not `require_relative`: the file has no `.rb` extension. **What wrong looks like:** the lint
exiting 0 with a marker it never found — check that a *deleted* marker fails too, since a regex that
stops matching silently turns the lint into a no-op that passes forever.

**The marker is literally `Reviewed YYYY-MM-DD`** (`MARKER = /Reviewed\s+(\d{4}-\d{2}-\d{2})/`,
one line above `DEFAULTS`). Use that exact string to drive the deleted case, and **assert your own
edit actually changed something** — on 2026-08-19 two independent drivers both guessed
`reviewed-on:`, stripped a string that does not occur in the file, and got `ok?=true, message=nil`,
which is precisely the silent-pass-forever shape this paragraph warns about. The probe reported the
defect it was written to catch, and the defect was in the probe:

```ruby
orig = File.read("lib/lain/price_book.rb")
src  = orig.gsub(/Reviewed\s+\d{4}-\d{2}-\d{2}/, "")
abort "the gsub matched nothing -- you are testing your own typo" if src == orig
p PriceFreshnessLinter.check(source: src, path: "lib/lain/price_book.rb", today: Date.today)
```

Correct output is `ok?=false` with
`no "Reviewed YYYY-MM-DD" marker found near the price table`.

## 9 — `--context-pipeline` resolves at LAUNCH, and the header reads it back

Six words ship — `default`, `reminder`, `cache-breakpoints`, `prune`, `dedupe-tool-calls`,
`purge-failed-inputs` — joined with `+` and folded **left to right**, so order is part of the name.
Like §7, everything here is settled while the `Backend` builds its `Context`: **no model call**, and
`< /dev/null` with no `--prompt` reaches the REPL, reads EOF and exits.

**The instrument is the `session` header, not the screen.** Nothing renders the pipeline; the header
carries a `context_pipeline` key **only when a pipeline was named**. `drive.sh`'s `ls -t` recipe
(`method.md`) is safe here because nothing else is writing, but pin the file anyway if a cockpit is
up:

```bash
header(){ ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next; next unless r["type"]=="session";
  puts(r.key?("context_pipeline") ? r["context_pipeline"].inspect : "(no key)")}' \
  "$(ls -t "$XDG_STATE_HOME/lain/sessions"/*/*.ndjson | head -1)"; }
count(){ ls "$XDG_STATE_HOME/lain/sessions"/*/*.ndjson 2>/dev/null | wc -l; }

run                                                      ; header   # unset
run --context-pipeline default                           ; header
run --context-pipeline prune                             ; header
run --context-pipeline 'dedupe-tool-calls+cache-breakpoints'; header
```

Driven against the built binary 2026-09-14 (`main` at `ea03482e`, sandboxed XDG, no model resident)
— every launch exit **0**:

| flag | header's `context_pipeline` |
|---|---|
| unset | `(no key)` — the header is byte-identical to every one written before the flag existed |
| `default` | `"default"` — renders the same bytes as unset, and is still told apart in the record |
| `prune` | `"prune"` |
| `dedupe-tool-calls+cache-breakpoints` | `"dedupe-tool-calls+cache-breakpoints"` — the name exactly as typed |

**A `"default"` on an unset launch, or `(no key)` on a named one, is the regression.** The first
would silently rewrite every recorded header's bytes; the second loses which arm a session was.

Then the refusals — count the session files around each, because **a refused name must leave no
journal behind**:

```bash
n=$(count); run --context-pipeline 'prune+nope';        echo "files $n -> $(count)"
n=$(count); run --context-pipeline 'prune+';            echo "files $n -> $(count)"
n=$(count); run --context-pipeline '';                  echo "files $n -> $(count)"
n=$(count); run --context-pipeline 'default+reminder';  echo "files $n -> $(count)"
```

Verified the same day — exit **1**, one line, **zero** backtrace frames, and the file count unchanged
every time:

```
unknown part "nope" in --context-pipeline "prune+nope", expected one of ["default", "reminder", "cache-breakpoints", "prune", "dedupe-tool-calls", "purge-failed-inputs"], or several joined by "+"
unknown part "" in --context-pipeline "prune+", expected one of [...], or several joined by "+"
unknown part "" in --context-pipeline "", expected one of [...], or several joined by "+"
repeated part "reminder" in --context-pipeline "default+reminder", expected one of [...], or several joined by "+"; each stage renders once, and "default" is reminder+cache-breakpoints
```

Read the last one carefully: `default+reminder` repeats no WORD, and is refused by the **stage** it
repeats, because `default` *is* `reminder+cache-breakpoints` and the workspace would be sent twice.
A launch that accepts it is the regression.

**The `default` tail is said only when `default` was typed** (since 2026-09-14; round 17's F123 found
it on every repeated-part refusal). *Driven 2026-09-14*, `--context-pipeline prune+prune`, exit 1:

```
repeated part "prune" in --context-pipeline "prune+prune", expected one of ["default", "reminder", "cache-breakpoints", "prune", "dedupe-tool-calls", "purge-failed-inputs"], or several joined by "+"; each stage renders once
```

and `default+reminder` still ends `; each stage renders once, and "default" is
reminder+cache-breakpoints` (driven the same day).

**A word REPLACES the default; it does not add to it.** `prune` alone sends no workspace reminders
and marks no cache breakpoints, and nothing degrades loudly, because nothing it requires is
missing. A driver who launches `prune` into a real session and files "the todo list stopped
reaching the model" has found the documented arm, not a defect — `prune+default` keeps both.

### 9b — the recorded name survives replay

`lain bench variance` reloads each recording and re-resolves its header's name, and it **refuses to
compare recordings whose pipelines render different stages**, because a pipeline difference would
otherwise be reported as the model's variance. Using the sessions §9 just wrote:

```bash
lain bench variance <the prune session> <the unset session>; echo "exit=$?"
lain bench variance <the unset session> <the default session>
```

Verified 2026-09-14: the first exits **1**, no backtrace, ending
`cannot compare runs under different context pipelines: prune vs unset`; the second **reports**,
because an unset flag and `default` render the same stages. A table for the first pair is the
regression; a refusal for the second is too.

### 9c: the bench arm flags

Three flags select bench arms: `--confine off|classes|reader`, `--judge-facts off|facts|request` and
`--tripwire off|observe`. The defaults are `reader`, `off` and `observe`: a plain launch runs the sandbox and the
observe-only tripwire. An unknown value refuses at launch, exit 1, with no session file and no tmux session
(`unknown --confine value "bogus", expected one of off, classes, reader`). The header (the `session` record)
records only the arms that are on, as `"arms":{"confine":"reader","tripwire":"observe"}` for a plain launch, and
a launch with every arm off writes no `arms` key at all. The arms act: `--confine` and `--tripwire` change what
a bash call runs under and what the journal holds, so a header that names an arm is evidence the arm was built,
but not that it ran. A box that cannot build the sandbox still records `confine: reader` in the header, with a
`capability_degraded` record and a startup notice that bash runs unconfined. `bench variance` ignores `arms`. **A `--resume` or
`--fork` keeps the recorded arms** (round 25, a25-2, fixed), with a flag typed on the resume winning over the record: an arm the old header
did not record is off, and a header with no `arms` key at all (every session on disk before the arms existed) resumes with every arm off,
not with today's defaults. An arm that resumes weaker than a fresh chat's default and was not typed gets one notice, for example
`running without --confine (off), as recorded; a fresh chat runs reader (pass --confine reader to run it)` (and the tripwire's
equivalent); a typed flag that differs from the record gets `recorded with --confine reader; continuing with off (the current flags win)`.
Driving every arm is
[`bash-confinement.md`](bash-confinement.md); this section only reads the header.

Verified 2026-10-17 against `06375702` on a no-nvim chat run with `--non-interactive`: the plain launch wrote the
header above, `--confine off --tripwire off` wrote none, and `--confine bogus` refused by name.

### What §9 cannot reach

- **Spawn inheritance.** A child renders through its parent's pipeline — its `Context` comes from
  the same factory, and the persona swap keeps the name — but a child's requests are not journaled
  (`request_sent` is wired into the main agent only), so the record cannot show it. It is spec-owned
  (`spec/lain/role_spec.rb`, "reshapes the factory context without dropping its named pipeline").
- **`--resume` / `--fork`.** They do **not** inherit the recorded name: the resumed header carries
  whatever the new launch was given. Documented behaviour today, not a finding.
- **`lain up PATH -- --context-pipeline <typo>`** refuses in the pre-flight, on the operator's own
  terminal rather than in a dead tmux pane, and creates no session. **Driven by round 17** — it held
  as written.

## What this scenario does not cover

The **compaction path at scale** — filling the context until a compaction actually fires. Rounds 3
and 4 both failed to reach it (round 3 died to F10, round 4 to the then-per-session iteration
ceiling), which makes it the least-exercised path in the whole QA suite. The ceiling is per-ask since
T14, so the obstacle is now only volume: **`rails-blog.md` §1 is where that act now lives**, and it
carries the precondition (real tool bytes) that a short session cannot satisfy.
