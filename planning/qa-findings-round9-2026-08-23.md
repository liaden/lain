# QA round 9 — 2026-08-23

## Summary

**The full round was driven in one context, with the subject slot filled properly for the first
time since round 8's second pass.** `session-and-window` (§1–§8, complete), `rust-cli` (including
the deliberate compile-error unhappy path and recovery), **`bowling-ruby` as the subject** —
`cockpit-surfaces` piggybacked on it per README's rule rather than on the smoke test —
`bench-arms`, and `failure-injection` §1, §2, §3, §11a. `cockpit-surfaces` covered §1, §2, §3, §4,
**§4b (only its second drive ever, and the README's named #1 item for this round)**, §5, §5b, §6,
§7 and §8.

**The headline is a controlled measurement that overturns a standing claim in `bench-arms.md`.**
F54: `num_batch` **does** re-key the ollama runner. With a `-b 512` runner resident, one `lain chat`
carrying `LAIN_NUM_BATCH=2048` reloaded it (pid 2176470 → 2177020, `-b 512` → `-b 2048`); repeating
the identical request against the now-matching runner did **not** reload (same pid). Round 8
concluded the opposite from an uncontrolled observation, and `bench-arms.md` currently tells drivers
to warm with `ollama run` — which produces a `-b 512` runner that lain then reloads, so the advice
does not prevent the ~27s first-arm outlier it was written for.

**Round 8's four approval-surface defects are in good shape: F40, F42, F44 and F45 do not
reproduce, F48 is fixed, F43 persists with a changed symptom.** Round 7's F29 fix holds, F27 stays
withdrawn, F34 and F38 are confirmed fixed again, and F23 (fork/resume of a spawned session) passes
with a valid control pair.

**Two of README's named gaps are closed by this round**: the plain `--no-nvim` approval path works
(prompt renders, `y` is consumed, turn completes), and §4b's note rail passes end to end including
the placement-order check it exists for.

Four new findings (one MEDIUM feature gap, one MEDIUM UX, two LOW UX), one overturned measurement,
two scenario corrections, three process defects.

| id | sev | what |
|---|---|---|
| **F54** | **MEDIUM (overturns a doc claim)** | `num_batch` DOES re-key the ollama runner — controlled before/after pair with a matching-request control; `bench-arms.md` says it does not, and its "warm the model first" advice does not prevent the reload |
| **F51** | **MEDIUM (feature gap)** | no journal record names the collapse strategy `--compact-strategy` selected — `compaction` has no `strategy` member, and `context_derived.strategy` names the *derivation* class (`Source::Derived::Held`), a different axis |
| **F50** | **MEDIUM (UX)** | `.lain/state.json` is written into the project root with no ignore path, rewrites every turn, and is committed by a `git add -A` — lain's own repo gitignores it (`.gitignore:22`); a user's project gets permanent `git status` noise |
| F52 | LOW (UX) | `lain://approval`'s trailer lines each become their own closed one-line fold; the affordance line renders with fold-fill `··` appended (round 8's F43, symptom changed) |
| F53 | LOW (UX) | `lain: handed 1 note back; their markers go with them` — plural possessive on a single note |
| P11 | process | **both** close-out negatives are blind to `.lain/` written into the launch cwd — the XDG `find` cannot see it and `git status` cannot either, because lain's repo gitignores it |
| P12 | process | `pgrep`/`pkill -f` self-match killed the issuing command (exit 144) — **6th round running**, and hit here having read the warning |
| P13 | process | this shell is zsh: unquoted `$A` does **not** word-split, so a loop passing `--num-ctx 0` sent it as one joined argument and produced a Thor usage error that reads like a refusal |

## Round-8 defects re-checked

