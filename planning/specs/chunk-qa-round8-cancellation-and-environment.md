# Say what happened: cancellation, capability, and the child environment

status: draft
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson

## Intent

Discharge QA round 8 (`planning/qa-findings-round8-2026-08-21.md`, F40–F49 plus MODEL-2), the
round-7 residue round 8 never drove, and one process defect in the QA method itself.

**Six of these findings share one shape: the system knows a fact and never says it.** A tool call
that was cancelled leaves a `tool_use` with no result rather than a record saying it was cancelled
(F46). A compaction that has permanently stopped increments a streak counter nothing reads (F47). A
provider with no prompt cache is reported as `saving $0.000000` (F49). A model that emitted its tool
call as prose lands on the *healthy* `end_turn` arm (MODEL-2). A refusal names a remedy the human
cannot reach while `/rewind` — which already works — goes unmentioned (F48). An approval parked for
a human renders nowhere once a sibling surface answered the first one (F40). In every case the
mechanism is sound and the *witness* is missing, which is why a green suite of ~14,000 examples sees
none of them.

Alongside that, one finding is a fix that was written and never generalised: `Grader::TestHarness`
already scrubs lain's own bundler environment out of a child process, with a class doc naming the
exact hazard — and `Tools::Bash`, the tool the model actually uses, never got it (F45).

That becomes **`Lain::Exec`**: a name for a question the code already answers twice without naming
it — *how does a command get executed?* `Tools::Bash` runs in process through `Mixlib::ShellOut`;
`Tools::CoreExec` runs the same `Bash::Input` out of process through lain-core. Those are two
backends of one seam, and this chunk names it, gives it the scrub F45 needs, and adds a third:
a bare-bones `docker run`.

**It is deliberately NOT under `Lain::Isolation`.** That module answers a different question — how a
*worker* gets a *workspace* — and the main chat pointedly does not use it: `wiring.rb:293-296` says
*"Only actor-mode subagents lease: `#run_state` builds the main chat's Session on `WorkerEnv.default`
deliberately, because the user's own edits belong in the user's own tree,"* and `exe/lain:843-845`
records that `--isolation` *"is inert in chat today"*. A container backend added there would be
reachable only from actor-mode subagents nothing constructs — a second inert flag beside the one
already documented as inert.

## Grounding

Verified against the working tree on **2026-08-21** by reading the code, not the findings. Four
parallel exploration passes; where they disagreed with the findings document, the code won.

**F46's stated cause is WRONG and is corrected here.** The findings say the per-ask iteration
ceiling orphans the `tool_use`. It cannot: `Budget#check_iterations!` runs at the top of `#step`
(`agent.rb:401`), *before* `call_model`, so it cannot interleave between the assistant commit
(`agent.rb:433`) and the tool_result commit (`agent.rb:516-517`). The journal agrees — the five
`run_interrupted` records in `records/journal-rails-blog.ndjson` follow **25, 25, 25, 25 and 12**
`turn_usage` respectively; the first four are the ceiling and each left the record clean, and the
one that stranded `call_f4eu93ak` came after **12**. The window that can strand a call is
`agent.rb:433 → 517`, reachable by `Budget#interrupt` → `Async::Task#stop` (Ctrl-C, `shutdown.rb:169`;
grace expiry, `shutdown.rb:170`), by the token ceiling (`agent.rb:437`, unarmed in chat), or by a
raise out of `transition`/`perform_tools`. **The exact trigger in the QA session is not identified**
— no Ctrl-C was sent — and T3 is written against the window rather than against any one trigger.
Every *consequence* in F46 is reproduced and stands.

- **F40 confirmed, with the reason no spec catches it.** `ApprovalPolicy#watch` is
  `loop { answered(queue.dequeue) }` (`approval_policy.rb:81-83`); `#decide` (`:91-94`) calls
  `@reader.call` with no `decided?` re-check and no way to abort. `Pending#decide`
  (`approval/queue.rb:184-192`) resolves `@promise` — which wakes only the **gated** fiber; nothing
  signals surface watchers. `dequeue` (`:281-284`) skips decided pendings only at dequeue time.
  `@arrivals` is an `Async::Queue` (`:232`), so one arrival reaches exactly one waiter.
  **`pending.await` is public and resolves on decide, so a racer needs no new primitive.**
  Precedent for a bounded terminal-ish read: `shutdown.rb:283-288`.
  The two-surface seam spec (`approval_policy_spec.rb:197-297`) gates two calls but its reader
  always returns; the real-editor spec (`neovim_runtime_spec.rb:401-455`) parks the reader forever
  with `sleep(60)` but gates **one** call. The defect lives in the gap between them.
- **F42/F43/F44 are one seam.** `open_at_rest` (`10_folds.lua:67-72`) returns line 1 only for
  `QUESTION`; every other view re-opens the fold holding the **last** line, which for
  `lain://approval` is the key-hints trailer. `foldtext` (`:186-193`) returns `getline(v:foldstart)`
  when `span == 1` — the empty string for a blank trailer, which nvim pads with the `fold:`
  fillchar. `set_approval` (`62_approval.lua:122-132`) opens a window at `rows > 0` and **there is
  no `nvim_win_close` anywhere under `runtime/`**. Ruby side: `ApprovalView` `WIDTH = 96`,
  `INDENT = "  "`, `ELISION = "..."`, `lines_for` at `:467-472`.
