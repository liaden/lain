# `planning/qa/` — the manual QA bench

**Manual QA is not a slower unit test.** It is the only thing that drives two real components
against each other with a human at the approval gate, and every defect it has found so far lived
in a seam that had specs on **both** sides. Round 1 found eleven behind a green suite of ten
thousand examples; round 4 found seven more, two of them session-killers.

These documents are the **inputs to the `manual-qa` skill** (`.claude/skills/manual-qa/`). The skill
owns the procedure and the driver scripts; these own the method and the scenarios.

## Layout

| Doc | What it is |
|---|---|
| [`method.md`](method.md) | **The standing method.** Toolchain, sandbox isolation (and why XDG alone is not enough), the approval-gate discipline, driving the cockpit, the journal-quiet rule, driving nvim over RPC, what to record, and the local model's known failure modes. Scenario-independent; read once per round. |
| [`bench.md`](bench.md) | Bringing up the model server: which of the two ollama installs, the residency controls, `n_slots`/`OLLAMA_NUM_PARALLEL` as a recorded precondition, and why `--num-ctx` alignment avoids a 27s reload. |
| [`oracles/bowling.rb`](oracles/bowling.rb) | The driver's grading instrument for the bowling subject. Grades `Bowling.score(rolls)`. Never the model's own specs. |

## Scenarios

Pick by the question being asked, not by coverage. Each states its own cost and preconditions.

**The core seven** — the loop, the cockpit, the record, the bench:

| Scenario | The question it answers | Cost |
|---|---|---|
| [`session-and-window.md`](scenarios/session-and-window.md) | Is the bench **honest before a model is asked** — served window, `provenance`, occupancy, the launch-level refusals, the `options` asymmetry, **which prices it will quote and which collapse strategy it resolved**? Mostly needs no model call. | cheap |
| [`rust-cli.md`](scenarios/rust-cli.md) | Does the loop work **end to end**, on a non-Ruby toolchain, with a real compile-error unhappy path? The smoke test. | cheap |
| [`cockpit-surfaces.md`](scenarios/cockpit-surfaces.md) | Do the nvim/tmux surfaces tell the truth — review flow, **notes on a survey of a dummy app the round writes itself**, buffer staleness, the approval surfaces and the notifier that shares their queue, the live timeline, how a refusal is *delivered*? **Four of round 4's seven defects were here, and every fix landed somewhere other than where the symptom was.** | cheap, piggybacks |
| [`failure-injection.md`](scenarios/failure-injection.md) | Is the record **unforgeable**, does every failure path refuse by name, and do the **tool bounds, the windowed-read contract and the summarizer's ceilings** hold? The deterministic half needs no model at all. The standalone regression gate. | minutes |
| [`bowling-ruby.md`](scenarios/bowling-ruby.md) | Does the **authoring loop** produce something worth having — plan, execute, critique, graded against driver-owned oracles? | 1–3 sessions |
| [`bench-arms.md`](scenarios/bench-arms.md) | Does the arm driver produce numbers that are not artifacts, **say what produced them, and refuse a price it cannot stand behind**? | ~5 min |
| [`rails-blog.md`](scenarios/rails-blog.md) | **Context economics at scale** — the composed compaction strategy firing for real, unbounded tool output, the gate under volume, and what a broken cache cost in dollars. The only scenario that reaches any of these. | expensive |

**The six added 2026-08-23**, each covering a tier the core seven never reach. All are driveable
against the **local** bench — ollama, `git`, `docker`, the filesystem — and none needs a remote
provider or a forge:

| Scenario | The question it answers | Cost |
|---|---|---|
| [`repl-commands.md`](scenarios/repl-commands.md) | Does the **command surface** do what `/help` says — `/help`, `/pin`, `/unpin`, `/keep`, `/btw`, `/rewind`, `/fork`, `/goal`, `/meta`, `/review-submit` and the ten others? Ten of the twenty had never been typed in a round. Every refusal path is a **zero-model-turn** path. | cheap |
| [`epic-tier.md`](scenarios/epic-tier.md) | Does a four-stage pipeline stay honest when only a journal remembers where it is — the stage-boundary ruling, all four gate policies, the drain-is-journaling fold, and the fail-**closed** abort on a damaged record? ~4,100 lines with no prior coverage at all. | cheap |
| [`secret-boundary.md`](scenarios/secret-boundary.md) | Does the **three-place split** hold — gate on the effect, filter on the result, mask on the content — with a real model pulling on it, and is a denial actually unliftable (including under `/mode auto`, the approve-all posture)? `--secret-oracle` is a local model by construction. | cheap |
| [`changeset-review.md`](scenarios/changeset-review.md) | Does a review of a **real diff** tell the truth? `cockpit-surfaces` drives the review rails over `/survey`, which has no old side, no base ref and no commits — everything that makes a changeset a changeset is untouched by it. Local branches only; no forge. | cheap |
| [`subagents-and-backends.md`](scenarios/subagents-and-backends.md) | When the loop stops being one process, does anything still tell the truth — `actor` mode, `--isolation worktree`'s real-`git` seams, `--exec docker`, `lain watch`, `--windows`? Also settles whether `--isolation`'s "inert in chat" help text is still true. | minutes |
| [`memory-and-dogfood.md`](scenarios/memory-and-dogfood.md) | Does what a session learned **come back**? The memory ceiling and its chain, the `memory_root` pairing, `lain consolidate` / `improve` / `improvements`, and `bench sweep`'s offline five-arm recall@k. | cheap–minutes |

**Added 2026-08-24** — the first scenario that needs a **remote, metered** provider, which is why
it sits apart from the six above rather than joining them:

| Scenario | The question it answers | Cost |
|---|---|---|
| [`ollama-cloud-arm.md`](scenarios/ollama-cloud-arm.md) | Does `--provider ollama-cloud` **refuse correctly before it spends anything**, denominate with a published window rather than a guess, keep the subscription key off hosts it did not choose, and leave a paid round trip recoverable after a crash? The wire is byte-identical to the local arm by construction, so everything findable is in auth, window, admission and the WAL. **Steps 1–4 cost nothing**; the whole scenario budgets under ten completions. | quota |

Its step 7 is the one to read before using this arm for anything: **neither ollama arm is a
determinism-comparable bench arm on this machine right now**, so a `bench variance` number taken
from either is measuring the server rather than the change.

**Added 2026-08-25** — the first scenario to own a **command** rather than a tier, written because
`/survey`'s coverage was scattered across another scenario's two subsections and the parts nobody
had driven were the parts nobody owned:

| Scenario | The question it answers | Cost |
|---|---|---|
| [`survey.md`](scenarios/survey.md) | Does `/survey` refuse honestly at a **size no round has driven** (lain's own `lib/` is 742 files / 161,963 lines against ceilings of 300 / 30,000), does the **walk** admit and withhold the right paths — gated is *listed and masked*, only denied is withheld — and is the **docent thread reachable at all**? Runs entirely on the **local** arm. | cheap |

It takes the **docent thread pane** off `cockpit-surfaces` §4b, which is where that debt had sat
**undriven since round 7** — dropped by rounds 8, 9 and 10, and named "3rd round owed" in round 10's
own coverage table. §7 was that debt, and it is why this scenario belongs in the regression gate
rather than the rotation: it is deterministic apart from one local model call, and the thing it
guards had slipped four rounds precisely because it was always somebody's optional last section.

**DISCHARGED as of round 11 (2026-08-25).** All seven sections were driven — the first drive of any
of them. **Round 7's F31 is fixed** (the thread pane's `BufWriteCmd` refusal no longer raises: no
traceback, no modal, `:w` in 0s against two 120s RPC timeouts) and **F56 is fixed**. Seven new
findings, headed by **F64** (a docent that parks an `ask_human` strands the thread pane while the
inbox, the HUD and `:LainReply` disagree about whether the question is live) and **F65** (the `<CR>`
gesture opens the RAW file, putting unreleased secret bytes on a surface `Projection` masks
everywhere else). **Six of the scenario's own predictions were falsified and corrected in place** —
including §4's planted key, which sat below both detector gates and so made that check pass for the
wrong reason. Two predicted defects were withdrawn with their mechanisms.

