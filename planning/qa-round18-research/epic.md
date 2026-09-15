# Round 18, epic tier: what changed last, and why

**Scope:** F148, F149, F150, F151, F163, F164, F165, F154 (epic half) and the LOWs F192–F194.

**Base:** `main` at `90f081b9`. Line numbers are for that tree.

**Method:** code reads, `git log -L`/`-S`/`show`, and the planning documents. Nothing was run.

**Sources, and how this file names them:**
- "the plan": `planning/specs/chunk-qa-round17-the-record-the-human-the-window.md`.
- "R17": `planning/qa-findings-round17-2026-09-14.md`.
- "R18": `planning/qa-findings-round18-2026-09-15.md`.
- "fork": `~/tmp/lain-qa-round18/records/fork-epic-report.md`.

**Classes used in each finding's part 4:**
- **(a)** a regression introduced by the latest fix;
- **(b)** a gap left outside the card's scope;
- **(c)** pre-existing behaviour the chunk never touched;
- **(d)** by design, with a ruling owed or taken;
- **(e)** the finding or scenario is wrong.

---

## F148 — a refused launch ends the `/implement-epic` run

### 1. Mechanism, re-verified

**Confirmed.** In `lib/lain/cli/epic_driver/factory.rb`:
- `Run#drive` (846–857) computes `stop_reason`, folds, and reports `unplanned`.
- It then calls `fill(folded)` (875–877), and `return if @live.empty?` (853) ends the recursion.
- `fill` takes `startable(folded).take(width - @live.size)` and calls `launch` on each.
- `launch` (901–908) rescues every `StandardError` into `@reported`, so a refused launch adds nothing to `@live`.

**The trigger is width-dependent.** It fires when every launch in one fill refuses:
- A later fill would offer the next startable issue, because `untouched?` (894–896) excludes the reported one.
- But no later fill happens: the only re-entry into `drive` is after `settle_one` (855–856), which needs something live.

**One detail the finding omits.** A run-wide refusal does not go through this path:
- A torn sign-off seen by the progress fold raises out of `@progress.call` (850), outside `launch`'s rescue.
- `factory_spec.rb:533–547` pins that raise ("refuses to start over a torn issue_plan sign-off … launches nothing").
- A torn line first seen inside `@plans.call` (the `ensure_plan_approved!` walk) is a `Lain::Error`. `launch` would rescue it and report it per issue.

### 2. Most recent change

**Neither round-17 card touched the loop.** `git log -L846,857` and `-L901,908` show only:
- `e92c4483` (2026-09-11, "epic: /implement-epic works a mounted epic's approved issues to its branch"), which introduced it;
- `b31a7d58` (2026-09-13), which collapsed the driver's five files into three.

T19 (`51b0be4d`) changed `run`, the layout, `judge` and the landing checkout, but not `drive`, `fill` or `launch`.

### 3. Why it is this way

**The stated design is the opposite of the behaviour:**
- `e92c4483`'s message: "A refusal stops its own issue and never the run".
- The class comment (factory.rb:616–619): "ONE ISSUE'S TROUBLE IS ONE ISSUE'S. Every step after the launch can refuse, and each refusal stops that issue, records why, and leaves the loop running".
- `launch`'s comment (898–900): "The rest of the run keeps moving."

**The loop's shape is "fold, fill, settle one, fold again"** (842–845), and its termination rule assumed an empty fill means nothing is runnable. No card or ruling discusses a fill that refused everything.

**The specs never reach the case:**
- `run_spec.rb:243–256` ("an issue whose plan is not approved") has a sibling `a` that launches, so the run continues through `a`'s settle.
- `factory_spec.rb:518–531` ("refuses an issue whose plan declares no subject") has a single issue.

### 4. Classification

**(c)** Pre-existing since `e92c4483`. It contradicts that commit's own stated intent, and no round-17 card touched the loop.

### 5. Constraints and open questions

