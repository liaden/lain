# Where the record lives: locations, names, and a backend that only works on one client

status: done (2026-08-24) -- T2 committed as a26ee02b; T3/T5/T6/T7/T8/T9 absorbed by
`chunk-qa-round10-one-gate-one-record.md` as T17/T18/T24/T19/T20/T21 and all landed there
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson

## Intent

Discharge the code findings of QA round 9 — `planning/qa-findings-round9-2026-08-23.md` (F50–F54)
and its continuation `planning/qa-findings-round9-remaining-2026-08-23.md` (F55–F57).

**Most are one shape: a fact written somewhere it does not belong, or under a name that is not its
own.** Machine state that changes every turn is written into the user's source tree with no ignore
path, so every session dirties a git repo (F50). The compaction record names its trigger, its cache
state, its bytes and its dollars and never names the **strategy that ran** — the one axis
`--compact-strategy` exists to vary and the bench exists to compare (F51). A refusal about a survey
reasons about "a branch" (F56); a receipt for one note says "their markers" (F53); an approval's
key-hint line wears fold-fill characters (F52).

**One is not that shape and outranks the rest.** `Exec::Docker` hardcodes
`--user "#{Process.uid}:#{Process.gid}"`, correct for docker and **exactly inverted for rootless
podman**, where the host user is already container root. On a `podman-docker` host the backend
mounts the project and can then neither read nor write it, and two `:seam` specs go red — they
passed before only because they were **skipped** for want of a client (F57). That makes this the
first round-9 finding that leaves the suite red rather than merely dishonest.

**Not in scope, already discharged:** F54 and P11–P16 were corrections to `planning/qa/` and
`.claude/skills/manual-qa/`, applied in commit `07e0bef2`. No card should look for them in `lib/`.

## Grounding

Verified against the working tree on **2026-08-23** by four parallel exploration passes, direct
measurement, and a panel pass that **overturned four of this plan's own premises**. Where the plan
and the code disagreed, the code won; each correction is recorded below because the superseded
version is the intuitive one and will be re-proposed otherwise.

**Suite state at plan time: 15172 examples, 2 failures, 15 pending** — both failures
`spec/lain/exec/docker_spec.rb:355` and `:372`, both F57. The suite is green on a host with **no**
docker client, because the `:seam` block is gated by `DockerBackendAvailability`. **A card that
"fixes" F57 by re-skipping is a regression.**

**F57's cause, measured.** Same bind mount, rootless podman 6.1.0:

```
docker run --rm --user 1000 --volume $D:$D --workdir $D alpine sh -c 'cat seed.txt; touch made'
  -> uid=1000(tara)  cat: Permission denied   touch: Permission denied
docker run --rm         --volume $D:$D --workdir $D alpine sh -c 'cat seed.txt; touch made2'
  -> uid=0(root)     seed                     made2 lands on the host owned by tara
```

Omitting `--user` under podman satisfies the exact property `docker_spec.rb:372` asserts. `user:` is
already an injected keyword (`lib/lain/exec/docker.rb:110`, used at `:169`), and `ExecBackend#docker`
(`cli/exec_backend.rb:126`) passes **no** `user:` today, so a `nil` default is inert until something
supplies one.

**CORRECTION 1 — the client cannot be identified where this plan first put it.**
`CLI::ExecBackend#on_path?` (`exec_backend.rb:137-142`) returns a **Boolean and discards the
candidate path**; its `filesystem:` duck answers only `file?` and `executable?`. There is no
non-executing way to tell docker from podman-docker there, and `exec_backend.rb:20-29` argues the
no-spawn property as doctrine. `ExecBackend.resolve` also runs **twice** per launch
(`exe/lain:866` pre-flight and `cli/wiring/toolset_build.rb:307` wiring), so a probe there costs two
spawns per `lain chat`. **Resolution therefore lives inside `Exec::Docker`, lazily, on first
`#call`** — where a subprocess is already being spawned — with the prober injected. T1 owns it and
`ExecBackend` is untouched.

**CORRECTION 2 — threading the operator's string through `CLI::Backend` is forbidden by the cops.**
Measured by applying the minimal edit and running the real config, then reverting:

```
lib/lain/cli/backend.rb:23:5:        Metrics/ClassLength:  [111/110]   (Max: 110, .rubocop.yml:139)
lib/lain/compaction/source.rb:189:7: Metrics/MethodLength: [11/10]
```

Both are **at** their cap today. CLAUDE.md forbids loosening a `Metrics/*` limit, and
`backend/span_summarizer.rb:11-13` already records that `Backend` "sits at the `Metrics/ClassLength`
cap and was deliberately kept out of every card" in the previous chunk. **So the string must reach
`Source` without a new argument at `backend.rb:521` and without a new ivar in
`Source#initialize`.** The shape that does both: `SpanSummarizer.resolve` already reads
`@options[:compact_strategy]` (`span_summarizer.rb:78`) and already returns the strategy into
`Source`'s existing `strategy:` slot — so it returns a **choice** that carries the resolved strategy
*and* the operator's word, and `Source` keeps exactly the ivar it has. T5 owns that.

**CORRECTION 3 — the seam gate refuses to pull, so "an image not present locally" is untestable.**
`DockerBackendAvailability.unavailability` (`docker_spec.rb:33-39`) skips the whole block with
`"the image #{IMAGE} is not present locally -- run \`docker pull #{IMAGE}\`; a :seam spec must not
pull it"`. An AC needing an unpulled image is unreachable by construction, and satisfying it would
mutate a host-global image store shared by twelve `parallel_rspec` workers. T2 is therefore
**argv-level only**; the effect is checked by hand (integration check 3).

**CORRECTION 4 — `plugin/nvim`'s half of F50 is already written and already cross-pinned.**
`plugin/nvim/lua/lain/init.lua:68` computes `vim.fn.sha256(cwd):sub(1, 12)` — byte-for-byte
`Paths#project_hash`'s recipe — and `spec/plugin/nvim_plugin_spec.rb:202` asserts it equals
`Digest::SHA256.hexdigest(nvim_cwd)[0, 12]`. Lua is not a risk. **Shell is.**
`plugin/tmux/scripts/lain-status` is `#!/bin/sh`, `set -eu`, whose only optional dependency is `jq`
and whose documented contract is to never blank and never error; reproducing
`sha256(realpath(dir))[0,12]` there needs `realpath`/`readlink -f` **and** a sha256 binary, none
POSIX. **Plan-level decision: the tmux renderer is TOLD the path and never computes the hash.** It
already takes an optional `DIR` argument (`lain-status:5`, passed as `#{pane_current_path}` from
`plugin/tmux/lain.tmux:30`); T9 gives it a state-file path instead. See Open decision 4.