| id | verdict | evidence |
|---|---|---|
| **F40** | **FIXED** | 12 `approval_pending` / 12 `approval_decision` in one rust session, answered across BOTH surfaces. `call_i56e1vrp` answered via `:LainApprove` journals `rung:"surfaces", reason:"a surface approved this call (nvim)"`; the very next gated call in the same ask (`call_dpm11x9y`) rendered a normal `[y/N]` prompt in the chat pane and was answered `(tty)`. Round 8's 11-pendings→1-prompt shape is gone. |
| **F42** | **FIXED** | the pending row folds **open** at rest — `foldclosed(1..3) == -1` — and the pane shows the full command on lines 2–3. Round 8's symptom (row closed, command hidden behind a truncated summary) does not reproduce. |
| F43 | **PARTIAL — differently, arguably better** | the mechanism persists: lines 4 and 5 are each their own closed one-line fold (`foldclosed(4)==4`, `foldclosed(5)==5`). The *symptom* changed: the blank separator now renders blank rather than as a full-width `·` bar, but the affordance line renders as `-- y approve, n deny  (:LainApprove / :LainDeny)··`. Filed as F52. |
| **F44** | **FIXED** | `lain://approval` primes at attach with **no window** (tab2 = 4 windows: journal/timeline/inbox/request); the window opens when a pending arrives (tab2 = 5) and is **gone again** after the pendings are answered — the bowling session, having answered 7 pendings, read `tab2=4`. |
| **F45** | **DOES NOT REPRODUCE** | the model's `bash` call ran `bundle install` then `bundle exec rspec` in `$QA/project` and resolved the **project's own** bundle: a 1199-byte `Gemfile.lock` listing only rspec, against lain's 19395-byte lock. lain's own `Gemfile.lock` md5 unchanged across the whole round (P9 also does not reproduce). |
| **F48** | **FIXED** | `--fork` on the torn session says `cannot fork TORN-turn.ndjson: …`; `--resume` on the same file says `cannot resume TORN-turn.ndjson: …`. Each door carries its own prefix. |
| F46, F47 | **NOT DRIVEN** | both need an interrupt landing inside `Agent#step`'s tool-dispatch window; `failure-injection` §6 was not reached. Not a pass. |
| F49 | **NOT DRIVEN** | `lain friction`'s cache_waste needs `rails-blog`, which is an owed round. |

## Round-7 fixes re-confirmed

| id | verdict | evidence |
|---|---|---|
| F29 | **HOLDS** | `/status` typed as the very line after `/inbox` renders normally; journal unchanged 208→208; `inbox 1` still parked. The drain classifies like the outer prompt. |
| F27 | **STAYS WITHDRAWN** | `/status` at a bare `human>` renders, journal unchanged, question still parked. |
| F34 | **HOLDS** | after `<CR>` on a review row the tab holds 3 windows and focus is **taken to the sidebar** (`winnr()==1`, `bufname()=="lain://review"`). |
| F38 | **HOLDS** | `x` acknowledges by ROW: `lain: marked reviewed: 1 hunk(s) of ../tally/lib/tally.rb`, not the old digest form. |
| F23 | **HOLDS** | spawned session (`message=4 child_turn=6 turn=58`, 6 causal-parent refs, **0 unresolved**) forks and resumes, both **exit 0**. Control (a session with `message=0`) also forks, exit 0. |

---

## F54 — `num_batch` re-keys the ollama runner; `bench-arms.md` says it does not

**MEDIUM.** `bench-arms.md` states: "**`num_batch` does not re-key the runner, though `--num-ctx`
does.** Both round-8 arm runs sent `num_batch: 2048` against a runner whose argv read `-b 512`,
across two full suites, with residency unchanged throughout." That is wrong.

**Evidence — a controlled pair, with the control that rules out "lain always reloads":**

```
# 1. load a runner with ollama's own defaults, no num_batch anywhere
curl -s localhost:11434/api/generate -d '{"model":"qwen3-coder:30b","prompt":"hi","stream":false,"options":{"num_predict":1}}'
runner 2176470  ->  -c 32768  -np 1  -b 512  -ub 512

# 2. ONE lain request carrying LAIN_NUM_BATCH=2048
LAIN_NUM_BATCH=2048 lain chat --provider ollama --model qwen3-coder:30b --no-nvim --prompt 'say hi in one word' < /dev/null
runner 2177020  ->  -b 2048        # PID CHANGED: the runner was reloaded

# 3. THE CONTROL — repeat the identical request against the now-matching runner
LAIN_NUM_BATCH=2048 lain chat ... --prompt 'say hi in one word' < /dev/null
runner 2177020  ->  -b 2048        # SAME PID: no reload
```

