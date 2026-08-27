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

**PLACED, as of round 13: it joins the REGRESSION GATE**, on the same standing rule as
`repl-commands`, `epic-tier` and `survey` — anything deterministic belongs in the cheap set even
when the feature it guards is not. Until round 13 it sat in no tier at all: described here,
scheduled nowhere, which is exactly the "somebody added it and nobody scheduled it" case the skill
tells a round to name. Its first drive (round 13) found §1's instrument was not executable as
written — `slot_fills` is a **bench** record and a plain `lain chat` writes zero — which is a fair
argument for driving a new scenario promptly rather than letting it age unrun.

Almost all of it is a zero-model-turn refusal or `/ruby` inspection path, on `repl-commands.md`'s
shape. The one exception is its §6 second half: confirming the shipped default actually misses the
cache on a real round trip costs **2 completions against a live Anthropic key** — the free half of
§6 (the byte count against the published floor) costs nothing and is not a substitute for it.

**Added 2026-08-27** — the first scenario over `lib/lain/shell/`, written because the subsystem that
decides, per gated call, whether a command runs as reconstructed argv or as a string handed to
`sh -c` had **no** manual coverage at all and was not in this file's Known gaps either. The gap was
invisible:

| Scenario | The question it answers | Cost |
|---|---|---|
| [`shell-term-approval.md`](scenarios/shell-term-approval.md) | Does the **parse boundary** refuse what it claims to (the 4096-byte cap reporting *both* broken and not-covered, the newline that has no separator node and is caught by arithmetic instead), do the **verdict arms** land where they say — `git` abstaining deliberately, `deny` existing and being **unreachable in production** — and **can a driver tell from the outside which arm ran**? Runs entirely on the **local** arm. | cheap |

**It joins the REGRESSION GATE**, on the standing rule stated twice below: anything deterministic
belongs in the cheap set even when the feature it guards is not. §1, §2, §4a, §6 and §10 are
zero-model `/ruby` reads; the rest is under fifteen local completions.

**Roughly half of it is written against an unlanded chunk and says so, section by section.**
`planning/specs/chunk-shell-term-approval.md` is `status: draft`, so the config deny path, the rule
that auto-approves an all-allowlisted term, the term-carrying `Rule::Call`, the journal record naming
the arm and `web_fetch`'s non-routable refusal are all marked **blocked on** the card they wait for,
with the pre-state to confirm today instead. Driving a blocked section and filing the absence is the
one way that scenario's first round wastes itself.

## What a full round drives, and in what order

**A full round — the default when no scope is named — drives EVERY scenario in
`planning/qa/scenarios/`.** `.claude/skills/manual-qa` defers to this section for the order, and the
**directory listing is the authority on the set**: enumerate it fresh at the start of every round,
never from a count or a list written down anywhere, including here. A scenario added since the last
round is in scope the moment it exists.

**The tiers below are ORDERING AND BUDGETING, not a filter.** That is the correction round 13 forced:
this file used to describe the full round as a five-step subset with everything else "placed" into a
regression gate and rotating owned rounds needing separate invocations, and the predictable result
was that scenarios slipped round after round while the document read as though they were covered.
Round 13 drove everything in one context at the user's explicit instruction and reached
`rails-blog`'s compaction act for the first time in the bench's history — which settled the question.
**Nothing is deferred by convention any more. Dropping a scenario is a decision to name in the
findings, with its reason.**

**The spine, and it goes first**, because everything else reads better once the loop is known good:
`session-and-window` → `rust-cli` → **a SUBJECT with `cockpit-surfaces` piggybacked** →
`bench-arms` → `failure-injection`.

**Then the scenarios that bring up their own subject**, each with its own bring-up and its own tree —
`secret-boundary`, `changeset-review`, `subagents-and-backends`, `memory-and-dogfood`,
`rails-blog` — and **that reasoning is still sound and is why they are sequenced last rather than
interleaved**: each half-builds a precondition the others would trip over, and interleaving them is
how a round ends with three fixtures and no result. Sequencing them is the answer; deferring them to
a round that never comes is not. `rails-blog` is the most expensive and needs a real precondition
handled deliberately rather than improvised: **`rails` may be absent from the box**, and installing
it collides with the `GEM_HOME` question — round 13 installed Rails 8.1.3.1 into the sandbox and the
close-out negatives held, so that recipe is known to work.