**F51's mechanism (unchanged, and confirmed).** The scheduler cannot name the strategy at emit time:
`#accounting` builds the record at `compaction/scheduler.rb:284` holding only `@compact`,
`@hard_cap`, `@journal`, `@model`, `@price_book` plus per-call `need`/`cold`/`history_size`/
`base`/`rewrite`/`ran_under`. `Source#commit` (`source.rb:442`) already threads `ran_under:` down
this exact path and is the precedent; `scheduler.rb:196-204` explains why a per-call value leaves
the `Ractor` shareability contract untouched. **Never capture the strategy object** — `Summarizing`
holds a live oracle and a mutable memo. The panel confirmed `Source::Derived`, `Derived::Outcome`
and `#weigh` need **no** change.

**F51's field is `collapse_strategy`, not `strategy`.** `Telemetry::ContextDerived` already has a
`strategy` member holding the **derivation class name** — a different axis, and two units under one
name in one NDJSON stream is the UX5 hazard `telemetry/compaction.rb:53-60` documents.

**F52's current shape is deliberate and spec-pinned.** Every line starts a record unless it begins
with two spaces (`runtime/05_records.lua:28`, `:53-55`), so the blank separator and the `HINT` line
each become their own one-line fold — intentional, per `05_records.lua:30-45`.
`approval_view_spec.rb:1023-1029` pins "leaves the key hints in a fold of their own". The defect is
in `foldtext()` (`runtime/10_folds.lua:208-217`), which pads to window width **only** for a blank
summary; the `span > 1` branch has the identical bug, invisible today only because record rows are
open at rest. T10 fixes the general statement, not the special case.

**F56's design is already settled in the file the card edits.** `Outbox#held_source`
(`outbox.rb:133`) returns `local_branch`/`github_pr`/`corpus`, and its docstring (`:123-128`) argues
**against** a kind test here: "Deciding here which word means what would put a kind test on the
object whose one responsibility is submission." So the fix is in the sentence — `%<label>s` already
says survey/branch/PR, and the constant should stop naming a second noun.

**F53 is one line.** `runtime/48_annotate.lua:335-337` singularises the noun and leaves
`"back; their markers go with them"` outside the conditional. Both receipt specs match only a prefix
(`annotate_spec.rb:833`, `:844`).

**Nothing in `lib/` writes a `.gitignore`**, confirmed by grep; `Epic::GitIgnores` (`cli/epic.rb:99-146`)
only reads, by shelling to `git check-ignore -v`, and its docstring states the policy. That is why
F50 is fixed by relocation rather than by a warning.

## Execution log (orchestrator, 2026-08-23)

**Baseline re-measured before wave 1, and it matches the plan exactly:** `15172 examples, 2 failures,
15 pendings`, the two failures being `spec/lain/exec/docker_spec.rb:355` and `:372`. **This host has
`podman-docker`** (`/usr/bin/docker` → `podman version 6.1.0`), so F57's seam examples RUN here rather
than skipping — integration check 2 is reachable on this box, and T1's fix is directly measurable.

**Trap, new, worth adding to `docs/toolchain-traps.md`:** `bundle exec rake pspec` was observed
**exiting 0 while printing `rake aborted!`** and a non-zero failure count. Score a suite run on the
printed `N examples, M failures` line, never on the exit status. This compounds the existing
"check the COUNT, not just the failure count" trap — there are now two ways a red `pspec` reads green.

**Orchestration incident: the first wave-1 spawn was discarded, no code lost.** The agent tool's
`isolation: "worktree"` cut all seven worktrees from `36aa11a4` (2026-08-20) — **48 commits behind
`main`**, predating the entire `Lain::Exec` subsystem (added in `6ab98dd2`), so T1's two files did not
exist in its tree at all. T1 detected it and escalated rather than improvising; the other six were
stopped before they could implement against stale code. Worktrees are now created by the orchestrator
directly from `main` at `.claude/worktrees/<card>` on `chunk9/<card>`, with the untracked 47MB
`lib/lain/lain.so` copied in (no card in this chunk touches Rust, so a per-worktree `rake compile` is
pure waste) and a per-card `TMPDIR` to keep the shared-mutable-state trap out of the wave.

**Staleness corrections applied to the cards, verified against `07e0bef2`:**

- **T1:** the positional assertion is `docker_spec.rb:90` (`argv.first(4)`) and the tail-safe one is
  `:96` (`argv.last(4)`). The card said `:87`/`:93` — three low.
- **T1, new measured fact the Grounding lacked:** `docker --version` prints `podman version 6.1.0` on
  **stdout** under `podman-docker`, with the shim banner on **stderr**. That is a discriminator which
  **contacts no daemon**, unlike `docker info`, which `docker_spec.rb`'s own header warns can hang.
  `docker version --format '{{.Client.Version}}'` returns a bare `6.1.0` with no vendor word and is
  **not** usable.
- **T1, the `freeze` question is answered:** `Exec::Docker` has **no** `Ractor.shareable?`, `frozen?`
  or `freeze` assertion anywhere in the suite, so the lazy-memoisation shape is a free design choice
  against the `freeze` at `docker.rb:115`.
- **T13:** there is no `Approval::Queue#ask`. The gate seam is `#call` (`queue.rb:252`) and
  `#adjudicate` (`:269`); `#dequeue` is `:281`, `#admit` `:298`.

### Wave 1 outcome

| card | verdict | note |
|---|---|---|
| T1 | APPROVE-WITH-FIXES (1 substantive) | **F57 fixed; suite green 15178/0/15.** Fix round: the probe ignored the caller's deadline (a `timeout: 1` call ran 10.4s and reported success). |
| T4 | APPROVE | 2 NITs handed to T5/T6. |
| T7 | in review | AC2 not met as written — see below. |
| T10 | APPROVE-WITH-FIXES → applied | Both fixes comment-only; verified the Lua delta is unchanged. |
| T11 | APPROVE, zero findings | |
| T12 | APPROVE | 2 cosmetic NITs. |
| T13 | APPROVE-WITH-FIXES → applied | Header overturned by the panel; prose corrected and re-verified. |

**Landing order is FORCED, and the plan did not say so.** `pre-commit`'s `ruby-checks` hook runs
`rake compile check`, i.e. the whole suite. While `main` carries F57's two failures **no commit in
this chunk can pass the hook**, so **T1 lands first** and unblocks the rest. T7 still cannot land in
wave 1 at all — the contract above squashes it with T8 and T9.

