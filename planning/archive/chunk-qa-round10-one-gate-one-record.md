# One gate, one record: a dead safety seam, a flag that outlived its reason, and four refusals that lie

status: done (2026-08-24)
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson

## Intent

Discharge the code findings of QA round 10 (`planning/qa-findings-round10-2026-08-23.md`, F58–F66),
**delete `--yolo` entirely**, and absorb the unlanded remainder of the round-9 chunk so one plan owns
the tree.

**The headline is that lain's protected-path argv check already exists and has never run.**
`Escalation::Triage#literal`/`#refused` (`escalation.rb:555-573`) classify every word of a parsed
`bash` argv and deny with `PROTECTED = "the command's argv names a path no approval may lift"`. It is
dead because `Switchboard#build_ladder` (`switchboard.rb:249`) calls `Escalation.for` without a
`triage:`, so `Triage#initialize` falls back to `AnyPath`, which answers `:ordinary` for every path
(`escalation.rb:489-496`). That is F63: `cat ~/.ssh/id_rsa` reaches the human as an *ordinary*
approval, and under an approve-all policy it simply runs. The fix is wiring, not invention.

**`--yolo` goes.** It is read in exactly one place (`switchboard.rb:98`) and does two things —
skip the `Approval::Queue` and start the session in posture `:auto`. Both are reachable through
`/mode auto`, which the modes chunk already established as the real mechanism
(`planning/specs/chunk-modes-approval-undo.md:1715`). Deleting it also kills two now-unreachable
branches (`refuse_queueless`, `NO_QUEUE`) whose error text names the flag.

The rest are refusals that mislead: a record that cannot say why a run stopped (F59), a retry line
with no line ending (F58), a `read_file` that kills the ask instead of refusing a file (F62), and
four CLI messages that name the wrong command, the wrong noun, or an empty store that is not empty
(F60, F61, F64, F65, F66).

**This chunk should not be read as sealing F63 against a human who has typed `/mode auto`.** Wiring
the triage rung denies a protected argv at the *default* posture, which is F63 as filed. A Triage
deny is an ordinary ladder deny, and an approve-all policy bypasses the ladder entirely — so the
`/mode auto` route to `Gate::ApproveAll` stays open by decision, not by oversight. T23 records it as
a known-open observable so round 11 does not re-file it as new. The Open decisions section carries
the reasoning and the cost.

Discharges ROADMAP item 36.

## Grounding

Explored 2026-08-23 against the working tree at `ffd27c06`, by four parallel readers. Verified,
with the places code and documents disagree:

- **F63 is an unwired seam, not a missing feature.** `Triage`'s deny arms are implemented and
  spec'd (`spec/lain/approval/escalation_spec.rb:653-842`, twenty examples), and
  `escalation_spec.rb:834-841` explicitly pins that *the default protects nothing*. The class
  comment says so outright: "Inert until wired" (`escalation.rb:425-426`). A reference
  implementation of the exact factory the wiring needs already exists in the spec support at
  `escalation_spec.rb:157-183`, resolving cwd via `WorkerEnv#resolve` the same way
  `Tools::Bash` does (`bash.rb:176`).
- **The finding document's F62 diagnosis was WRONG and is corrected here.** It attributed the
  crash to the secret boundary. The raise is `Canonical.normalize` at `canonical.rb:120`, inside
  `Event::Payload#initialize` (`event/payload.rb:24`) on `Timeline#commit` — **after**
  `RedactSecretReads` has passed the result through cleanly. `Scan#readable?`
  (`redact_secret_reads.rb:436`) is structurally incapable of answering false for a String
  (`:418-421` wraps a String in a one-element array of truthy `Piece`s); it answers false only for
  an Array carrying an unscannable block. So the secret boundary is a **witness, not a
  participant**, and the same read dies with the middleware unwired. `bash.rb:114` and
  `grep.rb:247` carry the identical latent defect, unreported.
- **Two specs pin the contract F62 must change.** `spec/lain/tools/read_file_spec.rb:1023-1027`
  asserts invalid UTF-8 survives the capped read intact, and
  `spec/support/shared_examples/tier_one_read_contract.rb:107` asserts `is_error` is **false** for
  a binary file. Both must flip; that they must is the signal the contract was wrong, not the code.
- **`--yolo` is one flag, one read, two effects.** Declared `exe/lain:871-872` on `chat` only;
  read at `switchboard.rb:98`; `:145` decides the queue, `:148` the starting posture. Every other
  `lib/` hit is a comment. `lain up . -- --yolo` forwards to `chat` (`cli/up.rb:758`) and will
  start failing at Thor.
- **Do NOT delete the nil-queue family.** `Env::YoloApprovals` (`cli/command/env.rb:35-45`),
  `RedactSecretReads::Unqueued` (`redact_secret_reads.rb:94-129`) and the fourteen nil-queue guards
  are all reached by `--non-interactive` too (`switchboard.rb:145` gates on `@attended && !yolo`).
  They need renaming, not removal.
- **`--yolo`, the `auto_approve` mode LAYER, and the `:auto` POSTURE are three different things.**
  Only the flag dies. The layer (`mode/layer.rb:84`) is the mode-vocabulary name of the
  `--auto-approve` FLAG's concept; the posture (`mode/posture.rb:161-162`) is what `--yolo` was
  already collapsed into.
- **`--isolation` is not inert.** `wiring.rb:308` resolves it on every chat (an unknown name
  refuses at startup), `wiring.rb:270` injects it into a live `Supervisor`, and
  `subagent.rb:215` guards only on `supervisor.running?`. Round 10 confirmed the launch refusal by
  driving it. The help text at `exe/lain:907-910` is the stale half, and it is the ONLY stale
  help string in the file (78 `desc:` strings grepped).
- **`RunInterrupted` has two call paths, not one.** `Conductor#close` (`conductor.rb:172`)
  **already holds the reason and discards it**; `Repl::Ask#refuse` (`repl/ask.rb:76-87`) is the
  catch-all where a stalled stream and a `Canonical::UnsupportedType` both land indistinguishably.
- **There are exactly two decorators**, and the taxonomy the fix needs is real: `ProviderRetry`
  promises "one attributed line" (`provider_retry.rb:22-24`); `ToolOutput` returns raw streamed
  bytes despite a docstring that says otherwise (`decorators.rb:52-59`). `Sink::IOAdapter#write`
  (`sink.rb:44-51`) confirms a chunk may legitimately carry no newline.
- **`Improvements` already holds the allowlist it does not use** —
  `KIND_ORDER = Improvement::KINDS` at `cli/improvements.rb:16`. `--project` is unvalidated the
  same way, and `Paths#project_hash` never raises, so a typo'd path yields a well-formed hash
  matching nothing. `Improvements` defines no error class; the convention is `< Lain::Error`
  plus `LainCLI::Boundary#render` (`exe/lain:49-53`).
- **Four distinct advice strings are needed for F60**, not one: `epic status`, `epic submit`,
  `epic land`, and `chat --epic` (`epic_mount.rb:144`). `epic queue`/`approve`/`deny` do **not**
  reach `chosen` and must not be touched.
- **Round 9's chunk is `status: in-progress`** with T1/T4/T10/T11/T12/T13 landed and
  T2/T3/T5/T6/T7/T8/T9 owed. Absorbed here as **T17 (=r9 T3), T18 (=r9 T5), T19 (=r9 T7),
  T20 (=r9 T8), T21 (=r9 T9), T24 (=r9 T6)** — six cards, because **r9 T2 is already written**:
  `git diff lib/lain/exec/docker.rb` shows `RUN = [CLI, "run", "--rm", "--quiet"].freeze` with its
  measured justification comment and 11 spec lines, and r9 T1 is committed (`c43d088c`). That work
  is verified and committed by the orchestrator before wave 1 rather than re-implemented.
  **r9 T6 must not be dropped:** r9 T4 landed the `collapse_strategy` member (`ff53028e`) and T18
  lands the wiring, so without T24 the field ships and no compaction record ever carries it —
  F51 would stay half-discharged behind a green suite.
- **The deletion sweep has TWO traps, both measured 2026-08-23, and the first is the dangerous one.**
  (a) In an agent shell `grep` is a **shell function**, not the binary — it is gitignore-aware, and
  `grep -rl yolo .` returns **0** worktree hits, so a sweep looks complete when it is not.
  `command grep -rl yolo .` returns **703**. Use `command grep` for every verification in this
  chunk, exactly as `method.md` already requires elsewhere. (b) `.claude/worktrees/` holds **eight
  sibling worktrees** of this repo (gitignored at `.gitignore:39`) and `.git/worktrees/*/index` are
  binary git files that also match. `--exclude-dir=.claude` alone is **insufficient** — it leaves 8
  hits. The correct exclusion is `--exclude-dir=.claude --exclude-dir=.git`, which reduces the tree
  to the real work list of **186 files**. A naive `sed -i` from the root will edit eight other
  checkouts.

### Divergence found at execution time (2026-08-23, orchestrator)

**Round 9's remainder is not owed — it is written and uncommitted.** Grounding recorded only r9 T2
as written. In fact `.claude/worktrees/t3,t5,t6,t7,t8,t9` each hold a complete implementation plus a
detailed `.handback-T*.md`, left uncommitted when round 9's orchestration stopped. None of their
files collide with what main changed between `07e0bef2` and `ffd27c06`, so each diff applies to
current main unchanged.

**T17, T18, T19, T20, T21 and T24 are therefore executed as HARVEST cards, not implement cards**
(user decision): rebase the existing worktree diff onto current main, run its specs, send it through
the full panel review as if freshly written, and land it. Re-implement only what review rejects. The
hand-backs carry design reasoning the cards do not restate — T9's per-pane tmux path resolution and
T5's `Source#collapse_strategy` interface contract especially — and are the reason harvesting beats
a clean-room rewrite here.

Pre-step commits made before wave 1: `a26ee02b` (r9 T2, the `--quiet` change) and `cde61940` (the
round 9/10 planning record, including this document).