**The boundary with `cockpit-surfaces` is stated in both files.** §4/§4b keep the gesture rails, the
note rail and the refusal-delivery rule, all on a dummy tree small enough to state in full — the
right subject for an anchor assertion. `survey.md` takes everything needing a tree of real size or a
tree with something planted in it.

**Also added 2026-08-25** — the project extension API, written because no scenario drove
`.lain/slots/` at all: three levels of override, two of them checked here, and a cache-floor claim
that had never been measured against a real prefix:

| Scenario | The question it answers | Cost |
|---|---|---|
| [`prompt-slots-and-roles.md`](scenarios/prompt-slots-and-roles.md) | Does a project's own `.lain/slots/` tree actually reach the model — does a top-level or role override land verbatim, does a typo'd filename refuse loudly **by name** at every level (`UnknownSlot`) rather than being silently ignored, and does the shipped 364-byte default system slot actually miss Anthropic's 4096-token cache floor on the wire, not just on paper? | cheap (one step paid) |

Almost all of it is a zero-model-turn refusal or `/ruby` inspection path, on `repl-commands.md`'s
shape. The one exception is its §6 second half: confirming the shipped default actually misses the
cache on a real round trip costs **2 completions against a live Anthropic key** — the free half of
§6 (the byte count against the published floor) costs nothing and is not a substitute for it.

**Also added 2026-08-26** — the shell subsystem, which had **zero** manual-QA coverage: no scenario
mentioned `Shell::Verdict`, `Parse`, `Pipeline`, the term arm or arm selection, and the five
scenarios that touch `bash` all use it as a vehicle for something else. It was not in Known gaps
either, so the gap was invisible:

| Scenario | The question it answers | Cost |
|---|---|---|
| [`shell-terms.md`](scenarios/shell-terms.md) | Does the **deterministic half of the shell subsystem** decide the way it says it does — which commands earn the no-shell **term arm**, which a project's `[shell] exclude` table refuses **by name** (a deny path that had never been driven), which are approved by `Approval::ComposedTerm` with **nobody asked**, and — the half that matters more — which still reach a human? Plus the `web_fetch` egress floor and the `shell_arm` record in **both** attended and `/mode auto`. | cheap (one step paid) |