**A hard acceptance criterion for T6, from T4's panel:** every LIVE construction of
`Telemetry::Compaction` must pass `collapse_strategy:` explicitly and never rely on the `nil`
default. Otherwise "predates this field" and "T6 forgot" are the same value in the journal, and
F51's grouping cannot tell them apart. `scheduler.rb:284` currently relies on the default — that is
exactly what T6 must change. Verified: `"eager"` collides with no real leaf
(`STRATEGIES = %w[summarizing elide summarize-conversation elide-tools]`, `DEFAULT = "summarizing"`).

**Follow-ups this round opened, none of them in this chunk:**

1. **Approval arrival is unmeasured at arity three.** A queue that admits three pendings to
   `@parked` but never `@arrivals.enqueue`s them passes every example in
   `multi_pending_spec.rb` AND all three in `notify_spec.rb`, while `Frontend::ApprovalPolicy#watch`
   — the one sanctioned consumer — is handed nothing and **no human is ever asked**. Covered at
   arity one (`approval_spec.rb`) and two (`queue_concurrency_spec.rb`); nothing at three. Off
   limits for T13 by instruction, since round 8's F40 lives in `#dequeue`'s one-arrival-one-waiter
   FIFO and draining it in a spec consumes what a surface is owed.
2. **`NOT_A_PULL_REQUEST` sits outside the refusal width budget.** The plan asserted it "IS covered"
   by `spec/refusal_width_discipline_spec.rb`; T12 and its panel both measured otherwise —
   `RefusalWidthDiscipline.measured` returns `nil` for it, because it is raised via the
   `Outbox::Nowhere` exception and never crosses the `review_refused`/`refusable` rail sinks that
   spec's derivation traces. It renders at ~230 characters. A refusal a human reads, exempt from the
   budget every other refusal is held to.
3. **`rake pspec` can exit 0 while printing `rake aborted!`** — belongs in `docs/toolchain-traps.md`
   beside the existing "check the COUNT" entry. Two ways a red suite now reads green.

### Wave 2 outcome, and a lesson about the bench measuring itself

| card | state | note |
|---|---|---|
| T2 | APPROVE, landed pending a quiet box | `--quiet` on `RUN`. Panel measured that it removes pull narration and leaves stdout/stderr/failed-pull diagnostics byte-identical. |
| T3 | implemented, awaiting its own suite run | |
| T5 | in flight | |
| T8 | done | Shared `M.project_hash()` in Lua, cross-pinned byte-for-byte against `ProjectDir#state_path`. |
| T9 | done | Answered the design question this plan owed — see the Open decision 4 amendment. |

**THE ORCHESTRATION LESSON, recorded because it corrupted measurements this round.** Running four
agents that each run `bundle exec rake pspec` drove this 16-core box to **load average 214** with
seven concurrent `parallel_rspec` runs. Under that, commits fail on starved examples, and — worse —
**every flake RATE measured during it is inflated**. The handback panel could not reproduce that
card's claimed 20% before-rate in 14 consecutive runs, and contention is the likeliest reason the
original number looked as bad as it did.

The rule this round earned: **mechanisms are proven by forcing probes; rates are only trustworthy on
a quiet box.** Every flake fixed today was diagnosed by *forcing* the defect deterministically — a
gated `Surfaces#prime`, an instrumented autocmd dispatch log, a lock-sighting counter — and those
diagnoses stand regardless of load. The failure-rate figures beside them do not.

**So: serialize suite runs.** Agents get targeted spec files; the orchestrator does one authoritative
full run. This is a bench for studying orchestration tactics, and it just measured one of its own:
fan-out is free only until the fanned-out work contends for the same finite machine.

**Flake work this round (not in the plan, from a mid-chunk instruction to fix flakes rather than
route around them):** four investigated, all four diagnosed, **one real product bug found**.

1. `buffers_spec` re-attach — spec barrier that was a no-op for a second attach. **Landed.**
2. `thread_view_spec` cursor-following — `nvim_command` returning before `CursorMoved` dispatched.
   **Landed.**
3. `cli/review_spec` pair — **not flakes at all.** `SpecWatchdog::Stuck` misattributing a starved
   `git` subprocess to whichever example was current. The watchdog now reports **starved vs stuck**.
   **Landed.**