The reload is caused by the **mismatch**, not by lain. This also re-measures and **confirms**
`bench.md`'s `-b 512` claim, which I had doubted after seeing `-b 2048` on a live runner — that
runner had been loaded by a previous lain request, which is exactly the mechanism.

**Why it matters beyond the doc.** `bench-arms.md` tells a driver to "warm the model before the run
if the wall-time column is the subject", and `bench.md`'s warming recipe is `ollama run
qwen3-coder:30b ""` — which produces a `-b 512` runner. lain then reloads it on the first arm, at
`bench.md`'s own ~27s. **That is a better explanation for the ~27s first-arm outlier rounds 4 and 8
both recorded** than the generic "first-load cost" now written into the scenario. It also means
round 6's 30.9s→9.3s reading *does* generalise to lain's own launches, contrary to the note
currently retiring it.

**Corroborating negative:** my own `bench arms` run showed **no** outlier (single-thread max 1.8422s
against a 1.3935s median) — because the runner was already at `-b 2048` from the preceding lain
sessions, so nothing reloaded.

**Fix shape:** correct both documents. What would pin it: warm through a lain request (or one
matching `num_batch`) rather than through `ollama run`, and have `bench arms` record the runner's
argv in its attribution header, where it would be visible beside the wall-time column it explains.

## F51 — no record names the collapse strategy the run resolved

**MEDIUM, feature gap.** `--compact-strategy` composes four names with `+` and is refused, resolved
and composed at launch (`session-and-window` §7 passes in full). Nothing then records which strategy
ran.

**Mechanism.** `Telemetry::Compaction` is
`Data.define(:trigger, :cache_state, :bytes_before, :bytes_after, :cost_saved, :cost_spent, :model)`
(`lib/lain/telemetry/compaction.rb:141`) — there is no `strategy` member. Its own docstring says the
record exists so "`Compare` can attribute a cost delta to the scheduling policy rather than to the
summarizer itself", but a delta cannot be attributed to a *strategy* that is absent.

**Evidence that rules out the innocent explanation.** `context_derived` *does* carry a `strategy`
field, which is what makes this easy to mis-read as covered — but across all 15 records it holds
`"Lain::Compaction::Source::Derived::Held"`, the source-**derivation** class, on every one. Grepping
the whole 311-line journal for any of the four collapse names (`elide-tools`,
`summarize-conversation`, `summarizing`, `elide`) returns **nothing**.

**Reproduction:** any session that compacts.

```bash
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next; next unless r["type"]=="compaction";
  puts "trigger=#{r["trigger"].inspect} strategy=#{r["strategy"].inspect}"}' "$JOURNAL"
# -> trigger=["plan_step_completion"] strategy=nil    (x15)
grep -cE '"(elide-tools|summarize-conversation|summarizing|elide)"' "$JOURNAL"   # -> 0
```

**Why it matters here specifically.** CLAUDE.md's first line is that the bench is the deliverable
and context strategies must be "swappable, observable, and comparable". The arm under test is
swappable and it is not observable: a round comparing two strategies can only recover which one ran
from the launch flag it typed, not from the experiment record. Everything else about a compaction —
why it fired, what cache state, how many bytes, what it cost, which model priced it — is recorded
with unusual care.

**Fix shape:** add `strategy` to `Telemetry::Compaction`, carrying the operator's own composed word
(`"elide-tools+summarize-conversation"`), the way `bench arms`' header prints the operator's
`--isolation` word rather than a class name. What would pin it: a journal reduction that can group
`bytes_before - bytes_after` by strategy name without consulting the launch command.

## F50 — `.lain/state.json` dirties every user project, with no ignore path

**MEDIUM (UX).** `Project` writes `.lain/state.json` into the project root and rewrites it every
turn (`elapsed`, `idle`, `occupancy` all move). Nothing adds it to a `.gitignore`, and lain never
writes one — `grep -rn gitignore lib/ exe/` finds only *readers* (`shadow_git`, `survey/walk`,
`tools/grep`, `frontend/completion/sources`).

**The evidence that makes it a finding rather than a preference:** lain's own repository gitignores
it — `.gitignore:22` is `/.lain/`. The people who hit this fixed it for themselves and not for the
projects lain is pointed at.

**Reproduction:**

```bash
mkdir -p /tmp/x && cd /tmp/x && git init -q && lain chat --provider ollama --model M < /dev/null
git status --porcelain     # -> ?? .lain/
git add -A && git commit -qm seed
# one lain turn later:
git status --porcelain     # ->  M .lain/state.json, forever, on every turn
```

Observed live: this round's subject repo has `.lain/state.json` **tracked** (`git ls-files` lists
it) because the seed commit's `git add -A` swept it in, and it then showed as ` M` after every turn.

**Fix shape:** either write `.lain/` into the project's `.gitignore` on first use (announcing it), or
put the mutable half under `XDG_STATE_HOME` beside the journal, which is already redirectable and
already where per-session state lives. What would pin it: a seam spec that runs a turn in a git
project and asserts `git status --porcelain` is empty afterwards.

## F52 — `lain://approval` trailer lines fold as one-line closed folds

