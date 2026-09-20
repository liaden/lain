# Scenario: the arm driver

**What it exercises:** `lain bench arms` — the **four** orchestration arms (single-thread control,
orchestrator-worker, dual-ledger, adaptive-router), the grader, the token ledger, and since 2026-08-18 the **cost
column and the attribution header**: whether the report says what produced it, and whether it
refuses to quote a price it cannot stand behind.

**Cost:** ~5 minutes, no interaction. **Precondition: the chat is closed.** A second model on one
GPU evicts the first, which is a measured 84.0s against 7.5s.

**Needs:** `bench.md` up, model resident at the context the run will use (else pay a reload).

---

```bash
lain bench arms spec/fixtures/arms/tasks.yml --provider ollama --model qwen3-coder:30b \
     --cheap-model qwen3:4b --isolation worktree --journal "$QA/records/arms.ndjson"
```

**Run it from a scratch git repository, not from lain's checkout** — `--isolation worktree` needs a
repository to branch checkouts from, and the sandbox's is the one to lend it (the 2026-09-14 drives
below ran from an empty-commit repository with the fixture named by absolute path).

**Round 18 put every model-calling command on one flag band, and `bench arms` is one of them.**
`ModelFlags` declares `--provider`, `--model`, `--api-base`, `--num-ctx` and `--num-batch` on
`chat`, `epic submit`, `bench record`, `bench arms`, `consolidate` and `improve` alike, and it
replaced `RECORD_FLAGS`/`ARMS_FLAGS`' backend halves and `EpicSubmit::Adjudication.flags`. Three
consequences worth driving here, because this is where the old split bit hardest:

- **The throughput flags reach the bench now.** `LAIN_NUM_BATCH=2048 lain bench arms …` against
  the local runner must show **no `-b 512` reloads** in the ollama log — the arms carry
  `num_batch`/`num_ctx` into their requests the way a chat does, where before they could not and
  every arm quietly ran the runner at ollama's own default.
- **The flags declare no Thor default**, so an unset flag is distinguishable from one typed at
  the default value. That is what makes a recorded profile usable; a band that defaulted would
  make every flag look typed.
- **`--provider` still resolves to `anthropic` when nothing names one**, so `.envrc`'s
  `LAIN_PROVIDER` does not silently decide a bench run and the command refuses on a missing key.
  The resolution order is typed → recorded → environment → built-in, and a bench invocation
  records nothing to read back, so for `bench arms` it is effectively typed → environment →
  built-in.

`--isolation` unset is not `none`, and `--journal` without `--isolation` refuses.

**Round 17 could not run this scenario at all, and two corrections came out of trying.** Both
refusals below are pre-spend, and both were *driven 2026-09-14* against the built binary:

- **The arms have a tool floor, so they need a checkout to write in.** Without `--isolation
  worktree --journal PATH`, exit 1:
  `this run's tools can write (bash, edit_file, write_file) and nothing isolates where they write, so they would act in the working tree this command was run from; add --isolation worktree --journal PATH`.
- **The routing arm needs a cheap model the operator names, on any backend but Anthropic's.**
  Round 17's refusal said a local model was "no cheaper than" Claude Haiku and pointed at a Ruby
  method argument no CLI user can pass (F110). Since 2026-09-14 `--cheap-model ID` names the routing
  arm's cheap sibling; unset on a non-Claude model, exit 1:
  `the adaptive-router arm routes narrow tasks to a cheaper model, and this run resolved "qwen3-coder:30b", which is not a Claude model -- so this roster has no cheaper sibling to name for it. Give `bench arms` an Anthropic --model, or a --cheap-model naming a model this backend can serve`.
  Equal to `--model`, exit 1:
  `the adaptive-router arm would send both branches to "qwen3:4b", running the control twice under two names. Name a --cheap-model different from --model`.