- **F45: the fix exists one seam over.** `Grader::TestHarness::FRAMEWORK_ENV`
  (`test_harness.rb:64`) = `/\A(?:BUNDLE_|BUNDLER_|RSPEC_|RUBYOPT\z)/`, applied at `:110-117` over
  the union of live `ENV` and the worker env. Its class doc (`:19-32`) names the hazard verbatim.
  `Tools::Bash` passes `environment: worker_env.env` (`bash.rb:201-212`) with no scrub;
  `WorkerEnv.default` snapshots the whole `ENV` (`worker_env.rb:47-51`); `exe/lain:28-32` is where
  `BUNDLE_GEMFILE` is set. The removal lever is documented at `worker_env.rb:9-18`: *"Absent key:
  leaks; explicit nil: scrubs."* `Tools::Bash` is the **only** file under `lib/lain/tools/` that
  spawns in process; `Tools::CoreExec` has the same posture out of process (`core_exec.rb:28-35`).
  There are **five** separate `GIT_CONTEXT_SCRUB`-shaped constants (`isolation/worktree.rb:47-59`,
  `project/dotfiles.rb:78-89`, `workspace/snapshot/scope/shadow_git.rb:111-116`,
  `project/resolver.rb:55-56`, plus `handback` reusing worktree's) and no shared home.
  `spec/lain/cli_spec.rb:321-400` already proves this hazard for `exe/lain` and records that
  **clearing `RUBYOPT` alone is not enough** — `BUNDLER_SETUP` is read from `gem_prelude`.
- **F47 confirmed exactly.** `@consecutive` is seeded (`derived.rb:85`), reset (`:129`) and
  incremented (`:163`) — and **read nowhere in `lib/`**; the only consumers of
  `derivation_refused` are two specs. `README.md:298` states the streak's purpose with no
  implementation behind it. `since_compaction` is written by `StatusFeed#measures`
  (`status_feed.rb:465-469`) and rendered by nothing — `cli/up/hud.rb:77-82` projects only
  `cache_deadline`, `fleet`, `inbox_count`, `approvals_pending`, `occupancy`, `mode_lighter`.
  `PromptComposer::RunState#to_h` (`prompt_composer.rb:382-385`) carries no compaction variable.
- **F48's mechanism.** `Resume#fork` calls `refuse_mid_tool!` (`resume.rb:105`), whose sentence
  hardcodes `"cannot resume "` (`resume.rb:47-54`). `Resume` *has* a `fork_refusal` formatter
  (`:183-185`) but it is used only for `Corrupt`/`MissingObject`/ENOENT (`:117-123`), so the
  torn-head path bypasses it. **`pending_tool_use?` is defined twice** — `resume.rb:58-61` and
  `rewind.rb:119-122` — and consumed by three doors (resume, fork, rewind).
- **Rewind already works and is already helpful.** `Rewind#settled_target!`
  (`rewind.rb:104-117`) refuses only when the *target* is the torn turn, and it computes
  `nearest_valid` (`:128`) and names the valid landing points in the refusal. So "decline to
  re-dispatch and continue from the last settled state" is a shipped capability; it is simply never
  mentioned by the refusal a human actually meets.
- **F49's two lines come from one detector reading two things.** `cache_rewrites`
  (`report.rb:148-153`) calls `Bench::Rewrites.from_journal`, which reads **only** `request_sent`
  digest chains (`rewrites.rb:62-67`) — no cache fields — so it fires on ollama as on Anthropic.
  `CacheWaste` uses the same detector (`cache_waste.rb:380`) but multiplies by
  `cache_creation_input_tokens` (`:383`), which ollama always reports as 0
  (`provider/ollama/decoding.rb:91-93`), so `rebilled_tokens` sums to zero and `report.rb:184`
  routes to the "none" note. **"none" therefore means "the billed cache-creation tokens were zero",
  not "no break occurred".** `saving_on` (`:396-402`) returns `Dollars.zero` for zero read tokens,
  so a cacheless provider gets a confident `saving $0.000000`. `CacheWaste` has **no** reference to
  any capability. `Telemetry::CapabilityDegraded` (`telemetry/turn_stream.rb:292-299`) is written at
  `capability/policy.rb:87-91` and IS read offline by `bench/session/loader.rb:308-312` — the
  precedent exists; `agent_build.rb:131-145` records that nothing in a live chat consumes it. The
  contradictory pairing is asserted in no spec; `cache_waste_spec.rb`'s header says the all-zero
  case is *deliberately avoided*.
- **MODEL-2's silence has a named cause.** A prose tool call carries no `tool_calls`, so
  `decode_stop_reason` (`ollama/decoding.rb:81-89`) returns `:end_turn` and the turn lands on the
  **healthy** arm of `Agent::LoopMachine`; `FAILURE_REASONS` is never reached.
  `Agent#commit_and_account` (`agent.rb:424-439`) inspects content nowhere. The nearest existing
  concern is `parse_arguments` (`ollama/decoding.rb:71-75`) — *"a String must never reach the
  Timeline"* — which is the same class of wire-shape violation, in the same file.
- **Round-7 residue.** `51_thread.lua:639` still `error()`s deliberately so a `BufWriteCmd` reports
  failure; the traceback and hit-enter modal ride back with it, and a panel measured that leg at
  `{"mode"=>"r","blocking"=>true}` with the next RPC round trip timing out. Round 7's own verdict:
  closing it needs a way to fail a write without raising out of the callback — *"a card and not a
  line"*.

## Panel corrections folded in

Reviewed 2026-08-21; verdict **request-changes**, four BLOCKERs, all fixed here. Recorded because
three of the four were premises the code contradicted, and a later reader should see they were
caught rather than never raised.

- **`/rewind` is not reachable from the refusal that would name it.** `Rewind#call(args, env)`
  (`rewind.rb:29-34`) reads `env.timeline` and `env.agent` — a live REPL — while
  `refuse_mid_tool!` fires before one exists. The first draft's T5 would have shipped a refusal
  naming an unreachable remedy, which is the defect it claimed to fix. The reachable remedy is
  `lain chat --fork SESSION@<earlier settled digest>`: `Resume#fork` (`:101-106`) checks out first
  and refuses second, so an earlier digest forks clean today.
- **The "five duplicated git scrubs" were two decisions and a placeholder.**
  `project/resolver.rb:34-38` says its constant *spawns nothing* and exists for a future card that
  does; `project/dotfiles.rb:77-82` explicitly declines to share the worktree constant, with a
  reason. That consolidation card is **cut** (Open decision 2).
- **Repair at load is simpler and strictly more complete than repair at the tear**, and it matters
  because Open decision 4 admits the triggering interrupt is unidentified — an in-process unwind
  handler cannot see SIGKILL, OOM or reactor teardown. T3 is now the load-side repair and is the
  card that discharges F46; T6 is the tear-time improvement.
- **T12's "tell the human" AC was unreachable and made an undecidable AC load-bearing.**
  `Frontend::Decorators.for` (`decorators.rb:34-39`) has two clauses and no listed card adds a
  third. Dropped; the card is journal-only and the precision goal is demoted.
- Also fixed: T4's Reuse line stated the two `pending_tool_use?` copies were byte-equivalent — they
  are not, and the difference is load-bearing (below). T10's dependency on T3 was narrative, not
  code. T7 listed one file for a method with three callers. T3's "gate 2" citation was
  misattributed. T13's spec target already exists. T14's evidence path is outside the repo.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb`, `lain.gemspec`,
  `.rubocop.yml`, `spec/spec_helper.rb`.
- **`lib/lain/prompt/default.toml` is orchestrator-owned for this chunk.** T10 needs one new
  variable in its `format` string. CLAUDE.md records that naming this file on a `rubocop` command
  line silently stripped `format = `; the orchestrator applies that diff and re-reads the file.
- **Three wave-1 cards (T1, T12, and T6 in wave 3) each need one `require` line in `lib/lain.rb`.**
  That file is load-order sensitive — a load-time `NameError` means the entry is too early — so
  those three hand back through one needle. Wave 1 is ten cards in the graph and about eight in
  practice.
- No deviations from the default review process. T2, T7, T13 and T6 are `risk: high`.

## Open decisions

1. **`Lain::Exec` ships with three backends, so the seam is exercised rather than speculative.**
   `Exec::Local` (in-process `Mixlib::ShellOut`), `Exec::Core` (the existing lain-core RPC arm,
   which today is a separate tool rather than a backend) and `Exec::Docker` (T2). The panel's
   speculative-generality objection was aimed at a one-implementation seam; three answers it. **It is
   deliberately not under `Lain::Isolation`** — see Intent for the two code comments that make a
   container backend there unreachable from chat.
2. **The git-context scrub consolidation is CUT, not deferred.** The first draft proposed collapsing
   five constants; two of them are documented decisions to stay separate and one spawns nothing at
   all. Re-proposing it needs a reason those comments are wrong, not a duplication count. It would
   also have edited `isolation/worktree.rb` and `handback.rb`, which back the suite's slowest spec
   file and two of CLAUDE.md's named load-induced flakes.
3. **No salvage of a malformed tool call (T12).** A mis-parse would execute a call the model never
   properly expressed, and tier-3 gating does not help when the parse itself is wrong. T12 reports;
   it does not repair, and it does not render to the human.
4. **The interrupt that tore the QA session is unidentified.** T3 repairs at load, which is why that
   does not block the chunk: a load-side repair is trigger-agnostic. T6 covers the in-process case
   it can see.
5. **An explicit human retry affordance at resume is DEFERRED**, at the user's direction. With T3
   the session resumes and the model is told its call was cancelled, so the model re-calls if it
   wants. Revisit if a QA round shows the model failing to re-attempt a torn call. This is a
   decision, not an oversight.
6. **T9 leaves one question for its implementer to answer in the open, not in a trigger:** the Q
   event is written before the park (`ask_human.rb:531-537`), so a question with no possible answer
   already exists in the record by the time EOF is seen. What that should look like — a matching
   refusal event, or nothing — is a Journal-shape decision and needs an AC, not a silent choice.

## Waves

Wave 1: T1, T4, T7, T8, T9, T10, T11, T12, T13, T14  (no unmet deps)
Wave 2: T2 (←T1), T3 (←T4)
Wave 3: T5 (←T3), T6 (←T3)

Critical path: **T4 → T3 → T5** (and T4 → T3 → T6), three deep.

## Tasks

### T1 — Name `Lain::Exec` and stop leaking lain's own toolchain into every child  [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/exec.rb` (new), `lib/lain/exec/local.rb` (new), `lib/lain/exec/core.rb` (new),
`lib/lain/tools/bash.rb`, `lib/lain/tools/core_exec.rb`, `lib/lain/grader/test_harness.rb`
**Reuse:** `Grader::TestHarness::FRAMEWORK_ENV` (`test_harness.rb:64`) and its union-of-live-ENV
application (`:110-117`) — the existing correct implementation, **moved rather than rewritten**.
`WorkerEnv`'s documented nil-value lever (`worker_env.rb:9-18`). `spec/support/with_env.rb`.
**Shared-file wiring:** one `require` line for `lain/exec` in `lib/lain.rb`, after `worker_env`.
**Reachable from:** `exe/lain:28-32` sets `BUNDLE_GEMFILE` → `Wiring#chat_env` (`wiring.rb:248`)
→ `Session#worker_env` → `Tools::Bash#build_shell_out` (`bash.rb:201-212`), constructed at
`cli/wiring/base_tools.rb:19`. Live on every gated shell call in any `lain chat`.

**The scrub belongs on the backend, not on `WorkerEnv.default`.** `WorkerEnv` is a value that
isolation-leased workers also carry (`isolation/worktree.rb:125`); scrubbing at
`Wiring#chat_env` would miss those. Scrubbing in the backend covers every caller.

**Acceptance criteria:**

```gherkin
Scenario: a child command does not inherit lain's own Gemfile
  Given a process whose BUNDLE_GEMFILE names lain's own Gemfile
  When the bash tool runs a command that prints its BUNDLE_GEMFILE
  Then the command reports none

Scenario: the whole framework family goes, not one variable
  Given a process carrying BUNDLE_GEMFILE, BUNDLER_SETUP, RUBYOPT and RSPEC_OPTS
  When the bash tool prints its environment
  Then none of those four names appears

Scenario: a variable the session deliberately lent is still delivered
  Given a session whose worker env sets a marker variable
  Then the command reports the lent value

Scenario: GEM_HOME survives, because the child still needs to find gems
  Given a process carrying GEM_HOME
  Then the command reports the inherited value

Scenario: the out-of-process backend scrubs identically
  Given the same process environment
  When the same command runs through the core backend
  Then both backends report the same environment
```
→ spec file: `spec/lain/exec/local_spec.rb`, `spec/lain/exec/core_spec.rb`,
`spec/lain/tools/bash_spec.rb` (extends `describe "worker env (session-lent env and cwd)"` at
`:124-209`)

**Escalation triggers:**
- `spec/lain/tools/bash_spec.rb:169` ("leaks a host env var the injected WorkerEnv omits — additive
  override, not confinement") asserts the current leak as intended. This card narrows *what* leaks.
  Confirm it stays true for non-framework vars; do not silently delete it.
- **The core backend's scrub must stay an explicit `nil`, not an omission.** `core_exec.rb:25-36`
  records that the env map merges over *the daemon's* inherited environment — and the daemon is
  lain's own child, so it already carries `BUNDLE_GEMFILE`. An omission works in process and
  silently regresses out of process.
- `Grader::TestHarness` keeps `GEM_*` deliberately (`test_harness.rb:19-32`). If moving the constant
  tempts you to widen it, **stop** — that changes which gems a child can find.
- If the move changes any assertion in `spec/lain/grader/test_harness_spec.rb:53-58`, stop: it was
  meant to be behaviour-preserving there.

### T2 — A bare-bones `docker run` execution backend  [wave 2] [risk: high]

**Depends on:** T1
**Files:** `lib/lain/exec/docker.rb` (new), `lib/lain/exec.rb`, `lib/lain/cli/exec_backend.rb` (new),
`exe/lain`
**Reuse:** `CLI::IsolationBackend` (`cli/isolation_backend.rb`) as the **shape** for a validated
`--flag <name>` resolver — its "a bad flag is refused here, not at the first acquire" doctrine
applies verbatim. `Isolation::Compose` (`isolation/compose.rb`) already shells to docker and is the
precedent for how this repo invokes it.
**Shared-file wiring:** none — `exe/lain` is not on this chunk's shared list and only T2 touches it.
**Reachable from:** a new `--exec` flag on `lain chat` resolved by `CLI::ExecBackend`, threaded to
`Tools::Bash`/`Tools::CoreExec` through the same construction site T1 uses
(`cli/wiring/base_tools.rb:19`). **This card is what makes the seam real**; without it `Lain::Exec`
has one shape and the panel's speculative-generality objection stands.

**Deliberately bare.** One `docker run --rm` per command, the project mounted, the scrubbed
environment passed through. No image building, no lifecycle, no daemon reuse, no networking policy.
The point is a second backend that genuinely differs, not a container story.

**Acceptance criteria:**

```gherkin
Scenario: a command runs inside the container
  Given the docker backend configured with an image
  When a command that prints the kernel hostname runs
  Then the hostname is not the host's

Scenario: the project is visible to the command
  Given a project directory and the docker backend
  When a command lists the working directory
  Then the project's files are present

Scenario: the framework scrub applies here too
  Given a process carrying BUNDLE_GEMFILE
  When a command prints its environment inside the container
  Then BUNDLE_GEMFILE is absent

Scenario: an unusable backend is refused at launch, not at first call
  Given a docker backend named with no docker available
  When the session is launched
  Then it refuses by name and exits non-zero
  And no session is created

Scenario: the default is unchanged
  Given no exec flag
  Then commands run through the local backend exactly as before
```
→ spec file: `spec/lain/exec/docker_spec.rb` (tagged `:seam`, skipped without docker),
`spec/lain/cli/exec_backend_spec.rb`

**Escalation triggers:**
- **A container is not a security boundary and this card must not imply one.** CLAUDE.md is explicit
  that an "in-process sandbox is not a sandbox"; the same honesty applies here. If the flag's help
  text or any docstring starts describing confinement guarantees, stop — the tier-3 approval gate is
  still the boundary.
- Docker availability is environmental. Follow `IsolationBackend`'s rule and refuse at **resolve**
  time; a `docker: command not found` surfacing mid-run as a tool error buries what the operator got
  wrong.
- `spec/support/tags.rb` gates `:nvim` on a version probe — follow that shape for docker rather than
  inventing a skip. If CI has no docker, this spec must skip, not fail.
- If mounting the project read-write turns out to let a container write files the host approval gate
  never saw, **stop**: that is a gate bypass and a different card.

### T3 — Repair a torn head when the session is loaded  [wave 2] [risk: medium]

**Depends on:** T4
**Files:** `lib/lain/cli/resume.rb`, `lib/lain/bench/session/loader.rb`
**Reuse:** T4's shared predicate. `Tool::ResultBlock` (`tool/result_block.rb:63`) — the only mint
site for a `tool_result` block. `Approval::Queue`'s vocabulary for a decision nobody made
(`TIMEOUT_SURFACE`, `ABANDONED_SURFACE`).
**Shared-file wiring:** none
**Reachable from:** `CLI::Resume#rebuild` and `#fork` — `lain chat --resume` / `--fork`, and the
`/fork` slash command via `cli/command/fork.rb:67`.

**This is the card that discharges F46.** When a loaded session's head is an assistant `tool_use`
with no results, project a cancellation `tool_result` into the rebuilt timeline so the chain is
valid: the session resumes, compaction derives, and the model is told its call was cancelled.

**The journal is not rewritten.** The repair is a *projection* decision made while rebuilding an
in-memory timeline for a new session; the NDJSON keeps the honest torn record. That is what
separates this from the fabrication `refuse_mid_tool!` rightly refuses — nothing claims the tool
produced output, and nothing edits what was witnessed.

**Why at load rather than at the tear.** It is trigger-agnostic. Open decision 4 records that the
interrupt which tore the QA session is unidentified, and a load-side repair covers SIGKILL, OOM and
reactor teardown, which no in-process handler can see.

**Acceptance criteria:**

```gherkin
Scenario: a session torn mid-tool resumes
  Given a journal whose head is an assistant tool_use with no results
  When the session is resumed
  Then it resumes rather than refusing

Scenario: the same session forks
  Given the same journal
  When it is forked at its advertised head
  Then it forks rather than refusing

Scenario: the rebuilt chain is valid
  Given the same journal
  When the session is rebuilt
  Then the conversation validates with no unanswered tool_use

Scenario: the model is told, and told nothing false
  Given the same journal
  Then the projected result reports the call as cancelled
  And it reports no output for the tool

Scenario: the journal on disk is unchanged
  Given the same journal
  When the session is resumed
  Then the journal file's records are byte-identical to before

Scenario: an untorn session is projected exactly as before
  Given a journal whose tools all returned
  Then no cancellation result appears in the rebuilt timeline
```
→ spec file: `spec/lain/cli/resume_spec.rb`, `spec/lain/bench/session/loader_spec.rb`

**Escalation triggers:**
- **`refuse_mid_tool!` may become unreachable for torn heads.** If so, decide explicitly whether it
  stays as a backstop for shapes the repair cannot handle or is deleted — and if it stays, T5 still
  applies. Leaving a dead refusal with a wrong verb is the worst of the three outcomes.
- `Bench::Session::Loader` is also the **bench** rebuild path (`bench/variance.rb`,
  `Compare::Run`). A repair that changes what a recorded session replays as would change bench
  numbers. If the repair must be resume-only, say so and site it accordingly.
- If `Context::Conversation#valid?` (`conversation.rb:192-193`) rejects the projected block for a
  reason other than pairing — a `:missing_tool_id`, a content-shape rule — stop: guessing at the
  block's shape produces a chain that passes here and fails at the provider.

### T4 — One definition of "the head is a tool_use awaiting results"  [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/event.rb`, `lib/lain/cli/resume.rb`, `lib/lain/cli/command/rewind.rb`
**Reuse:** the two existing copies, `resume.rb:58-61` and `rewind.rb:119-122`.
**Shared-file wiring:** none
**Reachable from:** `CLI::Resume#rebuild` and `#fork`, `CLI::Command::Fork#anchor!`,
`CLI::Command::Rewind#settled_target!` — four live doors.

**The two copies are NOT equivalent, and the difference is load-bearing.** `rewind.rb:119-122` opens
with `!head.nil? &&`; `resume.rb:58-61` does not. `nearest_valid` (`rewind.rb:127-130`) evaluates the
predicate over `(1..heads.length)`, and `heads[heads.length]` is `nil` — so adopting resume's
spelling makes every torn-head refusal die with `NoMethodError` on the exact path T5 then builds on.
**Adopt rewind's spelling.**

**It is a predicate on an `Event`, not on a `Timeline`** — `nearest_valid` calls it over arbitrary
events off `timeline.ancestors.to_a`, not over a head. That is why `lib/lain/event.rb` is the home.

**Acceptance criteria:**

```gherkin
Scenario: one definition, four doors
  Given the repository after this card
  When lib/ is searched for a predicate testing an assistant head for an unanswered tool_use
  Then exactly one definition exists

Scenario: a torn head answers true
  Given an assistant event carrying a tool_use and no result
  Then the predicate answers true

Scenario: a nil head answers false rather than raising
  Given no event at all
  Then the predicate answers false

Scenario: a settled head answers false
  Given the user event carrying the tool results
  Then the predicate answers false

Scenario: an ordinary text answer answers false
  Given an assistant event carrying only text
  Then the predicate answers false

Scenario: the rewind refusal still names its valid landing points
  Given a chain whose head is torn
  When a rewind targets it
  Then the refusal names at least one valid target
```
→ spec file: `spec/lain/event_spec.rb`, `spec/lain/cli/command/rewind_spec.rb`

**Escalation triggers:**
- The nil case above is not hypothetical — it is reached on every `nearest_valid` call. If your
  implementation drops the guard, `rewind_spec`'s existing refusal examples are what should fail;
  if they do not, the spec is not covering the boundary and that is its own finding.
- `spec/lain/event_spec.rb` asserts no `Turn` constant remains (CLAUDE.md). Adding a predicate to
  `Event` must not reintroduce turn-shaped vocabulary.

### T5 — Make the torn-head refusal name its own door and a reachable remedy  [wave 3] [risk: low]

**Depends on:** T3
**Files:** `lib/lain/cli/resume.rb`, `lib/lain/cli/command/fork.rb`
**Reuse:** `Resume#fork_refusal` (`resume.rb:183-185`) — the existing formatter this path bypasses.
**Shared-file wiring:** none
**Reachable from:** `lain chat --fork` / `--resume`, and `/fork` (`cli/command/fork.rb:67`).

**The remedy is `--fork SESSION@<earlier settled digest>`, NOT `/rewind`.** `Rewind#call`
(`rewind.rb:29-34`) needs a live REPL (`env.timeline`, `env.agent`) and this refusal fires before one
exists. `Resume#fork` (`:101-106`) checks out *before* refusing, so an earlier digest forks clean.

**Scope note.** After T3 this refusal fires only for shapes the repair cannot handle. If T3's
escalation concludes it fires never, this card becomes a deletion — which is a fine outcome and
should be taken deliberately rather than leaving a dead refusal with the wrong verb.

**Acceptance criteria:**

```gherkin
Scenario: the fork door says fork
  Given a session this chunk's repair cannot rebuild
  When it is opened with --fork
  Then the refusal names the fork door

Scenario: the resume door says resume
  Given the same session
  When it is opened with --resume
  Then the refusal names the resume door

Scenario: the remedy named is one the human can actually reach
  Given the same session
  When either door refuses
  Then the refusal names forking at an earlier settled digest
  And it does not name a command that needs a live session

Scenario: both doors exit non-zero with no backtrace
  Given the same session
  Then the process exits non-zero
  And no backtrace frame is printed
```
→ spec file: `spec/lain/cli/resume_spec.rb`, `spec/lain/cli/command/fork_spec.rb`

**Escalation triggers:**
- `spec/lain/cli/command/fork_spec.rb:90-92` pins the child-side refusal on `/awaiting tool results/`
  — "in the child's own words". Keep that example meaningful.
- `resume.rb:39-46` argues fork and resume must face "the SAME refusal verbatim ... one predicate,
  one wording". This card splits the **verb** while keeping one predicate; update that comment. If it
  argues the shared wording is load-bearing beyond DRY, stop.

### T6 — Commit a cancellation result at the tear, so the model learns mid-run  [wave 3] [risk: high]

**Depends on:** T3
**Files:** `lib/lain/agent.rb`, `lib/lain/agent/tool_runner.rb`,
`lib/lain/telemetry/tool_cancelled.rb` (new)
**Reuse:** T3's cancellation block shape — the two must agree, and T3 defines it.
`Async::Task#defer_stop` as already used at `agent.rb:425`.
**Shared-file wiring:** one `require` line for `lain/telemetry/tool_cancelled` in `lib/lain.rb`.
**Reachable from:** `Agent#perform_tools` (`agent.rb:516-517`) on every tool-calling turn.

**This is the improvement, not the fix.** T3 already makes a torn session usable. What T6 adds is
that the *running* model is told its call was cancelled, in the turn where it happened, instead of
finding out only if someone resumes.

**The `defer_stop` question is settled and the implementer should not re-derive it.**
`Async::Task#defer_stop` (`async/task.rb:384-414`) resets its tri-state guard in both the
`rescue Cancel` arm and the `ensure`, so entering a *fresh* `defer_stop` while unwinding from a
`Cancel` arms correctly; a concurrent cancel during that region returns false rather than raising
(`:345-349`). `Async::Stop = Async::Cancel < Exception` (`async/stop.rb:9`). The commit can be made
to survive its own interruption.

**Acceptance criteria:**

```gherkin
Scenario: a tool that finished keeps its own result
  Given a turn carrying three tool_use blocks
  When the run is stopped after the first has returned
  Then the first block's result is the tool's own output
  And the other two report cancellation

Scenario: every unanswered call is answered
  Given the same turn
  Then all three tool_use blocks have results
  And the conversation validates

Scenario: cancellation before dispatch is distinguishable from after
  Given one run stopped before its tool was dispatched
  And another stopped while its tool was running
  Then the two results differ in what they claim about effects

Scenario: an ordinary completed turn gains nothing
  Given a turn whose tools all returned normally
  Then no cancellation result appears
```
→ spec file: `spec/lain/agent_spec.rb`, `spec/lain/agent/tool_runner_spec.rb`,
`spec/lain/seams/tool_cancellation_spec.rb`

**Escalation triggers:**
- **`ToolRunner#run` (`tool_runner.rb:87-95`) accumulates blocks into a LOCAL via `flat_map`.** On an
  unwind every block is lost, including completed tools'. The first AC exists because the obvious
  implementation replaces a finished tool's real output with "cancelled" — fabrication in the
  direction this chunk is otherwise careful about.
- **`tool_runner.rb:115-138` argues the current behaviour is correct**: *"An interrupt never reaches
  here at all, so a stopped turn commits exactly what it always did AND leaves every digest still
  summarizable."* That is the comment this card contradicts, and it carries an `Oracle::Eager`
  digest-spending consequence. Read it and address the consequence, do not just edit past it.
- `delivery` (`:108-111`) pairs blocks with `causal_parents: answered_questions`, and
  `answered_questions` (`:176-179`) is a **destructive** harvest. Decide whether a cancellation
  commit harvests; a half-harvest silently drops an answered question's consumption edge.
- If T6's block shape diverges from T3's, **stop** — two shapes for one fact is how the two repairs
  come to disagree.

### T7 — Let the terminal approval surface abandon a prompt another surface answered  [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/frontend/approval_policy.rb`
**Reuse:** `Pending#await` (`approval/queue.rb:202`), which already resolves on decide.
**Shared-file wiring:** none
**Reachable from:** `CLI::Repl::ApprovalSurfaces#approval_surface` (`approval_surfaces.rb:63-67`),
spawned per line at `:103-110`, in every interactive `lain chat`.

**The concurrency question is settled.** `Promise#await` (`promise.rb:47-49`) →
`Async::Variable#wait` → `Async::Condition#wait`; `Condition#signal` does
`ready.num_waiting.times { ready.push(value) }`, so **every** parked waiter is woken, and a waiter
arriving after resolution finds `@condition` nil and returns immediately. A second fiber awaiting the
same `Pending` is safe and no new primitive is needed.

**The racer belongs in `#answered`, not `#decide`.** `#decide` has three callers:
`#answered`; `CLI::Command::Approve#call` (`approve.rb:29`); and `CLI::Command::Surface`
(`surface.rb:71`), which uses the **default** reader `prompt_and_read` (`:163-167`) — a
thread-blocking `@input.gets` with no reactor. `Async::Task.current` raises there. `#answered` is the
only caller with both a task and a scheduler-routed reader.

**Acceptance criteria:**

```gherkin
Scenario: a second gated call prompts after the first was answered elsewhere
  Given two gated calls parked on one queue
  And a terminal reader that never returns
  When another surface decides the first call
  Then the terminal surface prompts for the second call

Scenario: answering at the terminal is unchanged
  Given a gated call parked on the queue
  When a human types y at the terminal
  Then the call is approved
  And the decision is signed by the terminal surface

Scenario: an abandoned prompt records no decision and no fault
  Given a gated call answered by another surface while the terminal read is outstanding
  Then the terminal surface records no decision for that call
  And no fault is journaled against it

Scenario: an unanswered call still fails closed
  Given a gated call nobody answers
  When the queue's window elapses
  Then the call is denied

Scenario: the non-reactor caller still works
  Given the approval surface used outside a reactor with its default reader
  When a parked call is decided through it
  Then it behaves as it did before this card
```
→ spec file: `spec/lain/frontend/approval_policy_spec.rb`,
`spec/lain/frontend/neovim_runtime_spec.rb`

**Escalation triggers:**
- **If the new example passes against the unmodified `approval_policy.rb`, it is the wrong example.**
  The two existing specs each cover half: `approval_policy_spec.rb:197-297` gates two calls but its
  reader always returns; `neovim_runtime_spec.rb:429` parks the reader with `sleep(60)` over exactly
  one call. An AC must combine *reader never returns* **and** *two pendings*.
- **Abandonment must not travel as a `StandardError`.** `#answered` (`:119-124`) rescues
  `StandardError` and denies with `FAULT_SURFACE`; a raise-based abandonment would journal a spurious
  `tty_fault` against a call another surface *approved*. That is the third AC.
- `spec/approval_consumer_discipline_spec.rb:52-65` is a Ripper lint allowlisting
  `approval_policy.rb` as the sole `#dequeue` consumer in `lib/`. The racer adds none; if yours does,
  that lint wants a written justification first.
- `approval_policy_spec.rb:87` pins today's "no-op on an already-decided pending" where the reader
  still runs and returns. Confirm whether it survives.
- If abandoning leaves Reline's terminal state dirty — half-drawn prompt, swallowed keystroke — or
  leaves `Conductor`'s countdown ticker stopped (`conductor.rb:154-160` restores only
  `@reply_outstanding`), **stop** and report both.

### T8 — The approval buffer shows the command, and its blank line stays blank  [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/frontend/neovim/runtime/10_folds.lua`,
`lib/lain/frontend/neovim/runtime/62_approval.lua`
**Reuse:** `open_at_rest`'s existing QUESTION branch (`10_folds.lua:67-72`) — this adds a second
form, it does not invent the distinction. **`60_question.lua:157` carries a comment explaining that
`:close`, `:enew` and `nvim_win_close` do not behave as expected under `bufhidden = "hide"`** — read
it before writing the close path; it is the only prior art in `runtime/`.
**Shared-file wiring:** none
**Reachable from:** `ApprovalView#posted` (`approval_view.rb:440-450`) calls `set_approval` on every
render; folds install at `BufWinEnter` (`10_folds.lua:205-216`).

**Three symptoms, one seam.** `lain://approval` is a **form**, not a log — its live record is its
*first*, exactly as `lain://question`'s is — so `open_at_rest` must not re-open the key-hints trailer
and leave the pending command folded behind a truncated summary. `foldtext` must not return the empty
string for a blank trailer, which nvim renders as a bar of fold fillchars. And a window opened
because rows appeared must close when they are gone.

**Acceptance criteria:**

```gherkin
Scenario: the parked command is readable without opening a fold
  Given one approval parked whose command is longer than the summary width
  Then the command text is visible on screen

Scenario: the key hints do not steal the open fold
  Given one approval parked
  Then the row holding the pending call is not folded closed

Scenario: a blank trailer renders as a blank line
  Given an approval buffer with a blank line between the rows and the hints
  Then that line renders as blank rather than as fold fill

Scenario: the window closes when the queue empties
  Given an approval window opened because a call was parked
  When every parked call has been decided
  Then the approval window is no longer displayed

Scenario: a window the human opened themselves is not taken away
  Given a human has opened the approval buffer in a window of their own
  When the queue empties
  Then that window remains

Scenario: rows fold independently of one another
  Given two approvals parked
  When one row is opened
  Then the other row's fold state is unchanged
```
→ spec file: `spec/lain/frontend/neovim/approval_view_spec.rb` (extends
`describe "the fold surface, in a real editor", :nvim, :seam` at `:730-861`)

**Escalation triggers:**
- **A text read cannot see fold state.** The existing `fold_state` helper
  (`approval_view_spec.rb:772-784`) runs `foldclosed` inside `nvim_win_call` for exactly that reason;
  an AC asserted with `getbufline` asserts nothing.
- `05_records.lua:32-42` records a **measurement** proving the blank trailer must answer
  `spanning_record` true or nothing folds at all. Change only what `foldtext` renders. If you find
  yourself editing `CONTINUATION` or `spanning_record`, stop.
- `approval_view_spec.rb:577-597` is a cross-language drift guard comparing `05_records.lua`'s
  `CONTINUATION` to `ApprovalView::INDENT`. It must keep passing.
- Knowing "did lain open this window" needs state that survives a render. `10_folds.lua:17-24`
  records that `:vsplit` copies window *options* but not window *variables*; choose accordingly and
  say why.

### T9 — EOF at the reply prompt refuses instead of writing an answer nobody gave  [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/cli/human_replies.rb`, `lib/lain/tools/ask_human.rb`
**Reuse:** `Tools::AskHuman::Unattended::REFUSAL` (`ask_human/unattended.rb:24-27`) — the sentence and
the doctrine already exist for `--non-interactive`, which is the same condition by another door.
`Approval::Queue::ABANDONED_SURFACE` is the sibling precedent for "decided by nobody".
**Shared-file wiring:** none
**Reachable from:** `Reply#read` (`human_replies.rb:1049-1052`), reached from `AnswerLoop#exchange`
on every parked `ask_human` in a live chat.

`read` does `read_reply(...).to_s`, collapsing nil (EOF — no human will ever answer) into `""` (a
human pressed Enter). The second is a deliberate, documented answer (`human_replies.rb:613-620`); the
first is journaled as a `message` record `from: "human"` with `payload: {"answer": ""}` — a human
utterance in a session with no human attached.

**Acceptance criteria:**

```gherkin
Scenario: EOF writes no answer attributed to a human
  Given a parked ask_human and a closed stdin
  Then no message record attributed to the human is written

Scenario: EOF tells the model nobody is attached
  Given the same conditions
  Then the ask_human call returns an error result saying no answer will come back

Scenario: the loop takes another turn rather than parking
  Given the same conditions
  Then the agent dispatches a further turn carrying that error result

Scenario: a typed blank line is still an answer
  Given a parked ask_human
  When a human presses Enter on an empty line
  Then that is delivered as the answer
  And a message record attributed to the human is written

Scenario: the record says what became of the unanswerable question
  Given the same EOF conditions
  Then the journal distinguishes this question from one a human answered emptily
```
→ spec file: `spec/lain/cli/human_replies_spec.rb`, `spec/lain/tools/ask_human_spec.rb`

**Escalation triggers:**
- **The typed-blank-line behaviour is deliberate** (`human_replies.rb:613-620`). If your change
  cannot distinguish EOF from a typed blank line at this seam, stop — collapsing them the other way
  is worse than the defect.
- There is an **existing asymmetry**: the drain (`:1220-1223`) already treats `""` as "nothing typed"
  while `read` treats it as an answer. Reconcile deliberately; do not leave three readings of EOF in
  one class.
- The Q event is written before the park (`ask_human.rb:531-537`), so it exists by the time EOF is
  seen. The last AC is Open decision 6 — answer it in the plan's terms, not by silent choice.
- `Tools::AskHuman::Unattended` has **no spec file**. Reusing its refusal makes that gap
  load-bearing; consider closing it here.

### T10 — Say when compaction has stopped  [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/status_feed.rb`, `lib/lain/frontend/prompt_composer.rb`,
`lib/lain/compaction/source/derived.rb`
**Reuse:** `PromptComposer`'s elide-rather-than-zero convention (`prompt_composer.rb:344-346`) and the
`#fleet`/`#mode` shape (`:408-422`).
**Shared-file wiring:** one new variable in `lib/lain/prompt/default.toml`'s `format` string, applied
by the orchestrator.
**Reachable from:** `PromptComposer` renders the prompt line on every `you>`; `StatusFeed` writes
`.lain/state.json`, which `cli/up/hud.rb` projects into the tmux status line.

`derivation_refused` carries a `consecutive` streak whose stated purpose (`derived.rb:155-161`,
`README.md:298`) is to distinguish "one awkward turn" from "a session that has stopped" — and nothing
reads it. After T3 this state is rarer; a state that is rare and silent is worse than one that is
common and silent.

**Acceptance criteria:**

```gherkin
Scenario: a healthy session says nothing about compaction
  Given a session whose compactions are succeeding
  Then the prompt line carries no compaction-stalled reading

Scenario: a repeatedly refused derivation is surfaced
  Given a session whose derivation has been refused several times in a row
  Then the prompt line reports that compaction is stalled

Scenario: the reading clears when a compaction succeeds
  Given a session that was reporting a stall
  When a derivation succeeds
  Then the prompt line stops reporting it

Scenario: the state file carries the streak for a non-terminal reader
  Given a session whose derivation has been refused
  Then the state file reports the streak
```
→ spec file: `spec/lain/status_feed_spec.rb`, `spec/lain/frontend/prompt_composer_spec.rb`

**Escalation triggers:**
- **Name the channel before writing either end.** `@consecutive` is private state on a per-turn
  `Compaction::Source::Derived` writing to its own `@journal` (`derived.rb:164`); `StatusFeed` learns
  through `#<<(event)` (`status_feed.rb:289-299`); `PromptComposer::RunState` reads
  `@status_feed.state` (`:382-385`). **If those are not the same channel, this card ships a state
  field nothing feeds and a segment that never renders** — the F28 shape this codebase has hit three
  times. Establish the connection first and say what it is.
- **Do not name `lib/lain/prompt/default.toml` on a `rubocop` command line** (CLAUDE.md).
- `StatusFeed#observed` (`:459-464`) deliberately excludes `since_compaction` from the change token
  (rationale `:446-453`). If the new field belongs in the token, revisit that reasoning explicitly.
- The prompt line is a snapshot printed once per prompt, not a live widget. If that latency makes the
  reading misleading rather than late, say so — a one-time notice at the crossing is a different
  design and may be the right one.
- Choosing the threshold is a judgement. State it and its reason; 2 and 3 are both defensible.

### T11 — Report what the cache did, and say which question each line answered  [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/friction/cache_waste.rb`, `lib/lain/friction/report.rb`
**Reuse:** `Telemetry::CapabilityDegraded` (`telemetry/turn_stream.rb:292-299`), journaled at
`capability/policy.rb:87-91` and already read offline by `bench/session/loader.rb:308-312`.
`PriceBook`'s refusal-over-a-confident-zero doctrine (`price_book.rb:48-50`).
**Shared-file wiring:** none
**Reachable from:** `CLI::Friction` (`cli/friction.rb:23-26`) for `lain friction SESSION`;
`CLI::Improve` (`cli/improve.rb:80`) is the second consumer.

`cache_rewrites` reads only `request_sent` digest chains, so it fires on any provider;
`cache_waste` multiplies the same rewrites by `cache_creation_input_tokens`, which a cacheless
provider always reports as 0 — so the report says `4 prefix rewrites detected` and, two lines later,
`none -- no prefix break was re-billed`. Both true; neither says which question it answered.
Separately `saving_on` (`:396-402`) returns a confident `saving $0.000000` for a provider with no
cache at all.

**Acceptance criteria:**

```gherkin
Scenario: a provider with no prompt cache is named as such
  Given a session journal recording that prompt caching was degraded
  Then the cache section says the provider does not cache
  And it reports no dollar saving

Scenario: the two cache lines each say what they measured
  Given a session with prefix rewrites and no billed cache creation
  Then the rewrite line and the waste line do not contradict each other

Scenario: a caching provider is unaffected
  Given a session with real cache reads and a re-billed prefix break
  Then the waste figure and the tokens-served figure are reported as before

Scenario: a clean caching session still states it was clean
  Given a caching session with no prefix break
  Then the section appears and says so rather than being omitted

Scenario: a journal that never recorded the capability is not guessed at
  Given a journal carrying no capability_degraded record
  Then the report does not claim the provider caches
```
→ spec file: `spec/lain/friction/cache_waste_spec.rb`, `spec/lain/friction_spec.rb`

**Escalation triggers:**
- **`saving_on` carries a reasoned comment this card overturns** (`cache_waste.rb:394-395`: *"Zero
  tokens at an unknown rate is exactly zero, so an unpriced model only taints a figure that had
  tokens behind it"*). Address the argument; do not edit past it.
- `cache_waste_spec.rb:17-20` states its fixtures use **non-zero** cache fields on purpose, because
  all-zero fixtures "would let every assertion here pass while asserting nothing". Add a case; do not
  relax the file's premise.
- `capability_degraded` is written on the **live chat** path only. A recorded or hand-assembled
  journal may not carry it, and absence must not read as "this provider caches" — that is the last
  AC.
- `cache_rewrites` does not segment per model while `CacheWaste` does (`:302`), so the counts
  legitimately differ across a `/model` switch. Reconciling must not paper over that.

### T12 — Notice when the model writes its tool call as prose  [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/provider/ollama/decoding.rb`,
`lib/lain/telemetry/malformed_response.rb` (new)
**Reuse:** `parse_arguments` (`ollama/decoding.rb:71-75`) is the existing home for "the wire handed us
the wrong shape" — *"a String must never reach the Timeline"*. This belongs beside it, in the provider
that knows its own model family's failure modes.
**Shared-file wiring:** one `require` line for `lain/telemetry/malformed_response` in `lib/lain.rb`.
**Reachable from:** `Provider::Ollama#complete` decodes every response on the live chat path;
`backend.rb:199` passes the run journal in, so the record is journaled in production.

The local model emits `<function=bash>…</function>` as assistant **text** on roughly half of first
turns (3 of 6, identical prompts, fresh sessions). With no `tool_calls`, `decode_stop_reason`
(`:81-89`) returns `:end_turn` and the turn lands on the *healthy* arm — nothing notices, nothing is
journaled, the ask is a silent write-off.

**Journal-only, deliberately.** An earlier draft also rendered this to the human, which made a false
positive expensive and required a decorator no card owned (`decorators.rb:34-39` has two clauses).
Reporting to the journal costs a reader one grep and costs a false positive nothing.

**Acceptance criteria:**

```gherkin
Scenario: a prose tool call is journaled as malformed
  Given an ollama response whose text carries a function-call envelope and no tool calls
  When the response is decoded
  Then a malformed-response record is journaled naming what was found

Scenario: the turn is otherwise unchanged
  Given the same response
  Then the assistant text still reaches the timeline as it did before

Scenario: an ordinary text answer is untouched
  Given a response whose text is prose with no function-call envelope
  Then no malformed-response record is journaled

Scenario: a well-formed tool call is untouched
  Given a response carrying real tool calls
  Then no malformed-response record is journaled
```
→ spec file: `spec/lain/provider/ollama_spec.rb`, `spec/lain/telemetry_spec.rb`

**Escalation triggers:**
- **Precision is a goal, not a contract.** A model *explaining* `<function=bash>` and a model
  *emitting* it produce byte-identical text with no `tool_calls`; the distinction is undecidable in
  the degenerate case. Narrow it with structure (a well-formed closing envelope, a name in the live
  toolset, the envelope occupying the trailing content) and **record the residual false-positive
  rate in the card's notes**. Do not add a rendering path to compensate.
- This is a pattern for **one model family**. It belongs in `Provider::Ollama`, never in `Agent` or
  `Timeline`. If the implementation wants a hook above the provider, escalate.
- `lib/lain/provider/ollama/` deliberately has **no** `decoding_spec.rb` (`decoding.rb:30-34`).
  Follow that convention.

### T13 — Refuse a thread-pane write without raising out of the callback  [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/frontend/neovim/runtime/51_thread.lua`
**Reuse:** **`_G.__lain.review_refused` (`65_review.lua:236-247`) is a LOCAL `nvim_echo`, not an
RPC** — so it still delivers on the leg where `vim.rpcrequest` has just failed, which is precisely the
leg that still raises. `48_annotate.lua:520-541` is a working precedent for the exact shape
(`pcall(vim.rpcrequest, …)` → `review_refused(refusal)` → `return`).
**Shared-file wiring:** none
**Reachable from:** the thread pane's `BufWriteCmd`, reached by `:w` after `<leader>Lt` in the
`/survey` review flow.

`51_thread.lua:639` deliberately `error()`s so `:w` reports failure on the leg where a typed question
reached nobody. Round 7 judged that raise correct and recorded that the traceback and hit-enter modal
ride back with it — a panel measured `{"mode"=>"r","blocking"=>true}` with the next RPC round trip
timing out.

**A candidate answer nobody has written down:** set `vim.bo[buf].modified = true` after the handler
returns, so the buffer presents as unsaved without the callback raising.

**Acceptance criteria:**

```gherkin
Scenario: a question that reached nobody is refused in words
  Given a thread pane with a typed question that cannot be delivered
  When the buffer is written
  Then the refusal is rendered on the refusal rail
  And it names why the question was not sent

Scenario: the refusal does not raise a traceback
  Given the same conditions
  Then the editor messages contain no stack traceback

Scenario: the refusal does not block the RPC
  Given the same conditions
  Then the editor is not in a blocking prompt
  And a subsequent RPC call returns

Scenario: the write is not reported as successful
  Given the same conditions
  Then the buffer still presents as modified
```
→ spec file: `spec/lain/frontend/neovim/thread_view_spec.rb` — **which already exists** as a
real-nvim spec (`RSpec.describe Lain::Frontend::Neovim, "the review thread pane", :nvim` at `:77`,
1387 lines, with `describe "what it refuses"` at `:902`). Extend it; do not add a second harness.

**Escalation triggers:**
- **If the last two ACs prove genuinely irreconcilable, stop and escalate rather than shipping a
  write that lies about having succeeded.** Round 7 chose the traceback over that lie deliberately;
  reversing it silently would be worse than leaving the traceback.
- `51_thread.lua:625-631` argues for the current raise. If its argument survives the fix, update the
  comment rather than deleting it.
- That spec file is 1387 lines of real-nvim work. CLAUDE.md's MAX-not-sum rule means adding to it
  moves the suite's wall floor; if the addition is large, say so.

### T14 — Correct the QA record and the method that produced it  [wave 1] [risk: low]

**Depends on:** none
**Files:** `planning/qa-findings-round8-2026-08-21.md`, `planning/qa/method.md`,
`planning/qa/scenarios/rails-blog.md`
**Reuse:** this plan's Grounding section, which carries the corrected F46 analysis and its evidence.
**Shared-file wiring:** none
**Reachable from:** documentation only. Included because a findings document with a wrong cause is
worse than none — the next round reads it as settled.

Four corrections:

1. **F46's stated cause is wrong.** The evidence is the 25/25/25/25/**12** `turn_usage` split across
   the five `run_interrupted` records, and `Budget#check_iterations!`'s position at `agent.rb:401`.
   Rewrite against the `agent.rb:433 → 517` window and say the trigger is unidentified. **The journal
   is at `/home/tara/tmp/lain-qa-round8-2026-08-21/records/journal-rails-blog.ndjson` — outside the
   repo and outside any worktree.** An isolated agent must be given it or must say it could not check.
2. **P8** — `method.md`'s "refuse anything reaching outside the sandbox" is an enumerated deny-list,
   which is the wrong shape when the sandbox path is known. Make it an allow-list against `$QA`.
3. **P9** — a QA sandbox `GEM_HOME` reached `exe/lain`, which pins `BUNDLE_GEMFILE` to lain's own
   Gemfile, and bundler silently re-locked the repo's `Gemfile.lock`. Add the warning, and add
   **`git status` on the repo** to close-out — round 8 verified the sandbox negative and never looked
   at the tree it launched from.
4. **`rails-blog.md` §2** — its premise was not reached even in the scenario built for it (largest
   tool result 4,713 bytes, zero caps disclosed). Record that §1's volume came from turn *count*, not
   result *size*.

**Acceptance criteria:**

```gherkin
Scenario: the findings no longer blame the iteration ceiling
  Given the round-8 findings after this card
  Then F46 attributes the orphaned call to the dispatch window
  And it states the triggering interrupt is unidentified
  And it retains the evidence for every consequence

Scenario: the QA method refuses by allow-list
  Then the sandbox rule is expressed as an allow-list against the sandbox path

Scenario: close-out checks the repository it launched from
  Then the method's close-out includes git status on the repo

Scenario: the rails scenario separates its two volumes
  Then it distinguishes turn count from tool-result size
  And records that the result-size premise is still unreached
```
→ spec file: none — documentation. Verified by reading and by integration check 7.

**Escalation triggers:**
- If your own reading of the journal disagrees with this plan's Grounding on the 25/25/25/25/12
  split, **stop**: the correction would then be wrong, which is the failure this card exists to fix.
- If the journal is unreachable from your worktree, **say so and stop** rather than correcting F46
  from this plan's summary alone.
- Do not delete F46's consequences while correcting its cause. Every one was reproduced and is
  independent of the trigger.

## Integration checks

1. `bundle exec rake pspec` — full suite green. **Baseline measured 2026-08-21 before any card:
   14,926 examples, 0 failures, 15 pending, 37s at `LAIN_SPEC_WORKERS=12`.** Check the example
   *count*, not just the exit status; CLAUDE.md records that a dead worker looks like "fewer
   examples, 0 failures".
2. `bundle exec rubocop` (bare — never naming a `.toml`), `cargo test`,
   `cargo clippy --all-targets -- -D warnings`, `pre-commit run --all-files`.
3. Discipline specs specifically: `spec/approval_consumer_discipline_spec.rb` (T7),
   `spec/output_discipline_spec.rb`, `spec/lain/frontend/neovim/runtime_loader_spec.rb` (T8, T13),
   `spec/reply_surface_discipline_spec.rb` (T9).
4. **`git status` must be clean apart from the chunk's own changes** — see T14/P9. In particular
   `Gemfile.lock` must be unmodified.
5. **A manual pass is required**, because five cards fix things only a driver can see. Run
   `/manual-qa` over `failure-injection` + `session-and-window` + `cockpit-surfaces`, and:
   - **T7** — two gated calls in one ask; answer the first via `:LainApprove`; confirm the chat pane
     prompts for the second. Round 8's F40 reproduction.
   - **T8** — `cockpit-surfaces.md` §8's fold recipe against a parked approval with a long command.
   - **T13** — `cockpit-surfaces.md` §4b, which **no round has driven since round 7**.
   - **T3** — interrupt a session mid-tool (Ctrl-C during a slow `bash`), then resume it.
6. Re-run `lain friction` over a preserved ollama journal (T11) and confirm no dollar figure is
   quoted for a cacheless provider. The round-8 rails journal named in T14 is a suitable fixture.
7. **T1 end to end, outside the suite**: `lain up` on a bundler-managed project and have the model run
   `bundle exec rake -T`. Round 8 could not do this without a driver-side wrapper; after T1 it must
   work unaided. **This is the check that proves the defect is gone rather than scrubbed in a unit
   test.** Then repeat under T2's docker backend.