**LOW (UX).** Round 8's F43 with a changed symptom, so it is filed rather than folded into the
re-check table.

Measured, on both of two separate pendings, identically:

```
line 1: level=1 closed=-1 closedend=-1     <- row summary   (open)
line 2: level=1 closed=-1 closedend=-1     <- full command  (open)
line 3: level=1 closed=-1 closedend=-1     <- full command  (open)
line 4: level=1 closed=4  closedend=4      <- blank separator, its OWN closed fold
line 5: level=1 closed=5  closedend=5      <- affordance,      its OWN closed fold
```

The affordance line renders as `-- y approve, n deny  (:LainApprove / :LainDeny)··`, the trailing
`··` being nvim's `fold:` fillchar (confirmed with `capture-pane -p | cat -A` → `M-BM-7M-BM-7`).
Neither line is a record and neither has anything to hide, so folding them means the one line that
tells a human *how to answer* wears a fold marker.

Note this also means **`cockpit-surfaces.md` §8 step 2 is now wrong as written**: it expects each
row's first line to read `foldclosed(<line>) == <line>` at rest. The record row is open at rest, and
what is closed is the trailer. Corrected in the scenario.

## F53 — plural possessive on a single note

**LOW (UX).** `:LainNoteDone` with one note pending acknowledges
`lain: handed 1 note back; their markers go with them`. The count is correctly singularised and the
possessive is not. Reproduction: place one note, `\LN`.

---

## Scenario corrections — the documents were wrong, not lain

These cost driver time this round and would cost the next round the same, so they are corrected in
place and recorded here.

### `session-and-window.md` §4 — the three readers agree with a **one-turn lag**

§4 says "`compaction_decision.used_tokens` should equal the matching `turn_usage.usage.input_tokens`
(round 4: both 4515, exactly)". Read as same-index, that is **0/29** on this round's session and
reads as a defect. The real relationship, over 29 decisions and 29 usages:

```
decision[i] == turn_usage[i-1]   ->  28/28 pairs
decision[i] == turn_usage[i]     ->  0/29 pairs
decision[0].used_tokens          ->  nil        (cold: nothing measured yet)
```

The decision is made **before** the turn and can only use the last completed turn's measured usage,
so the lag is inherent and honest. Round 4's exact equality was a short session where the pairing was
unambiguous. **The three readers do agree** — the last decision read `used=14100 window=32768`,
`state.json` read `occupancy: 0.2562…`, and the HUD read `ctx 26%`, each consistent with the turn it
belongs to.

### `bench.md` — `ollama run <model> ""` does not return

The residency recipe `ollama run qwen3-coder:30b ""` **hung in interactive mode** and had to be
killed after 3m20s. Use the API instead:

```bash
curl -s localhost:11434/api/generate \
  -d '{"model":"qwen3-coder:30b","prompt":"hi","stream":false,"options":{"num_predict":1}}' >/dev/null
```

### `session-and-window.md` §8 — the lint's day count is computed, not fixed