Baseline suite before wave 1: **15203 examples, 0 failures, 15 pendings**; `rubocop` 1375 files, no
offenses.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb`, `lain.gemspec`,
  `.rubocop.yml`, `spec/spec_helper.rb`, `lib/lain/cli/command.rb` (the command unit's index), and
  **`exe/lain`** — two cards need one-line changes there (T1 deletes the `--yolo` declaration, T10
  replaces the `--isolation` description), so it is orchestrator-applied rather than cut across waves.
- **Before wave 1, one pre-step:** the dirty `lib/lain/exec/docker.rb` + `spec/lain/exec/docker_spec.rb`
  are round-9's T2, already implemented and panel-reviewed. Run `bundle exec rspec
  spec/lain/exec/docker_spec.rb` and **commit** them; do not revert and do not re-implement. This
  chunk has no card for that work — T17 pins it.
- **This plan carries two independent tracks and MAY be executed as two chunks.** T1–T15 and T22–T23
  (the flag, the gate, the record) share no file and no dependency with T17–T21 and T24 (round 9's
  remainder). The panel recommended splitting on the strength of a 13-wide wave 1. They are kept in
  one document because one plan owning the tree was the explicit instruction; an orchestrator that
  prefers two queues can cut cleanly along that line without re-planning.
- Round 9's plan doc gets `status: superseded-in-part` with a pointer here, naming T2/T3/T5–T9 as
  absorbed.

## Open decisions

- **`/mode auto` still reaches `Gate::ApproveAll`, and T3 does not change that.** Wiring the triage
  rung denies a protected argv on the *default* posture, which is F63 as filed. It does **not** make
  a bash argv unliftable the way a `read_file` path is: `Effect::Handler::Sensitivity`
  (`effect/handler/sensitivity.rb:99`) sits *outside* the Gate and so cannot be lifted by any
  policy, whereas a Triage deny is an ordinary ladder deny that an approve-all policy bypasses
  entirely. Extending `Sensitivity::PATH_FIELDS` (`policy.rb:82-96`) to parse bash argv would close
  that, and is deliberately **not** in this chunk. Note the cost is a SHAPE change rather than a new
  row: `PATH_FIELDS` already carries `"bash" => "cwd"` and `"core_exec" => "cwd"`
  (`policy.rb:94-95`), so bash is in the pre-gate table already and contributes one path where it
  needs N — and `policy_spec.rb:47-50`'s exact-equality guard is the smaller half. **Owner: round 11,
  as the first card of the next QA chunk.** T23 records the hole as a known-open observable in the
  meantime.
- **`RedactSecretReads::Unqueued` approves while the rest of an unattended run denies.** Its
  approve-everything answer is justified in-code by "`--yolo` already answers approve everywhere
  else" (`redact_secret_reads.rb:94-102`). After T1 the only caller is `--non-interactive`, where
  `asking_policy` returns `DenyAll` (`switchboard.rb:291`) — so it becomes the single fail-open in
  an otherwise fail-closed run. **T1 is what creates that incoherence** — `--yolo` was the caller for
  which approve-everything was coherent — so this is caused here, not inherited, and T1 carries an
  escalation trigger saying so. **T4** renames it and its docstring must state the fail-open in
  words. **Flipping it to deny is deferred**: it changes what an unattended run returns for every
  sensitive read and wants its own measurement. **Owner: round 11**, alongside the `/mode auto`
  decision above — both are approval-boundary questions and belong in one pass.
- Whether `bash`/`grep` get F62's encoding refusal too. T8 names the shared defect and fixes
  `read_file` only, which is the reported instance.

## Waves

```
Wave 1 (14): T1, T2, T5, T6, T7, T8, T10, T11, T12, T14, T15, T17, T18, T19
Wave 2  (6): T3 (←T1), T4 (←T1,T2), T9 (←T8), T20 (←T19), T21 (←T19), T24 (←T18)
Wave 3  (4): T13 (←T3), T22 (←T4), T23 (←T3,T14), T25 (←T1,T2,T4)
Critical path: T1 → T3 → T23   (three chains tie at length 3; T1→T3→T13 and T1→T4→T22 are the others)
```

**Wave 1 is 14 wide, and that is the plan's weakest point.** The panel flagged it and recommended
splitting the chunk. The width is inherent to absorbing round 9's remainder into one document, which
was the deliberate choice — see the Orchestrator contract for the clean cut line
(T17/T18/T19/T20/T21/T24 are round 9's track and share no file with round 10's). An orchestrator
running this as one chunk should expect a wide merge queue in wave 1 and **must not run concurrent
suites**: CLAUDE.md's rule is that a red `pspec` is not evidence until
`pgrep -cf 'mise/installs/ruby/[0-9.]*/bin/parallel_rspec'` reads 0, and eight sibling worktrees
already live under `.claude/worktrees/`.

## Tasks

### T1 — Delete the `--yolo` flag and the branches only it could reach   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/cli/switchboard.rb`, `lib/lain/cli/wiring/board_build.rb` (the stale
`@option options [Boolean] :yolo` doc at `:49-51` only), `spec/lain/cli/switchboard_spec.rb`,
`spec/lain/cli/wiring/toolset_build_spec.rb`, `spec/lain/tools/subagent_spec.rb`,
`spec/lain/effect/handler/sensitivity_spec.rb`, `spec/lain/cli/wiring_spec.rb`
**Reuse:** `Mode.new(posture: :accept_edits)` is already the non-yolo arm at `switchboard.rb:148`;
`Effect::Handler::Gate::DenyAll` at `:291` already covers the unattended arm.
**Shared-file wiring:** delete `exe/lain:871-872` (the `method_option :yolo` declaration) —
one-line diff to the orchestrator.
**Reachable from:** `exe/lain#chat → CLI::Wiring#switchboard (wiring.rb:460) → BoardBuild.for
(board_build.rb:52) → Switchboard.for` — the one memoized construction on the real path.

Remove the `yolo:` required keyword from `Switchboard#initialize` (`:128`) and from
`Switchboard.for` (`:98`). **It is a REQUIRED keyword, so every direct `Switchboard.new` raises
`ArgumentError: unknown keyword: :yolo` until it is updated** — five sites across four spec files,
all listed above and all owned by this card, because a wave-1 card that cannot green its own suite
blocks the merge: `toolset_build_spec.rb:66,:335,:366`, `subagent_spec.rb:809`,
`handler/sensitivity_spec.rb:31`, plus `wiring_spec.rb:608-610,:1216-1217`. `@approvals` becomes `Approval::Queue.new(journal:) if @attended`
(`:145`); the seed becomes an unconditional `Mode.new(posture: :accept_edits)` (`:148`).

Then delete the three things that become unreachable, **together** — `asking_policy` returns
`DenyAll` for `!@attended` before it can reach the sentinel, so none of these can fire again:
`refuse_queueless` (`:302-309`, whose message names the flag), `NO_QUEUE` (`:322-323`), and the
`resolve` guard at `:266`. Correct the class doc's claim that the switchboard reads
`--auto-approve` (`:67`) — it does not; `ToolsetBuild` does. Sweep the comment-only mentions at
`:14, :15, :23, :29, :32, :60, :92, :103, :122-123, :141, :156, :165-166, :243, :275, :296-297, :313`.

**Acceptance criteria**

```gherkin
Scenario: a chat wires an approval queue with no flag to skip it
  Given an attended session built through Switchboard.for with default options
  Then the board exposes an Approval::Queue
  And the starting posture is accept_edits

Scenario: an unattended session still wires no queue
  Given a session built with non_interactive: true
  Then the board exposes no approval queue
  And the asking policy denies

Scenario: the removed flag is not silently ignored
  When "lain chat --yolo" is invoked
  Then it exits nonzero
  And the message is Thor's arity refusal naming the stray argument
```

(Measured 2026-08-23: `check_unknown_options!` is declared nowhere, so Thor answers a stray switch
on a zero-arity command with `ERROR: "lain chat" was called with arguments ["--yolo"]`, exit 1 —
an **arity** error, not an unknown-option one. Assert that shape, not the words "unknown option".)
→ spec file: `spec/lain/cli/switchboard_spec.rb` (delete `:91-96`, `:162-180`, `:356-392`; drop the
`yolo:` kwarg from the `switchboard(...)` helper at `:15-17`; rewrite `:123-127` to `attended: false`),
and `spec/lain/cli_spec.rb` for the Thor arm.

**Escalation triggers**
- `spec/lain/cli/wiring_spec.rb:608-610` passes `yolo: true` specifically to stop a tier-3 `bash`
  parking on the gate. It is the ONE non-mechanical spec rewrite in this card's blast radius —
  `non_interactive` will *deny* rather than approve, so it needs `/mode auto` or an injected
  `ApproveAll`. If that rewrite is not obviously behaviour-preserving, stop and confirm.
- If `refuse_queueless` turns out to be reachable by some path other than `--yolo`, stop — the
  dead-code claim in Grounding is then wrong and the deletion set changes.
- **This card CREATES an incoherence it must not silently ship.** `RedactSecretReads::Unqueued`
  approves every sensitive-region release; after this card its only caller is `--non-interactive`,
  where `asking_policy` returns `DenyAll` (`switchboard.rb:291`). So an unattended run will deny
  every gated call and approve every region release. `--yolo` was the caller for which
  approve-everything was coherent. Do not fix it here (see Open decisions) — but if T4's rename
  does not land in the same chunk, stop and say so.
- `spec/lain/cli/command/surface_spec.rb:141` pins the shipped command roster by
  `contain_exactly`; it is T2's file, not this card's. If it goes red here, the two cards raced.

### T2 — Delete the `/yolo` REPL command   [wave 1] [risk: low]

**Depends on:** none
**Files:** delete `lib/lain/cli/command/yolo.rb`, delete `spec/lain/cli/command/yolo_spec.rb`,
modify `lib/lain/cli/command/surface.rb`, `spec/lain/cli/command/surface_spec.rb`
**Reuse:** `/mode auto` and `/mode accept_edits` (`cli/command/mode.rb`) already reach the identical
`PolicySwitch` transitions this command wrapped.
**Shared-file wiring:** remove `require_relative "command/yolo"` from `lib/lain/cli/command.rb:33`.
**Reachable from:** `Command::Surface#registry` (`surface.rb:128`) — the registry every REPL builds.