Six of its ten sections are **zero-model `/ruby` inspection**, on `prompt-slots-and-roles.md`'s
shape; three spend local completions; §9 alone is metered. Its §0 names the **three postures**
(attended ladder, `/mode auto`'s `ApproveAll`, the one-rung unattended deny-all) because they
decide differently and a driver who conflates them files a false finding.

**Seventeen scenarios do not fit in one round, and pretending otherwise is how a slot gets
substituted** — that is the failure rounds 7 and 8 made with `cockpit-surfaces`, one level out. So
the six added 2026-08-23 are **not appended to the full round below**. They, and the two scenarios
added since, are placed:

- `repl-commands` and `epic-tier` are cheap and fully deterministic, so they join the
  **regression gate** (see below) on the standing rule that anything deterministic belongs in the
  cheap set even when the feature it guards is not. **`survey` joins them as of 2026-08-25** on the
  same rule: §1–§6 are zero-model, and §7's one local call is what stops the docent debt being
  deferred a fifth time. **`shell-terms` joins them as of 2026-08-26** on the same rule again:
  §0–§4 and §8 are zero-model `/ruby` paths, and they cover the whole deterministic surface —
  arm selection, the config deny path, the approval rule's allowlist, and the egress floor.
  Cut its §9 first (it is the only metered step) and its §7 second (it needs a docker daemon);
  **do not cut §5**, which holds every negative control.
- `secret-boundary`, `changeset-review`, `subagents-and-backends` and `memory-and-dogfood` are
  **owned rounds**, on `rails-blog`'s precedent: a scenario that owns its context has no position in
  a list to be unlucky about. Schedule one per round alongside the full round, rotating.

  **`secret-boundary` is DISCHARGED as of round 10.** It slipped round 9, carried, and round 10
  drove §3, §4 and §5 — so the three-place split is now **3 of 3 driven** rather than resting on
  specs, and §5 produced the round's HIGH finding (F63). The rotation may now advance.

  **The rotation slot for round 11 is `rails-blog`**, which is the only scenario still driven **zero
  times end to end**, and whose §2 (unbounded tool output) no round has ever reached. It has a real
  precondition round 11 must handle deliberately rather than improvise: **`rails` is absent from
  this box** (not on `PATH`, gem not installed), and installing it collides with P15's `GEM_HOME`
  question. Budget the install as part of that round, or say plainly that it slipped again.

**Two scenarios are described above and scheduled nowhere**, which is the exact failure this
placement list exists to prevent: `prompt-slots-and-roles` (added 2026-08-25) and
`ollama-cloud-arm` (added 2026-08-24) each have a table row and appear in no tier. **Neither is
placed here** — the placement is a judgement about a round's budget, not a bookkeeping edit, so
naming them keeps them visible as a debt rather than letting a table row read as coverage.

**A full round — the default when no scope is named** (`.claude/skills/manual-qa` defers to this
line for the order): `session-and-window` → `rust-cli` → a subject with `cockpit-surfaces`
piggybacked → `bench-arms` → `failure-injection`.

**That is FIVE steps, and `rust-cli` is not one of the subjects.** It is the smoke test; the subjects
are `bowling-ruby` and `rails-blog`, and the third step is a SUBJECT with `cockpit-surfaces` riding
on it. **Rounds 7 and 8 both collapsed steps 2 and 3** — each piggybacked `cockpit-surfaces` onto the
`rust-cli` crate, each wrote "the `rust-cli` crate served as this round's subject", and neither
noticed it was repeating the other. The substitution is easy precisely because `rust-cli` leaves a
working crate behind, so the slot *looks* filled. Two consecutive rounds means `bowling-ruby` has had
no coverage since 2026-08-19, when it scored 5/5 oracles.

So, mechanically: **`cockpit-surfaces` piggybacks on the SUBJECT session, not on the smoke test.**
Bring the subject up before deciding where the cockpit checks ride — round 8 launched the cockpit
before it had read `cockpit-surfaces.md`, and the slot was gone by the time anyone chose. If the
subject really is being skipped, that has to be said in the findings **before** the round ends, not
reconstructed afterwards.

**Run BOTH subjects** (`bowling-ruby` and `rails-blog`), rather than picking one. This line used to
say "one subject", and the predictable consequence is that the cheaper one always won. **The same
consequence recurs one level out** when the smoke test is allowed to stand in for a subject, which is
what the paragraph above exists to stop.

**But `rails-blog` gets its OWN round, in its own driver context** — it is not the tail of the
sequence above, and it is not something a full round "reaches" if there is budget left. Rounds 4, 5
and 6 each ended without it, always for the same reason: one context carried every scenario and was
spent by the time the expensive one came up. **Reordering is not the fix** — it only moves which
scenario starves. A scenario that owns its context has no position in the list to be unlucky about.

So: dropping `bowling-ruby` from a round is a decision to name in the findings. `rails-blog` is not
dropped, because it was never in that budget — it is **owed**, and a round should say so. A scenario
skipped by convention stops being a gap anyone can see; one that is separately scheduled stays
visible as an outstanding debt instead.

**A suggested regression gate after a chunk lands:** `failure-injection` + `session-and-window`,
and since 2026-08-23 also `repl-commands` + `epic-tier`, since 2026-08-25 `survey`, and since
2026-08-26 `shell-terms`.
All six are cheap, deterministic, and cover the paths most chunks touch. As of 2026-08-18 the first pair
also covers **most of a chunk that was mostly not about the cockpit at all** — the price table and
its lint, `--compact-strategy` resolution, both tool-bound shapes, the `edit_file` refusal
vocabulary, the summarizer's ceilings, the per-ask iteration ceiling and the `lain up`
crash-on-start case. That is deliberate: **a check that only runs in an expensive scenario mostly
does not run**, so anything deterministic belongs in the cheap set even when the feature it guards
is expensive. The two added in 2026-08-23 are there on exactly that rule: `repl-commands` is almost
entirely zero-model-turn refusal paths, and `epic-tier` is deterministic except for one policy.
`shell-terms` is there on the same rule a third time, and it is the clearest case yet: the whole
deterministic shell surface answers to `/ruby` with no model call at all, while the feature it
guards — a rule that approves a shell command with no human — is the most expensive thing in the
tree to be wrong about. `survey` is there on the same rule again, with a caveat that is the point
of adding it: **cut its §7 last, not first.** Every other section in it is deterministic and will keep; §7 is the one thing
in this whole directory that has been dropped by three consecutive rounds, and it is only ever
dropped because it is the section at the end that needs a model.

**If the gate is too long to run every time, cut `epic-tier` first** — say so in the findings rather
than letting it drop quietly, which is the failure mode this whole file keeps re-learning.

The corollary is the one thing the gate cannot do: **nothing deterministic can tell you a
compaction strategy works**, because a compaction needs volume that a cheap scenario cannot
manufacture. `rails-blog.md` §0 is the only place that act lives, and it carries a precondition
(tool results of real size) without which it silently measures nothing while paying for a model
call per turn.

## Findings

Written per round. **Rounds 2 through 12 have been deleted** -- every finding in them is
discharged, and git history is the archive: `git log --diff-filter=D --stat -- planning/` names the
commit that removed them, and `git show <commit>^:<path>` reads any of them back whole. A round
stays here only while it is still in flight:

- [`../specs/chunk-qa-round11-survey-surfaces.md`](../specs/chunk-qa-round11-survey-surfaces.md)
  — the chunk that discharges round 11, following the round-7 precedent below: fourteen cards,
  F64–F70 plus the corpus ceiling, verified by round 12
- [`../specs/chunk-qa-round7-constructed-and-consistent.md`](../specs/chunk-qa-round7-constructed-and-consistent.md)
  — the chunk that discharges both round-7 documents
- [`../qa-findings-research-2026-08.md`](../qa-findings-research-2026-08.md) — the research pass

## Coverage notes

Per-section coverage a scenario file cannot state about itself, because it is about which round
first exercised the section rather than what the section asks for:

- **Round 9 (2026-08-23) drove six of the thirteen** — `session-and-window`, `rust-cli`,
  **`bowling-ruby` as the subject with `cockpit-surfaces` piggybacked on it** (the first round since
  round 8's second pass to fill the subject slot properly), `bench-arms`, and `failure-injection`
  §1/§2/§3/§11a. It drove **none of the six added that day**, and no owned round.

- **Round 10 (2026-08-23) drove nine of the thirteen**, all thirteen having been in scope: the full
  round's first four steps (`session-and-window` complete, `rust-cli`, **`bowling-ruby` as the
  subject at 5/5 oracles with `cockpit-surfaces` piggybacked on it**, `bench-arms` with a warm
  control), plus first-ever coverage of `secret-boundary` §3/§4/§5, `changeset-review` §3/§4,
  `epic-tier` §6 (both halves), `subagents-and-backends` §1, and `memory-and-dogfood` §5/§6.
  **It did NOT run `failure-injection`** — the full round's fifth step, traded for the four owned
  scenarios; that is the one departure from the order above and it carries a specific debt, because
  **the F26 stall recurred** in `rust-cli` and `§12`'s proxy reading is what would settle it.
  `rails-blog` was unreachable (no Rails on the box).

- **The six scenarios added on 2026-08-23 have now each been driven at least once** (rounds 9 and
  10 between them), so they are no longer coverage-on-paper. What follows is the original note,
  kept because its warning about predictions-vs-defects still applies to their many undriven
  sections. Originally: **driven ZERO times.** `repl-commands`,
  `epic-tier`, `secret-boundary`, `changeset-review`, `subagents-and-backends` and
  `memory-and-dogfood` were written from the code rather than from a round, so every expected string,
  every record name and every ceiling in them is a **prediction**. The first round to drive each
  should expect to correct the document as much as to find defects, and should say which it did:
  a wrong expectation in a scenario and a defect in lain look identical from the driver's seat, and
  telling them apart is the first round's real job. Until then they are coverage on paper only.

- **`shell-terms.md` has been driven ZERO times.** Written 2026-08-26 from the code — every
  expected string in it was read through a real object in a real process at the merged tree, which
  makes each one a claim about *that* checkout on *that* box and not a round's finding. Two things
  in it are the likeliest to be wrong first, and both are hand-maintained tables: `ComposedTerm`'s
  ten-program allowlist with its per-program disqualifying flags, and `web_fetch`'s blocked-range
  list. The first round should expect to correct the document as much as to find defects, and
  should say which it did.

- **`cockpit-surfaces.md` §4b (notes on a survey) was first driven on 2026-08-20**, in round 7's
  `/survey` supplement. Rounds 4, 5, 6 and round 7's
  own main pass had all skipped it — nobody had placed a note on a survey before that round.
  **Round 8 skipped it again; round 9 drove it, so it now stands at TWO drives.** Round 9 passed
  every check in it except the thread pane (`\Lt`, the one part that spends a model call): the
  cmdline stays open on `\Ln` (`mode()=="c"`), all four markers render `right_align` with the
  correct kinds including `blocker`, **the payload arrives in placement order 5, 9, 2, 3** rather
  than the positional 2, 3, 5, 9, `drifted: false` is present on every record, and a second `\LN`
  sends nothing and says so. It also demonstrated end to end, for the first time, that the `blocker`
  kind is what the verdict policy reads — `approve` refused over it by name, and a note on the same
  line resolved it. **What is still owed here is the thread**, and with it round 7's other
  `:LainReviewDone` leg (`51_thread.lua:639`).
- **`cockpit-surfaces.md` §8 (fold state on the approval and inbox rows) was first driven on
  2026-08-21**, in round 8. It had been carried in `method.md` as pending "once T9/T12 land"; those
  have landed, the RPC recipe runs, and it immediately produced two findings (F42, F43) that no
  buffer-text probe in §1 or §2 could have seen.
- **`rails-blog.md` §1 (compaction at scale) was first reached on 2026-08-21**, in round 8's second
  pass — the first time in eight rounds. 11 compactions, both triggers, occupancy falling 25–30
  points each time, and **no `Overlap`** across the composed `elide-tools+summarize-conversation`
  pair. Until then every claim about the two content-selective strategies rested on specs alone.
  **`rails-blog.md` §2 (unbounded tool output) was NOT reached even then** — largest tool result
  4,713 bytes, zero caps disclosed. §1's volume came from turn COUNT, not result SIZE; do not read a
  pass on one as a pass on the other.
- **`bowling-ruby.md` was last driven on 2026-08-21** (round 8, second pass): 5/5 oracles, and §2's
  F23 fork/resume regression step passed with a valid control pair. Before that it had been dropped
  by rounds 7 and 8's first pass — see the subject-slot guard above, which exists because of it.

## The rules that outrank everything else here

(The `manual-qa` skill carries the operative three-line form; these are the same rules stated for
someone deciding what a round is FOR.)

1. **Success is not "nothing went wrong."** It is: every defect the previous round found behaves
   *differently* now, every knowingly-partial fix fails the way its documentation says rather than
   some worse way, and every new defect is recorded with a **reproduction** rather than a
   description. **A round that finds nothing new did not push hard enough.**
2. **A fix can make the failure mode worse.** *Differently* is not the same as *better* — record
   which. One round turned a >400s silent hang into a hard crash of the whole session.

## Known gaps — what no scenario covers

Worth stating plainly, because "every defect behaves differently now" reads as coverage:

- **`:LainReviewDone` — one leg passes, one is owed.** Round 8 drove it against a survey buffer and
  it refuses cleanly (`lain: :LainReviewDone needs an open EPIC review, and this buffer is not one
  -- a changeset review or a survey hands back with :LainReviewVerdict {verdict} instead`), with no
  `stack traceback:`, `nvim_get_mode()` not blocking, and the journal unchanged; at 161 characters
  against a measured `v:echospace` of 88 it exercised the width rail too. **The other leg is still
  owed:** `51_thread.lua:639` deliberately raises out of a `BufWriteCmd`, so the traceback-and-modal
  shape survives there. Reaching it needs `cockpit-surfaces.md` §4b's thread pane, which no round has
  driven — rounds 8 and 9 both stopped short of it.
- **The plain, non-cockpit path — narrowed by round 9, not closed.** Almost every scenario runs under
  `lain up --nvim`. **The `--no-nvim` approval path now works**: round 9 drove it and the prompt
  renders naming the requester, `y` is consumed, and the turn completes, so round 4's permanent wedge
  is gone. `cockpit-surfaces.md` §5 forces that one comparison and nothing else does, so the rest of
  the plain path — REPL commands, `/inbox`, the HUD — remains uncovered.
- **`--resume` — partly driven.** Round 9 resumed a spawned session (exit 0) and drove three damaged
  journals through it (refuses by name, exit 1, no backtrace). Still undriven is `repl-commands.md`
  §4's loop `/btw` → `/keep` → `lain sessions` → `--resume`, which asks a question whose answer
  depends on the carried-over turns — the half that tests continuity rather than refusal.
- **The secret boundary — written 2026-08-23, still undriven.** `secret-boundary.md` was scheduled as
  round 9's owned round; **round 9 did not run it**, so it carries to round 10 and the rotation must
  not advance past it. Every claim about the three-place split rests on specs alone, and a written
  scenario is not coverage.
- **Isolation backends — `subagents-and-backends.md` §3 written 2026-08-23, undriven.** It carries an
  open question to settle by driving: the `--isolation` flag's help text says it "is inert in chat
  today" because no chat path spawns an actor-mode subagent, but `CLI::Wiring` builds a real
  `Supervisor` with `fleet_isolation(...)` and `Subagent#adopt_actor` refuses only
  `unless supervisor.running?`. One of the two is wrong.
- **Program identity on the term arm — uncovered by construction, not by omission.** `shell-terms`
  (2026-08-26) drives everything the approval rule *does* check about a program; what nothing
  checks is whether the binary `execvp` finds is the program the allowlist vouched for. `PATH` is
  inherited and uncontrolled, so a shim in a user-writable directory runs. The four rungs that
  would close it (resolve-and-record, resolve-and-constrain, verify-identity, control `PATH`) are
  costed in `../specs/chunk-shell-term-approval.md` and built by nothing. **A round that finds a
  shim running has found documented scope**, so the gap is stated here rather than left for a
  driver to re-derive as a finding.
- **Cost and latency.** Nothing records wall-clock or tokens per act, so "the plumbing works" and
  "the plumbing is usable" are not separated. One wiring mistake once cost 84.0s against 7.5s and
  nothing here would catch the same class again.
- **Compaction at scale** — still owed, and now for a *different* reason than budget. Round 6
  recorded the first evidence the path executes at all: six `compaction` records fired incidentally
  with `trigger: ["token_threshold"]`, 335–360 KB collapsing to 14–26 KB, with `bytes_before/after`
  correctly named. That is the occupancy path running end to end — it is **not** `rails-blog.md` §1,
  which additionally asks whether a *composed* strategy does what its name says, and that still rests
  on specs alone. Round 6 also identified a live blocker: **F26** (a concurrent unjournaled oracle
  call starving the turn on a one-slot server) fires precisely on the large tool results this
  scenario needs, so a round driven before F26 lands would measure the stall rather than the
  strategy.
  The obstacle that stopped rounds 3 and 4 (a per-session iteration ceiling) is gone since T14, so
  what remains is only volume and patience. Until a round actually reaches it, **every claim about
  the two content-selective strategies rests on specs alone**, and `--compact-strategy` is checked
  no further than name resolution.
- **A tripped tool bound leaves no journal record.** The bounds are checkable, but only through the
  `tool_result` text — so nothing here can answer "did a bound fire during ordinary use", which is
  the question that would say whether a ceiling is set too low.
- **Subagent structure — no scenario covers it because no surface renders it.** `Buffers::TimelineView`
  walks only `render_parent` (`Timeline#ancestors`), a linear chain from one head; no frontend file
  references `child_turn` or a `:spawn` event; and `StatusFeed#observed` publishes the fleet as
  `@fleet.keys` off a `{spawn_digest => true}` map (`status_feed.rb:388,457`), which every reader
  (`prompt_composer.rb:409`, `cli/command/status.rb:53`) immediately collapses to `.size` — an
  integer count, with no parent/child edge reaching any display. Round 5 journaled 29 `child_turn`
  and 10 `message` records in one `fleet 2` session and none of it showed anywhere outside the
  journal. A scenario cannot drive this until a surface exists to project the causal edges
  (`spawn`/`child_turn`/`message` parent-child structure) rather than just their count; that surface
  is deferred, not scheduled (`planning/specs/chunk-qa-round5-causal-fold-and-surfaces.md`, T13).
  **Partly narrowed 2026-08-23:** `lain watch` IS a surface over one actor's lineage, and
  `subagents-and-backends.md` §5 drives it. What stays undrivable is the *fan* — parent/child edges
  across a fleet — which is what T13 owes; one lineage at a time is not it.

Still uncovered as of 2026-08-23, and **not** addressed by the six scenarios added that day, so that
"thirteen scenarios" does not read as completeness:

- **`Toolset::Disclosure`, both arms.** `Upfront` vs `Deferred` (+ the `tool_search` tool) is a
  headline context-strategy axis and `Bench::DisclosureSweep` exists to compare them — but **there is
  no `lain bench disclosure-sweep` subcommand**, and no chat flag selects an arm. It is library-only,
  so nothing a driver can type reaches it. Same for `Bench::DeciderSweep`. A scenario here is blocked
  on a CLI entry point, not on writing.
- **`Context` strategies other than `compact`/`reminder`/`cache_breakpoints`.** `pinned_messages`,
  `mailbox`, `dedupe_tool_calls`, `purge_failed_inputs`, `model_switch`, `tail_injection`,
  `protected_patterns` are composed by no live pipeline path a flag selects. `Context::Recall` is
  explicitly opt-in and unwired — see `memory-and-dogfood.md`'s note, which exists so the next round
  does not go looking for it.
- **`Exec::Core` and the `lain-core` daemon.** Refused by name from `--exec` **by design** (it needs
  a started client and the reactor holding it), so it is unreachable from any chat. The `:core`-tagged
  specs cover it; what is missing is a human at the gate, which needs a `bundle exec ruby` harness
  rather than a scenario.
- **The forge half of the review tier.** `Source::GithubPr`, `lain epic land`'s promote/merge path,
  and `/review-submit` actually posting all need github.com. `changeset-review.md` and `epic-tier.md`
  drive the **boundary** — that a local-branch review refuses to post, and that `land` refuses before
  the first forge intent — and stop there deliberately.
- **Compaction strategies `identity`, `replacement` and `elide_tool_observations` by name.**
  `session-and-window.md` §7 resolves the names it resolves; these three are never named in any
  scenario, so `--compact-strategy` coverage is narrower than it looks.
- **`bench variance`, `bench record`, `bench plan-sweep`.** `bench-arms.md` covers `arms` and
  `memory-and-dogfood.md` §6 covers `sweep`; the other three have one prose mention between them.