§8 quotes the stale-marker output as "200 days old". It is `today - marker`, so driving it with
`Date.today + 200` prints **205** today. Only the arithmetic is fixed; the figure in the doc was
true on the day it was written.

---

## What passed, in brief

Recorded because "success is not nothing went wrong" cuts both ways — these are the assertions that
now have evidence behind them.

- **`session-and-window` §1** — 9/9 launch refusals by name, exit 1, zero backtrace. The trained
  maximum (262144) arrived with residency verified **COLD**, which is what makes it a real reading.
- **§2** — 25.887s at the default connect timeout, 7.892s at `LAIN_CONNECT_TIMEOUT=1`. Ordinals
  `1, 2, 3` then **`attempt 4, giving up`** — F16's repeated ordinal is not back. Backoffs render at
  two places (`0.14s`, `0.21s`, `0.41s`). Attribution via `pathcount.rb`: **6 connections = 2× `GET
  /api/ps` + 4× `POST /api/chat`** — four attempts, four ordinals, no hidden retries.
- **§3** — turn 1 cold: `window=8192 prov="guessed" sig=[]`. Turns 2–29: `window=32768
  prov="probed"`. The window **re-resolves mid-session**; T6's memoization regression is not back.
- **§5** — exactly one `capability_degraded`, and nothing on screen.
- **§6** — `extra={"num_batch" => 2048}` with the knob, `extra={}` with `env -u`. Only what was asked
  for.
- **§7** — all four names listed in every refusal; the empty and trailing-separator cases name the
  PART and the whole value separately (`unknown part "" in --compact-strategy "elide-tools+"`);
  `elide+summarizing` launches, as designed.
- **§8** — opus 5/25/6.25/0.5, sonnet 3/15/3.75/0.3, haiku 1/5/1.25/0.1 per MTok; `cache_creation`
  exactly 1.25× input and `cache_read` exactly 0.1× on all three. `claude-fable-5` and
  `claude-mythos-5` raise by name. The freshness lint passes live, fails at +200 days, and fails with
  the marker deleted — and the `gsub` guard confirmed my edit actually matched.
- **`rust-cli`** — end to end. The driver-injected `fn main(x: i32)` was found and fixed, `cargo
  test` went 3-passed-1-failed → **4/4**, and the DoD one-liner returns `the 3` / `cat 1`. Multi-line
  `cargo` stderr diagnostics survived intact as tool results.
- **`bowling-ruby` (the subject)** — **5/5 oracles**, including the load-bearing oracle 4 (133) and
  the tenth-frame oracle (30).
- **`cockpit-surfaces` §1** — all seven views primed with placeholders; `lain://journal` holds
  `(no streamed tool output yet)` (T18 holds) and, once real output appended, the placeholder was
  **replaced not stranded** (linecount 1, holding only the `rustc` line).
- **§2** — all four views moved across two asks (timeline 24→54, request 865→1310, diff 598→1037,
  journal 16→122) against `turn_usage` 12→27. F17 is not present.
- **§3** — `not attached yet` then `attached -- layout opened`, in that order.
- **§4** — every refusal delivered cleanly: **0 `stack traceback:` anywhere**, `nvim_get_mode()
  .blocking == false` on every one. `v:echospace=88` against `&columns=100`, and the 158-character
  partial-verdict refusal was **middle-elided to fit** with the full sentence preserved in
  `:messages` — T5's width rail working as designed. The full approve both acknowledged
  (`lain: this review is settled: approve`) **and** journalled
  `review_verdict` with `changeset_digest: "survey-corpus-v1:e438a728…"`.
- **§4b** — the section README named #1 for this round, and it passes. `\Ln` leaves the cmdline open
  (`mode()=="c"`, `getcmdline()=="LainNote note "`). All four markers render `right_align` with the
  correct kinds, **including `blocker`**. **The payload arrived in placement order 5, 9, 2, 3** —
  not the positional 2, 3, 5, 9 that `nvim_buf_get_extmarks` returns natively, which is the check
  this section exists for. `drifted: false` is present on every record. A second `\LN` sends nothing
  and says so. And the `blocker` kind is demonstrably what the verdict policy reads: `approve` refused
  over it by name, and answering it with a note on the same line resolved it exactly as the refusal's
  remedy promised — an end-to-end demonstration §4b asks for and had never had.