Note the second model on one GPU: `--cheap-model qwen3:4b` beside `qwen3-coder:30b` evicts the
resident model whenever the router switches (`bench.md`'s 84.0 s against 7.5 s), so read the
wall-time table with that cost in mind. *(The full run was not driven on 2026-09-14.)*

## "Non-zero" is not a usable oracle

The suite floor is already **0.0625**, because a task with `contains:` + `excludes:` gold has its
`excludes` half pass vacuously against an absent file. And a totally collapsed orchestrator arm
still reads **1.000** on the grade row, because the grade is computed on the orchestrator's own
timeline. Use three conjoined checks:

1. mean grade **materially above 0.0625**;
2. non-zero on at least one task **other than** `fix-off-by-one-loop`;
3. a **non-zero spend/token row for every arm** — the only row a collapsed arm cannot fake.

**A 1.000 grade beside a collapsed spend row is the known follow-up reproducing, not a pass.**

Round 4's reading, for comparison — three arms then, before adaptive-router joined the roster:

    grader score          n   mean  median    min    max
    single-thread         8  0.812   1.000  0.000  1.000
    orchestrator-worker   8  0.812   1.000  0.000  1.000
    dual-ledger           8  0.938   1.000  0.500  1.000

    total tokens          n    mean  median     min     max
    single-thread         8   224.9   212.5   184.0   276.0
    orchestrator-worker   8   441.6   468.5   228.0   682.0
    dual-ledger           8  3283.6  3478.0  2375.0  3902.0

All three checks passed: the orchestrator-worker arm's 0.812 is backed by 441.6 real tokens, so it
is not a collapsed arm faking a grade on its own timeline.

## The header must say what produced the report

Since T12 the report opens with attribution, not just counts — because a dollar figure on a report
naming no model is exactly the lie `PriceBook` refuses to tell:

```
Arm driver — 4 arms over 8 tasks
  fixture:   spec/fixtures/arms/tasks.yml
  model:     qwen3-coder:30b
  isolation: worktree
```

*(Prediction, not yet driven: the header shape above was measured with three arms and no isolation;
the arm count and the `worktree` word are what the current roster and the required flag imply.)*

Check all four lines:

- **the fixture path is the one you passed**, not a count of prompts. The Driver is handed prompts
  and cannot name its own suite, so this arrives from the command — a blank here means the wiring
  was lost, and an unattributable bench report is a weak experiment record.
- **the model is the SEAM's own answer**, so it is what actually ran rather than a second resolution
  of the flags. If it disagrees with `--model`, that disagreement is the finding.
- **an unset backend says `unset — Arm::NoIsolation leased nothing`**, not a blank and not `none` —
  reachable now only by a toolless run, since the tool floor refuses an unset backend. A
  blank field reads as "there was none"; this says the run leased nothing, which is a fact about the
  experiment. With `--isolation` set, the header prints **the operator's own word** (`none`,
  `worktree`) rather than a class name — a header reading `Isolation::Journal` means it fell back to
  the wrapper's class and can no longer distinguish the two backends it exists to distinguish.
- **no credential and no base URL anywhere in it.** `spec/output_discipline_spec.rb` cannot see
  inside a report String, so this one is checked by eye, every round.

`unrecorded` in any field is the honest "the record does not know" — legitimate for a hand-assembled
run, and a finding when the flag was actually passed.

## The cost column, and its deliberate refusal

`cost (USD)` joins `grader score`, `total tokens` and `wall-time (s)` as a fourth table. **Against a
local model it does not print numbers, and that is the correct outcome** — `qwen3-coder:30b` has no
row in `PriceBook::DEFAULTS`, so pricing raises and the section degrades to the Ledger's own message:

```
cost (USD)
  not priced — no price for model "qwen3-coder:30b"; configure a fallback to degrade
```

Three things this is checking, and the first is the one that actually broke:

1. **The rest of the report still renders.** Score, tokens and wall-time never needed a model. Letting
   the price failure out took the *whole* report down — after every run was already paid for, and
   with the memo never landing, so a retry re-ran and re-paid the suite for no record. A missing
   report where a `not priced` line belongs is a serious regression, not a cosmetic one.
2. **It refuses rather than printing `0.000000`.** A silently-free model is the lie this whole object
   exists to prevent; a zero cost row beside non-zero tokens is the failure.
3. **One refused arm refuses the SECTION, not just its row.** A table with figures for three arms and
   a gap for the fourth invites exactly the comparison the missing number cannot support.

**`lain bench variance` degrades the same way since 2026-09-14.** Round 17 found it refusing every
local recording that had turns (`no price for model "qwen3-coder:30b"; configure a fallback to
degrade`, exit 1), while this report degraded only its cost section (F109). Its cost row now reads
`not priced` with the ledger's reason and the rest of the comparison renders. *(Prediction, not yet
driven: needs two `lain bench record` recordings of a local model.)*