**And the cheap deterministic set can go anywhere**, which is what makes it useful as a standalone
regression gate after a chunk: `failure-injection`, `session-and-window`, `repl-commands`,
`epic-tier`, `survey`, `prompt-slots-and-roles`, `shell-term-approval`. Running one of these early
costs almost nothing and catches a broken bench before a subject session is spent on it.

**`rust-cli` is NOT one of the subjects.** It is the smoke test; the subjects
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

**`rails-blog` gets its own bring-up and its own subject tree, inside the one round** — not its own
invocation. Rounds 4, 5 and 6 each ended without it, always for the same reason: one context carried
every scenario and was spent by the time the expensive one came up, and the fix this file reached for
then was to schedule it separately. **That fix failed for three more rounds**, because a separate
invocation is one nobody starts. Round 13 drove it in the same context as the spine and reached its
compaction act. So: **reordering is not the fix and neither is deferral** — what is left is budget.
Start `rails-blog`'s bring-up early enough that it is not what the round runs out of time on, and if
the budget really will not stretch, say which scenario is being dropped and why **before** the round
ends rather than reconstructing it afterwards.

So: dropping ANY scenario from a round is a decision to name in the findings, `bowling-ruby` and
`rails-blog` included. A scenario skipped by convention stops being a gap anyone can see; one named
in the findings stays visible as an outstanding debt instead.

**A suggested regression gate after a chunk lands** — this is a *scoped* invocation, named by the
user, and never what a round with no scope named runs: `failure-injection` + `session-and-window`,
and since 2026-08-23 also `repl-commands` + `epic-tier`, since 2026-08-25 `survey`, and since
2026-08-27 `prompt-slots-and-roles` + `shell-term-approval`.
All are cheap, deterministic, and cover the paths most chunks touch. As of 2026-08-18 the first pair
also covers **most of a chunk that was mostly not about the cockpit at all** — the price table and
its lint, `--compact-strategy` resolution, both tool-bound shapes, the `edit_file` refusal
vocabulary, the summarizer's ceilings, the per-ask iteration ceiling and the `lain up`
crash-on-start case. That is deliberate: **a check that only runs in an expensive scenario mostly
does not run**, so anything deterministic belongs in the cheap set even when the feature it guards
is expensive. The two added in 2026-08-23 are there on exactly that rule: `repl-commands` is almost
entirely zero-model-turn refusal paths, and `epic-tier` is deterministic except for one policy.
`survey` is there on the same rule again, with a caveat that is the point of adding it: **cut its
§7 last, not first.** Every other section in it is deterministic and will keep; §7 is the one thing
in this whole directory that has been dropped by three consecutive rounds, and it is only ever
dropped because it is the section at the end that needs a model. `shell-term-approval` is there on
the rule twice over: most of it is `/ruby` against the loaded library, and the half of it that is
already shipped guards a subsystem with **zero** manual coverage before this.

**If the GATE is too long to run in a scoped invocation, cut `epic-tier` first** — say so in the
findings rather than letting it drop quietly, which is the failure mode this whole file keeps
re-learning. **That licence is the gate's alone.** It is not a licence to trim a full round, which
drives everything in the directory.

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

- [`../qa-findings-round14-2026-08-27.md`](../qa-findings-round14-2026-08-27.md) — round 14, the
  first round driven under the corrected skill contract (every scenario in the directory, no
  preplanned subset), and the round that **wrote the seventeenth scenario**
  (`shell-term-approval`) because the shell subsystem had none and the draft chunk's own card for it
  had never run. **F79 (HIGH)**: a session whose subagent asked a question can be neither forked nor
  resumed — F23's failure returning through the `message_replay` index space, reproduced on two
  sessions with a clean control. **F78 (MED-HIGH)**: a zero-usage `turn_usage` zeroes both the feed's
  `occupancy` and `last_turn_usage`, which is compaction's own input. **F73 reproduces unfixed.**
  Eleven of seventeen scenarios driven; the six that were not are named in the findings.