- **§5** — all five surfaces agree on a live pending (pane names `agent asks:`, `lain://approval`
  holds the full command and the affordance, `state.json` `approvals_pending: 1`, journal
  `approval_pending` with `requester`, and `config.toml` never created). The escalation ladder is
  fully journalled and names *which* surface answered — `(tty)` vs `(nvim)`.
- **§5b** — all five steps. Step 4's refusal is better than the scenario predicted: `error:
  /nonsense is not a registered command -- nothing ran, and nothing was answered. If you meant it as
  text, start the line with a space` — it names the escape hatch as well as the fault.
- **§6** — the timeline moved on the multi-line reply (54→56) and again on the next ask (56→58), with
  no one-line-per-record marker. Multi-line prose is correctly folded to one row per record.
- **§8 step 5** — the continuation-line case: `:LainApprove` with the cursor on line 3 (a *detail*
  line) resolved that row's call. No "nothing on that row", no neighbour answered.
- **`bench-arms`** — header attribution complete, `isolation: unset — Arm::NoIsolation leased
  nothing` verbatim, **no credential or base URL anywhere**. All three conjoined checks pass: means
  0.812 / 0.812 / 0.938 against a 0.0625 floor, and a real token row for **every** arm (222.0 /
  447.2 / 3273.6) so no arm is faking a grade on its own timeline. The cost section refuses by name
  (`not priced — no price for model "qwen3-coder:30b"`) **while the rest of the report renders** —
  the failure that actually broke. No `StalledStreamError`. Highly reproducible against round 4:
  grades identical, tokens within 1%.
- **`failure-injection` §1** — 311 and 216 lines, **0 unparseable, 0 `journal_error`**, and both
  sessions carry `parent` **and** `causal_parents`, so §3 tested something (unlike round 4).
- **§2** — the torn session advertises **42 turns vs 43, the same head digest, and `1 line
  unparsed`**; both doors then refuse `turn record 3 (user) recorded as blake3:b004… re-commits to
  blake3:fde4…`, exit 1, **0 backtrace frames**. Invisible at rest, unforgeable on use — both halves.
- **§3** — six door×damage combinations, all `Corrupt`, all exit 1, all 0 frames. The dangling case
  correctly uses the **message** index space (`message record 14 (message) cites a causal parent this
  replay never landed`). The malformed case is **better than documented**: rather than borrowing the
  dangling vocabulary, it has its own sentence naming the bad value — `records causal_parents as
  [nil, "blake3:…"]; the field is a set of digest strings, and only an array of them lands`.
- **§11a** — all three construction refusals reach the operator's terminal through `lain up`, exit 1,
  no backtrace, **no session created**, and — the caveat that decides whether the section tests
  anything — **no "opening the cockpit unchecked" degrade warning**, so the pre-flight genuinely ran.
- **The plain `--no-nvim` approval path** (README's named gap) — `agent asks: approve
  bash({"command" => "echo PLAINPATH"})? [y/N]` rendered, `y` was **consumed**, the call ran, the turn
  completed. Round 4's permanent wedge does not reproduce.
- **Live constants, read through `/ruby` rather than off the source**: `WHOLE_BOUND.limit=262144`,
  `WINDOW_BOUND.limit=1048576`, `BYTES_PER_TOKEN=4` — matching the bounds named in the tool schemas
  the model is actually sent, so schema and enforcement have not drifted.

## Withdrawn before filing

- **`cost_saved`/`cost_spent` arriving as JSON strings (`"0.0"`) rather than numbers.** Nearly filed;
  `lib/lain/telemetry/compaction.rb` documents it and says explicitly "Ask `#priced?` rather than
  comparing against `"0.0"`". Documented design, not a defect.
- **`summary_hits: 0` across all 15 compactions while `summary_misses` climbs 1→14.** Inconclusive,
  not filed: no summarizer was declared in this session, so there was no cache to hit. What would
  settle it: drive `bowling-ruby` §1's `/meta summarizer` path (including the `.lain/summarizers.rb`
  copy step that scenario warns is easy to miss) and re-read the same reduction.