**Constraints:**
- **`STARTABLE = "in_flight"` (633) and the one-writer rule** ("Approving an issue's plan is what writes `pending -> in_flight` … a driver that moved an issue itself would be a second one", 628–632). A refill must not start pending issues.
- **`untouched?` is what stops the refold offering the same issue forever** (891–896). A refill loop terminates only because a reported issue is excluded.
- **Width is a concurrency bound** (`run_spec.rb:211–222`, "bounds how many actors are live at once"). A refill must still never exceed it.
- **Run-wide refusals should stay run-wide.** The torn-sign-off raise (`factory_spec.rb:533–547`, T5's AC "the driver will not start issues over an unreadable sign-off … starts no issue") escapes the loop. A refill must not turn a run-wide `SessionJournals::Unreadable` met inside `@plans.call` into N per-issue reports.
- **Recursion depth.** `drive` recurses per settle. A refill that recursed per refusal would add a frame per refused issue.
- **Specs to keep green:** `run_spec.rb` (width; pending; plan-not-approved; budget 418–443; interrupt 445–497; "leaves the asker free" 503), and `factory_spec.rb:518–547`.

**Open questions for the human:**
- Should a launch refusal that is not issue-specific (an unreadable journal, `SessionJournals::Unreadable`) abort the run rather than be reported per issue?
- Should the summary line say what was never reached, rather than only `N left for you`?

---

## F149 — the landing checkout is per project, not per epic

### 1. Mechanism, re-verified

**Confirmed, and the finding understates how long it lasts.** In factory.rb:
- `LANDING = "landing"` (65–67). `landing_checkout` (508–518) builds `LandingCheckout.new(path: File.join(worktree_root, LANDING), …)`.
- `worktree_root` is `IsolationBackend.worktree_root(@root, paths:)` (574), a per-project container (`cli/isolation_backend.rb:90`).
- `LandingCheckout#cut` (247–250) calls `standing? ? relock : add`. `standing?` (262–265) is true only when the directory's `symbolic_head` equals **this** epic's branch ref.
- So a checkout standing on `epic/plans` reads not-standing for `epic/tiny`. `add` (267–271) runs `git worktree add --lock …` into an existing path, and git refuses with "already exists".
- `release` (252–256) only unlocks; nothing removes or re-points the checkout.

**How long it survives comes from `Isolation::Gc::Checkouts#settle`** (`isolation/gc.rb:298–307`), not from a flat 7 days:
- **Nothing landed** (the fork's `plans` case): the reflog never moved, so `unmoved` keeps it with "nothing has landed since it was cut; retained until …" (321–325) until `retain_days`.
- **Landed but the epic not merged to main:** "unmerged commits; retained until …" (303), then `expire` at `retain_days`.
- **Landed and merged to main:** reaped on the next gc (304; the fork saw `reaped …/landing: landed on main`).
- So a second epic is blocked until the first is finished and merged, or `retain_days` passes.
- **Concurrency makes it worse.** Two epics driven concurrently in two chats collide the same way. The second meets git's "already exists", not the named "leased by live process" refusal, because `unheld!` (295–301) is reached only through `relock`.

### 2. Most recent change

- **`LANDING` and the shared path:** `e92c4483`. The original `cut_landing` already did `File.join(worktree_root, LANDING)` with `return path if standing_on?(path)`.
- **T19 `51b0be4d`** ("epic driver: read the project's layout, judge net work, lock landing") moved that into `LandingCheckout`. It added the lock, `relock`, the compare-and-swap `taken!`, and `release`, and kept the path and `standing?` rule verbatim. The diff shows `standing_on?` becoming `standing?` and `cut_landing` becoming `LandingCheckout#cut`.
- **T10 `4b0778f8`** ("worktrees: a retained checkout detaches; gc keeps one that never moved") added `moved?`/`unmoved` (`gc.rb:309–325`).

### 3. Why it is this way

**The standing-reuse comment** (260–261): "An earlier run's checkout is reused where it stands, so a chat driving its epic twice does not accumulate worktrees." Reuse was designed per epic. Nothing considered a second epic.

**T19's problem statement** was F116's lock half only: "the landing checkout is cut unlocked". Its design: "`cut_landing` adds its checkout **locked**, and the run's end releases the lock."

**T10's gc guard is the reason the collision now lasts.**
- F116 found gc reaping a fresh landing checkout as "landed on main". T10's AC: "a fresh checkout at its cut point is not reaped as landed … kept … nothing has landed since it was cut".
- Before T10, an un-moved landing checkout cut at main's tip was reaped daily. That accidentally cleared the collision for the nothing-landed case.
- The landed-but-unmerged case was already kept before T10 (`c4ace79b`'s "unmerged commits").

The Execution log (plan, 375–377) notes that F116 is not closed until T19's lock lands. Nobody raised multi-epic use.

### 4. Classification

**(b)** A gap outside T19's scope: T19 kept a per-project path it did not examine. T10's deliberate guard lengthened the nothing-landed case from about a day to `retain_days`. That is a consequence of a correct fix, not a regression in the fix's own terms.

### 5. Constraints and open questions

**Constraints:**
- **T19's lock discipline:**
  - the lock is written in the same `worktree add` (211–217);
  - `release` drops only this process's seal (252–256);
  - `relock`'s compare-and-swap against a dead lock (273–293);
  - T19's escalation trigger: "released on every run end, including Ctrl-C" (`holding` 486–490).
- **Pinned specs:** `factory_spec.rb:740–755` (two runs race for one checkout; exactly one wins) and `factory_spec.rb:501–511` (a human's lock is refused and left alone).
- **T10's gc guard must keep holding** (`gc_spec.rb` "a fresh checkout at its cut point is not reaped", and "calls work reachable from main landed"). The gc fixtures hard-code `File.join(@root, "landing")` (`gc_spec.rb:130, 305`); `factory_spec.rb:187` reads `described_class::LANDING`.
- **Re-pointing a standing checkout to another epic's branch moves its HEAD reflog.** `gc.rb:315–319`'s `moved?` would then read "moved", and a checkout whose new head is reachable from main could be reaped as "landed on main". That is F116's shape by another route. `landing/<slug>` does not have this interaction.
- **`gc`'s `inside?` (270–274)** accepts any path under the worktree root, so a nested `landing/<slug>` stays in scope.
- **The in-place branch:** a chat already standing on the epic branch lands in the human's checkout (`InPlace`, 219–223; 515). Leave it unchanged.

**Open questions for the human:**
- Should two epics in one project be driven **concurrently**, or only in turn? A per-epic path answers both; re-pointing answers only "in turn".
- Should an existing `…/landing` from before the fix be migrated or left for gc?

---

## F150 — a retry past the red step wedges on the stale issue branch (F99 DIFFERENT)

### 1. Mechanism, re-verified

**Confirmed.** In `lib/lain/cli/epic_driver/issue_actor.rb`:
- `IssueActor#cut` (211–222) calls `WorkingBranch.owned(branch_name, from: git.head…)`, then `switched!` (224–229) runs `git switch`.
- `WorkingBranch#establish` (`isolation/working_branch.rb:148–153`) creates the branch only when absent. A standing owned branch is reused where it stands (`standing`, 157–163), whatever `from:` says.

**The red step then runs over that branch.** In factory.rb, `IssueTests#call` (1049–1053) calls `generated` (1073–1080), which raises unless `TestGeneration::Record#generated?`.

**`generated?` reads false when the file already exists and is unchanged.** It is `(created? || changed?) && (…)` (`gherkin/test_generation.rb:53`): `created?` needs `before.nil?`, `changed?` needs `before != after`.

**On a retry the branch already holds attempt 1's red commit,** so the target exists before the spawn. A test-engineer that correctly leaves matching tests alone produces "left no tests the layout accepts".

**The misleading parenthetical is real.** It interpolates `record.verdict` (1078–1079), which is the guard's accepting verdict ("… mirrors …").

**The finding misses a second false statement.** The brief says "Your checkout stands on `#{branch}`, cut from the tip of `#{working_branch}`" (issue_actor.rb:87–94), which is untrue on a retry. The actor is told to rebase onto the epic branch before settling (126–134), and retirement rebases (`RedOnly` comment, factory.rb:319–325). So the stale base alone is recovered downstream, and the wedge is only the red step.

### 2. Most recent change

- **The reuse rule:** `abb6e4ea` (2026-09-11, "an issue launches as an actor … cuts lain/issue/<slug>/<id> at the epic branch's tip through WorkingBranch.owned") and `91f015ea` ("never force-moved").
- **`generated?`:** `68f0d4f7` (2026-09-11).
- **T10 `4b0778f8`** made the retry reach this point. Its AC: "the retained checkout's HEAD is detached … And `git switch lain/issue/e/i` succeeds in a new worktree". Before T10 the retry died earlier on "already used by worktree" (R17 F99).

### 3. Why it is this way

**Reuse is deliberate and pinned:**
- `issue_actor_spec.rb:297–310`: "A retry finds the branch its first attempt made. It is reused where it stands, never reset onto the epic's newer tip."
- `working_branch.rb:14–18`: "NEVER FORCE-MOVED … an existing one is left exactly where it is. One lain created carries a marker … the only licence anything has to delete it later."

**`generated?` requiring a change is deliberate too** (test_generation.rb:45–52): "A target left as it was reads false even when a sibling was written."

**Retries were designed around the anchor, not the branch:**
- `e92c4483`: "The attempt is read from the anchors already in the repository, so a retry launches rather than being refused by the last attempt's anchor."
- factory.rb:451–456 and `unanchored!` (issue_actor.rb:246–257) say the same.

**T10 scoped only the checkout-holds-branch half.** The Execution log (plan, 376–377) records a remainder: "A retained checkout left mid-rebase still blocks the retry's `git switch` (F99 remainder)". Nobody considered the red step over a branch that already carries its red commit.

### 4. Classification

**(b)** Two deliberate rules meet, and no card examined the combination: "reuse the owned branch where it stands" and "generation must change the target". T10 made it reachable but did not cause it.

### 5. Constraints and open questions

**Constraints:**
- **Never force-move a working branch** (`working_branch.rb:14–18`; `issue_actor_spec.rb:297–310`; `working_branch_spec.rb:211` "reuses a branch lain owns where it stands, moving nothing and re-marking nothing"). The finding's "reset the branch per attempt" contradicts a pinned, commented decision. Relitigating it needs the human.
- **Refuse a branch lain did not create** (`issue_actor_spec.rb:277–295`).
- **The attempt anchor is how attempts are told apart** (`unanchored!`, issue_actor.rb:246–257; `issue_actor_spec.rb:263–273`). The lane `issue.<slug>.<id>.<attempt>` (231) already carries the attempt, so a per-attempt branch name is one available axis, if the human wants it.
- **Red-step refusals are specified:**
  - no layout;
  - no mirroring level;
  - no tests the layout accepts;
  - tests that already pass (1082–1089, "check nothing the work will change");
  - `issue_tests_spec.rb`.
- **If the fix carries attempt 1's red commit forward:**
  - The commit message records `from criteria <digest>` (1108), which can identify it.
  - Attempt 1 may also have left **implementation** commits on the branch (it reached retirement), so `failing` could then refuse with "none failed before any work was done". That sentence would be false.
- **`RedOnly`** judges no-work by net diff from `merge-base(epic, tip)` (factory.rb:338–344). A carried-forward red commit on a stale base must still judge correctly after retirement's rebase.

**Open questions for the human:**
- Keep "reuse where it stands" and teach the red step to accept an existing red commit whose criteria digest matches? Or name the branch per attempt? The second changes the one-branch-per-issue shape the brief and landing assume.
- Should the brief stop claiming "cut from the tip of epic/<slug>" when the branch was reused?

---

## F151 — a parseable but damaged `gate_decision` still fails open (F93's class)

### 1. Mechanism, re-verified

**Confirmed, and wider than the finding says.** In `lib/lain/approval/signoff_queue.rb`:
- `SignoffQueue.apply` (330–335) checks only `type` (inclusion in `["gate_decision"]`), `policy` (presence) and `approved` (true or false) via `Contracts::Decision` (122–132).
- `Partition` (153–164) checks `epic_slug` and `stage` for **presence** only (`Contracts::Partition`, 86–94).
- `from_journal` (308–314) reads through `Journal.records(entries, type: JOURNAL_TYPE)`, so a record whose `type` is misspelt never reaches `apply`. It is simply foreign.
- `SessionJournals` keeps only `@types` records (`counted_in`, `cli/session_journals.rb` near the end of the file). Its `Torn` sniff applies only to **unparseable** lines.

**Other damaged fields fail open by the same route.** This is inferred from the code and was not driven by the fork:
- **A misspelt `policy`** (for example `"deferrd"`) makes `deferred?` (339) false. The record is taken as terminal and **drains**, so a parked deferral reads as answered.
- **A damaged `epic_slug`** (a different but non-blank slug) parks under a partition the real epic never asks about. That reads as drained.
- **A damaged `issue_id` for an issue-scoped stage** parks under another issue's partition. The real issue's partition then reads as drained.

**The contrast inside the tier:** `Epic::Progress`'s stage fold does validate `stage` on read. `checked_start` constructs `Stage.new(record["stage"])` (`epic/progress.rb:170–174`), which raises `UnknownStage` (`epic/stage.rb:15–17`).

### 2. Most recent change

- **T5 `60998de4`** ("refuse a sign-off fold over a journal it could not read whole") added `UnreadableRecord` and the rescue in `from_journal`, and made `SessionJournals` strict on torn lines.
- **T17 `7016ab7d`** added `UnreadableRecord.for` (74–78) and the note that `Gate.from_journal` refuses the same way.
- **`Contracts::Decision`'s `type`/`policy` guard** dates from `29404c57` (2026-07-28), with later contract renames (`286473bc`) and `7faa53ba` (issue_id).

### 3. Why it is this way

**T5 was scoped to F93 (torn line) and F114 (`approved: "maybe"`).** Its design: "Refuse only what could matter … a line whose type prefix is unreadable, or names gate_decision/stage_transition, refuses; a torn line of any other type is counted and skipped". Its fold-boundary item: "`SignoffQueue.from_journal` translates `ArgumentError` into `UnreadableRecord`".

**T5's escalation triggers fence this area:**
- "`spec/lain/journal_spec.rb` pins `.records` skipping foreign lines. This card must **not** change `Journal.records`."
- "If a **write-side** spec would have to change, stop."

**The code states the hazard and the fail-closed doctrine:**
- `stage.rb:15–16`: "a typo that constructs folds onto a partition nothing writes to, and reads as drained."
- `Contracts::Decision`'s comment (103–121): "Refusing is the only answer safe in BOTH directions" and "`approved` is a TRUNCATION CANARY. No producible record is ever rejected by that clause". This is the argument that would also license a closed-set `stage` check on read.
- The epic-domain panel ruling (`planning/archive/chunk-epic-domain.md:790–798`): "a failed queue rebuild aborts the session. It never degrades to an empty queue".

**The scenario (`epic-tier.md` §9) withdrew one variant:** "Round 17 withdrew the flipped-digest-byte variant: it fails closed as an unknown partition, not as a drained one". So digest damage was judged safe; address damage in the other fields was not examined.

### 4. Classification

**(b)** Outside T5's scope (torn lines plus `approved`). The class was known in the code's own comments (`stage.rb:15–16`) and not closed.

### 5. Constraints and open questions

**Constraints:**
- **Do not change `Journal.records`' foreign-skip contract** (T5 trigger; `spec/lain/journal_spec.rb:537`). A gate-shaped record of unknown type can only be caught above it, in `SessionJournals` or the fold.
- **Validate at the fold, not at the write-side carrier.** Several specs write `GateDecision`s with non-pipeline stages through a live `Gate#call` (`stage: "s"` in `spec/lain/approval/gate_registry_spec.rb`, `gate_regression_spec.rb`, `gate/policy_spec.rb`; `"nonsense"`/`"qa"`/`"planning"` in `epic/records_spec.rb`, `epic/submission_spec.rb`). T5: "The carriers' write-side `ArgumentError` is untouched."
- **Load order.** `Approval` loads before `Epic`, so `Epic::STAGES` must be read at call time, as `SessionJournals::Torn.decisive_types` does (a method, "Epic::StageTransition loads after this unit").
- **The listing stays lenient and warns.** Only the `EpicQueue` listing opts into `Tolerate` (`session_journals.rb` `Refuse`/`Tolerate`; `epic_queue_spec.rb`).
- **One refusal sentence.** `UnreadableRecord.for` is shared with `Gate.from_journal` (70–79; `gate_registry_spec.rb:80–98`).
- **The policy set is closed in practice:** `interactive` (`gate.rb:186`), `hands_off`, `deferred`, `adjudicated` (`gate/policy.rb:137,157,175,224`) and `signoff` (`epic_queue.rb:60`). Adjudicated parks journal `policy: "deferred"` (`policy.rb:101–105`).

**Open questions for the human:**
- **Should the read-side fold also validate `policy` against that set?** A misspelt policy drains, which is the same fail-open.
- **Can `epic_slug`/`issue_id` damage be caught at all?** The fold has no list of real epics or issues. Should an address naming no existing epic or issue refuse at `status`/`submit`?
- **What is a "gate-shaped record of unknown type"?** Which field set counts (the fork proposed `artifact_digest` + `epic_slug` + `policy`), and does it refuse or warn?

---

## F163 — the stage boundary treats a never-submitted stage as drained

### 1. Mechanism, re-verified

**Confirmed.**
- `Epic::Stage#ensure_open!` (`epic/stage.rb:111–116`) rejects only earlier stages whose `queue.drained?` is false.
- `SignoffQueue#drained?` (`signoff_queue.rb:277`) is `parked(...).empty?`, so a partition nothing ever wrote to is drained.
- The only callers are `Policy::Boundary#ensure_open!` (`approval/gate/policy.rb:48–66`), used by `Policy#decide` (87–95) and by the adjudicator (`gate/adjudicator.rb:427`).
- Nothing on the submit path consults whether an earlier stage was **approved**.
- `EpicSubmit#settled` (`cli/epic_submit.rb:458–467`) checks `required` plans only for `implementation` (`Artifacts#required`, 192).

**The consequence runs into the driver.** An `issue_plan` approval moves the issue to `in_flight` through `Epic::Advance` → `InFlight` (`epic/advance.rb:62, 90–97`; `in_flight.rb`). The driver launches exactly `in_flight` issues (`factory.rb:633`).

**Two truths then disagree.** The stage fold starts at `research` when no transition exists (`epic/progress.rb:87–90`). So `status` reads `stage research` with an issue in flight, as the fork saw.

### 2. Most recent change

- **No round-17 card touched `ensure_open!`.** `stage.rb`'s last behavioural change is `7faa53ba` (2026-09-11, issue-scoped partitions); `345a4e63` only deleted error classes.
- **The rule dates from `29404c57`** (2026-07-28, "approval: gate policies, stage boundaries, and a queue that is a fold").
- **T25 `f13d276d`** added `Epic::Advance`, which reads the stage fold (`epic.stage(slug)`) to decide what an approval **advances**, but not whether a gate may **open**.

### 3. Why it is this way

**It is the interview ruling, stated as "drained":**
- `planning/archive/chunk-epic-domain.md:534–538`: "a stage's gates may only open when every earlier stage's queue partition is drained — partitions are keyed (epic_slug, stage) … `SignoffQueue#drained?(epic_slug, stage)`".
- That card's trigger (line 584): "If any check needs state broader than one (epic_slug, stage) partition — cross-epic ordering, global drains — stop".
- The docstring (`stage.rb:23–27`) gives the purpose: "it may never cross a boundary, or an epic would reach implementation on a plan nobody ever signed off", which is what happened.
- `planning/archive/chunk-implement-epic.md:346` relies on it: "One issue's parked gate never blocks another's. `Stage#ensure_open!` → `queue.drained?`".

**The scenario endorses the letter.** `planning/qa/scenarios/epic-tier.md` §6: "`lain epic submit epic_plan other-epic` … MUST proceed -- partitions are (epic_slug, stage)". The fork (§6 correction) asks for a ruling before keeping that.

**T25's comment shows the stage fold was deliberately kept separate:** "An epic-wide stage is read from the stage fold alone, never from epic.md" (`advance.rb:13–16`). T25 changed only what an approval advances.

### 4. Classification

**(d)** By design: the "drained" rule is the recorded interview ruling. Whether "drained" should mean "has a terminal approval" is a ruling **owed**, and R18 already files it as "E18-5 (ruling)".

### 5. Constraints and open questions

**Constraints:**
- **Partitions stay scoped to `(epic_slug, stage[, issue_id])`.** One epic must never block another (`stage_spec.rb:111–150`; the "epics do not block each other's boundaries" AC in chunk-epic-domain). A stricter rule scoped within one epic does not cross that trigger. But §6's "other-epic with untouched research MUST proceed" half would change: it would need other-epic's research approved to prove the partition keying.
- **Issue scoping** (`stage_spec.rb:156…`): "a sibling's parked plan is not this issue's boundary". A positive-approval rule for `issue_plan` → `implementation` already exists (`EpicSubmit#ensure_approved!`, 481–488).
- **One boundary call site** (`Policy::Boundary`, `gate/policy.rb:40–66`, from `chunk-epic-wiring-intake-landing.md` T9). A stricter check goes there, and then needs a second collaborator (the stage fold or the gate registry) beside the queue. `Policy::Drained` exists "only for a caller that legitimately has no queue" (chunk-epic-domain panel note).
- **About 21 `submit("issue_plan", …)` calls in `spec/lain/cli/epic_submit_spec.rb`** and many policy specs open later stages over empty earlier partitions. A stricter rule rewrites their fixtures.
- **Stage fold semantics:** issue-scoped verdicts never advance the epic-wide stage (`progress.rb:184–188` `watched`). A rule "the epic's stage must have reached X" would read `issue_plan` as the ceiling, never `implementation`.

**Open question for the human.** Does an earlier stage need a **terminal approval** (positive evidence), or only **no parked sign-off**? If the former, is the evidence the stage fold (`stage_transition`) or an approved `gate_decision` for that partition?

---

## F164 — a terminal interactive gate has no timeout or latency; Ctrl-C prints a backtrace

### 1. Mechanism, re-verified

**Confirmed.**
- `EpicSubmit::Prompt#ask` (`cli/epic_submit.rb:97–100`) writes the question, blocks in `@input.gets`, and returns an already-resolved promise.
- `Gate#call` (`approval/gate.rb:264–282`) calls `asker.ask` (267) **before** `await` (435–440).
- `await` starts `@clock` and `task.with_timeout(@timeout)` only around `promise.await`, so the whole human wait is outside both.
- The journaled latency is the time to `await` an already-resolved promise.

**Ctrl-C.** `exe/lain`'s `render` (81–85) rescues only `Lain::Error`, so `Interrupt` escapes Thor. Only `exit_status` (90–96) rescues `Interrupt`, and `epic submit` (exe/lain:404–409) uses `render`.

**The chat-borne gate is unaffected.** Its asker returns an unresolved promise (`Heard`/`Hearing`, 116–161), which is why the fork's control journaled `latency: 105.3`.

### 2. Most recent change

- **T17 `7016ab7d`** edited `Prompt`: EOF became `GateReply::EOF`, `unheard`, and `Heard`/`Hearing`. It kept `ask`'s synchronous shape and the design comment.
- **The synchronous prompt and its comment** are from `7dfdd9dd` (2026-07-30, "cli: put a stage artifact in front of its gate"). `Gate#await`'s clock placement is from `f263b116` (2026-07-28).

### 3. Why it is this way

**The timeout is off by explicit design** (`epic_submit.rb:48–54`, present since `7dfdd9dd`):

> "`#ask` resolves the promise before it returns, so {Approval::Gate}'s timeout window never opens here. Deliberate: the answerer is the person who just typed the command, this process has no second fiber to hand the reactor to while a `gets` blocks, and a bare CLI's refusal is Ctrl-C."

**T17 re-read this code and kept it.** Its scope was F100 (retire questions), E1 (hands_off unattended) and E3 (EOF).

**The latency ≈ 0 record is not addressed by any comment.** It contradicts the `GateDecision` contract's own stance (`gate.rb:43–45`): "Guarded rather than coerced: `to_f` turns nil … into 0.0, writing 'answered instantly' -- a measurement nobody made -- into the experiment record."

**The comment's premise may no longer hold.** The fork's backtrace frame (`async/scheduler.rb:538 in Thread.handle_interrupt`) shows the `gets` running under Async's fiber scheduler (`Verdict#call` wraps the decision in `Sync`, 302–307). The premise "no second fiber to hand the reactor to" should be re-verified before it is relied on either way. This is an observation from the fork's evidence, not verified here.

### 4. Classification

Three parts:
- **(d)** the timeout: by design, a ruling taken in `7dfdd9dd` and retained by T17.
- **(c)** latency ≈ 0: a pre-existing consequence of that design that nobody examined.
- **(c)** the Ctrl-C backtrace: pre-existing, since `render` never rescued `Interrupt`.

The same shape appears at `lain bench arms` (F178).

### 5. Constraints and open questions

**Constraints:**
- **Fail-closed on every non-affirmative reply, EOF included,** journaled as `eof` (T17 AC "end of input is not a human's answer"; `epic_submit_spec.rb:883`). Also `unrecognised` (T17 review ruling).
- **`Prompt.on` returns nil for a non-TTY session** so `Policies::Deps` refuses an interactive stage by name (67–80; T17 AC "an unattended submit of an interactive stage refuses in words").
- **`Gate#call`'s ensure ordering:** journal first, register second (270–278); withdraw and retire from `ensure` (279–282, 378–424). A promise that resolves asynchronously must still retire nothing for a prompt that names no question (`retired` returns unless `asked.respond_to?(:digest)`).
- **Latency on expiry reports the window, not the clock delta** (426–440).
- **Only the frontend and exe may touch `$stdin`/`$stdout`** (CLAUDE.md output discipline). `Prompt` takes injected streams.
- **`run_spec.rb:503` "leaves the asker free for the next run's first gate"** must hold.

**Open questions for the human:**
- Should a terminal gate the human just invoked be subject to `DEFAULT_TIMEOUT` (300 s) at all? This is the explicit design choice to confirm or overturn.
- If the timeout stays off, should the latency be measured from the question's write, or journaled as unmeasured rather than about 0?
- Should `Interrupt` map to a named refusal for every `render` command, or only for `epic submit`?

---

## F165 — `lain epic merge` drops criteria and reopens a done issue

### 1. Mechanism, re-verified

**Confirmed. The loss is in the CLI, not in `Graph#merge`.**
- `CLI::Epic#merge` (`cli/epic.rb:288–295`) builds the arrival as `Lain::Epic::Issue.new(id: as, title: title || merged_title(...))`. That gives a default `description: ""`, `status: "pending"` and `criteria: nil` (`epic/issue.rb:82–84`).
- `Graph#merge` (`epic/graph.rb:186–199`) takes `as:` as given. It inherits only edges, and provenance when the arrival declares none.
- **Contrast:** `CLI::Epic#split` (269–277) builds each part as `original.with(id: part_id)`. Its docstring (260–263) says "each inherits `id`'s title, description and criteria".
- Nothing in either merge refuses or warns about a `done` side.
- **A second effect the finding leaves out.** Because the merged issue has `criteria: nil`, a later driver launch refuses at `IssueActor#criteria_of` (`issue_actor.rb:239–244`, "declares no acceptance criteria").

### 2. Most recent change

- **T18 `dac580d4`** ("graph edits keep the preamble and shared provenance") edited `Graph#merge` to add `shared_discovery` and the preamble carry.
- **The CLI's criteria-less arrival** is from `82bd3784` (2026-09-11, "status --mermaid draws the graph, and add/split/merge edit it"), moved by `f7c89e61` (2026-09-12).
- **Graph merge semantics** are from `f145e520` (2026-07-28).

### 3. Why it is this way

**T18's problems were only F117 (preamble) and fork E7 (shared provenance).** Its design: "`Graph#merge` keeps a provenance both sides share." Criteria and status were not in scope.

**`f145e520`'s message** covers edges and provenance ("add and merge let the author's value win"), not content.

**`Graph#merge`'s comment** (186–192) reasons only about provenance ("a merge has two parents and `discovered_from` holds one, so choosing between two DIFFERENT answers would be a guess").

**The asymmetry with split is unexplained anywhere.** Split's criteria carry has a docstring; merge has none.

### 4. Classification

**(b)** Pre-existing since `82bd3784`, adjacent to T18. T18 edited the same method for a sibling loss (provenance) and did not examine content or status.

### 5. Constraints and open questions

**Constraints:**
- **Merge semantics pinned in `spec/lain/epic/graph_spec.rb`:** edges unioned, self-references dropped, provenance rules (279–321), and fiber replay (233–240, 353–365).
- **`spec/lain/cli/epic_spec.rb:726–731`** pins that the merged issue inherits both sides' edges.
- **The graph digest is graph-only and `canonical` includes description and criteria** (`issue.rb:110–112`). A merge that carries criteria changes the arrival's digest and therefore the `graph_revision` fiber's preimage. The fiber replay laws (`graph_spec.rb`, "a merge unions … Replaying this fiber over `other`") must still hold.
- **Criteria are Gherkin source inside a fence** (`issue.rb:57–61` `NO_SCENARIOS`; `Document.grammar_failures`). Concatenating two fences must still parse to at least one scenario and pass the document grammar (`Issue#emittable?`).
- **The issue_plan digest composes the criteria** (`7faa53ba`), so any merged issue's plan needs re-approval.
- **"Abandoning a blocker does not unblock"** (`graph.rb:131`, `blocking.rb:158`). Status handling in merge must not bypass it.

**Open questions for the human:**
- Concatenate both criteria blocks, refuse unless the author names a side, or require criteria on the command?
- Refuse to merge a `done` (or `in_flight`) side, or carry the "least finished" status and say so?

---

## F154, epic half — adjudication spikes send no `num_batch`

### 1. Mechanism, re-verified

**Confirmed.**
- `EpicSubmit::Adjudication.flags` (`cli/epic_submit.rb:601–604`) returns only `provider`, `model` and `max_tokens`.
- `from_options` (400–405) builds `Backend.new(Adjudication.flags(options))`.
- `Backend#sampler_extra` (`cli/backend.rb:602–606`) reads `@options[:num_batch]`/`:num_ctx`, which are absent.
- `exe/lain`'s `epic submit` (397–409) declares `--issue`, `--digest`, `--provider` and `--model` only.
- `LAIN_NUM_BATCH` becomes a default only through `ModelFlags.throughput` (exe/lain:778–788), declared for `chat` via `ModelFlags.declare(self)` (1033).
- `Backend#tier_options` (T14, backend.rb:241–268) is not on this path at all. The adjudication backend is the spawn's **main** provider, not a secondary tier.

**In-chat adjudication is not wired.** `Factory#submit` (factory.rb:590–593) builds `EpicSubmit` with no `role_spawn:`/`brief:`, so an adjudicated stage refuses there as "not wired" (epic_submit.rb:362–366).

### 2. Most recent change

- **T14 `bfe984e9`** ("backend: secondary model calls carry the chat's runner-keying options") added `tier_options`/`RUNNER_KEYS` for the summarizer, span summarizer and secret oracle.
- **`Adjudication.flags`** is from `7faa53ba` (2026-09-11), moved by `f7c89e61`.

### 3. Why it is this way

**T14's reachability named three in-chat sites** (`summary_oracle`, `CompactionStrategy.resolve(tier:)`, `secret_surface`). Its rule was within one process: "carries them only when the tier's model **equals the chat's model** on the same ollama endpoint".

**`lain epic submit` has no chat in its process,** so T14's rule has nothing to compare against.

**The adjudication comment** (543–545) says it "builds its own over the same backend flags a chat reads -- the precedent is {CLI::Improve.from_options}". In fact it reads only two of them. `epic_submit_spec.rb:1037–1041` repeats "from the same backend flags a chat reads".

**The throughput flags' comment** (exe/lain:763–777) requires that an unset variable contributes nothing, so an unflagged payload stays byte-identical.

### 4. Classification

**(b)** Outside T14's enumerated reachability. R17's F95 named only the chat's secondary calls.

### 5. Constraints and open questions

**Constraints:**
- **Unset means absent:** `EnvDefaults.numeric` gives nil and no `options` key (exe/lain:763–777; `backend_spec.rb`'s no-options example; T14 AC "a flagless run still sends no options").
- **Ollama-only keys never reach another provider's wire** (T14 review; `Backend::OLLAMA_ONLY_KEYS`, backend.rb:52; `sampler_extra` 602–606). `epic submit --provider` defaults to `anthropic` (exe/lain:399).
- **The pair is built lazily, only when a stage is adjudicated** (`Adjudication.pair`, 585–592; `epic_submit_spec.rb:564–572`, and 1064–1075 "builds no backend when no stage is adjudicated").
- **T14's rule stands:** the chat's temperature and seed never reach a tier. If `epic submit` gains sampler flags, only the runner-keying pair is in question.
- **The shared cause (R18's F154 main half)** is the same gap in `bench arms`, `consolidate` and `improve` (`Backend.new(options)` at `consolidate.rb:30`, `improve.rb:126`, exe/lain:553, 641). One fix shape may cover all of them.

**Open question for the human.** For a standalone command, is the rule "honour `LAIN_NUM_BATCH`/`LAIN_NUM_CTX` as a chat would", declaring the throughput flags on the command? Or "carry only when the adjudicator's model equals some configured chat model"? T14's same-model rule has no in-process chat to compare with here. Carrying `num_ctx` to a different model forces that model's own reload (T14's reason for not carrying it).

---

## F192 (LOW) — graph edits vs runtime state, `a_b` ids, abandoned blocks `finish`

### E18-11: graph edits orphan parked gates

1. **Mechanism.**
   - `CLI::Epic#apply` (`cli/epic.rb:406–415`) reads `epic.md`, edits the graph and writes it back. It reads no session journal, so parked gates, in-flight transitions and anchors are not consulted.
   - `split` gives each part `original.with(id:)` (272), which carries the stored status.
   - The fork's parked implementation gate for `export-writer` stayed in the queue and could still be approved.
   - Confirmed as far as the code goes; the queue's cross-epic listing is the fork's evidence.
2. **Change.** `82bd3784` (verbs), `f7c89e61` (moved), `dac580d4` (T18, preamble). No card touched runtime checks.
3. **Why.**
   - `apply`'s comment is about write ordering and the preamble only (382–405).
   - `Progress`'s unknown-id message (`epic/progress.rb:160–168`) already anticipates that "a structural edit dropped the provenance", and `Discovered from:` is the recovery the design chose.
4. **Class: (c).**
5. **Constraints.**
   - The `graph_revision` journaling order: write before journal, "reviewed and kept deliberately" (395–405).
   - Split takes provenance from the split id (`f145e520`).
   - **Open question:** refuse, or warn, when an edited issue holds parked or approved gates?

### E18-12: an id like `a_b` is listed ready and can never be submitted

1. **Mechanism.**
   - `Issue` construction checks the markdown grammar (`ID_RESERVED`/`ID_RULES`, `issue.rb:20–41`) but not `Home::NAME` (`home.rb:35`).
   - `Issue#emittable?` (115–120) answers for both grammars, but its only callers are specs (`issue_spec.rb:378–411`, `document_spec.rb:414`).
   - `Home.checked_name` refuses at `submit` time (home.rb:103–108). Confirmed.
2. **Change.** `4f4ef2a8` (2026-07-30, "ask the issue whether it can be emitted, once").
3. **Why.**
   - `chunk-epic-wiring-intake-landing.md` T10 deferred it by an escalation trigger: "Do not make `split`/`merge` refuse un-emittable results; that behavior change belongs to a future card if the panel wants it."
   - `chunk-epic-domain.md` follow-up 3 (~1120–1132) named the hazard: a graph "valid and content-addressed yet contain an issue whose story file can never be written".
4. **Class: (b).** A known gap, deliberately deferred to a future card that was never written.
5. **Constraints.**
   - `Issue` is mutation-tested (the same card's trigger).
   - Lowercase-only `NAME` exists for case-insensitive filesystems (home.rb:29–35).
   - Refusing at parse makes an existing `epic.md` holding such an id unreadable. **Open question:** refuse at parse, or at `add` plus `status`?

### E18-13: one abandoned issue makes `finish` impossible

1. **Mechanism.**
   - `EpicFinish#finished!` (`cli/epic_finish.rb:85–93`) refuses unless every issue is `DONE`, and its remedy names `lain epic land`.
   - `land` requires `in_flight`, and `InFlight` never moves an abandoned issue ("a plan does not restart a done or abandoned issue", `in_flight.rb:10–12`).
   - No command removes an issue. Confirmed.
2. **Change.** `832dd353` (2026-09-11).
3. **Why.** `issue.rb:13–18`: "`lain epic status`, whose remaining-work rule is 'not done is remaining'. `abandoned` is deliberately NOT this -- it is work somebody stopped, it still blocks, and only an edge edit gets past it." `finish` applies that rule literally. The remedy sentence was written for the pending/in_flight case.
4. **Class: (d)** for "abandoned is not done", a deliberate rule; **(c)** for the wrong remedy wording and the missing removal verb.
5. **Constraints.**
   - `Graph#ready`/`Blockage` treat an abandoned blocker as blocking (`graph.rb:131`, `blocking.rb:158`).
   - **Open question:** does `finish` accept `abandoned` as terminal, or does the human want a `remove` verb?

---

## F193 (LOW) — stranded child work, repeated retry digest, inbox count mismatch

### E18-14: a child's uncommitted work hands back `nothing_to_do dirty:false`

1. **Mechanism.** Confirmed, and it has a specific trigger the finding does not name.
   - `Tools::Subagent#run_child` (`tools/subagent.rb:277–285`) calls `sync.call(...)` inside `.tap` **after** `child.ask` returns.
   - A child that raises (the 25-iteration ceiling) never syncs, so `Leases#hold` (`isolation/leases.rb:196–205`) keeps `synced = SelfSync::Result::NONE`.
   - Its `ensure` then surrenders with that `NONE`, whose `to_record` is `sync: nil, dirty: false` (`self_sync.rb:100–112, 126`).
   - `NOT_HANDED_BACK` is only produced from a real `:dirty` sync (`self_sync.rb:109`; `Run#sync` 219–223).
   - The fork's two checkouts (`children/9e6f0fcf35b6`, `children/208f034b262d`) are the same two ceiling-hit children as E18-9, so this is **the same root as F137** (a failed one-shot child's error path).
2. **Change.**
   - `run_child`'s sync placement: its comment "The self-sync runs HERE too, after the answer and before the lease's reclaim" (270–275).
   - T4 `69df4d08` and T12 `afb5e73f` touched `subagent.rb`, but not this path.
3. **Why.**
   - The sync is placed where "only this block still holds [the child] live", so a conflict can be put to the child.
   - `SelfSync`'s comment: "A DIRTY TREE IS NOT REBASED … what becomes of it once the lease is released is the release's decision" (28–31).
   - T10 keeps a dirty checkout retained and detached.
   - Nobody designed the record for the raise path.
4. **Class: (c)** on the error path. It shares F137's gap.
5. **Constraints.**
   - `Leases#hold`'s `ensure` surrenders with "nothing spawned while an exception climbs" (175–186).
   - `Async::Stop` is not a `StandardError`.
   - T10's retain-and-detach AC.
   - A dirty reading on surrender must not rebase (SelfSync rule).

### E18-15: a retry's spawn repeats attempt 1's digest

1. **Mechanism.**
   - The spawn body is `{prefix, posture, only, spawned_from, task: digest(prompt)}` (`tools/subagent/lineage.rb:64–67`).
   - `lane` and `adoption` are written only for actor spawns (143–147).
   - The red step's `test_engineer` is a one-shot through `@role_spawn.within(worker_env)` (factory.rb:1074). Its lent lane is the run's seam lane, not the attempt's (`role_spawn.rb:59–71`).
   - The same head plus the same prompt gives the same digest. Confirmed.
2. **Change.** T12 `afb5e73f` ("Identical work from one head still shares an address").
3. **Why.** Plan Open decision 5: "Two spawns of **identical** prompts from one head keep one digest … Accepted: they are the same work, and `scribe_spec.rb:380`'s child-turn dedupe depends on it." `lineage.rb:43–46` says the same: "a ruling, not a dependency".
4. **Class: (d)**, ruling taken. A retry separated in time is a case the ruling did not name. **Open question:** does "the same work from one head" cover a second attempt?
5. **Constraints.**
   - Cross-run reproducibility: "a nonce … would break CROSS-RUN reproducibility" (`lineage.rb:52–58`).
   - The `scribe_spec.rb:380` dedupe.

### E18-16: `/status inbox 2` vs `/inbox` listing one

1. **Mechanism.** Not verified in depth.
   - The two readers are different objects. `/status` reads the status feed's `inbox_count` (`cli/command/status.rb:50`; `status_feed/reading.rb:123`).
   - `/inbox` "reuses HumanReplies's OWN drain object" (`cli/command/small.rb:44–53`).
   - The fork itself says the mechanism is not verified.
2. **Change.** T17 `7016ab7d` (gate questions retire on the tee); T6/T13 (drain surfaces).
3. **Why.** Not established. Possibly "the drain shows the head" (fork).
4. **Class:** unclassified pending a read. Possibly **(d)** if the drain shows one question at a time by design.
5. **Constraints.** The inbox parity specs T17 reused (`status_feed/inbox_spec.rb`, `frontend/neovim/inbox_view_spec.rb`).

---

## F194 (LOW) — epic wording and small refusals

These were spot-checked, not all traced.

| item | where | class / why |
|---|---|---|
| `epics_home "repo " is not one of xdg, repo` | `config/epics.rb:65` | (c): internal key name |
| stage/policy typos reported in two passes; a bad policy does not name its stage | config validation for `[epics.gates]` (not traced) | (c) |
| `--issue`/`--digest` silently ignored on `research` | `EpicSubmit::Artifacts#submission` (`epic_submit.rb:179–187`) reads them only for issue stages | (c) |
| re-submitting a parked artifact journals a second `deferred` | `settled` → `standing` only when `gate.approved?` (458–467); otherwise `Verdict` decides again, and `SignoffQueue#park` is idempotent in memory only (231–248) | (c) |
| `lain epic deny` prints `signed off …` | `EpicQueue#confirmation` (`epic_queue.rb:154–160`), shared by both verbs; last touched by T25 `f13d276d` | (c), adjacent to T25 |
| `epic_plan … (1 issues)` | `Submission#fact` (not traced) | (c) |
| unrecognised reply quotes the newline | `Epic::GateReply` (T17) | (b), a T17 detail |
| `/implement-epic --wdith 1` does not name the flag | `command/implement_epic.rb` (not traced) | (c) |
| `status` reads `stage issue_plan` after a landing | `progress.rb:184–188` `watched`: "once the epic is planning its issues the stage reads the first issue-scoped one for the rest of the run"; `advance.rb` `Still` "nothing moves until it lands" | **(d)** by design |
| implementation `gate_decision` has `criteria_digest: null` | `Artifacts#implementation` (211–213) passes none; `GateDecision` docstring: "`criteria_digest` is the … digest an issue plan was approved WITH" (`gate.rb:83–86`) | (d), per the docstring |
| `approve` of an already-approved digest says "no parked sign-off" | `epic_queue.rb:172–178` | (c) |
| the adjudicated key refusal does not name the stage | `Adjudication.pair` builds the backend for any adjudicated stage (585–592) | (c) |

The parenthetical `(… mirrors …)` in F150's refusal is a wording defect in `IssueTests#generated` (factory.rb:1078–1079) and belongs with F150.

---

## Cross-finding

### Shared root causes

1. **"Drained" is inferred from the absence of a record under an exact key** (F151, F163).
   - The fold cannot tell "answered" from "never asked" from "asked under a damaged address".
   - F163 is the design reading of that absence, and F151 is damage exploiting it.
   - Both live behind `Policy::Boundary` → `Stage#ensure_open!` → `SignoffQueue#drained?`.
   - A boundary that demanded **positive evidence** (a terminal approval of each earlier partition) would also blunt address damage. A misspelt stage, slug or policy would then leave the real partition with no approval, and the boundary would refuse. This makes F151's closed-set validation defence in depth rather than the only guard.
   - F163's ruling therefore shapes F151's fix. Take F163 first.

2. **Identity keyed one level too coarse for repeat use** (F149, F150, E18-15).
   - The landing checkout is keyed by project, not epic (F149).
   - The issue branch is keyed by issue, not attempt (F150).
   - The one-shot spawn is keyed by head and prompt, not attempt (E18-15).
   - Each was a deliberate choice with a written reason: reuse without accumulating worktrees, never force-move, and reproducible content-derived identity. Each reason was argued for the single-use case.
   - One decision covers the family: "what dimension does a retry or a second epic add to identity?" Each fix must keep its own invariant.

3. **Bookkeeping written only on the success path** (F148, E18-14, and outside this group F137/E18-9).
   - `drive` re-enters only after a settle.
   - `run_child` syncs only after a successful ask, and its completion `message` is written only after `run_child` returns (`spawn_one_shot`, subagent.rb:238–247).
   - E18-14 and F137 share one fix site: the error path of `Subagent#run_child`/`spawn_one_shot`.

4. **`lain epic submit` is its own assembly and misses what the chat wiring provides** (F154 epic half, F164).
   - It has no throughput flags and a synchronous prompt outside the gate's clock.
   - `render` does not rescue `Interrupt`. That last point is shared with every `render` command and with F178 (`bench arms`).

5. **Graph verbs are document-only** (F165, E18-11, E18-12, E18-13).
   - `CLI::Epic#apply` reads `epic.md` alone.
   - Merge builds its arrival from id and title.
   - No verb consults runtime state or `Issue#emittable?`, and no verb removes an issue.
   - One card over `CLI::Epic`'s edit verbs could take F165, E18-11 and E18-12. E18-13 needs the human's ruling on `abandoned`.

### Which fixes cover which findings

| one fix | covers | caveat |
|---|---|---|
| A positive-approval boundary in `Policy::Boundary` (after the F163 ruling) | F163, most of F151's fail-open | F151's `type`/`policy` damage still wants a read-side refusal; §6's second half and many `epic_submit_spec` fixtures change |
| A read-side closed-set check in `SignoffQueue.apply` (stage in `Epic::STAGES`, policy in the known set) | F151 stage and policy variants | not `epic_slug`/`issue_id`; not a misspelt `type` (needs `SessionJournals`); not the write side |
| Refill in `Run#drive` until something is live or nothing is startable | F148 | keep run-wide refusals run-wide |
| Per-epic landing path | F149 | gc fixtures; existing `…/landing` checkouts |
| An attempt-aware red step or branch | F150; possibly E18-15 if the attempt enters the one-shot's prompt or body | never-force-move and branch-reuse specs |
| Completion and sync written on the error path of a one-shot child | E18-14 (and F137, E18-9) | Async::Stop ensure semantics |
| Throughput flags on `epic submit`, or a shared rule for standalone commands | F154 epic half (and bench arms, consolidate, improve) | byte-identical unflagged payload |
| An awaited terminal read plus an `Interrupt` rescue in `render` | F164 (latency, Ctrl-C); the timeout only if the human overturns the `7dfdd9dd` design | fail-closed EOF and unrecognised |
| Merge carries criteria and refuses or announces status | F165 | fiber replay laws; the criteria grammar |