Drop `registry.register(Yolo.new)` at `surface.rb:128` and remove `"yolo"` from the roster
assertion at `surface_spec.rb:141`. Leave `Approval::PolicySwitch` untouched — `/mode` and
`Switchboard#seed` are its other writers.

**Acceptance criteria**

```gherkin
Scenario: the command registry no longer offers /yolo
  Given a REPL command registry built by Command::Surface
  Then it registers no command named "yolo"
  And "/mode auto" is the documented way to reach an approve-all policy

Scenario: typing the removed command is refused, not silently ignored
  Given a live REPL
  When the human types "/yolo on"
  Then the registry reports an unknown command
```
→ spec file: `spec/lain/cli/command/surface_spec.rb`

**Escalation triggers**
- If any command other than `/mode` writes `Approval::PolicySwitch`, the "redundant alias" premise
  is wrong — stop and report what else flips the live gate.
- If the unknown-command path raises rather than reporting, that is a pre-existing behaviour this
  card must not change; note it and keep the AC to what the registry does.

### T3 — Wire the triage rung's path classifier so the argv check can fire   [wave 2] [risk: high]

**Depends on:** T1
**Files:** `lib/lain/cli/wiring/board_build.rb`, `lib/lain/cli/switchboard.rb`,
`spec/lain/cli/wiring/board_build_spec.rb`, `spec/lain/cli/switchboard_spec.rb`
**Reuse:** **the factory already exists as spec support** —
`EscalationSpecSupport::Classifiers` (`spec/lain/approval/escalation_spec.rb:157-182`), whose own
comment calls it "what a session's wiring would hand the triage rung". **Promote it, do not fork
it**: move the real object into `lib/` beside `BoardBuild.classifier` (`board_build.rb:85-87`) and
leave the spec constructing *that*, so there are not two implementations of a security-relevant
total factory that can drift and twenty escalation examples exercising the wrong one.
`WorkerEnv#resolve` (`worker_env.rb:63-65`) is the cwd resolution, matching `Tools::Bash` (`bash.rb:176`).
**Call `BoardBuild.rules(project:, notice:)` ONCE** — hoist it to a local in `BoardBuild.for` and
pass the value to both the policy and the triage factory. It parses the config and fires
`notice.call(UNREADABLE…)` on `Config::Malformed` (`board_build.rb:112-117`), so a second call means
two parses and **two identical startup notices** for one broken config.
**Shared-file wiring:** none.
**Reachable from:** `CLI::Wiring#switchboard` (`wiring.rb:460`, the one memoized construction) →
`BoardBuild.for` (`board_build.rb:52`) → `Switchboard.for` → `#seed` → `#build_ladder`
(`switchboard.rb:249`), where `Escalation.for` is called on every attended chat.

Pass a `cwd -> #classify` factory into `Switchboard.for`/`#new`, and thence
`Escalation.for(..., triage: Approval::Escalation::Triage.new(sensitivity: factory))`.

**The factory MUST be total.** `escalation.rb:503-521` is explicit: a raise becomes a `RUNG_BROKE`
fault, and a fault turns a deny into an abstention a human then approves — and `cwd` is
model-controlled (`bash.rb:73`), so a raising factory is a model-triggerable disarm.

**CORRECTED 2026-08-23, after review — the original instruction here was WRONG and shipped a
one-argument bypass.** It said to fall back to `Triage::AnyPath` on any error, as the reference
implementation does. `AnyPath` protects *nothing*, and `cwd` is model-controlled, so any `cwd` the
factory cannot digest — `"bad\0dir"`, `42`, `{"a":1}`, `true`, `"~nosuchuser"`, invalid UTF-8, all of
them JSON a model can emit — discards the whole classifier and returns F63 verbatim: the protected
key reaches a human as an *ordinary* approval. Driven and confirmed on a real `BoardBuild.for` board.
The `cwd` contributes nothing to classifying an ABSOLUTE path, so discarding the classifier over a
bad `cwd` is over-broad as well as unsafe.

**Fall back instead to a session-anchored `Lain::Sensitivity`, built EAGERLY in `#initialize` from
`home`/`cwd` — both of which are wiring-controlled and never model-controlled.** `Triage::AnyPath`
remains the fallback only for a wiring-level failure, where nothing better exists. Building eagerly
also makes a mis-wired `home`/`cwd` fail loudly at construction instead of silently disarming the
rung for a whole session.

**Acceptance criteria**

```gherkin
Scenario: a bash call naming a protected path is denied by the triage rung
  Given a real board built by BoardBuild with the default posture
  When the agent requests bash with command "cat /home/u/.ssh/id_rsa"
  Then the ladder denies at the triage rung
  And the journalled reason names the argv as a path no approval may lift
  And no approval is parked for a human

Scenario: an ordinary command is untouched
  Given the same board
  When the agent requests bash with command "ls -la"
  Then the triage rung abstains
  And the call reaches the surfaces rung as before

Scenario: an unresolvable cwd disarms nothing
  Given the same board
  When the agent requests bash naming a protected absolute path with a cwd that cannot be resolved
  Then the ladder still denies at the triage rung
  And no fault is recorded
  And no approval is parked for a human

Scenario: the board actually passes the classifier, rather than accepting the inert default
  Given a Switchboard built by BoardBuild.for
  Then its triage rung's classifier factory is not Triage::AnyPath
```
→ spec file: `spec/lain/cli/wiring/board_build_spec.rb` (the production-path AC — a real board, not
an injected Triage), plus `spec/lain/cli/switchboard_spec.rb` for the ladder composition.

**Escalation triggers**
- `spec/lain/approval/escalation_spec.rb:837-841` pins that the DEFAULT `Triage` protects nothing.
  This card must NOT change that default — it changes the caller. If making the AC pass requires
  editing `AnyPath`, stop: the seam is wrong.
- **The new keyword will have a default, and a default is how this rung gets silently re-disarmed.**
  Deleting the argument at `board_build.rb:53` would restore `AnyPath` with a fully green suite —
  which is the dormant-feature failure this whole plan is written against. That is why the last AC
  asserts collaborator IDENTITY at the construction site, not just behaviour. The codebase already
  does exactly this, for exactly this reason, at `tool_guard_spec.rb:127,:135`
  (`expect(...).not_to be_a(Unqueued)` / `.to be(Unqueued.instance)`) — copy that shape.
- `switchboard_spec.rb:42` pins rung names/order and `:44-53` pins that a parked call journals
  exactly `%w[triage rules]`. If adding the classifier changes either, stop.
- `board_build_spec.rb:122-140` pins that the sensitivity table never leaks into the approval rung.
  A second `Lain::Sensitivity` must not break it — if it does, build one and share it.
- CLAUDE.md permits exactly one `Filter.new` in `lib/` (`policy.rb:137`). If your approach needs a
  second, stop — reuse `Lain::Sensitivity`, which is not a `Filter`.

### T4 — Rename the queueless stand-ins for the reason they now exist   [wave 2] [risk: medium]

**Depends on:** T1, T2
**Files:** `lib/lain/cli/command/env.rb`, `lib/lain/cli/command/surface.rb`,
`lib/lain/middleware/redact_secret_reads.rb`, `spec/support/command_env.rb`,
`spec/lain/cli/command/env_spec.rb`, `spec/lain/cli/command/approve_spec.rb`,
`spec/lain/cli/command/surface_spec.rb`, `spec/lain/cli/tool_guard_spec.rb`,
`spec/lain/cli/wiring/agent_build_spec.rb`, `spec/lain/middleware/redact_secret_reads_spec.rb`,
`spec/lain/cli/repl/approval_surfaces_spec.rb`, `spec/lain/cli/repl/line_scope_spec.rb`,
`spec/lain/cli/wiring_spec.rb`
**Reuse:** the Null Object doctrine in CLAUDE.md and `Sink::Null` as the exemplar; the existing
substitution site `approvals || Env::YoloApprovals` (`surface.rb:114`).
**Shared-file wiring:** none.
**Reachable from:** `Command::Surface#assemble_env` (`surface.rb:114`) and
`CLI::ToolGuard#read_kwargs` (`tool_guard.rb:68-77`) — both on the `--non-interactive` path.

`Env::YoloApprovals` becomes a name about the queue's absence, not about a deleted flag (e.g.
`Env::NoApprovals`). Re-document `RedactSecretReads::Unqueued` (`:94-129`) so its justification
cites the unattended session rather than `--yolo`. **Do not change what either one does** — see
Open decisions.

**The `Unqueued` docstring must state the fail-open out loud**, because after T1 it is the only one
left: an unattended run denies every gated call (`switchboard.rb:291`) and approves every sensitive
region release. Its current justification — "`--yolo` already answers approve everywhere else" — is
about to become false, and a stale justification for a fail-open is worse than none.

**Acceptance criteria**

```gherkin
Scenario: an unattended session still reads a nil-free approvals collection
  Given a command Env assembled for a session that wired no approval queue
  Then the approvals reader answers an empty enumeration
  And /approve reports that nothing is pending

Scenario: no symbol in lib/ names the deleted flag
  When lib/ is searched for "yolo", excluding .claude
  Then there are no matches
```
→ spec file: `spec/lain/cli/command/env_spec.rb`, `spec/lain/cli/command/approve_spec.rb`

**Escalation triggers**
- Every renamed constant is also referenced from `spec/support/command_env.rb`, a SHARED helper.
  If renaming it breaks specs outside this card's Files list, stop and hand the list back.
- If any rename changes behaviour rather than naming, stop — this card is a rename.
- The `Unqueued` approve-vs-deny inconsistency is an Open decision, NOT this card's to fix.