- **The HUD missing `ctx N%` at the first `you>`.** It is absent only while `state.json` has
  `occupancy: null` — before any turn. It appears from the first turn on. Honest elision.
- **`bench.md`'s `-b 512` claim.** I saw `-b 2048` on a live runner and doubted it; a clean reload
  with no options gave `-b 512 -ub 512`. The doc is right — the `-b 2048` runner had been loaded by a
  previous lain request, which is F54.

## Model behaviour — not lain defects

- **`qwen3-coder:30b` writes correct code and wrong specs.** Its bowling implementation passes 5/5
  driver oracles while its **own** specs fail 7/11, and the failures are its assertions, not its
  code: it asserts a tenth frame of `10,5,5` scores 25 (it scores 20) and `5,5,5` scores 20 (it
  scores 15). Same shape in `rust-cli`: it asserted 6 unique words where the input has 9. This is
  the sharpest evidence yet for `bowling-ruby` §3's question — the plumbing worked perfectly and the
  *test* artifact was not worth having, even though the implementation was.
- **It spawned a subagent unprompted, twice**, in both sessions, producing `message` and `child_turn`
  records without the documented `@researcher[/critique]` grammar. Convenient here (it gave §5b and
  F23 a free precondition) but worth knowing: `method.md` says a bare `@researcher <question>` does
  not spawn, and this was not that — it was the model reaching for the `subagent` tool on its own.
- **No `<function=` literal appeared this round**, in either session. No restart was needed.
- **It does not emit parallel tool calls.** Confirmed again: 12 gated calls across one rust session,
  strictly one pending at a time. `cockpit-surfaces` §5's three-at-once notifier property remains
  **undrivable with this model** and is still an open half of F24 — not a pass.

## Process notes

- **P11 — both close-out negatives are blind to `.lain/`.** My `session-and-window` §1/§2/§7 probes
  ran with cwd = the lain checkout, so lain wrote `.lain/state.json` **into the repo**. The XDG
  `find` cannot see it (it is not under `~/.local/state/lain`) and `git status --porcelain` cannot
  either (`.gitignore:22`). Both negatives passed while a file sat outside the sandbox. Cleaned up
  manually; a third close-out check is now in `method.md`. This is round 8's P9 one level over: the
  sandbox's own negative cannot see what the sandbox does not contain.
- **P12 — `pkill -f` self-match, sixth round running.** `pkill -f 'ollama run qwen3-coder'` matched
  the agent shell's own command line and killed the command issuing it (**exit 144**), losing the
  probe mid-run. `method.md` documents this trap and names five prior occurrences; I hit it anyway,
  reaching for it reflexively while cleaning up a hung process. The reliable form
  (`ps -eo pid,args | grep '[o]llama run' | awk '{print $1}'`) worked first try. Worth treating as a
  standing hazard rather than a lesson anyone has learned.
- **P13 — this shell is zsh, and zsh does not word-split unquoted parameters.** A `for A in
  "--num-ctx 0" "--compact-strategy nonesuch"` loop passed each as **one joined argument**, producing
  `ERROR: "lain chat" was called with arguments ["--num-ctx 0"]`. That is a Thor usage error wearing
  the shape of a construction refusal, and both `exit=1` and `has-session` failing made it look like
  a pass. Re-driven with explicit arguments, §11a passes properly. `method.md`'s scenarios are
  written in bash idiom; a zsh driver must quote or use arrays.
- **An orphaned tmux server from round 7 is still on this box** — `tmux -L ctrlc2-2805074 … bundle
  exec exe/lain chat --no-journal`, started **Aug 20, elapsed 3d 02:45**, with no child processes and
  no CPU. It was not contending during this round (checked, precisely because `bench-arms`' wall-time
  column is a timing claim), but it is exactly the contaminant `method.md` names, and it is three
  days old. Left in place rather than killed — it is another context's server, not mine.
- **`n_slots` and `OLLAMA_NUM_PARALLEL` recorded as bench.md requires:** the runner's argv reads
  `-np 1`, and `OLLAMA_NUM_PARALLEL` is unset (default). Both are **1**, so every contention reading
  in the scenarios holds for this round.
