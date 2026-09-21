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
| [`session-and-window.md`](scenarios/session-and-window.md) | Is the bench **honest before a model is asked** — served window, `provenance`, occupancy, the launch-level refusals, the `options` asymmetry, **which prices it will quote, which collapse strategy it resolved, and which context pipeline renders every request — read back off the session header** (§9, `--context-pipeline`)? Mostly needs no model call. | cheap |
| [`rust-cli.md`](scenarios/rust-cli.md) | Does the loop work **end to end**, on a non-Ruby toolchain, with a real compile-error unhappy path? The smoke test. | cheap |
| [`cockpit-surfaces.md`](scenarios/cockpit-surfaces.md) | Do the nvim/tmux surfaces tell the truth — review flow, **notes on a survey of a dummy app the round writes itself**, buffer staleness, the approval and question surfaces — nvim-first in a cockpit since 2026-09-14, with the chat pane announcing and a guarded inline prompt only in `--no-nvim` — the live timeline, how a refusal is *delivered*? **Four of round 4's seven defects were here, and every fix landed somewhere other than where the symptom was.** | cheap, piggybacks |
| [`failure-injection.md`](scenarios/failure-injection.md) | Is the record **unforgeable**, does every failure path refuse by name, and do the **tool bounds, the windowed-read contract and the summarizer's ceilings** hold? The deterministic half needs no model at all. The standalone regression gate. | minutes |
| [`bowling-ruby.md`](scenarios/bowling-ruby.md) | Does the **authoring loop** produce something worth having — plan, execute, critique, graded against driver-owned oracles? | 1–3 sessions |
| [`bench-arms.md`](scenarios/bench-arms.md) | Does the arm driver produce numbers that are not artifacts, **say what produced them, and refuse a price it cannot stand behind**? | ~5 min |
| [`rails-blog.md`](scenarios/rails-blog.md) | **Context economics at scale** — the composed compaction strategy firing for real, unbounded tool output, the gate under volume, and what a broken cache cost in dollars. The only scenario that reaches any of these. | expensive |

**The six added 2026-08-23**, each covering a tier the core seven never reach. All are driveable
against the **local** bench — ollama, `git`, `docker`, the filesystem — and none needs a remote
provider or a forge:

| Scenario | The question it answers | Cost |
|---|---|---|
| [`repl-commands.md`](scenarios/repl-commands.md) | Does the **command surface** do what `/help` says — `/help`, `/pin`, `/unpin`, `/keep`, `/btw`, `/rewind`, `/fork`, `/goal`, `/meta`, `/review-submit`, `/introspect` and the eleven others? Twelve of the twenty-three are driven by nothing else. Every refusal path is a **zero-model-turn** path. **RE-DERIVE the count from the registry** — the literal roster at `spec/lain/cli/command/surface_spec.rb` — never from this row: it read "twenty" from the day `/introspect` shipped (2026-08-26) until 2026-08-28, and "twenty-one" until round 17 counted 23 in `/help`. | cheap |
| [`epic-tier.md`](scenarios/epic-tier.md) | Does a four-stage pipeline stay honest when only a journal remembers where it is — the stage-boundary ruling, all four gate policies, the drain-is-journaling fold, and the fail-**closed** abort on a damaged record? ~4,100 lines with no prior coverage at all. | cheap |
| [`secret-boundary.md`](scenarios/secret-boundary.md) | Does the **three-place split** hold — gate on the effect, filter on the result, mask on the content — with a real model pulling on it, and is a denial actually unliftable (including under `/mode auto`, the approve-all posture)? `--secret-oracle` is a local model by construction. | cheap |
| [`changeset-review.md`](scenarios/changeset-review.md) | Does a review of a **real diff** tell the truth? `cockpit-surfaces` drives the review rails over `/survey`, which has no old side, no base ref and no commits — everything that makes a changeset a changeset is untouched by it. Local branches only; no forge. | cheap |
| [`subagents-and-backends.md`](scenarios/subagents-and-backends.md) | When the loop stops being one process, does anything still tell the truth — a one-shot's lease under `--isolation worktree`'s real-`git` seams, `--exec docker`, `lain watch`, `--windows`? `actor` mode has no chat path (round 17), so its checks are recorded as unreachable from chat rather than driven. | minutes |
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
| [`survey.md`](scenarios/survey.md) | Does `/survey` refuse honestly at a **size no round has driven** (lain's own `lib/` is ~780 files / ~164,000 lines as of round 17, against ceilings of 300 / 30,000 -- re-count it, the figure drifts every round), does the **walk** admit and withhold the right paths — gated is *listed and masked*, only denied is withheld — and is the **docent thread reachable at all**? Runs entirely on the **local** arm. | cheap |

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

**Added 2026-08-26 and 2026-08-27 — the shell subsystem, in the two scenarios that divide it.**
`lib/lain/shell/` is ~1,300 lines deciding, per gated call, whether a command runs as reconstructed
argv with no shell anywhere or as a string handed to `sh -c`, and it had **zero** manual-QA
coverage: no scenario mentioned `Shell::Verdict`, `Parse`, `Pipeline`, the term arm or arm
selection, and the five scenarios that touch `bash` all use it as a vehicle for something else. It
was not in Known gaps either, **so the gap was invisible** — which is why this file now declares it
once, here, rather than twice in adjacent sections as it did until 2026-08-28.

| Scenario | The question it answers | Cost |
|---|---|---|
| [`shell-terms.md`](scenarios/shell-terms.md) | Does the **deterministic half of the shell subsystem** decide the way it says it does — which commands earn the no-shell **term arm**, which a project's `[shell] exclude` table refuses **by name** (a deny path that had never been driven), which are approved by `Approval::ComposedTerm` with **nobody asked**, and — the half that matters more — which still reach a human? Plus the `web_fetch` egress floor, the `shell_arm` record in **both** attended and `/mode auto`, and the one instrument nothing else here has: a paid measurement of the arm *distribution* over a real session. | cheap (one step paid) |
| [`shell-term-approval.md`](scenarios/shell-term-approval.md) | Does the **parse boundary** refuse what it claims to (the 4096-byte cap reporting *both* broken and not-covered, the newline that has no separator node and is caught by arithmetic instead), do the **verdict arms** land where they say — `git` abstaining deliberately, `deny` existing and being **unreachable in production** — and **can a driver tell from the outside which arm ran**? Plus the `Triage` rung's own reasoning over a resolved term, `STDIN_SAFE`, and the recursive-read hazard a term-shaped rule cannot see. Runs entirely on the **local** arm. | cheap |

**They DIVIDE the subsystem; neither is retired.** Ruled 2026-08-28 under the standing rule that one
subsystem does not get two scenarios silently. The two were written a day apart, independently, on
branches that only met at the merge `9ead317c`, and they did overlap heavily. **Each now carries a
"What it deliberately does NOT own" section naming what the other owns**, so the division is stated
in both files rather than inferred from this one: `shell-terms` owns the wide command-by-command
sweep (§1/§4), the both-postures `shell_arm` check (§6) and the metered arm-distribution
measurement (§9); `shell-term-approval` owns the mechanism underneath it — the parse boundary (§1),
the `Triage` rung's rung-by-rung table (§4a/§4b), `STDIN_SAFE` (§3a), the recursive-read hazard (§5)
and whether `deny` is reachable in production at all. **Where they land on the same ground — the
config-deny table, the approval rule's "no prompt" case, the docker pipeline, the `web_fetch`
refusal strings — drive it once, at `shell-term-approval.md`, and skip the duplicate.** Each file
says so at the point it happens. Driving both in full is no longer duplicated work; driving both
without reading those two sections still is.

**Both are in the REGRESSION GATE**, on the standing rule below: anything deterministic belongs in
the cheap set even when the feature it guards is not. `shell-terms` §0–§4 and §8 are zero-model
`/ruby` reads, §5–§7 spend local completions, and **§9 alone is metered** — cut §9 first, §7 second
(it needs a docker daemon), and **do not cut §5**, which holds every negative control. In
`shell-term-approval`, §1, §2, §4a, §6 and §10 are zero-model; the rest is under fifteen local
completions. `shell-terms` §0 names the **three postures** (attended ladder, `/mode auto`'s
`ApproveAll`, the one-rung unattended deny-all) because they decide differently and a driver who
conflates them files a false finding.

**`shell-term-approval`'s `blocked on` markers are spent.**
`planning/specs/chunk-shell-term-approval.md` is `status: done`, and every section in the scenario
now reads DRIVABLE NOW — the config deny path, the auto-approving rule, the term-carrying
`Rule::Call`, the arm record and `web_fetch`'s non-routable refusal all shipped. Read a surviving
`blocked on` sentence as history, never as licence to file the absence. (Its preamble, which called
that chunk `draft` and unlanded, was corrected on 2026-09-14.)

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
regression gate after a chunk. **This is the one authority on that set** — the gate paragraph below
argues for it and deliberately does not re-list it, because until 2026-08-28 there were two
enumerations here and they disagreed: this one omitted `shell-terms` while the gate's named it, and
a scenario placed in one list and not the other reads as unplaced from whichever one you happen to
read. The set, with the date each joined:

`failure-injection` and `session-and-window` from the start; `repl-commands` and `epic-tier` since
2026-08-23; `survey` since 2026-08-25; `shell-terms` since 2026-08-26; `prompt-slots-and-roles` and
`shell-term-approval` since 2026-08-27.

Running one of these early costs almost nothing and catches a broken bench before a subject session
is spent on it.

**`ollama-cloud-arm` has a placement too, in two halves.** It sat in no tier at all until
2026-08-28 — described in the table above, scheduled nowhere, which is the same "somebody added it
and nobody scheduled it" case `prompt-slots-and-roles` already taught this file once. **Its steps
1–4 cost nothing** (the missing-key refusal, the plaintext-key refusal, admission and window
resolution, all before a byte is spent) and run with the cheap set; **the rest needs the remote
metered provider** and is budgeted at the expensive end of the round beside `rails-blog`. It is not
on the dated gate roster above — the gate is a scoped invocation over deterministic scenarios and
this one's second half is neither — but a full round drives both halves or names the drop.

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
user, and never what a round with no scope named runs. **Its membership is the cheap deterministic
set enumerated above and nowhere else** — one list, so the two cannot drift apart again. All of it
is cheap, deterministic, and covers the paths most chunks touch. As of 2026-08-18 the first pair
also covers **most of a chunk that was mostly not about the cockpit at all** — the price table and
its lint, `--compact-strategy` resolution (and, since 2026-09-14, `--context-pipeline` resolution and
its header field), both tool-bound shapes, the `edit_file` refusal
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

- [`../qa-findings-round19-2026-09-21.md`](../qa-findings-round19-2026-09-21.md) — round 19, a full
  round over all eighteen scenarios in ten contexts (the spine plus nine parallel forks with their
  own sandboxes). **Every scenario driven; none dropped.**
  - **The headline, found independently by four contexts: the ollama arm puts no generation cap on
    the wire.** `max_tokens` is journaled and never sent, `num_predict` is absent from all of `lib/`
    — one task decoded 85,150 tokens against a declared 4,096 and outlived its own client by ~13
    minutes. With `n_slots = 1` it starves the box, and the stall clock cannot catch it because it
    arms on silence.
  - **Three more HIGH:** an in-root **symlink** under an ordinary name is auto-approved by
    `ComposedTerm` (F131 one route on); `lain chat --root PATH` is ignored, so `.lain/slots/` never
    loads; and a detected `malformed_response` is a **silent write-off delivered as a successful
    result** — the record has zero consumers in `lib/`.
  - **Two long-owed sections reached:** `survey` §7, dropped by three consecutive rounds, and
    `rails-blog` §1b, whose over-window handoff was driven end to end for apparently the first time
    — **F173 is fixed**.
  - **`bench arms` cannot report:** one task hitting the iteration ceiling aborts the whole run,
    discarding 13 completed grades (Fp-3), so the grade table and cost column are undriven.
  - **Process:** method.md's cockpit-nvim kill was box-wide and **killed six sandboxes' cockpits
    mid-round**; `answer.sh` treated every non-`deny` argument as approve and released a refused
    private key; the "names only" key recipe printed the key. All three are fixed in this commit.

- [`../qa-findings-round18-2026-09-15.md`](../qa-findings-round18-2026-09-15.md) — round 18, the
  discharge chunk's integration check 9: a full round over all eighteen scenarios, nine of them in
  parallel fork contexts with their own sandboxes.
  - **The round-17 discharge mostly holds.** F88–F93 are fixed on the paths round 17 drove, and so
    are most MED-HIGH/MEDIUM items.
  - **Most of what is new is the same class arriving one route past each fix.** A key file under an
    ordinary name is still auto-approved by content (F131). Consolidate now finds lineages and stores
    nothing (F134). Every non-chat command still drops `num_batch` (F154). A *failed* child never
    leaves the fleet (F137).
  - **New HIGHs:** `/fork`/`/btw` start the child on Anthropic (F132); a note journals a masked secret
    (F133); a crash mid-spawn strands the session (F135).
  - **`rails-blog` §1 reached composed compaction and then wedged:** the `keep_last` tail alone filled
    the window (F173). A session can also be pinned at a guessed window for good (F136).
  - **Process:** four contexts re-derived the isolation grep wrong, so it is now `$QA/isolation.sh`
    (P40); the driver's own `bench arms` thrashed the shared runner for 65 minutes (P41).
- [`../qa-findings-round17-2026-09-14.md`](../qa-findings-round17-2026-09-14.md) — round 17, a full
  round over all eighteen, four scenarios of it driven in parallel fork contexts with their own
  sandboxes. **Six HIGH:** any non-ASCII byte in `bash` output tears the ask (F88) and the dangling
  call it leaves stalls composed compaction for good (F89); ollama's silent prompt truncation reads
  as LOW occupancy (F90); `ComposedTerm` releases unnamed credential files with nobody asked (F91);
  `shell_arm`/`isolation_lease` never reach the journal (F92); a torn `gate_decision` opens an epic
  stage (F93). **F84 fixed.** `shell-terms` got its **first drive**. The desktop notifier these
  documents gated on was deleted in `c40ab419` (P36); `SKILL.md` and `qa-sandbox.sh` were corrected
  in the round, and the scenario passages on 2026-09-14. Discharged by
  [`../specs/chunk-qa-round17-the-record-the-human-the-window.md`](../specs/chunk-qa-round17-the-record-the-human-the-window.md),
  whose integration check 9 is the next full round over the corrected scenario set.

- [`../qa-findings-round15-2026-08-27.md`](../qa-findings-round15-2026-08-27.md) — round 15, the
  round that drove **seventeen scenarios and reported "all 17 … none dropped" against a directory
  that held eighteen** — `shell-terms.md` had landed through the merge the previous day and the
  round counted a list instead of enumerating the directory, which is the failure the standing rule
  above exists to prevent and the reason it is restated here. **F79 is FIXED** (a session whose
  subagent parked a question forks and resumes, both doors exit 0, 0 unresolved causal refs) — but
  the relay that fixes it introduced **F81 (MED-HIGH)**: a relayed child question is journalled
  **twice**, so every answered subagent question leaves a permanently stale `lain://inbox` row and an
  `inbox_count` that never returns to 0. **F81 is round 11's F64 generalised** — the disagreement is
  not docent-specific and does not need a stall. **F82 (MEDIUM)**: one oversized tool result pins
  occupancy at 100% with `head_bytes: 2`, so `approaching_window` fires with nothing to compact and
  nothing tells the human — filed only after the decision path was cleared four ways. **F80 is
  fixed on both halves** (help text corrected, and a spawned child was observed running in a real
  leased worktree). First drives for **`shell-term-approval`** and **`memory-and-dogfood`**, and
  **`survey` §7 — the docent thread, owed since round 7 and dropped by rounds 8, 9 and 10 — passes.**
  Three findings **withdrawn on the mechanism**, and nine scenario corrections filed.
- [`../qa-findings-round14-2026-08-27.md`](../qa-findings-round14-2026-08-27.md) — round 14, the
  first round driven under the corrected skill contract (every scenario in the directory, no
  preplanned subset), and the round that **wrote `shell-term-approval`** because the shell subsystem
  had none and the draft chunk's own card for it had never run. It was the seventeenth scenario **on
  its own branch and the eighteenth once merged**: `shell-terms.md` had already landed on `main` the
  previous evening (`4357a2d9`), and the two lineages only met at `9ead317c` — which is where round
  15's miscount came from. **F79 (HIGH)**: a session whose subagent asked a question can be neither forked nor
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
- **`memory-and-dogfood` and `shell-term-approval` are no longer coverage on paper — round 15 drove
  both for the first time.** `shell-term-approval` reproduced every measured value in §0–§3a,
  including the newline row (`separators=0`, the arithmetic that stops `echo hi | rm -rf /tmp/x`) and
  `PROGRAM_RUNNERS` at exactly 92, and it corrected its own §0/§8 claim that the arm is unobservable.
  `memory-and-dogfood` reached the manifest, all three passes and `bench sweep`'s offline five-arm
  recall@k. **Every scenario in this directory has now been driven at least once EXCEPT
  `shell-terms`** — round 15 wrote "every scenario" against a seventeen-item list while the
  directory held eighteen, and that sentence is corrected here rather than deleted, because the
  overcount is the interesting part: a coverage claim taken from a list is how a scenario becomes
  invisible.

- **`survey` §7's four-round debt is DISCHARGED (round 15).** The docent thread pane was owed since
  round 7 and dropped by rounds 8, 9 and 10; it now passes end to end — the answer renders in the
  thread pane while RPC gestures still land in 0s, the duplicate `:w` refuses in words, and both
  `docent_asked` and `docent_answered` are journalled. The standing instruction to **cut §7 last,
  not first** is what finally got it driven; keep it.

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

- **`shell-terms.md` was first driven in round 17 (2026-09-14)** — every section but the metered §9,
  which has no Anthropic key on this box and was void anyway until F92 journalled `shell_arm`
  (fixed 2026-09-14; a local session's journal now carries one per `bash` call). The
  hand-maintained tables held on all sixteen listed rows; the WIDER sweep is what found F91
  (credential files outside the `Sensitivity` table approved with nobody asked) and T3 (no
  240.0.0.0/4 row in `web_fetch`). **Every scenario in the directory has now been driven at least
  once.** The history below is kept because the miscount it records is the lesson.
- **`shell-terms.md` had been driven ZERO times through round 16, and was the only
  scenario in the directory of which that was true.** Round 15's own coverage table names seventeen
  scenarios and this is the one absent from it; the round reported "none dropped" because it counted
  its list rather than the directory. **It is in the regression gate and in a full round both**, so
  the next round of either kind drives it, and a first drive is worth taking early. Written
  2026-08-26 from the code — every
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
  against a measured `v:echospace` of 88 it exercised the width rail too. **The other leg is no
  longer owed, and this entry is kept only so the discharge is on the record.** It said the thread
  pane's `BufWriteCmd` raises, that the traceback-and-modal shape survives there, and that reaching
  it needs `cockpit-surfaces.md` §4b's thread pane which no round had driven. All three have moved:
  the thread pane was taken off `cockpit-surfaces` §4b into `survey.md` §7; round 11 drove it (F31
  fixed at the site) and round 15 drove it again end to end, with the duplicate `:w` refusing in
  words; and round 14 measured the refusal at **123ms, 0 tracebacks, no modal**, `nvim_get_mode()`
  answering. `51_thread.lua`'s callback now says in its own comment that it answers rather than
  raises. What no round's record shows is `:LainReviewDone` typed *from a thread buffer* — a
  narrower question than this entry ever asked, and not a gap in the same sense.
- **The plain, non-cockpit path — narrowed by round 9, and now DIFFERENT by design.** Almost every
  scenario runs under `lain up --nvim`. Since 2026-09-14 the two paths answer questions and approvals
  differently on purpose: a cockpit's chat pane announces a parked call in one line and reads only
  commands (`command>`), while `--no-nvim` keeps its inline `[y/N]` and `human>` reads behind three
  guards (typeahead held or discarded, a decided prompt closed in words, an answered question
  retired). `cockpit-surfaces.md` §5 drives both, and a pass on one is not a pass on the other. The
  rest of the plain path — `/inbox`'s drain there, the HUD — is still driven only incidentally.
- **`--resume` — partly driven.** Round 9 resumed a spawned session (exit 0) and drove three damaged
  journals through it (refuses by name, exit 1, no backtrace). Still undriven is `repl-commands.md`
  §4's loop `/btw` → `/keep` → `lain sessions` → `--resume`, which asks a question whose answer
  depends on the carried-over turns — the half that tests continuity rather than refusal.
- **The shell subsystem — covered, except for one metered measurement.** `shell-term-approval.md`
  was first driven in round 15 and `shell-terms.md` in round 17, so neither is coverage on paper any
  more. What is still owed is `shell-terms.md` §9, the paid arm-distribution measurement off a real
  session's journal — skipped by round 17 for want of an Anthropic key, and void until 2026-09-14
  anyway, because the `shell_arm` record never reached the session file (F92). The hand-maintained
  tables (`ComposedTerm`'s allowlist and flags, the `Sensitivity` credential rows widened on
  2026-09-14, `web_fetch`'s blocked ranges) remain the likeliest things to be wrong first.
- **Isolation backends — the one-shot lease is driven; actor mode is unreachable from a chat.**
  The open question this entry used to carry ("inert in chat" help text against a real `Supervisor`)
  is settled in `subagents-and-backends.md` §3: a model-dispatched one-shot leases through the one
  resolved backend, and round 17 watched a lease appear in `git worktree list` and disappear. What
  round 17 established besides is that the chat's `subagent` tool is **one-shot only** — actor mode
  is wired for the epic orchestrator alone — so §3's actor, nested-spawn-at-a-third-path and
  depth-cap checks have no chat path to reach them.
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
- **Compaction at scale — reached twice, and the sticky cut never.** Rounds 8 and 13 reached
  `rails-blog.md` §1 under the composed `elide-tools+summarize-conversation` strategy (see the
  coverage notes above). Round 17 could not: F88's torn `bash` result left an unanswered call and
  F89 refused every derivation after it. Both are fixed as of 2026-09-14, and the same chunk changed
  what §1 has to measure — a committed cut now holds, a clearing signal must not un-compact, and an
  over-window prompt is refused by the provider rather than silently truncated (`rails-blog.md`
  §1b). None of that has been driven at volume; until a round does, it rests on specs and on the
  discharging chunk's integration check 7.
- **A tripped tool bound leaves no journal record.** The bounds are checkable, but only through the
  `tool_result` text — so nothing here can answer "did a bound fire during ordinary use", which is
  the question that would say whether a ceiling is set too low.
- **Subagent structure — CLOSED 2026-09-20, and the entry is kept so the discharge is on the
  record.** It said no scenario could cover the causal fan because no surface rendered it:
  `Buffers::TimelineView` walked only `render_parent`, no frontend file referenced `child_turn`
  or a `:spawn`, and the fleet was published as a set of digests every reader collapsed to
  `.size` — an integer count, with no parent/child edge reaching any display. Round 5 journaled
  29 `child_turn` and 10 `message` records in one `fleet 2` session and none of it showed
  anywhere outside the journal. The 2026-08-23 narrowing (`lain watch` is a surface over *one*
  lineage, driven by `subagents-and-backends.md` §5) left the **fan** owed.
  **The fan now has two surfaces.** `lain://status` draws the fleet as a nested tree, one row
  per child under the parent it was spawned from, and the input pane's header carries the top of
  the same tree. The parent edge is real causal structure rather than a flattened list: a
  grandchild is placed against the head its parent reported, since a `:spawn` names the head it
  came from and not the spawn that owns it. `cockpit-surfaces.md` §1 drives the tree — including
  the grandchild nesting, which is the check that the edge resolves — and §0 drives the header.
  **What stays true, and is a ruling rather than a gap:** none of it was added to the `:spawn`
  body. A spawn digest is an address a bench arm joins on and `lain watch` follows, so the
  fleet's own facts ride in `child_progress` records beside it and the spawn stays
  byte-identical. Two costs of that are written into the fold and are not findings: identical
  twins share one spawn digest and therefore one row, and a row's parent is resolved once, when
  it launches.

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