### T5 — Say why a run was interrupted   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/telemetry/session_lifecycle.rb`, `lib/lain/session_record/scribe.rb`,
`lib/lain/cli/chronicle.rb`, `lib/lain/cli/conductor.rb`, `lib/lain/cli/repl/ask.rb`,
and their specs
**Reuse:** **`SessionClosed` is the exact template** (`session_lifecycle.rb:16-46`) — a reopened
class carrying `REASONS` and a `reason!` guard, reopened precisely because a constant inside a
`Data.define` block scopes to the enclosing module (CLAUDE.md's pinned trap).
`Conductor::INTERRUPT_REASONS` (`conductor.rb:37-39`) is the existing vocabulary subset.
**Shared-file wiring:** none.
**Reachable from:** `Conductor#close` (`conductor.rb:172`) on every Ctrl-C or grace expiry, and
`Repl::Ask#refuse → #record_interruption` (`repl/ask.rb:76-87`) on every torn ask.

`RunInterrupted` gains a validated `reason:`. `Conductor` **already holds its reason and discards
it** — pass it through. `Ask#refuse` must classify: at minimum distinguish a provider stall
(`Provider::HTTP::Streaming::StalledStreamError`) from other `Lain::Error`s, so round 6's F26
triage can be done from the record.

**Acceptance criteria**

```gherkin
Scenario: a Ctrl-C names itself
  Given a live run
  When the conductor closes with reason interrupted
  Then the run_interrupted record carries reason "interrupted"

Scenario: a grace expiry is distinguishable from a Ctrl-C
  When the conductor closes with reason grace_expired
  Then the run_interrupted record carries reason "grace_expired"

Scenario: a stalled provider stream is distinguishable from both
  Given an ask that raises a stalled-stream error
  Then the run_interrupted record names the stall rather than a generic interruption

Scenario: an unknown reason is refused at construction
  When a RunInterrupted is built with reason :nonsense
  Then it raises ArgumentError naming the permitted reasons
```

**Name a NEW closed set; do not reuse `SessionClosed::REASONS`.** That one is
`%i[exit interrupted grace_expired salvaged]` (`session_lifecycle.rb:38`) and has nowhere to put a
stall — `:exit` and `:salvaged` are meaningless for an interruption.
`Conductor::INTERRUPT_REASONS` (`:39`) is a two-element subset of it and is the vocabulary
`Conductor` already has in hand. The new set needs at minimum those two plus a stall and a
generic torn-ask value.
→ spec file: `spec/lain/telemetry_spec.rb`, `spec/lain/cli/conductor_spec.rb`,
`spec/lain/cli/repl/ask_spec.rb`

**Escalation triggers**
- `spec/lain/telemetry_spec.rb:644-651` asserts the journal hash by **exact `eq`** — it fails the
  moment a field is added. That is expected; update it. If it fails in a way that is NOT the new
  field, stop.
- `spec/lain/cli/conductor_spec.rb:27` holds a hand-rolled chronicle fake
  (`def interrupted(head:)`) and `spec/lain/cli/repl/ask_spec.rb:15` an `instance_double` — both
  verify signatures, so both break on a new kwarg. Update both; if a third double appears, stop.
- `Chronicle::Null#interrupted` (`chronicle.rb:43`) must keep accepting whatever the real one does.
- The value object must stay deeply frozen — `Ractor.shareable?` has a spec.

### T6 — Give a line-shaped decorator its line ending   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/frontend/decorators.rb`, `lib/lain/frontend/decorators/provider_retry.rb`,
`lib/lain/frontend/tty.rb`, `spec/lain/frontend/decorators_spec.rb`,
`spec/lain/frontend/decorators/provider_retry_spec.rb`, `spec/lain/frontend/tty_spec.rb`
**Reuse:** `Countdown#above` (`tty.rb:809-813`) already holds the right predicate —
`puts unless rendered.end_with?("\n")`. `Sink::IOAdapter#write` (`sink.rb:44-51`) documents why a
tool-output chunk must NOT be forced onto its own line.
**Shared-file wiring:** none.
**Reachable from:** `Frontend::TTY#render` (`tty.rb:358-361`), the channel-drain path every session
runs.

Let each decorator say whether it is line-shaped (a message, not a type check — CLAUDE.md), and have
the **inactive** branch of `print_above` (`tty.rb:783-788`) honour it. `ProviderRetry` is line-shaped
and promises so in its docstring; `ToolOutput` is not, and its docstring's "one attributed line"
claim is wrong — correct it while you are there.

**Do NOT make `above` (`tty.rb:809-813`) conditional on the decorator.** Its `puts` is there because
the redrawn status line must start on a fresh line — a question about the STATUS LINE, not about the
content. Routing a decorator's self-description into it would land the bold status line mid-chunk
for `ToolOutput` on the active branch: a regression this card would be causing, in the one place
F58 does not manifest. The inactive branch is where the bug lives and the only place to change.

**Acceptance criteria**

```gherkin
Scenario: retry lines do not run together when no countdown is active
  Given a TTY frontend with no countdown running
  When four provider-retry events and an error are rendered
  Then the output contains five newline-terminated lines

Scenario: a streaming tool-output chunk is still not forced onto its own line
  Given a TTY frontend with no countdown running
  When a tool-output chunk without a trailing newline is rendered
  Then no newline is appended

Scenario: the active-countdown branch is unchanged, for BOTH decorators
  Given a countdown is running
  When a provider-retry event and then a tool-output chunk are rendered
  Then each prints above the status line and the status line redraws on a fresh line
  And the behaviour is byte-identical to before this card
```
→ spec file: `spec/lain/frontend/tty_spec.rb`

**Escalation triggers**
- No spec currently exercises `print_above`'s inactive branch; you are writing the first. If an
  existing example silently depended on the missing newline, stop and report which.
- `spec/lain/frontend/tty_spec.rb:844-858` pins the clear-line/redraw ordering on the ACTIVE branch.
  It must not move.
- If a third decorator has appeared since grounding, the taxonomy question is reopened — stop.

### T7 — Name the epic verb the operator actually ran   [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/cli/epic.rb`, `lib/lain/cli/epic_submit.rb`, `lib/lain/cli/epic_land.rb`,
`lib/lain/cli/epic_mount.rb`, `spec/lain/cli/epic_spec.rb`, `spec/lain/cli/epic_submit_spec.rb`,
`spec/lain/cli/epic_land_spec.rb`, `spec/lain/cli/epic_mount_spec.rb`
**Reuse:** `Epic#listed` (`epic.rb:254`) already formats the slug list. In-repo precedent for verb
substitution in a shared refusal: `/unpin` (recorded in round 9's findings).
**Shared-file wiring:** none.
**Reachable from:** `Epic#status` (`epic.rb:181`) and `Epic#resolve_slug` (`epic.rb:196`), reached
by `epic submit`, `epic land`, `epic land --resume`, and `chat --epic`.

Thread the invoked verb into `sole` (`epic.rb:246-252`) so the hardcoded
`"name one: lain epic status SLUG"` becomes the caller's own command. **Four distinct strings** are
needed: `lain epic status SLUG`, `lain epic submit STAGE SLUG`, `lain epic land ISSUE_ID SHA SLUG`,
and `lain chat --epic SLUG`. `epic queue`/`approve`/`deny` do **not** reach `chosen` — do not touch them.

**Acceptance criteria**

```gherkin
Scenario: submit's ambiguity refusal advises submit
  Given an epics home holding two epics
  When "lain epic submit research" runs with no slug
  Then it refuses naming both slugs
  And the remedy names "lain epic submit"

Scenario: the chat mount advises the chat flag, not an epic subcommand
  Given the same home
  When a chat is mounted with no --epic
  Then the remedy names "lain chat --epic"

Scenario: status still advises status
  When "lain epic status" runs with no slug
  Then the remedy names "lain epic status SLUG"
```
→ spec file: `spec/lain/cli/epic_submit_spec.rb`, `spec/lain/cli/epic_mount_spec.rb`,
`spec/lain/cli/epic_spec.rb`

**Escalation triggers**
- `spec/lain/cli/epic_spec.rb:331-337` pins the literal `/lain epic status SLUG/m` for the status
  path. It must keep passing unchanged — if threading the verb changes status's own message, the
  default is wrong.
- There are **five call sites but four distinct verbs**: `epic_submit.rb:288`, `epic_land.rb:204`
  AND `:217` (`land` and `land --resume` share one remedy string), `epic_mount.rb:144`, plus
  `Epic#status`'s own `chosen` at `epic.rb:181`. Do not stop over the fifth site — that is expected.
  Stop only if a caller appears that needs a FIFTH distinct string, or if `land --resume`'s remedy
  should differ from `land`'s.

### T8 — Refuse a file whose bytes cannot become a turn   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/tools/read_file.rb`, `spec/lain/tools/read_file_spec.rb`,
`spec/support/shared_examples/tier_one_read_contract.rb`
**Two changes, not one:** the refusal at `#deliver`, AND the encoding TAG at `read_file.rb:241`.
**Reuse:** the three sibling tools already do exactly this — `code_outline.rb:99-106`,
`file_symbols.rb:111-118`, `ast_search.rb:99-104` all fold an encoding failure into the
unreadable-file arm and return an error `Tool::Result` naming the file. `Read::Refused`
(`read_file.rb:169-177`) is the existing Null-Object sibling for a refusal that must not reach
`Session#record_read`.
**Shared-file wiring:** none.
**Reachable from:** `Read#deliver` (`read_file.rb:160-168`) — the single point where **both** the
`Whole` and `Window` readers turn bytes into a `Tool::Result`, on every `read_file` call.

Refuse at `#deliver` when the contents cannot become a canonical String, naming the path. This
keeps the read out of the read-set and hands the model an actionable `tool_result` instead of
killing the ask at `Canonical.normalize` (`canonical.rb:120`) during `Timeline#commit`.

**The predicate must be Canonical's question — and asking it exposes a SECOND, unreported defect
this card must also fix.** `capped` tags the read with `Encoding.default_external`
(`read_file.rb:241`). Under `LC_ALL=C` that is US-ASCII, and Canonical's question then refuses an
ordinary UTF-8 file. Measured on this tree's Ruby 4.0.6:

```ruby
"café\n".b.force_encoding(Encoding::US_ASCII).encode(Encoding::UTF_8)
# => Encoding::InvalidByteSequenceError: "\xC3" on US-ASCII
```

So a good UTF-8 file already kills the ask under a C locale, today, unreported. **Retag the read as
UTF-8** rather than as the locale's guess — which is what the sibling precedent actually does;
`spec/lain/tools/code_outline_spec.rb:120-125` pins it as "the read names its encoding". Without
that change the third AC below and the stated predicate are mutually unsatisfiable.

**Acceptance criteria**

```gherkin
Scenario: a binary file is refused by name, and the ask survives
  Given a file of random bytes in the project
  When the agent calls read_file on it
  Then the tool result is an error naming the file and saying it is not valid UTF-8
  And the ask completes rather than being interrupted

Scenario: a refused read teaches the model nothing about the file
  Given the same file
  When the read is refused
  Then no read is recorded in the session's read-set

Scenario: an ordinary UTF-8 file is still read under a C locale
  Given LC_ALL=C and a UTF-8 file containing non-ASCII text
  When the agent calls read_file on it
  Then the file is returned, not refused
```
→ spec file: `spec/lain/tools/read_file_spec.rb`

**Escalation triggers**
- **Three existing specs assert the OPPOSITE contract and must flip.** Two are the refusal:
  `read_file_spec.rb:1023-1027` ("keeps invalid UTF-8 intact through the capped read") and
  `tier_one_read_contract.rb:107`, where `false` means `is_error` must be false. The third is the
  retag: **`read_file_spec.rb:1015-1020` asserts the result's encoding equals a bare `File.read`'s**
  — it will fight the UTF-8 tag, and it is the spec that makes this card medium-risk rather than
  small.
- **The shared example's blast radius is ONE file, not every tier-1 tool.**
  `tier_one_read_contract.rb:107` sits in the group "a tier-1 read of any path that never raises"
  (`:100`), included only by `read_file_spec.rb:418`. The three-user group is the *other* one
  (`:40`, used by `memory_read_spec.rb:50` and `read_file_spec.rb:425,:436`) and this card does not
  touch it. If a tool other than `read_file` goes red, something is wrong with the change, not with
  the contract — stop.
- Do **not** change `Canonical` (`canonical.rb:118-125`) or `Scan#readable?`
  (`redact_secret_reads.rb:436`). `Canonical`'s refusal is pinned by
  `spec/support/shared_examples/canonical_laws.rb:181-187` and is correct; `readable?` asks a
  different question (unscannable *blocks*, not encodings) and answering it here would make the bug
  conditional on the secret boundary being wired.
- `bash.rb:114` and `grep.rb:247` have the identical latent defect. **Out of scope** (Open
  decisions) — note them, do not fix them here.

### T9 — Pin the read-to-turn seam that no spec crosses   [wave 2] [risk: medium]

**Depends on:** T8
**Files:** `spec/lain/seams/read_to_turn_spec.rb` (new)
**Reuse:** `spec/lain/seams/` is CLAUDE.md's home for a seam belonging to no single subject; the
`:seam` tag runs by default.
**Shared-file wiring:** none.
**Reachable from:** deferred: test-only. It pins the production path T8 fixes rather than adding a
capability — the capability is T8's.

Drive a **real** `read_file` of a non-UTF-8 file through `ToolRunner#delivery` into
`Timeline#commit`, with no doubles between them. This is the gap that let F62 ship green: the
`unreadable` spec (`redact_secret_reads_spec.rb:504-513`) injects content directly and never runs
the real reader, so nothing crossed the boundary where the raise actually lives.

**Acceptance criteria**

```gherkin
Scenario: a real read of a binary file commits a turn instead of raising
  Given a real ReadFile, ToolRunner and Timeline with no doubles between them
  When the agent reads a file of random bytes
  Then a turn commits carrying the refusal
  And Canonical raises nothing
```
→ spec file: `spec/lain/seams/read_to_turn_spec.rb`

**Escalation triggers**
- **This spec must be RED before T8 and green after, and you must actually check.** From inside
  this card's worktree T8 is already present, so: `git stash` T8's change to `read_file.rb` (or
  `git revert --no-commit` its commit), run the new seam, confirm it raises
  `Canonical::UnsupportedType`, then restore. A seam spec that was never seen red is not evidence.
  If it passes with T8 reverted, the F62 diagnosis in Grounding is wrong — stop and report.
- If it needs a double to construct, the seam is wrong; a seam spec with a double between the
  components is not one.

### T10 — Tell the truth about `--isolation`   [wave 1] [risk: low]

**Depends on:** none
**Files:** `spec/lain/cli/chat_flags_spec.rb`
**Reuse:** `IsolationBackend::BACKENDS` is already interpolated rather than restated
(`exe/lain:907-910`), on the rule that help text and resolver cannot disagree — keep that.
**Shared-file wiring:** replace the `desc:` at `exe/lain:907-910` and its comment at `:902-906` —
one-line diff to the orchestrator.
**Reachable from:** `lain chat --help`, the only place an operator learns what the flag does.

The claim "no chat path spawns an actor-mode subagent yet, so this is inert in chat today" is false:
`wiring.rb:308` resolves the flag on every chat (an unknown name refuses at startup — round 10 drove
this), `wiring.rb:270` injects it into a live `Supervisor`, and `subagent.rb:215` guards only on
`supervisor.running?`. Say what is true instead: the main chat's own session is deliberately never
isolated (`wiring.rb:248`, `:294-296`), and actor-mode subagents lease from this backend.

**Acceptance criteria**

```gherkin
Scenario: the help text no longer claims the flag does nothing
  When the chat command's --isolation description is read
  Then it names every backend
  And it does not claim to be inert

Scenario: the flag demonstrably does something
  When "lain chat --isolation nope" is invoked
  Then it refuses at launch naming the unknown backend
```
→ spec file: `spec/lain/cli/chat_flags_spec.rb`

**Escalation triggers**
- `chat_flags_spec.rb:213-216` asserts only that every backend NAME appears, so the sentence is free
  to change. If a spec asserting the "inert" wording turns up, stop — something else depends on it.
- This is the only stale help string found in `exe/lain` (78 `desc:` strings grepped). If you find
  another, report it rather than fixing it here.

### T11 — Make the improvements report refuse what it cannot answer   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/cli/improvements.rb`, `spec/lain/cli/improvements_spec.rb`
**Reuse:** **the allowlist is already in the file** — `KIND_ORDER = Improvement::KINDS`
(`improvements.rb:17`). The refusal convention is `SomeError < Lain::Error` in the unit plus
`LainCLI::Boundary#render` (`exe/lain:49-53`), which already wraps this command
(`exe/lain:962-966`) — so a raise gets exit-1-no-backtrace for free. `Improvement`'s own write-path
message (`improvement.rb:111`) is the wording to echo. `one_line` (`improvements.rb:91-93`) already
defends with `note.to_s` — the same defensiveness `note_line` lacks.
**Shared-file wiring:** none.
**Reachable from:** `LainCLI#improvements` (`exe/lain:966`) → `Improvements#report`.

Two defects, one responsibility — the report must not report an empty store when it was handed
something it could not use. Validate `--kind` against `Improvement::KINDS` before filtering
(`improvements.rb:50-53`), and guard `note_line`'s missing `evidence_digests` (`:80-84`) so a
damaged record refuses by name instead of raising `NoMethodError` with a backtrace — the bar round 9
already set for damaged journals.

**Acceptance criteria**

```gherkin
Scenario: a mistyped kind is refused, not reported as an empty store
  Given a store holding one bug and one knob
  When "lain improvements --kind bugs" runs
  Then it refuses naming the four valid kinds
  And it exits nonzero

Scenario: a valid kind matching nothing still reports the friendly empty message
  Given a store holding only a bug
  When "lain improvements --kind doc" runs
  Then it reports that nothing is recorded
  And it exits zero

Scenario: a record missing its evidence digests refuses by name
  Given a store whose first record has no evidence_digests key
  When "lain improvements" runs
  Then it refuses naming the damaged record
  And no backtrace is printed
```
→ spec file: `spec/lain/cli/improvements_spec.rb`

**Escalation triggers**
- `improvements_spec.rb:95-99` pins that a well-formed-but-absent `--project` hash gives the
  friendly empty message. **Malformed and absent must stay distinct** — if your validation makes
  that example refuse, the seam is wrong.
- `--project` is unvalidated the same way (`resolve_project`, `:55-57`, and `Paths#project_hash`
  never raises). Fixing it is in scope for this card ONLY if it does not disturb `:69-78`, which
  pins path resolution. If it does, stop and hand it back as its own card.

### T12 — Say what kind of thing `epic approve` wants   [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/cli/epic_queue.rb`, `spec/lain/cli/epic_queue_spec.rb`
**Reuse:** in-repo precedent for a refusal that names the ARGUMENT'S KIND: `/pin`'s
`"abc" is too short to name a turn (4 characters minimum) -- /pin names a turn, not a count`
(round 9's findings). `review.rows(nil)` already gathers the listing (`epic_queue.rb:148`).
**Shared-file wiring:** none.
**Reachable from:** `LainCLI#approve`/`#deny` (`exe/lain:290-297`) → `EpicQueue#drain`
(`epic_queue.rb:118-126`) → `#unknown_message` (`:147-153`).

`lain epic approve tally-rewrite` prints `no parked sign-off for "tally-rewrite" -- parked right
now:` and then lists a row **for tally-rewrite**. It is technically true — the verb takes a digest —
and reads as self-contradiction. Say that the argument must be a digest when it plainly is not one.

**Acceptance criteria**

```gherkin
Scenario: a slug passed where a digest belongs says so
  Given a home with a parked sign-off for epic "alpha"
  When "lain epic approve alpha" runs
  Then the refusal says approve names a parked artifact by digest
  And it still lists what is parked

Scenario: an unknown digest is unchanged
  Given the same home
  When "lain epic approve blake3:0000" runs
  Then the refusal reports no parked sign-off for that digest
```
→ spec file: `spec/lain/cli/epic_queue_spec.rb`

**Escalation triggers**
- The listing widens to every epic on purpose (`review.rows(nil)`), and the memo at `:113` is
  deliberate so the message reads the same fold `find` just missed. Do not narrow either.
- If distinguishing "looks like a digest" from "looks like a slug" needs a format constant that
  does not exist, stop rather than inventing one — `HASH_FORMAT` in `improvements.rb:24` is a
  precedent but for a different id.

### T13 — Pin what the auto-approver surface will and will not judge   [wave 3] [risk: medium]

**Depends on:** T3
**Files:** `spec/lain/approval/auto_surface_spec.rb`, `spec/lain/approval/secret_surface_spec.rb`
**Reuse:** `AutoSurface#judges?(outstanding) = outstanding.none?` (`auto_surface.rb:59`) and the
verdict grammar `VERDICT = /\A(approve|deny|defer)\.?\z/i` (`auto_surface.rb:33`).
**Shared-file wiring:** none.
**Reachable from:** deferred: test-only. It pins existing production behaviour wired at
`ToolsetBuild` (`toolset_build.rb:331`) under `--auto-approve`; no new capability.

No QA round has ever driven either model-at-the-gate surface. Round 10 raised a specific hypothesis
worth pinning either way: **a `bash` call carries no outstanding regions** — regions are a
`read_file`/`RedactSecretReads` concept — so `judges?` answers true and `AutoSurface` will judge a
`cat` of a protected path, which the region-based partition was never meant to cover. After T3 the
triage rung denies that call before any surface sees it; this card pins that ordering so a later
change cannot silently reopen it.

**Acceptance criteria**

```gherkin
Scenario: the auto-approver abstains on anything holding sensitive regions
  Given a pending whose outstanding regions are non-empty
  Then AutoSurface does not judge it

Scenario: a hedged verdict falls to defer, never to approve
  Given the auto-approver role answers "approve the read but deny the write"
  Then the pending is left undecided

Scenario: a protected bash argv never reaches the auto-approver at all
  Given a board with the triage rung wired and --auto-approve enabled
  When the agent requests bash naming a protected path
  Then the ladder denies at triage
  And the auto-approver is never asked

Scenario: the secret surface judges exactly the complement
  Given a pending whose outstanding regions are non-empty
  Then SecretSurface judges it
  And AutoSurface does not
```
→ spec file: `spec/lain/approval/auto_surface_spec.rb`

**Escalation triggers**
- The third scenario is why this card is wave 3: it needs T3's wiring. If it passes on a tree
  WITHOUT T3, the F63 grounding is wrong — stop and report.
- If `judges?` already excludes command tools by some path grounding missed, say so and drop that
  scenario rather than asserting a hypothesis the code refutes.

### T14 — Rewrite the QA scenarios that type a deleted flag   [wave 1] [risk: low]

**Depends on:** none
**Files:** `planning/qa/scenarios/repl-commands.md`, `planning/qa/scenarios/secret-boundary.md`,
`planning/qa/method.md`, `planning/qa/README.md`
**Reuse:** `/mode auto` reaches the identical policy; `planning/qa/method.md:183`'s standing rule
already pairs `/yolo` with `/mode +auto_approve`.
**Shared-file wiring:** none.
**Reachable from:** deferred: documentation. These are the inputs the `manual-qa` skill executes —
they are not code, but a scenario that types a removed flag fails at Thor on the next round.

`repl-commands.md` §6 is a whole executable section titled "`/yolo`, once, deliberately"
(`:208-223`); `secret-boundary.md` §5 literally runs `lain chat --yolo ...` (`:235-244`). Rewrite
both onto `/mode auto`. Update `method.md:183`'s rule and the two index rows in `README.md:41,43`.

**Acceptance criteria**

```gherkin
Scenario: no QA scenario invokes a flag the CLI no longer has
  When planning/qa/ is searched for "--yolo" and "/yolo"
  Then there are no matches outside historical findings documents

Scenario: the unliftable-rung section still has a way to reach an approve-all policy
  When secret-boundary.md section 5 is read
  Then it drives /mode auto and states what it is testing
```
→ spec file: none (documentation). Verified by the Integration checks' grep.

**Escalation triggers**
- Historical findings documents (`planning/qa-findings-round*.md`) and `planning/specs/chunk-*.md`
  are the RECORD of rounds that ran — do not rewrite history. Only live inputs change.
- `secret-boundary.md` §5 is the section that produced F63. If rewriting it would stop it finding
  F63's shape again, stop — the scenario's value is the probe, not the flag.

### T15 — Say in the findings what the round got wrong   [wave 1] [risk: low]

**Depends on:** none
**Files:** `planning/qa-findings-round10-2026-08-23.md`
**Reuse:** the round-9 findings' own precedent for correcting a filed diagnosis in place.
**Shared-file wiring:** none.
**Reachable from:** deferred: documentation. The findings doc is read by the next round to decide
what to re-check; a wrong mechanism there costs that round a probe.

F62 is filed as a secret-boundary defect. It is not: the raise is `Canonical.normalize`
(`canonical.rb:120`) on `Timeline#commit`, after the middleware passed the result through cleanly,
and the same read fails with the middleware unwired. Correct the mechanism, keep the observable,
and note that `bash`/`grep` share it. Also note F63's cause is an unwired seam rather than a missing
check, since that materially changes its fix cost.

**Acceptance criteria**

```gherkin
Scenario: the findings document names the real mechanism for F62
  When F62 is read
  Then it names Canonical.normalize on Timeline#commit
  And it states that the secret boundary is a witness rather than a participant
```
→ spec file: none (documentation).

**Escalation triggers**
- Do not restate the finding as "no defect". The observable — a killed ask and a reasonless
  `run_interrupted` — was real and reproduced; only the attributed layer changes.

### T17 — Pin the docker seam against whichever client is installed   [wave 1] [risk: low]

**Depends on:** none
**Files:** `spec/lain/exec/docker_spec.rb`
**Reuse:** `DockerBackendAvailability` (`docker_spec.rb:31-39`).
**Shared-file wiring:** none.
**Reachable from:** deferred: test-only, per round-9 T3's own card.

Absorbed from round 9 (its T3), and the only docker card here — r9 T2 is already written and is
committed as a pre-step (see the Orchestrator contract). The two `:seam` examples must pass under **both** docker and
rootless podman — they went red on this box only because installing `podman-docker` unskipped them.

**Acceptance criteria**

```gherkin
Scenario: the mounted project is readable and writable under either client
  Given a docker client on PATH
  When a command writes a file into the mounted project
  Then the file exists on the host owned by the calling user
```
→ spec file: `spec/lain/exec/docker_spec.rb`

**Escalation triggers**
- If the host has no docker client, these skip — a skipped seam is not a pass. Report the skip.
- If the `--quiet` change from round 9's T2 is NOT in the tree, stop: the orchestrator's pre-step
  did not run and this card would pin the wrong behaviour.

### T18 — Let the compaction wiring carry the operator's word   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/cli/backend/span_summarizer.rb`, `lib/lain/compaction/source.rb`, and specs
**Reuse:** `SpanSummarizer.resolve` (`span_summarizer.rb:77-79`), which already reads it.
**Shared-file wiring:** none.
**Reachable from:** `CLI::CompactionMount:76 → Backend#pipeline_source:367`.

Absorbed from round 9 (its T5), discharging F51's wiring half.

**Acceptance criteria**

```gherkin
Scenario: the resolved strategy reaches the compaction source
  Given a session launched with --compact-strategy elide-tools
  When the pipeline source is built
  Then it carries the operator's strategy name
```
→ spec file: `spec/lain/cli/backend/span_summarizer_spec.rb`

**Escalation triggers**
- Round 9's panel measured `CLI::Backend` at **111/110 `ClassLength`** and **11/10 `MethodLength`**,
  both already at cap, and CLAUDE.md forbids raising a `Metrics/*` limit. If threading the value
  requires touching `CLI::Backend`, stop — that is the constraint that reshaped round 9's card.

### T19 — Move the HUD's state file out of the user's source tree   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/project_dir.rb`, `spec/lain/project_dir_spec.rb`, and the prose sites naming
the old path
**Reuse:** `Epic::Home.container` (`epic/home.rb:72-80`).
**Shared-file wiring:** none.
**Reachable from:** `StatusFeed#default_path` (`status_feed.rb:519`) and `Frontend::TTY`.

Absorbed from round 9 (its T7), discharging F50 — machine state rewritten every turn into the
user's project with no ignore path. Round 10 re-checked F50 as **UNCHANGED**.

**Acceptance criteria**

```gherkin
Scenario: a chat writes no state file into the project root
  Given a chat run in a git repository
  When a turn completes
  Then the project root contains no .lain/state.json
  And git status is unchanged
```
→ spec file: `spec/lain/project_dir_spec.rb`

**Escalation triggers**
- Round 10's close-out uses `ls -d $LAIN_REPO/.lain` as a standing negative because lain's own
  repo gitignores `/.lain/`. If relocation changes what that check means, say so — the QA method
  depends on it.

### T20 — Point the nvim renderer at the relocated state file   [wave 2] [risk: low]

**Depends on:** T19
**Files:** `plugin/nvim/lua/lain/config.lua`, `spec/plugin/nvim_plugin_spec.rb`
**Reuse:** `plugin/nvim/lua/lain/init.lua:68` already computes `vim.fn.sha256(cwd):sub(1, 12)`.
**Shared-file wiring:** none.
**Reachable from:** the nvim plugin's HUD, read every turn by a cockpit user.

Absorbed from round 9 (its T8).

**Acceptance criteria**

```gherkin
Scenario: the nvim HUD reads the relocated state file
  Given a session whose state file lives outside the project
  When the plugin resolves the state path
  Then it resolves to the relocated path
```
→ spec file: `spec/plugin/nvim_plugin_spec.rb`

**Escalation triggers**
- Round 9's panel found this half "already written and already cross-pinned". If it is already
  done, verify and report rather than rewriting.

### T21 — Tell the tmux renderer where the state file is   [wave 2] [risk: medium]

**Depends on:** T19
**Files:** `plugin/tmux/scripts/lain-status`, `plugin/tmux/lain.tmux`, `lib/lain/cli/up.rb`, and specs
**Reuse:** `lain-status`'s existing optional `DIR` argument (`lain-status:5-7`).
**Shared-file wiring:** none.
**Reachable from:** `lain.tmux:30` builds the `#(...)` status job every cockpit runs.

Absorbed from round 9 (its T9).

**Acceptance criteria**

```gherkin
Scenario: the tmux status line reads the relocated state file
  Given a cockpit whose state file lives outside the project
  When the status job runs
  Then it renders the session's occupancy rather than an empty segment
```
→ spec file: `spec/lain/cli/up_spec.rb`

**Escalation triggers**
- Round 9's panel flagged **POSIX `sh`** as this card's real risk — `lain-status` is not bash.
  If a construct needs bash, stop.

### T22 — Sweep the deleted flag out of the shipped documentation   [wave 3] [risk: low]

**Depends on:** T4
**Files:** `docs/commands.md`, `README.md`, `ARCHITECTURE.md`, `ROADMAP.md`
**Reuse:** none.
**Shared-file wiring:** none.
**Reachable from:** deferred: documentation. These are what a user reads to learn the CLI.

Remove the `--yolo` row (`docs/commands.md:31`) and the `### /yolo` section (`:335-337`); remove the
`README.md:96` bullet **and its now-dangling anchor**; correct `ARCHITECTURE.md:484` ("the
`Approval::Queue` that `--yolo` bypasses"); drop `/yolo` from the command roster at `ROADMAP.md:845`
and close the open item at `ROADMAP.md:324` ("cheap rollback makes `--yolo` safe"), which dies with
the flag. Leave `ROADMAP.md:148` — it is a historical record of what M1b shipped.

**Acceptance criteria**

```gherkin
Scenario: no shipped document offers a flag the CLI does not have
  When docs/, README.md and ARCHITECTURE.md are searched for "yolo"
  Then there are no matches

Scenario: the README's command list has no dangling anchor
  When README.md's links into docs/commands.md are resolved
  Then every anchor target exists
```
→ spec file: none (documentation). Verified by the Integration checks.

**Escalation triggers**
- `planning/reviews/2026-07-14-joel-code-review.patch` is a patch ARTIFACT and
  `references/` is external research — both contain the string and neither is edited.
- `.claude/worktrees/` holds eight sibling checkouts and `.git/worktrees/` eight binary indexes.
  Any sweep needs BOTH `--exclude-dir=.claude` and `--exclude-dir=.git`, and must use
  `command grep` — the shell function silently answers 0.

### T23 — Prove the gate holds end to end, by hand   [wave 3] [risk: medium]

**Depends on:** T3, T14
**Files:** `planning/qa/scenarios/secret-boundary.md`
**Reuse:** the round-10 sandbox recipe and `$QA/pathcount.rb`-style probes in
`.claude/skills/manual-qa/`.
**Shared-file wiring:** none.
**Reachable from:** deferred: this is the human pass the Integration checks name. It verifies T3 on
the real binary, which no spec can do.

Add the probe that would have caught F63 to §5, phrased against the wired triage rung rather than
against `--yolo`: a `bash` call naming a protected path must be denied by name, at the default
posture, with the ladder journalling a triage deny and **no approval parked**.

**Acceptance criteria**

```gherkin
Scenario: the scenario names a check that fails on today's code and passes on T3's
  When secret-boundary.md section 5 is read
  Then it drives a bash call naming a protected path at the default posture
  And it names the journalled triage deny as the evidence
```
→ spec file: none (manual QA input).

**Escalation triggers**
- **Check it fails first, the same way T9 does.** From a tree with T3 reverted, drive the probe and
  confirm the call reaches a human as an ordinary approval; then restore T3 and confirm the triage
  deny. A manual probe that was never seen fail proves nothing about the fix.

### T25 — Purge or wire what the flag's deletion left behind   [wave 3] [risk: medium]

**Depends on:** T1, T2, T4
**Files:** determined by the audit; anything it proposes to DELETE from a file owned by a landed
card is this card's to change, anything it proposes to WIRE is escalated before it is written.
**Reuse:** `tmp/lib_reach_report.txt`, written by `spec/lib_reach_spec.rb` on every suite run — it
already lists public `lib/` methods named only from `spec/`, which is the exact shape a deletion
leaves behind. `command grep` per the sweep rules below.
**Shared-file wiring:** possible; hand back one-line diffs.
**Reachable from:** deferred: this card removes reach rather than adding it.

Added at the user's request, after T1/T2/T4 have landed, so the audit runs against a tree where
`--yolo`, `/yolo` and the queueless renames are already done rather than against a prediction of it.

Deleting a flag, a REPL command and two unreachable branches strands code in three distinct ways,
and each wants a different answer:

1. **Dead** — reachable from nothing but its own spec, and its reason for existing died with the
   flag. Purge it, and its spec with it.
2. **Orphaned but wanted** — a real capability whose only caller was the deleted flag. Wire it to
   the live path that should have had it, or say why nothing should.
3. **Load-bearing under a stale name** — reached by `--non-interactive`, which T4 renames. Not this
   card's, already covered; the audit must not double-touch it.

Take the `lib_reach` delta as the primary instrument: capture the report before and after the yolo
cards, and every method that newly appears in it is a candidate. `Approval::PolicySwitch` writers,
`Switchboard`'s private helpers, and anything under `cli/command/` that only `/yolo` reached are the
named places to look first.

**Acceptance criteria**

```gherkin
Scenario: nothing in lib/ is reachable only from a deleted caller's spec
  Given the lib_reach report from before the yolo cards
  And the report from after them
  When the two are compared
  Then every method the deletion newly orphaned is either purged or wired
  And the audit names which, for each

Scenario: the suite's example count falls only by the examples the audit deleted
  When the suite runs after the purge
  Then the count equals the post-T22 count minus the examples the audit removed
  And no example fails
```
→ spec file: none new; the card deletes specs or adds wiring specs as its findings dictate.

**Escalation triggers**
- **A purge is a deletion, and a wrong one is silent.** If a candidate's only caller is a spec but
  its docstring claims a production reason, stop and report rather than deleting — that is the
  dormant-feature shape this plan exists to fight, and deleting it hides the same defect the other
  way round.
- Anything the audit wants to WIRE is a capability change, not a cleanup. Stop and hand back the
  proposal; the orchestrator decides.
- `Env::NoApprovals` and `RedactSecretReads::Unqueued` are T4's and are **load-bearing** via
  `--non-interactive`. If the audit flags either as dead, its reachability model is wrong — stop.
- Do not extend the audit past what the yolo deletion exposed. Pre-existing dead code is a real
  finding but a different card; list it, do not purge it.


### T26 — Purge the derived switch Env projects and no command reads   [wave 3] [risk: medium]

**Depends on:** T25 (which found it), T1, T2, T4
**Files:** `lib/lain/cli/command/env.rb`, `lib/lain/cli/command/surface.rb`,
`lib/lain/cli/switchboard.rb` (the `surface_kwargs` line only), `lib/lain/approval/policy_switch.rb`
and `lib/lain/telemetry/switches.rb` (docstrings only), `lib/lain/cli/wiring.rb` (one comment),
and the specs that construct or read the member.
**Reuse:** `Switchboard`'s own `attr_reader :policy_switch` (`switchboard.rb:68`), which is live and
is where the one-queue identity can be re-anchored.
**Shared-file wiring:** none.
**Reachable from:** deferred: this removes reach rather than adding it.

T25's audit found `Command::Env#policy_switch` is the **only one of Env's thirteen members with zero
`lib/` readers**. Its sole reader was `Command::Yolo`, deleted by T2.

**It is not orphaned-but-wanted, and wiring it would be wrong.** `policy_switch` is not a peer of
`mode_switch` — it is **downstream** of it. `Switchboard#apply` (`:311`) does
`@policy_switch.switch(resolution.gate_policy, surface:)`, and `#apply` is what `/mode` reaches via
`mode_switch` → `BoundSwitch`. A mode flip *causes* the policy flip: `mode_switch` is intent,
`policy_switch` is the derived consequence. Commands express intent; the Switchboard derives the
gate. `/yolo` was the anomaly — it reached past the derivation and wrote the derived value directly,
which is the two-writers-for-one-slot problem `/mode` exists to avoid. So Env exposing it flattens a
derived value next to its own cause, and a `switches:` collaborator merging the three would hide that
rather than justify it.

**The one assertion worth keeping must survive.** `wiring_spec.rb:1176-1181` reaches through
`env.policy_switch` to pin that **the session has ONE queue** — the ladder's `surfaces` rung parks on
the same object `/approve` drains. Re-anchor it through the Switchboard, which owns the switch, so
the check survives the member.

Also correct the docstrings that record the superseded design as current: `surface.rb:33-34`'s
fail-open justification is false for this member (`/mode` never reaches the gate through
`env.policy_switch`); `telemetry/switches.rb:5,13` still say "/yolo's policy" and "A /yolo gate flip";
and T25 flagged `policy_switch.rb:88-89` and `wiring.rb:430` as making claims that are now false
rather than merely stale-named.

**Acceptance criteria**

```gherkin
Scenario: the command Env no longer carries a switch no command reads
  Given a command Env assembled by the live wiring
  Then it exposes no policy_switch reader
  And every member it does expose has a reader in lib/

Scenario: the session still has exactly one approval queue
  Given a board built by the live wiring
  When the ladder's asking rung is asked what queue it parks on
  Then it is the same object /approve drains

Scenario: a forgotten switch is still a loud failure
  When a Surface is constructed without one of its required switches
  Then it raises ArgumentError at construction
```
→ spec file: `spec/lain/cli/wiring_spec.rb`, `spec/lain/cli/command/env_spec.rb`,
`spec/lain/cli/command/surface_spec.rb`

**Escalation triggers**
- If any reader of `env.policy_switch` turns up in `lib/` or `exe/`, the premise is wrong — stop.
- If the one-queue assertion cannot be re-anchored without reaching into a private, stop and say so
  rather than dropping it: that check is what stands between a future rewiring and a session with two
  queues where `/approve` drains the wrong one.
- Do NOT touch `Switchboard#policy_switch` itself, or the Gate's use of it (`switchboard.rb:194`), or
  `toolset_build.rb:105`. Those are live.


## Integration checks

After the last wave:

- `bundle exec rake pspec` green, and **check the example COUNT against the pre-chunk baseline**,
  not just the failure count (CLAUDE.md: a dead worker and an OOM kill both look like a pass).
- `bundle exec rubocop` (bare, no path argument — never name a `.toml`) and
  `pre-commit run --all-files`.
- `cargo test && cargo clippy --all-targets -- -D warnings` — untouched by this chunk, run as a
  regression guard.
- **The deletion sweep — `command grep`, both excludes.** A bare `grep` here is a gitignore-aware
  shell function that answers 0 regardless, which is a check that cannot fail:

  **Sweep on the flag and the symbols, NOT on the bare word** — `"yolo"` is also a legitimate
  fixture string for an unknown epic gate policy (`spec/lain/config/epics_spec.rb:30,31,56`,
  `spec/lain/config/gates_spec.rb:25,26,75,77,211,214`) and appears in `config/epics.rb:118`. A
  bare-word sweep can never reach zero and is therefore not a check:

  ```bash
  command grep -rnE -- '--yolo|/yolo|YoloApprovals|:yolo\b' \
    lib/ spec/ exe/ docs/ README.md ARCHITECTURE.md
  #   -> EXACTLY three lines, all in spec/lain/config/, all the Ruby regex literal /yolo/ used as
  #      an unknown EPIC GATE POLICY fixture (gates_spec.rb:26,:214, epics_spec.rb:31).
  #      Nothing else. Those three are unrelated to the flag and must survive.

  command grep -rnE -- '--yolo|/yolo' planning/qa/                        # -> nothing (16 today)

  command grep -rlE -- '--yolo|/yolo|YoloApprovals' . \
    --exclude-dir=.claude --exclude-dir=.git   # -> only historical findings + chunk specs
  ```

  `ROADMAP.md` retains only the historical M1b line (`:148`). Baseline measured 2026-08-23: 163
  bare-word hits across `lib/ spec/ exe/ docs/ README.md ARCHITECTURE.md`, 16 under `planning/qa/`,
  186 files tree-wide once `.claude` and `.git` are excluded.
- `lain chat --yolo` exits nonzero. Measured 2026-08-23: with no `check_unknown_options!` anywhere,
  Thor answers `ERROR: "lain chat" was called with arguments ["--yolo"]` — an **arity** refusal, not
  an unknown-option one, so assert the exit status and the stray-argument shape rather than those
  words. `lain up . -- --yolo` refuses at launch through `Up::ChatPreflight` (`up.rb:295`), which
  really runs the child.
- `lain help chat` mentions no `--yolo` and no longer calls `--isolation` inert.
- **Manual pass (T23), on the real binary** — the one check no spec makes: in a sandbox cockpit at
  the default posture, ask the model to `cat` a protected path and confirm the ladder denies at
  triage with no approval parked. Then confirm an ordinary `bash` call still gates normally, which
  is the control that stops "it denies everything" reading as a pass.
- **A compaction record carries `collapse_strategy`** (T24) — the check that F51 is discharged
  rather than half-landed. Drive one compacting session and read the record.
- **The dead-code audit (T25) named every orphan and said purge-or-wire for each**, and the
  post-chunk `tmp/lib_reach_report.txt` has no entry that the yolo deletion created.
- Re-run round 10's close-out negatives, since T19 moves the file two of them watch: XDG leak with
  its positive control, `git status` against baseline with the **real** `HOME` (P16), and
  `ls -d $LAIN_REPO/.lain`.

### T24 — Journal the strategy on every compaction   [wave 2] [risk: medium]

**Depends on:** T18
**Files:** `lib/lain/compaction/scheduler.rb`, `lib/lain/compaction/source.rb`, and their specs
**Reuse:** `ran_under:` on `Scheduler#pipeline` — round 9's own card names it as the exact precedent
for a per-call keyword.
**Shared-file wiring:** none.
**Reachable from:** `Agent#step:494 → Source#context_for → #weigh:387 → #commit:442` — the path every
compacting turn takes.

Absorbed from round 9 (its T6), and **it is what makes F51 observable**. Round 9's T4 landed the
`collapse_strategy` member (`ff53028e`) and T18 lands the wiring that carries the operator's word to
the source; without this card the field exists, the value reaches the source, and **no compaction
record ever carries it** — F51 stays half-discharged behind a green suite, which is precisely the
dormant-feature shape this plan is written against.

**Acceptance criteria**

```gherkin
Scenario: a compaction record names the strategy that ran
  Given a session launched with --compact-strategy elide-tools
  When a compaction fires
  Then the journalled compaction record carries collapse_strategy "elide-tools"

Scenario: the default strategy is named too, not left blank
  Given a session launched with no --compact-strategy
  When a compaction fires
  Then the record names the strategy that actually ran
```
→ spec file: `spec/lain/compaction/scheduler_spec.rb`, `spec/lain/compaction/source_spec.rb`

**Escalation triggers**
- Round 9's T4 already shipped the member. If `Telemetry::Compaction` has no `collapse_strategy`,
  the premise is wrong — stop, because that means `ff53028e` is not what it claims.
- Compaction needs volume to fire; if the AC cannot be driven without a real compacting session,
  assert at the `Scheduler#pipeline` seam and say so rather than faking a record.

## Close-out (2026-08-24)

**All 24 planned cards landed, plus T25's escalation as T26 and a close-out gap as T27 — 24 commits.**
Suite `15368 examples, 0 failures, 15 pendings` against a pre-chunk baseline of `15203/0/15`; the
count rose by 165 and never fell. `rubocop` 1375 files clean; `cargo test` 9 passed, `clippy
--all-targets -D warnings` clean. `lain chat --yolo` exits 1 with Thor's arity refusal; `lain help
chat` names no `--yolo` and no longer calls `--isolation` inert; `planning/qa/` has zero flag hits;
`lib/` retains exactly two, both deliberate.

**F63 is closed at the default posture.** `cat ~/.ssh/id_rsa` denies at the triage rung, journals
`rung: "triage", verdict: "deny", faulted: false`, and parks nothing for a human.

### What the panel caught that a green suite would have shipped

- **The plan's own T3 instruction was a bypass.** It mandated falling back to `Triage::AnyPath` on
  any classifier error; `AnyPath` protects nothing and `cwd` is model-controlled, so
  `cwd: "bad\0dir"` returned F63 verbatim. AC 3 had pinned the bypass as correct, and the first
  implementation's spec asserted it. Card and code both amended; the fallback is now a
  session-anchored `Sensitivity` built from wiring-controlled values.
- **Three cards shipped a green suite over an unexercised AC** (T18, T24, and round 9's T6 half),
  each found by mutation on the production path rather than by reading.
- **T11's `--project` escalation was wrong**: `Paths#project_hash` does raise, three ways
  `rescue SystemCallError` never sees, one of them on the card's own cited line.
- **T19's `HOME` fix was measurement-invalid** — the probe injected a fake env while the process env
  was healthy; `Dir.home` returns a relative `HOME` verbatim, so F50 reproduced *after* the fix.
- **T21 introduced a never-blank violation into the renderer whose job is never being blank**
  (`dirname` above the degrade logic).
- **T14 sent the QA driver to the wrong posture**, where `plan`'s read-only permits refuse `bash`
  before the ladder sees it — silently voiding F63's control arm.
- **T23 quoted a refusal the binary does not emit**; the rung's reason never leaves the Journal.

### Owed to round 11 — carried, not lost

1. **The triage rung's deny needs the WHOLE command literal.** `Triage#literal` is reached only on
   `decision.allow?`, so any `Shell::Verdict` abstention — a quote, a tilde, a `$` expansion, a glob,
   or a second command after `&&` — skips the argv check entirely. `cat <key> && echo hi` carries a
   bare absolute path byte-identical to the denied spelling and is approved anyway. Five `OPEN:`
   examples pin each spelling in `auto_surface_spec.rb`.
2. **`Triage` prices its abstention as "already reaches a human". Under `--auto-approve` it reaches a
   model** whose prompt is never told a protected path is in the argv, polling every 0.05s.
3. **`/mode auto` still reaches `Gate::ApproveAll`** — open by decision, as planned.
   **T13's implementer proposes 1–3 are ONE card:** a pre-gate `Sensitivity::PATH_FIELDS` argv
   refusal sits outside the Gate, so it is unliftable by `ApproveAll` *and* nothing ever parks for
   `AutoSurface`. Worth taking.
4. **Two unliftable refusals, two operator experiences.** `Sensitivity#refuse` names the path and
   says no approval can lift it; the unliftable ladder rung renders byte-identically to an ordinary
   posture deny (`Gate::DENIAL`).
5. **`Paths#sessions_dir` is an accessor that `mkdir_p`s on read** — measured at 8354 directories,
   8329 empty, in the operator's real home, growing during the round. Call sites:
   `Journal.default_path`, `cli/command/surface.rb:115`. The spec-author rule ("a spec that builds a
   `ProjectDir` and asks for `state_path` now reaches the real `ENV`") belongs in
   `docs/toolchain-traps.md` with it.
6. **`grep` silently truncates.** `grep.rb:130-139`'s rescue ends the FILE, not the line, and is
   locale-independent: one binary line makes every later match vanish, `is_error: false`. File it
   against the **`ArgumentError` arm only** — the `SystemCallError`/`IOError` arm is the documented,
   intended skip. `grep.rb:131` (the locale half) is a separate one-word fix; `grep.rb:247` is latent
   only on `CoreSearch`.
7. **`bash.rb:114`** carries F62's crash on Canonical's *other* arm (not-convertible, ASCII-8BIT),
   locale-independent. A fix must handle both arms.
8. **`escalation.rb:150-168` is stale doubly** — says `triage:` "waits on a call site" and that
   `rules:` "is empty"; both false at the production call site.
9. **`RedactSecretReads::Unqueued` remains the single fail-open** in an otherwise fail-closed
   unattended run, now documented and pinned by a seam that will go red when round 11 flips it.
10. **Cop headroom at zero:** `Frontend::TTY` 110/110 ClassLength, `Source#initialize` 10/10
    MethodLength. The `Data.define` ClassLength counting trap belongs in `docs/toolchain-traps.md`.
11. **`lain up --isolation nope`** passes preflight and fails inside the tmux pane, where a dead-pane
    banner eats the cause.
12. **A path recipe implemented three times in three languages** drifted the same way twice: T20 and
    T21 each stripped a trailing `/` from `XDG_STATE_HOME` and forgot `$HOME`. Worth making
    executable rather than prose.

### Manual pass still owed

`planning/qa/scenarios/secret-boundary.md` §5 and §5b are written and landed but **have not been
driven by a human against the real binary**. That is the one check no spec makes.