- **Sandbox proof.** `find ~/.local/state/lain -newermt '2026-08-23T12:37:58Z'` → **0**, positive
  control `-newermt '2026-08-19'` → **468**. The `Z` was kept and the control is non-zero, so the 0
  is evidence rather than a spelling accident.
- **Desktop.** The whole round ran with `LAIN_DESKTOP=0` exported **before** the tmux server was
  started; every pane reported `1` on the `LAIN_DESKTOP=0` environ check, on both cockpits.
  `dunstctl count displayed` and `waiting` were **0** at start and **0** at close-out, which is the
  negative that proves it — approvals are raised `-u critical` and never auto-expire, so any that
  fired would still be on screen. **No act ran with the notifier on**, so §5's three-at-once and
  withdrawal checks were not exercised; see below.
- **Repo close-out.** `git status --porcelain` on the lain checkout is **byte-identical to the
  baseline** taken before act 0, and `Gemfile.lock`'s md5 is unchanged
  (`f51222770364686a2cb61b9845368b05`). Round 8's P9 does not reproduce.
- **nvim 0.12.4**, above the stated 0.11 minimum, so every reading here is trustworthy on that axis.

## What was not reached, and why

Named rather than left as apparent coverage.

- **`failure-injection` §4, §5, §6, §7, §8 (live bounds), §9, §10, §11b, §12.** §1–§3 and §11a were
  driven; the rest were not, on budget. §7 (the iteration ceiling) needs 25 model calls in one ask
  and §12 needs the logging proxy. **The constants behind §8/§9 were read live through `/ruby`** and
  agree with the tool schemas, so what is un-driven there is the *firing*, not the ceiling.
- **The supervisor door in §3.** The scenario names four doors and says explicitly not to mark an
  unreached one as passed. I drove `--fork`, `--resume` and the bench door against three damage
  shapes; the supervised-restart door I did not reach. **Not a pass.**
- **`cockpit-surfaces` §4b's thread pane** (`\Lt`) — the one part of §4b that spends a model call.
  Everything else in §4b was driven. This also leaves round 7's other named `:LainReviewDone` leg
  (`51_thread.lua:639` raising out of a `BufWriteCmd`) still owed, since reaching it needs the thread
  pane.
- **`cockpit-surfaces` §8's two-row independence check** (steps 2–4). Only ever one pending existed
  at a time, because this model does not batch tool calls. Step 5 (the continuation line) *was*
  driven and passes. The multi-pending fixture that scenario asks for still does not exist and is
  still worth building.
- **`bowling-ruby` §1 (`/create-plan`) and §3's `/critique`.** The subject was driven directly to a
  graded artifact instead. §3's *question* is answered with strong evidence anyway (see model
  behaviour), but the `/critique` rail itself was not exercised, and the T14 iteration-ceiling
  piggyback that rides on §1 was therefore not driven either.
- **An empty-file review row** (§4's "no hunk on this row" refusal) — the tally corpus has no empty
  file. The other two `x` refusals were driven.

## Owed rounds — scheduled, not dropped

These own their own context by README's rule, so they are **not** casualties of this round's budget
and should not be read as gaps in it:

- **`rails-blog`** — owed, as always, and now the only place §2 (unbounded tool output) can be
  reached; round 8 got §1 but explicitly not §2.
- **`secret-boundary`** — README schedules this as round 9's rotating owned round. **It was not
  run**, and it remains the largest untested surface here: every claim about the three-place split
  still rests on specs alone. It should be round 10's, before the rotation moves on.
- **`changeset-review`**, **`subagents-and-backends`**, **`memory-and-dogfood`** — the remaining three
  of the four added 2026-08-23, still driven **zero** times.

Of the thirteen scenarios in `planning/qa/scenarios/`, this round drove six
(`session-and-window`, `rust-cli`, `bowling-ruby`, `cockpit-surfaces`, `bench-arms`,
`failure-injection`). `repl-commands` and `epic-tier` — the two added to the regression gate on
2026-08-23 — were **not** driven and have still never been driven; they are cheap and deterministic
and should lead the next gate.
