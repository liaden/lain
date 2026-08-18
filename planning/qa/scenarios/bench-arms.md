# Scenario: the arm driver

**What it exercises:** `lain bench arms` — the orchestration arms (single-thread,
orchestrator-worker, dual-ledger), the grader, the token ledger, and since 2026-08-18 the **cost
column and the attribution header**: whether the report says what produced it, and whether it
refuses to quote a price it cannot stand behind.

**Cost:** ~5 minutes, no interaction. **Precondition: the chat is closed.** A second model on one
GPU evicts the first, which is a measured 84.0s against 7.5s.

**Needs:** `bench.md` up, model resident at the context the run will use (else pay a reload).

---

```bash
lain bench arms spec/fixtures/arms/tasks.yml --provider ollama --model qwen3-coder:30b
```

`--provider` defaults to the literal `"anthropic"` rather than through `EnvDefaults`, so `.envrc`'s
`LAIN_PROVIDER` does **not** reach it and the command refuses on a missing key. `--isolation` unset
is not `none`, and `--journal` without `--isolation` refuses.

## "Non-zero" is not a usable oracle

The suite floor is already **0.0625**, because a task with `contains:` + `excludes:` gold has its
`excludes` half pass vacuously against an absent file. And a totally collapsed orchestrator arm
still reads **1.000** on the grade row, because the grade is computed on the orchestrator's own
timeline. Use three conjoined checks:

1. mean grade **materially above 0.0625**;
2. non-zero on at least one task **other than** `fix-off-by-one-loop`;
3. a **non-zero spend/token row for every arm** — the only row a collapsed arm cannot fake.

**A 1.000 grade beside a collapsed spend row is the known follow-up reproducing, not a pass.**

Round 4's reading, for comparison:

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
Arm driver — 3 arms over 8 tasks
  fixture:   spec/fixtures/arms/tasks.yml
  model:     qwen3-coder:30b
  isolation: unset — Arm::NoIsolation leased nothing
```

Check all four lines:

- **the fixture path is the one you passed**, not a count of prompts. The Driver is handed prompts
  and cannot name its own suite, so this arrives from the command — a blank here means the wiring
  was lost, and an unattributable bench report is a weak experiment record.
- **the model is the SEAM's own answer**, so it is what actually ran rather than a second resolution
  of the flags. If it disagrees with `--model`, that disagreement is the finding.
- **an unset backend says `unset — Arm::NoIsolation leased nothing`**, not a blank and not `none`. A
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
3. **One refused arm refuses the SECTION, not just its row.** A table with figures for two arms and a
   gap for the third invites exactly the comparison the missing number cannot support.

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
- **Wall-time outliers.** Round 4 saw `single-thread` at a 29.6s max against a 1.39s median — 20×
  on one task, unexplained. Worth a look whenever the cost axis is the subject.

## What the arms cannot do today

Recorded here so a future round does not read a clean null as a result: **bench arm agents run with
an empty toolset** (`Bench::SpawnSeam` is constructed with `Toolset.new([])`) and **arm runs are
single-turn** (`Arm::SingleThread#run` does one `agent.ask`). A one-turn transcript never reaches
`Compaction::Need`'s threshold, so nothing about compaction or tool volume can be measured here —
use `rails-blog.md` for that.