- [`../qa-findings-round13-2026-08-25.md`](../qa-findings-round13-2026-08-25.md) — round 13, the
  full round **plus every other scenario in one context at the user's explicit instruction**, which
  overrode the owned-round convention and finally put `rails-blog` in a driver's hands. **That
  convention has since been retired** — the round default above is now every scenario in the
  directory, and round 13 is why.
  **`rails-blog` §0/§1 reached COMPACTION AT SCALE for the first time in this bench's history** — 5
  compactions of 38 decisions, each roughly halving the span, under exactly the composed strategy
  the flags asked for, with the round-2 rewrite F-series absent and no summarizer eviction. Rails
  8.1.3.1 was installed into the sandbox and **P9/P15 held** (`Gemfile.lock` byte-identical). Two
  new HIGH defects: **F73** (a second concurrent cockpit deadlocks its nvim on an E325 swap modal,
  killing the approval surface) and **F74** (`stalled_stream` kills healthy turns; the server was
  exonerated four ways and the code itself flags the landing site as unwanted). F29's `/inbox`-drain
  fix, F16, F17, the round-2 F-series and the UTF-8 prime crash all verified fixed.
  **Four scenarios were not driven at all** (`repl-commands`, `survey`, and the owned
  `changeset-review` / `subagents-and-backends` / `memory-and-dogfood` / `secret-boundary`) — named
  in the findings rather than left to look like coverage.
- [`../specs/chunk-qa-round11-survey-surfaces.md`](../specs/chunk-qa-round11-survey-surfaces.md)
  — the chunk that discharges round 11, following the round-7 precedent below: fourteen cards,
  F64–F70 plus the corpus ceiling, verified by round 12
- [`../specs/chunk-qa-round7-constructed-and-consistent.md`](../specs/chunk-qa-round7-constructed-and-consistent.md)
  — the chunk that discharges both round-7 documents
- [`../qa-findings-research-2026-08.md`](../qa-findings-research-2026-08.md) — the research pass

## Coverage notes

Per-section coverage a scenario file cannot state about itself, because it is about which round
first exercised the section rather than what the section asks for:

- **The scenarios that were once "owed" and are no longer.** `secret-boundary` slipped round 9,
  carried, and round 10 drove §3/§4/§5 — the three-place split is **3 of 3 driven** rather than
  resting on specs, and §5 produced that round's HIGH finding. `rails-blog` was driven end to end
  for the first time by **round 13**, reaching the compaction act that was its whole reason for
  existing. `prompt-slots-and-roles` sat in no tier at all until round 13 — described here,
  scheduled nowhere — and its first drive found §1's instrument was not executable as written
  (`slot_fills` is a **bench** record; a plain `lain chat` writes zero). That is the argument for
  driving a new scenario promptly rather than letting it age unrun, and it is why the round default
  above is now every scenario rather than a subset.
- **`memory-and-dogfood` has never been driven end to end**, and neither has `shell-term-approval`,
  which was written 2026-08-27. Both are coverage on paper until a round says otherwise.

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
  **§2 was finally reached on 2026-08-27 (round 14), and WITHOUT Rails** — largest single tool result
  **120,045 bytes**, 25x round 8's, admitted rather than refused because it sits just under `bash`'s
  131,072 ceiling, which is the volume the section wanted. The way in was the section's own second
  clause: "a non-minimal app, **or a directive that reads large generated files back**". A generated
  tree satisfied the premise on a box with no Rails installed. The bounding half was confirmed
  separately — `grep` over ~2,400 matches returns `... capped at 200 matches`. **This does not
  discharge §1** (round 13 did), and it does not discharge §0/§3/§4/§5, which still want the install.
  The lesson generalised into `method.md`: **a scenario's stated subject is usually one way to satisfy
  its premise, not the only one.**
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
- **The shell subsystem — `shell-term-approval.md` written 2026-08-27, undriven.** Every string in
  it is a prediction, and roughly half its sections are written against an unlanded chunk and marked
  as such. The half that is shipped guards a subsystem that had **no** manual coverage at all before
  it, so a first drive is worth scheduling promptly rather than letting the document age — that is
  the lesson `prompt-slots-and-roles` taught the hard way.
- **Isolation backends — `subagents-and-backends.md` §3 written 2026-08-23, undriven.** It carries an
  open question to settle by driving: the `--isolation` flag's help text says it "is inert in chat
  today" because no chat path spawns an actor-mode subagent, but `CLI::Wiring` builds a real
  `Supervisor` with `fleet_isolation(...)` and `Subagent#adopt_actor` refuses only
  `unless supervisor.running?`. One of the two is wrong.
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
a full directory does not read as completeness:

- **Program identity on the term arm.** `shell-term-approval.md` covers arm *selection*; nothing
  covers *which binary ran*. `PATH` is inherited and uncontrolled, `execvp` honours its order, and
  `cat /tmp/evil/cat f` is a measured `allow` with the written word as argv0. No surface records the
  resolved path, so no scenario can ask the question — the chunk's Open decisions carry the
  four-rung ladder that would make it askable, and rung 1 (resolve and journal the absolute path) is
  the cheap one.

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