4. `worktree_handback_spec` — spec-side (detached `git maintenance` racing `Dir.mktmpdir` teardown),
   **and a real `Handback` data-integrity bug found while ruling the product out**: `#conflict`
   inferred "no merge started" from "no unmerged paths", but `rerere.autoupdate` STAGES a replayed
   resolution, so git exits nonzero on a merge it has already finished. Handback aborted it and
   reported `:failed` — permanently, since the retry replays the same resolution. Under review.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb`, `lain.gemspec`,
  `.rubocop.yml`, `spec/spec_helper.rb`.
- **`.rubocop.yml` is on that list and this chunk must not touch it.** Two cards run against
  metrics caps that are at their limit; the answer is a collaborator, never a raised `Max`.
- `spec/support/**` loads by glob from `spec/spec_helper.rb`, so a new support file needs no require
  line — but must not depend on load ORDER (the glob is alphabetical; see `spec_helper.rb:16-35`).
- **T7, T8 and T9 must land in one commit.** T7 moves a path two renderers read; landing it alone
  leaves both HUDs blank. The orchestrator squashes the three.

## Open decisions

1. **T13 is test-only and does NOT close F24's open half.** It pins `Approval::Queue`'s multi-pending
   behaviour in a spec. It cannot be driven from a manual QA round: `spec/support/**` is invisible to
   `exe/lain`, and `PROVIDERS = %w[anthropic ollama bedrock]` (`cli/backend.rb:58`) means
   `Provider::Mock` is not selectable from `--provider`. The cockpit property in
   `cockpit-surfaces` §5/§8 — five surfaces agreeing on three simultaneous pendings — stays
   unmeasurable, and closing it needs a production-reachable scripted-provider door that is **not**
   in this chunk.
2. **F57's fix keys on the client, not on rootless-ness.** Rootful podman behaves like docker, so a
   fix keyed on "is podman" is wrong there. T1 resolves by asking the client what it is; if a
   rootful-podman host becomes available, re-verify. Recorded as a known incompleteness.
3. **The podman shim's `Emulate Docker CLI using podman` banner is out of scope.** It is emitted by
   `/usr/bin/docker` before lain's argv is seen and is silenced only by `/etc/containers/nodocker`,
   which is host configuration. T2 removes the image-pull progress, which IS lain's to control.
4. **AMENDED 2026-08-23 — the tmux renderer computes the hash, in `lain.tmux`, per pane at render
   time. `lain-status` still computes nothing.** The original decision below assumed the path could
   be handed to the renderer. It cannot: `plugin/tmux/lain.tmux` is a **tpm entry point sourced from
   `tmux.conf`**, with no `lain up` anywhere in that flow, and `lain up` writes its own
   session-scoped `status-right` (`Up::Hud#jq_status_right` interpolates an absolute path via
   `set-option -t @session`), so `lain.tmux` is a SEPARATE consumer rather than a downstream of
   `up.rb`. And `#{pane_current_path}` is expanded by tmux **per pane at render time**, so nothing
   can be precomputed when the file is sourced.

   Hashing once at source time was considered and rejected: every pane outside that one directory
   would then render **another project's** HUD, and a confidently wrong number is worse than the
   blank it replaces.

   So the status job re-enters `lain.tmux` (`#('<plugin>/lain.tmux' status #{q:pane_current_path})`),
   which gained `state-path`/`status` subcommands beside its unchanged install mode, and
   `lain-status` became `lain-status [STATE_FILE]` — one optional file argument, no directory join,
   no hash. **The literal constraint below is intact**: `lain-status` names no digest or path binary
   at all. `realpath` cost nothing either — `cd -- "$dir" && pwd -P` is a builtin.

   **What it costs, stated rather than discovered later:** the recipe now has a THIRD spelling
   (Ruby, Lua, bash), cross-pinned byte-for-byte against `ProjectDir#state_path` by spec; the
   standalone tpm path wants one of `sha256sum`/`shasum`/`openssl` and degrades to
   `lain: no state yet` at exit 0 with none of them; and the render path is bash rather than POSIX
   `sh`. The renderer that must never blank and never error keeps that contract; the renderer that
   feeds it is the one that gained a soft dependency.

   The original decision, superseded, was:

   **The tmux renderer is told its path; it never computes the project hash.** Reproducing
   `sha256(realpath)[0,12]` in POSIX `sh` would add `realpath` and a sha256 binary as hard
   dependencies to the one renderer designed to degrade honestly with nothing installed. T9 gives
   `lain-status` a state-file path and keeps its legacy `DIR` behaviour as the fallback.

## Waves

```
Wave 1: T1, T4, T7, T10, T11, T12, T13     (no unmet deps)
Wave 2: T2 (←T1), T5 (←T4), T8 (←T7), T9 (←T7)
Wave 3: T3 (←T1, T2), T6 (←T5)
```

Critical path: **T1 → T2 → T3** (equal-length sibling T4 → T5 → T6).

## Tasks

### T1 — Let the docker backend ask the client how it maps users            [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/exec/docker.rb`, `spec/lain/exec/docker_spec.rb`
**Reuse:** the injected `user:` keyword and its default (`docker.rb:110`); `#argv` (`:168-169`); the
recording fake inner exec (`docker_spec.rb:56-69`); `Exec::Local` as the thing that already spawns
**Shared-file wiring:** none
**Reachable from:** `CLI::Wiring::ToolsetBuild:307 → ExecBackend#docker:126 → Exec::Docker.new →
#call` — every `--exec docker` tool call. `ExecBackend` is deliberately NOT modified; see
Correction 1.

**Acceptance criteria:**

```gherkin
Scenario: a client that maps the host user to container root gets no --user
  Given a docker backend whose injected prober reports a podman-shaped client
  When it builds the argv for a command
  Then the argv contains no "--user" element

Scenario: a docker client still gets the calling user
  Given a docker backend whose injected prober reports a docker-shaped client
  When it builds the argv for a command
  Then the argv contains "--user" followed by "<uid>:<gid>" for the calling process

Scenario: a client that will not say what it is keeps today's behaviour
  Given a docker backend whose injected prober answers nothing usable
  When it builds the argv for a command
  Then the argv contains "--user" for the calling process
  And no error is raised

Scenario: the client is asked at most once
  Given a docker backend
  When two commands are run through it
  Then the prober was consulted once
```
→ spec file: `spec/lain/exec/docker_spec.rb`

**Escalation triggers:**
- `docker_spec.rb:87` asserts `argv.first(4) == %w[docker run --rm --user]` — **positional on the
  head**. Removing `--user` breaks it by design; update it to assert structure. (`:93` uses
  `argv.last(4)` and is index-safe from the tail — do not confuse the two.)
- Resolution must NOT happen in `ExecBackend` or at construction: `exec_backend.rb:20-29` argues the
  PATH-only probe as doctrine and `resolve` runs twice per launch. If the design seems to want it
  there, STOP.
- If the prober cannot be injected such that unit examples spawn no subprocess, STOP — a real
  subprocess in a unit spec is not acceptable.

### T2 — Stop the docker client narrating its own progress into the result   [wave 2] [risk: medium]

**Depends on:** T1
**Files:** `lib/lain/exec/docker.rb`, `spec/lain/exec/docker_spec.rb`
**Reuse:** `RUN` (`docker.rb:49`); `#argv` (`:168-169`)
**Shared-file wiring:** none
**Reachable from:** `ExecBackend#docker:126 → Exec::Docker#call`, every `--exec docker` tool call.

**Acceptance criteria:**

```gherkin
Scenario: the client is asked to suppress its own progress output
  Given a docker backend
  When it builds the argv for a command
  Then the argv asks the client not to narrate its own progress
  And the image still appears immediately before what the container is asked to run
```
→ spec file: `spec/lain/exec/docker_spec.rb`

**Escalation triggers:**
- **This card changes the head of the argv and `docker_spec.rb:87` asserts `argv.first(4)`
  positionally.** Expect to update it; if T1 already restructured that example, keep the structural
  form rather than reintroducing an index.
- `Tools::Bash.render_output` (`tools/bash.rb:107-116`) is shared byte-for-byte with the local and
  core backends and pinned by `spec/support/shared_examples/exec_boundary_parity.rb:51`. If a fix
  wants to filter output there, STOP — it must stay inside `Exec::Docker`.
- **No AC here asserts captured stderr.** The seam gate refuses to run without the image already
  pulled (Correction 3), so the effect is checked by hand in integration check 3. Do not add a
  scenario that needs an unpulled image, and do not make the seam block pull one.

### T3 — Pin the docker seam against whichever client is installed          [wave 3] [risk: low]

**Depends on:** T1, T2
**Files:** `spec/lain/exec/docker_spec.rb`
**Reuse:** `DockerBackendAvailability` (`docker_spec.rb:31-39`) as the gate and the place a reason is
already reported (`:331`); `spec/support/shared_examples/exec_boundary_parity.rb` as the shape
**Shared-file wiring:** none
**Reachable from:** deferred: test-only. It pins production behaviour rather than adding a
capability, so it is not an unwired feature.

**Acceptance criteria:**

```gherkin
Scenario: the mounted project is readable and writable whichever client is installed
  Given a real container client of either kind
  When a command reads a seeded file in the mounted project and writes a new one
  Then the read returns the seeded contents
  And the written file exists on the host owned by the calling user

Scenario: a skip says which client it found
  Given no usable container client
  Then the skip reason names what was probed and why it could not run
```
→ spec file: `spec/lain/exec/docker_spec.rb`

**Escalation triggers:**
- **Do not make these examples skip in order to go green.** They were skipped before, which is
  exactly how F57 shipped. If they still fail under podman after T1, report the argv and the
  container's `id` output rather than adjusting the assertion — the round measured that omitting
  `--user` is sufficient, so a contradiction means the diagnosis is wrong.
- Report the detected client through the **skip/pending reason**, not by writing to stdout: twelve
  `parallel_rspec` workers interleave unattributably.

### T4 — Give the compaction record a name for the strategy that ran        [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/telemetry/compaction.rb`, `spec/lain/telemetry/compaction_spec.rb`
**Reuse:** the `model:` member, added the same way and documented at `compaction.rb:145-146` as the
migration idiom (optional, defaulted, coerced `&.to_s&.freeze`)
**Shared-file wiring:** none
**Reachable from:** deferred to T6, which journals it on the production path. This card adds the
member and its vocabulary only.

**Acceptance criteria:**

```gherkin
Scenario: the record carries the operator's own words
  Given a compaction record built with collapse_strategy: "elide-tools+summarize-conversation"
  When it is journalled
  Then the wire hash has "collapse_strategy" => "elide-tools+summarize-conversation"

Scenario: the control arm has a name of its own
  Given a compaction record built for a run with no --compact-strategy
  When it is journalled
  Then the wire hash names the eager control arm rather than saying nothing

Scenario: a record from before this field is still readable
  Given a compaction record built with no collapse_strategy at all
  Then the wire hash has "collapse_strategy" => nil
  And the record is still deeply frozen
```
→ spec file: `spec/lain/telemetry/compaction_spec.rb`

**Escalation triggers:**
- **nil must not mean two things.** An un-flagged run is not "no strategy" — it is the eager control
  arm, argued at `backend/span_summarizer.rb:19-36` — while nil *also* means "written before this
  field existed" (`compaction.rb:183-186`: old journals are not migrated). F51's success criterion
  is grouping `bytes_before - bytes_after` **by strategy name without consulting the launch
  command**, which the control arm cannot satisfy if it is nil. Name it; the same problem is solved
  the other way for `cost_saved`/`cost_spent` at `compaction.rb:271-279`, and that reasoning is the
  precedent to follow and to cite in the header.
- `compaction_spec.rb:40` asserts `members.grep(/token/)` is empty and `:57` pins that unknown kwargs
  raise. `source_spec.rb:739-741`/`:756` make byte-level NDJSON substring assertions; `Data` appends
  members last so they should survive. If one breaks, STOP rather than loosening it.

### T5 — Let the compaction wiring carry the operator's word                [wave 2] [risk: high]

**Depends on:** T4
**Files:** `lib/lain/cli/backend/span_summarizer.rb`, `lib/lain/compaction/source.rb`, and their
mirrored specs
**Reuse:** `SpanSummarizer.resolve` (`span_summarizer.rb:77-79`), which **already reads**
`@options[:compact_strategy]` at `:78` and already returns into `Source`'s existing `strategy:`
slot; `Strategy::Base#name` (`compaction/strategy/base.rb:120`) and `Composed#name`
(`composed.rb:96`) for the fallback naming
**Shared-file wiring:** none
**Reachable from:** `CLI::CompactionMount:76 → Backend#pipeline_source:367 →
Backend#compaction_source:515 → Compaction::Source.new`.

**Acceptance criteria:**

```gherkin
Scenario: the resolved strategy still behaves as a strategy
  Given a compaction source built from a composed --compact-strategy
  When a compaction derives a context
  Then it derives exactly as it does today

Scenario: the operator's word is recoverable from the source
  Given a compaction source built from --compact-strategy elide-tools+summarize-conversation
  Then the source can name that composition as the operator typed it

Scenario: an unflagged run names the control arm
  Given a compaction source built with no --compact-strategy
  Then the source names the eager control arm
```
→ spec file: `spec/lain/cli/backend/span_summarizer_spec.rb`, `spec/lain/compaction/source_spec.rb`

**Escalation triggers:**
- **`lib/lain/cli/backend.rb` is at `Metrics/ClassLength` 110/110 and `Source#initialize` is at
  `Metrics/MethodLength` 10/10 — both measured, both at cap.** Adding a keyword at `backend.rb:521`
  or an ivar in `Source#initialize` puts them at 111 and 11. CLAUDE.md forbids raising either `Max`.
  That is why this card carries the operator's word **inside the value `SpanSummarizer` already
  returns** rather than as a new argument. If an approach needs a new parameter on either, STOP.
- **Never capture the strategy OBJECT anywhere it could be frozen or shared.** `Summarizing` holds a
  live oracle and a mutable memo (`cli/compaction_strategy.rb:103-118`); `Scheduler` freezes at
  `scheduler.rb:150` and `COMPOSE` carries a `Ractor` shareability contract. What travels onward is
  a frozen String.
- If a choice object breaks `Source`'s existing use of `strategy:` in a way that needs `Derived`
  (`source/derived.rb:111`) to change, STOP — the panel traced that `Derived`, `Derived::Outcome`
  and `#weigh` need no change, so that would mean the seam moved.

### T6 — Journal the strategy on every compaction                          [wave 3] [risk: medium]

**Depends on:** T5
**Files:** `lib/lain/compaction/scheduler.rb`, `lib/lain/compaction/source.rb`, and their specs
**Reuse:** `ran_under:` on `Scheduler#pipeline` — the exact precedent for a per-call keyword, with
its reasoning at `scheduler.rb:196-204`; `Source#commit` (`source.rb:442-450`) as the call site
**Shared-file wiring:** none
**Reachable from:** `Agent#step:494 → Source#context_for → #weigh:387 → #commit:442 →
Scheduler#pipeline:205 → #accounting:283 → Telemetry::Compaction.new:284`. **This is the card that
makes F51 observable**; without it T4 ships a member nothing ever fills.

**Acceptance criteria:**

```gherkin
Scenario: a session launched with a composed strategy journals that composition
  Given a chat launched with --compact-strategy elide-tools+summarize-conversation
  When a compaction fires
  Then the journalled compaction record's collapse_strategy is "elide-tools+summarize-conversation"

Scenario: an unflagged session journals the control arm
  Given a chat launched with no --compact-strategy
  When a compaction fires
  Then the journalled compaction record names the eager control arm

Scenario: the journal can be grouped by strategy with no launch command to hand
  Given a journal containing compactions from a flagged run
  When the records are grouped by collapse_strategy
  Then each group's bytes_before and bytes_after are attributable to one named arm
```
→ spec file: `spec/lain/compaction/scheduler_spec.rb`, and one production-path example in
`spec/lain/cli/wiring_spec.rb` (which already greps `journal.events.grep(Lain::Telemetry::Compaction)`
at `:827-834`)

**Escalation triggers:**
- Thread a **per-call argument**, never an ivar or anything reaching `COMPOSE` (`scheduler.rb:255-258`)
  — `ran_under:` exists precisely because that was ruled out once. If a change to `COMPOSE` or a
  memoized structure seems needed, STOP.
- `lib/lain/bench/plan_sweep/driver.rb:174` builds a `Scheduler` with **no journal**. A required
  keyword that breaks that construction is a STOP.

### T7 — Move the HUD's state file out of the user's source tree            [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/project_dir.rb`, `spec/lain/project_dir_spec.rb`, and the four prose sites that
currently argue the opposite: `lib/lain/paths.rb:12`, `lib/lain/status_feed.rb:13-18` and `:250`,
`lib/lain/frontend/tty.rb:70-71`, `lib/lain/cli/up.rb:640-650`
**Reuse:** `Epic::Home.container` (`epic/home.rb:72-80`) — the working
`File.join(paths.state_home, <kind>, paths.project_hash(root))` precedent; `Paths#state_home`
(`paths.rb:170`), `Paths#project_hash` (`:190-192`)
**Shared-file wiring:** none
**Reachable from:** `StatusFeed#default_path` (`status_feed.rb:519`), `Frontend::TTY`
(`frontend/tty.rb:93`) and `CLI::Up` (`up.rb:656`, which builds `Up::Hud`'s `state_path:`) all
default through `ProjectDir#state_path`.

**Acceptance criteria:**

```gherkin
Scenario: the state file lives under XDG state, keyed by project
  Given a project at a known directory
  When the locator resolves its state path
  Then the path is under XDG_STATE_HOME/lain, not under the project directory
  And two different projects resolve to two different paths

Scenario: every spelling of one directory resolves to one state file
  Given a session writing state, resolving its own directory as the kernel gives it
  And a HUD launched by `lain up PATH` from a different shell, expanding the PATH it was typed
  Then both resolve to the same state file
  And a symlinked, unexpanded or `..`-laden spelling of that directory resolves there too

Scenario: a lain session no longer dirties a git project
  Given a git repository with a clean working tree
  When a session runs a turn in it
  Then git status reports no untracked or modified files
```
→ spec file: `spec/lain/project_dir_spec.rb`, with the third scenario as a `:seam` example in
`spec/lain/seams/` driving a real turn against a real `git`

**Escalation triggers:**
- `ProjectDirDiscipline` (`project_dir_spec.rb:18-140`) is a Ripper tree-scan that FAILS if any file
  in `lib/` outside `EXEMPT = ["lain/project_dir.rb"]` recomposes the path. Keep the whole
  composition inside `project_dir.rb`. Note `Epic::Home` takes `paths:` as a **required** argument,
  so copying it literally means injecting `Paths` into three callers — which that discipline spec
  exists to refuse. If the design seems to want that, STOP.
- **Scenario 2 is the one that bites.** `up.rb:656` passes `root: cwd` while `status_feed.rb:519`
  and `tty.rb:93` use bare `ProjectDir.new` (→ `Dir.pwd`). Today `up.rb:640-650` documents the
  consequence as "merely looks stale"; under a hashed path it becomes a HUD pointing at a file
  nothing writes, with no file on disk for a human to `ls`. If the two cannot be made to agree
  inside this card, STOP — that is a design answer the plan owes.
- This card moves **only** `state.json`. `.lain/` still holds config, summarizers, slots, skills and
  repo-mode epics.

### T8 — Point the nvim renderer at the relocated state file                [wave 2] [risk: low]

**Depends on:** T7
**Files:** `plugin/nvim/lua/lain/config.lua`, `spec/plugin/nvim_plugin_spec.rb`
**Reuse:** **`plugin/nvim/lua/lain/init.lua:68` already computes `vim.fn.sha256(cwd):sub(1, 12)`**,
the same recipe as `Paths#project_hash`, and `spec/plugin/nvim_plugin_spec.rb:202` already
cross-pins it against `Digest::SHA256.hexdigest(nvim_cwd)[0, 12]`. Follow both.
**Shared-file wiring:** none
**Reachable from:** the nvim plugin's HUD, which a cockpit user reads every turn.

**Acceptance criteria:**

```gherkin
Scenario: the nvim renderer resolves the relocated file
  Given a state file at the new XDG location for a project
  When the plugin resolves the state path for that project
  Then it resolves to that file

Scenario: its answer agrees with Ruby's, byte for byte
  Given a project directory
  Then the Lua-resolved state path equals the path Ruby's locator resolves
```
→ spec file: `spec/plugin/nvim_plugin_spec.rb`

**Escalation triggers:**
- The existing cross-language pin at `:202` is for the **socket** path, not the state path. Add the
  state-path equivalent rather than editing that one; if they can share a helper, say so instead of
  duplicating the recipe a third time.

### T9 — Tell the tmux renderer where the state file is                     [wave 2] [risk: medium]

**AC2 RATIFIED AS REWRITTEN, 2026-08-23 — read this before drafting T8 or T9.** The scenario above
is not what the card first said. It said "a HUD launched from a **subdirectory** of that same project
... both resolve to the same state file", and T7 delivered a different property: **there is no walk to
a project root.** A session started in `proj/services` publishes a different file from one started in
`proj`, exactly as it wrote a different `.lain/state.json` before.

The substitution was reviewed and accepted, on three grounds. **One:** the escalation trigger's own
body names two *call-site spellings* — `up.rb`'s `root: cwd` against `status_feed.rb`/`tty.rb`'s
`Dir.pwd` — and asks whether "the two" can agree. That is a spelling question, and those two now
provably agree via `File.realpath(File.expand_path(dir))`. **Two:** there is no regression. Pre-T7 a
HUD in a different directory read a `.lain/state.json` nothing wrote and printed `lain: no state yet`;
post-T7 it reads an XDG path nothing writes and prints the same sentence. The original hand-back's
"stale became nothing" was pessimistic — it was already nothing. **Three:** a root walk was traced and
rejected, not skipped. It would give lain a THIRD project identity alongside `Paths#sessions_dir` and
`plugin/nvim/lua/lain/init.lua`'s socket, both of which key on cwd, and it would break the
byte-for-byte `sha256(cwd)[0,12]` pin CORRECTION 4 promises T8.

**So: the codebase has "one directory, however spelled, is one file". It has no notion of a project
ROOT.** A T8 author reading the original text would look for a walk that is not there.

**Integration check 5 passes under the whole chunk, not under T7 alone.** "A `lain up` launched from a
subdirectory" means the SHELL is a subdirectory: `@cwd` is pinned onto every pane by `tmux -c` at three
sites (`up.rb:793`, `:824`, `:874`/`:875`), so writer, status-right and nvim all key on one directory.
The tmux half already renders under T7 because `Up::Hud#jq_status_right` interpolates an **absolute**
`state_path` into a session-scoped `status-right` — `lain up`'s HUD never reads `pane_current_path`.
The nvim half needs T8.

**T9's recipe is OWED, and the original hand-back's version of it was wrong.** It said "take the path
from `up.rb:656`, compute nothing", and that `lain-status`'s `DIR` fallback would point at the retired
location, never find a file, and "stay honest". Both halves fail: `plugin/tmux/lain.tmux:30` is a **tpm
entry point sourced from `tmux.conf`** with no `lain up` in the flow, so `up.rb:656`'s string is
unreachable from it — `lain up` writes its own session-scoped `status-right`, making `lain.tmux` a
SEPARATE consumer — and T9's own escalation trigger says the standalone fallback **must keep working**,
which "permanently dead but honest" is the opposite of. The real constraint: `lain.tmux` is
`#!/usr/bin/env bash` and *could* compute; `lain-status` is `#!/bin/sh` and per Open decision 4 must
not; and `#{pane_current_path}` is interpolated by tmux **per pane at render time**, so nothing can
precompute a per-pane path when the file is sourced. **That is an unanswered design question this plan
owes T9.**

**T8 must not copy `init.lua` blindly.** `runtime_base()` falls back to `/tmp` with **no `$HOME`
branch** (right for runtime dirs, wrong for state), and Ruby's `home` falls back to `Dir.home` when
`HOME` is unset *or non-absolute*, which `vim.env.HOME` has no analogue for. `socket_path()`'s `sha256`
line is only reached when `cwd/.lain` is ABSENT, so T8 must extract the hash into a shared
`M.project_hash()` helper rather than reuse that branch. The absolute-only XDG rule matches: Ruby's
`value&.start_with?("/")` and Lua's `xdg:match("^/")` are the same test.

**Four sites pin the RETIRED location green and belong to the siblings**, not to T7:
`spec/plugin/tmux_plugin_spec.rb:42,128,142` and `spec/plugin/nvim_plugin_spec.rb:205,209`, plus
`plugin/nvim/doc/lain.txt:77,95,121`, `plugin/nvim/README.md:16`, `plugin/tmux/README.md:5`.

**Depends on:** T7
**Files:** `plugin/tmux/scripts/lain-status`, `plugin/tmux/lain.tmux`, `lib/lain/cli/up.rb`,
`spec/plugin/tmux_plugin_spec.rb`
**Reuse:** `lain-status`'s existing optional `DIR` argument (`lain-status:5-7`) and the job
interpolation at `lain.tmux:30`; `up.rb:656`, which **already resolves the path** the HUD needs
**Shared-file wiring:** none
**Reachable from:** the tmux status line — `lain.tmux:30` builds the `#(...)` job every cockpit runs.

**Acceptance criteria:**

```gherkin
Scenario: given a state file path, the renderer reads it
  Given a state file at an arbitrary path
  When the status script is given that path
  Then it renders the HUD from that file

Scenario: the renderer never computes a project hash
  Then the status script requires no sha256 or realpath binary to resolve its input

Scenario: it still degrades honestly
  Given a path that does not exist
  Then the script exits successfully and renders nothing
```
→ spec file: `spec/plugin/tmux_plugin_spec.rb`

**Escalation triggers:**
- `lain-status` is `#!/bin/sh` with `set -eu` and a documented contract to never blank and never
  error, with `jq` its only optional dependency. **Do not add `realpath`, `readlink -f`, `sha256sum`,
  `shasum` or `openssl` to it** — Open decision 4 exists to prevent exactly that. If the path cannot
  be supplied and the script seems to need to compute it, STOP.
- The tmux job is built from `#{pane_current_path}`, a *directory*. If supplying a file path means
  `lain.tmux` can no longer be used standalone without `lain up`, say so — the legacy `DIR` fallback
  is there to keep that working and must keep working.

### T10 — Pad every closed fold's summary, not just the blank one           [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/frontend/neovim/runtime/10_folds.lua`,
`spec/lain/frontend/neovim/approval_view_spec.rb`
**Reuse:** `foldtext()` (`10_folds.lua:208-217`) and its existing blank-summary branch — which is the
special case this card replaces with the general statement
**Shared-file wiring:** none
**Reachable from:** `Surfaces#prime` → every foldable `lain://` window.

**Acceptance criteria:**

```gherkin
Scenario: a closed one-line fold shows its own text with no fill characters
  Given lain://approval with one pending call
  When the key-hint line is displayed as a closed fold
  Then the displayed line is the hint text
  And no fold fill characters trail it

Scenario: a closed multi-line record row is padded too
  Given a record row folded closed
  Then its summary occupies the full screen line
  And no fold fill characters trail it

Scenario: the hints are still a fold of their own
  Given lain://approval with one pending call
  Then the key-hint line is its own fold
```
→ spec file: `spec/lain/frontend/neovim/approval_view_spec.rb`

**Escalation triggers:**
- `approval_view_spec.rb:1023-1029` deliberately pins "leaves the key hints in a fold of their own",
  and `05_records.lua:30-45` records WHY the trailer answers true. If a fix wants to stop the
  trailer being a record, STOP — those two exist to protect that.
- `10_folds.lua:117-119` explains `foldminlines = 0`. Do not change it.
- The `span > 1` branch returns `line .. "  (+N lines)"`; padding must account for that suffix's
  display width, not the raw line's.

### T11 — Make the one-note receipt read as one note                        [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/frontend/neovim/runtime/48_annotate.lua`,
`spec/lain/frontend/neovim/annotate_spec.rb`
**Reuse:** the `count == 1` ternary at `48_annotate.lua:336`
**Shared-file wiring:** none
**Reachable from:** `:LainNoteDone` (`48_annotate.lua:520-542`), the note rail's hand-back gesture.

**Acceptance criteria:**

```gherkin
Scenario: one note
  Given one note pending
  When the notes are handed back
  Then the receipt reads as singular throughout, with no plural possessive

Scenario: several notes
  Given four notes pending
  When the notes are handed back
  Then the receipt reads as plural throughout
```
→ spec file: `spec/lain/frontend/neovim/annotate_spec.rb`

**Escalation triggers:**
- `spec/refusal_width_discipline_spec.rb` budgets these at 80 columns and parses **Ruby only**, so
  `48_annotate.lua:326-328` records that the Lua strings are hand-checked. Keep both arities inside
  budget and report the measured widths in the hand-off.
- Existing specs assert only a prefix (`annotate_spec.rb:833`, `:844`). Extend them to the tail —
  leaving the new wording untested is how this shipped.

### T12 — Stop the review refusal naming a noun the label already carries    [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/review/submit/outbox.rb`, `spec/lain/review/submit/outbox_spec.rb`,
`spec/lain/cli/command/survey_spec.rb`
**Reuse:** `NOT_A_PULL_REQUEST` (`outbox.rb:72-74`) and its `%<label>s`, which already interpolates
`"survey of …"` (`cli/command/survey.rb:376`), `"branch …"` (`cli/review.rb:264`) or
`"pull request …"` (`:257`)
**Shared-file wiring:** none
**Reachable from:** `/review-submit` (`cli/command/review_submit.rb:96`) over any round whose
`number` is nil.

**Acceptance criteria:**

```gherkin
Scenario: a survey is not called a branch
  Given an open survey round
  When a human tries to submit it
  Then the refusal names the survey and its path
  And the refusal does not call it a branch
  And it still says where the annotations and the verdict went

Scenario: a branch round still reads correctly
  Given an open local-branch round
  When a human tries to submit it
  Then the refusal names the branch once, not twice
  And it still points at /review <pull-request> as the remedy
```
→ spec file: `spec/lain/review/submit/outbox_spec.rb`, `spec/lain/cli/command/survey_spec.rb`

**Escalation triggers:**
- **Do not reach for `#held_source`.** It exists (`outbox.rb:133`) and its docstring (`:123-128`)
  argues against using it here: "Deciding here which word means what would put a kind test on the
  object whose one responsibility is submission." The fix is in the sentence, which should stop
  naming a second noun.
- `outbox.rb:87-90` still describes `number` as "nil for a branch review" — prose predating the
  corpus source. Correct it in the same pass.
- Existing specs match substrings only (`outbox_spec.rb:124-145`, `survey_spec.rb:451-458`). Assert
  the new sentence, not a fragment.

### T13 — Pin what the approval queue does with several pendings at once     [wave 1] [risk: medium]

**Depends on:** none
**Files:** `spec/lain/approval/multi_pending_spec.rb`, and a support file under `spec/support/` if a
helper earns its place
**Reuse:** `Approval::Queue#adjudicate` (`approval/queue.rb:269`) — **staleness note, 2026-08-23: there
is no `#ask`; the gate seam is `#call`/`#adjudicate`.** And `spec/lain/approval/queue_concurrency_spec.rb`
already parks **two** pendings concurrently through the real ToolRunner→Gate→Queue path under a
gathered dispatch, asserting `queue.count == 2`. That is the reactor pattern to copy; this card's
additions are the **third** pending, individual addressability, and partial settlement (answering one
leaves two undecided), none of which that spec covers and the existing approval specs' reactor
setup — whatever they already use to drive `Async` fibers
**Shared-file wiring:** none — `spec/support/**` loads by glob
**Reachable from:** deferred: **test-only, deliberately not wired into `lib/`** — see Open
decision 1, which also records what it does NOT close.

**Acceptance criteria:**

```gherkin
Scenario: three calls are parked together
  Given three gated calls asked concurrently
  Then the queue holds three pendings at once
  And each is individually addressable

Scenario: answering one leaves the others undecided
  Given three pendings parked together
  When one is answered
  Then that one reports decided
  And the other two remain undecided
```
→ spec file: `spec/lain/approval/multi_pending_spec.rb`

**Escalation triggers:**
- **`Queue#ask` parks the calling fiber until the pending is decided.** "Three at once" therefore
  needs three concurrently-parked fibers under an `Async` reactor, not three sequential
  constructions — that is the whole difficulty and the reason this fixture does not already exist.
  If the existing approval specs have no reactor pattern to copy, STOP and report rather than
  inventing one.
- `Queue#dequeue` hands each arrival to exactly ONE waiter, and round 8's F40 lived in that FIFO. If
  parking three requires changing the queue, STOP — the spec must observe the real queue.
- A version that silently drops to one pending reproduces the false green this card exists to
  remove. Assert the count.

## Integration checks

1. **Full suite green, and the COUNT checked**: `bundle exec rake pspec` must report **≥ 15172
   examples** with **0 failures**. `parallel_tests` reports only surviving examples, so a drop in the
   count is a dead worker, not a pass.
2. **The docker seam must RUN, not skip.** On a host where `docker --version` resolves,
   `spec/lain/exec/docker_spec.rb`'s `:seam` block must execute and pass. Confirm it was not skipped
   — a skipped block is how F57 shipped.
3. **F55 by hand**, because no AC can reach it (Correction 3): with the image absent, run one
   `--exec docker` command and confirm the tool result's stderr carries no image-pull progress. The
   podman shim banner may remain (Open decision 3); say which lines survived.
4. `bundle exec rubocop` clean (`-a` only, never `-A`) and `pre-commit run --all-files`. **No
   `.rubocop.yml` diff.**
5. **F50 by hand**: run one turn in a scratch git repo, confirm `git status --porcelain` is empty
   afterwards, and confirm the HUD still renders in **both** tmux and nvim — including a `lain up`
   launched from a subdirectory, which is T7's scenario 2.
6. **F51 by hand**: launch with `--compact-strategy elide-tools+summarize-conversation`, drive enough
   volume to compact, and confirm the journal reduction prints the operator's composed string; then
   launch unflagged and confirm the control arm is named rather than nil.
7. **A manual QA pass** over `cockpit-surfaces` §4b and §8 for T10's fold change, and `changeset-review`
   §7 for T12's refusal. **Not** `cockpit-surfaces` §5's three-at-once property — Open decision 1
   records why this chunk cannot close it.