**A failed recording is set aside, and the remaining runs continue** — round 18's answer to a
run whose round trip dies partway through. The file is renamed to `<stem>.failed.ndjson` (hard
link, then unlink, and a name already taken refuses rather than clobbering), the sweep goes on to
the next run, and `bench variance` grows a `== Set aside ==` section listing each one with a
**reason**: `failed recording (<ErrorClass>: <message>)` off the `recording_failed` record, or
`no usage recorded beside a truncated stream` for a `.ndjson` that has neither. Drive it by
severing the transport mid-recording (`failure-injection.md` §4's proxy) on run 2 of 3, then:

```bash
ls "$QA/records"/*.failed.ndjson        # exactly one, named for the run that died
lain bench variance "$QA/records"       # a "Set aside" section naming it and why
```

Three things, and the third is the one that matters: the other two runs completed; the set-aside
file is **not** counted among the n≥2 recordings the distribution is computed over; and the
reason is in the report rather than only in the filename. A variance report that silently drops
the failed run, or that refuses whole because one run died, is the finding. Ctrl-C during a
recording takes the same path.

To see real figures, run one small sweep against a priced model — and note what the number excludes:
**LLM-judge tokens are not on the arms' ledgers**, so a rubric-graded run's cost omits the judge. That
omission is now *visible* for the first time; it is recorded, not fixed.

## Also confirm

- The **dual-ledger arm settles on its ledger rather than its grader**, and its terminal state
  distinguishes a dried-up ledger from a ceiling.
- **No `StalledStreamError`.** This arm runs concurrent actors against a single-slot ollama, which
  is the shape that has killed sessions elsewhere. It has not fired here in two rounds — the
  requests are 1.4–2.1s each, so no stream goes 30s silent — so if it *does* fire, that is a
  finding, not background noise.
- **Wall-time outliers are FIRST-LOAD COST, and that is settled rather than open.** Round 4 saw
  `single-thread` at a 29.6s max against a 1.39s median and recorded it as unexplained; round 8
  reproduced it (**27.47s** against a 1.39s median) and then re-ran the identical suite immediately,
  warm — the same arm came back **mean 1.51s, max 2.40s**. The outlier is the run's FIRST request
  paying the runner load, which `bench.md` already prices at ~27s. So: warm the model before the run
  if the wall-time column is the subject, and read a lone ~27s max on the first arm as the load,
  not as an anomaly. A ~27s outlier on a LATER arm, or on a demonstrably warm runner, is still a
  finding.
  **Round 9 refines the mechanism -- read the next bullet before acting on this one.** "Warm the
  model" is insufficient if you warm it with `ollama run`: that leaves a `-b 512` runner which lain
  then RELOADS. The outlier is a `num_batch` mismatch reload, not an unavoidable first-load.
- **`num_batch` DOES re-key the runner. Round 9 overturned this, with a control.** This bullet used
  to say the opposite, on round 8's uncontrolled observation. Measured 2026-08-23:

  ```
  # a runner ollama loads on its own, no num_batch anywhere:
  runner 2176470   -c 32768  -np 1  -b 512  -ub 512
  # ONE lain request carrying LAIN_NUM_BATCH=2048:
  runner 2177020   -b 2048          <- PID CHANGED, the runner reloaded
  # THE CONTROL -- the identical request again, runner now matching:
  runner 2177020   -b 2048          <- SAME PID, no reload
  ```

  The reload is the **mismatch**, not lain. Two consequences. Round 6's 30.9s→9.3s reading DOES
  generalise to lain's own launches. And **"warm the model before the run" is not enough if you warm
  it with `ollama run`** -- that produces a `-b 512` runner which lain reloads on the first arm, at
  `bench.md`'s own ~27s, which is a better explanation of the first-arm outlier below than generic
  first-load cost.

  **⚠️ Round 10 refines this again: warming through a lain CHAT is ALSO not enough.** Round 9's
  advice was "warm through a lain request", and round 9 saw no outlier. Round 10 warmed through an
  entire bowling cockpit session and verified the model resident at `ctx=32768` immediately before
  the run, and the first arm **still** paid the re-key:

  ```
  run 1 (after a full chat session, model verified resident):
    single-thread  mean 4.8138  median 1.3232  max 28.2800
  run 2, identical suite immediately after:
    single-thread  mean 1.3171  median 1.3179  max  1.3412     <- gone
  ```

  So the warm-up must match what **`bench arms` itself** requests, not merely be *a* lain request --
  a chat resolves a different key than the bench does. The reliable procedure is to **run the suite
  twice and read the second**, which is also round 8's remedy. A lone ~27s max on the FIRST arm of a
  FIRST run is the re-key; anywhere else it is still a finding.

  (Round 10 could not re-take the runner-argv control above: no separate `ollama runner` process is
  visible on ollama 0.32.12 on this box, so `-b`/`-c`/`-np` are unreadable from `ps`. Recorded as
  unreachable rather than as agreed.)

## What the arms cannot do today

**Corrected by round 17: the "empty toolset, single-turn" note this section carried is stale.** The
arms now run with a tool floor that can write (`bash`, `edit_file`, `write_file`, per the refusal
above), which is why a run needs `--isolation worktree`. What stays true is that nothing here is
built to reach compaction or tool **volume** — a fixture task is small by design — so use
`rails-blog.md` for that, and do not read an arms run's lack of a compaction as a result.
