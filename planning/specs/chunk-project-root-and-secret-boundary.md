# Project root, and the secret boundary

status: in-progress
commit-mode: orchestrator-commits
language: ruby
panel: Ruby — Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson

## Intent

Give Lain a **project root** distinct from its **working directory**, and build the read-side
secret boundary that a root makes possible. `lain up <path>` and `lain chat --root` become real;
a monorepo session runs with `cwd` deep in a subtree and `root` at the repo top; `$HOME` can
never be *inferred* as a root; and a read of a credential-shaped path is gated, region-approved,
and journaled instead of silently egressed.

The root also unblocks a rung that is already built. `approval/escalation.rb:156-158` says the
`rules` rung ships empty because *"T20's remembered answers need a project root the switchboard
does not hold."* T18 gives it one and wires `Approval::Remembered`'s **read** side. Note the
honest scope: `Remembered::Persister` and `Approval::Risk` stay dead after this chunk — `Risk` is
reachable only through the persister, and the persister needs a UI affordance this chunk does not
build.

Requirements draft: `planning/project-root-and-secret-boundary.md`. Part 3 of that doc (typed
egress tool, Landlock confinement in `crates/lain-core`) is **deferred to a later chunk** by
Joel's ruling and is not planned here.

## Grounding

Verified against the working tree at `dc49182`, 2026-08-07, by six parallel exploration passes,
then re-verified by a panel pass that corrected six citations and found seven design faults. Line
numbers below are post-correction.

**Root and cwd**
- There is **no project root anywhere**. `Dir.pwd` is the default at ~40 sites: `config.rb:79`,
  `project_dir.rb:46`, `skill/library.rb:44`, `prompt/slots.rb:59`, `skill/catalog.rb:38`,
  `dsl_catalog.rb:42`, `approval/risk.rb:285`, `approval/remembered.rb:202`,
  `workspace/snapshot.rb:92`, `workspace/restore.rb:101`, `review/source.rb:143`,
  `cli/command/surface.rb:46` (fanning out to `meta.rb:95`, `review.rb:99`, `review_submit.rb:77`),
  `cli/wiring.rb:326` (the one *explicit* one, whose comment names itself as the thread point),
  `cli/isolation_backend.rb:92`, `frontend/completion/sources.rb:34`,
  `frontend/prompt_composer.rb:191`, `isolation/compose.rb:189`, `supervisor/restart.rb:72`,
  `epic/home.rb:72,87`, `forge/gh.rb:210`.
- `Isolation::Worktree#worker_env_for` (`isolation/worktree.rb:125`) is the **only** thing in
  `lib/` that supplies a non-`Dir.pwd` cwd today.
- **`Session.normalize_path` is a CLASS method** (`session.rb:85-87`), deliberately public so
  `Session::Journaled` can ask what a read normalized to and match `#read?` exactly
  (`session.rb:78-84`). It expands against process `Dir.pwd`. A class method has no `worker_env`
  — which is the whole difficulty in T7.
- The read-set is **add-only**: `@reads << normalize(path)` / `@reads.include?`
  (`session.rb:93-101`). No removal, no partial state. T22 exists because of this.
- **`cli/wiring.rb` is at its `Metrics/ClassLength` budget** — its own header (`:18-48`) says
  *"the NEXT card must extract before it adds."*
- `exe/lain:621` is `def up(*chat_args)`, and `chat_flags!` (`exe/lain:76-80`) raises on any
  trailing arg without a `--`. `Up#default_state_path` (`cli/up.rb:297`) and the non-cockpit
  `new_session_args` (`cli/up.rb:175-178`) do not read `cwd`.

**Disagreements with the requirements draft, and which won**
1. **`Approval::Risk` is not wired.** Zero production call sites for `Risk`, `Remembered`, or
   `Persister` — spec-only. *Code won:* dead code to switch on (T18), not a control to extend.
2. **`Tools::Glob` forbids what the draft proposed.** `tools/glob.rb:10-17`: *"the real boundary
   is the tier system, `Effect::Handler::Gate`, and eventual OS confinement, never a path check
   inside a tier-1 tool."* *Doctrine won,* by Joel's ruling: sensitivity gates at
   `Effect::Handler::Gate`, and **no tier-1 tool gains a path check.**
3. **`Oracle::MemorySave` forbids a model round trip on the live dispatch path**
   (`oracle/memory_save.rb:8-17`). *Doctrine won, and the seam moved:* the local oracle is an
   `Approval::Queue` **surface** modelled on `Approval::AutoSurface`, adjudicating already-parked
   pendings asynchronously. Nothing sits on the synchronous path.
4. **The draft overstated the bash hole.** `Escalation::Triage` downgrades a `Shell::Verdict`
   *allow* to **abstain** (`escalation.rb:441`), so a literal `cat .env` already reaches a human
   under `queue` gate policies. *Code won:* T20 is scoped to a **new deny on the allow branch**,
   not to closing an open egress.
5. **Draft Q-D was not paranoid, and the plan initially dropped it.** *Restored:* once T18 reads
   `.lain/config.toml` as a pre-approval table, and T2 rung 3 lets any ancestor `.lain/` define
   the root, a cloned repo can pre-authorize tool calls. T18 now carries a consent rule and ACs.
6. **Draft R7's enforcement spec was dropped silently.** *Restored:* T5 ships the AST guard.

**Content detection cannot gate before the read, and that shapes three cards.** A path
classifier answers before the file is opened; a region detector cannot. So there are two
boundaries, not one: `Sensitivity::Policy` gates **paths** pre-read at the handler (T11), and
`RedactSecretReads` masks **content** post-read and parks a pending for release (T15). An earlier
draft of this plan had T15 masking silently with no release path, which left an ordinary
`Cargo.lock` permanently `<redacted:1>` with no move available to anyone.

**Seams the work builds on**
- `Effect::Handler::Gate#gated_tool_call?` (`effect/handler/gate.rb:81-89`) holds the effect *and*
  the resolved tool. `Switchboard#gate(inner:)` (`cli/switchboard.rb:88`) is the single
  chain-assembly point; `tools/subagent.rb:797` is the child equivalent.
- `Middleware::RefuseSecretWrites` (tool phase, `agent/tool_runner.rb:250-266`) is the mirror the
  read side wants. `Middleware::Env` is `fetch`-based, so a short-circuit **must** merge `:result`.
- `Approval::AutoSurface` — `#watch(queue)`, sweep loop, `Pruning`'s identity-keyed seen-set,
  `VERDICT`'s three-way answer with `:defer` a no-op. The template for T17.
- `Approval::Queue#admit`/`#settle` with a fail-closed `DEFAULT_TIMEOUT = 300`
  (`approval/queue.rb:227-231`). `Queue::Pending` is deliberately mutable coordination state
  whose no-lock claim (`:107-115`) rests on every mutation being straight-line.
- `Frontend::ApprovalPolicy` renders through an **injected reader** (`cli/switchboard.rb:181-183`),
  which is what keeps `lib/` off the terminal.
- **`review/hunk.rb:10-14` settles how to digest bytes**: *"`Canonical` is deliberately not used:
  a hunk body is already bytes, and routing it through a JSON-native canonicalization would
  normalize away differences the key exists to keep."* `workspace/snapshot.rb:75` is the idiom.
- Telemetry has **no registry**: `Data.define` + `include Journalable` + a `require_relative` +
  an optional `Guard`. `journal_type` is derived from the class name.
- `Capability::Policy.for` has **no production caller**. Nothing here may claim it as a control.
- `Approval::Rule::Call#gated?` (`approval/rule.rb:172`) is a **second reader** of
  `tool.requires_approval?`.
- `cli/backend.rb:167` — `summarizer_provider` is a **user-settable knob** with an ollama default
  over `PROVIDERS = %w[anthropic ollama bedrock]`, **not** a pin. T17 must not copy it.
- `cli/isolation_backend.rb:142-149` — `repo_root` ascends for `.git` with no ceiling and no
  refusal set. A **second walk** that T2's stop rule does not govern.
- `cli/repl/approval_surfaces.rb:57-65` — the surfaces spec *"pins both the SIZE of this set and
  the class of every member."*

**Naming.** `Mode::Posture` is documented as already overloaded twice (`mode/posture.rb:45-53`).
`Lain::Project` carries **`kind`** (`:project` | `:home`) and does not touch the posture ladder.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only):
  `lib/lain.rb`, `lain.gemspec`, `.rubocop.yml`, `spec/spec_helper.rb`, `lib/lain/telemetry.rb`,
  `lib/lain/effect/handler.rb`, `lib/lain/middleware.rb`, `lib/lain/approval.rb`,
  `lib/lain/oracle.rb`, `CLAUDE.md`; **`lib/lain/cli/switchboard.rb`** and
  **`lib/lain/cli/tool_guard.rb`** (five cards need one-line injections into each — that is
  central wiring, not card scope); and, once T1 and T8 land, the two subtree indexes
  `lib/lain/project.rb` and `lib/lain/sensitivity.rb`.
- Deviations from the default process: none.
- **Worktree base pinning (execution note, 2026-08-07).** The Agent tool forks each worktree
  from the *remote-tracking* ref: `origin/main` was `a8b338f`, five commits behind local `main`
  (`dc49182`), four of them the `up`/cockpit work T6 builds on. Sub-agents are denied
  `git reset --hard` by the permission system, correctly — git is the orchestrator's in this
  commit-mode. So the orchestrator fast-forwards each worktree itself
  (`git -C .claude/worktrees/agent-<id> merge --ff-only <main sha>`) immediately after spawn,
  and the implementer brief tells the agent to verify `git rev-parse HEAD` and *stop and ask*
  rather than run git. Two wave-1 agents caught the skew and escalated instead of working
  around it, which is the behavior the brief wants. **Resolved for waves 2-7 by pushing `main`
  to `origin` (Joel's call, taken mid-wave-1), so `origin/main == main` and later worktrees fork
  correctly with no salvage.** The plan doc was also committed before the fan-out: `gherkin_spec`
  globs `planning/specs/*.md` for one example per doc, so an untracked plan doc makes the primary
  tree read one example higher than every worktree and a sub-agent cannot tell that gap from a
  truncated run. Baseline at `0e5fab5`: **11211 examples, 0 failures, 14 pendings.**

## Open decisions

None gating a card. Four rulings taken during the interview and panel review, recorded so a
later reader does not re-litigate them:

- **Tier-1 tools keep their doctrine.** Sensitivity gates at `Effect::Handler::Gate`, never inside
  `read_file`/`grep`/`glob`/`list_files`.
- **A hard-denied read is loud** — `"refused: protected path <path>"`, not `"no such file"`.
- **Gating happens on the queue, not inline** (draft Q-B). `Approval::Queue` already has the
  ladder, the fail-closed timer and four surfaces; a second inline prompt mechanism would
  duplicate all of it.
- **A masked read parks a pending for release.** Masking without a release path is a dead end,
  not a control.

## Waves

```
Wave 1: T1, T4, T7, T8, T9, T13            (no unmet deps)
Wave 2: T2 (←T1), T3 (←T1), T10 (←T9), T11 (←T8), T20 (←T8), T22 (←T7)
Wave 3: T5 (←T1,T2,T4), T12 (←T8,T11), T14 (←T10)
Wave 4: T6 (←T2,T5), T16 (←T14), T18 (←T5)
Wave 5: T15 (←T10,T13,T14,T16,T22), T17 (←T13,T16)
        ⚠️ **T15 and T16 land as a PAIR, and the ledger wiring lands with T15** (2026-08-07,
        T14's panel; corrected from an earlier note of mine that said "T16 depends on T15", which
        would be circular — the plan already has T15 ← T16, and that order is right). T16 alone is
        a dormant capability (`Pending` *can* carry regions, nothing constructs one), so it is
        safe on its own. The window to avoid is landing the ledger's `ToolGuard`/`AgentBuild`
        wiring before T15 exists to consume it. T14-without-either is safe: the masking arm is
        absent, not half-wired.
        **T16 also absorbs `Repl::ApprovalSurfaces#approval_surface` (`cli/repl/approval_surfaces.rb:51-55`)**,
        which builds a SECOND `Frontend::ApprovalPolicy` for the watch fiber and is in no card's
        Files list — miss it and the TTY watch surface and the `/approve` drain prompt disagree
        about what has been released, which is the two-ledger bug at half scale.
Wave 6: T19 (←T8,T15)
Wave 7: T21 (←T11,T12,T15,T19,T20)
```

Critical path: **T9 → T10 → T14 → T16 → T15 → T19 → T21** (seven nodes).
Second-longest, and the one that gates the CLI surface: T1 → T2 → T5 → T6.

## Tasks

### T1 — Build the `Lain::Project` value object          [wave 1] [risk: low]

**Depends on:** none
**Files:** create `lib/lain/project.rb`, `spec/lain/project_spec.rb`
**Reuse:** `Lain::Guardable` + `Lain::Guard` for validate-then-freeze (`lib/lain/guardable.rb`,
the `Epics` example in its header); `Lain::Inspectable`; `WorkerEnv` (`lib/lain/worker_env.rb`)
as the shape precedent for a deeply-frozen, `Ractor.shareable?` sent-not-stored value.
**Shared-file wiring:** `require_relative "lain/project"` in `lib/lain.rb`, after `worker_env`
and before `cli`.

Four fields: `root`, `cwd`, `kind` (`:project` | `:home`), `detected_by` (`:flag`, `:config`,
`:lain_dir`, `:git`, `:none`). No detection here; that is T2. `detected_by` is not decoration —
T2's reporting reads it and T18's consent rule branches on it.

**Acceptance criteria:**

```gherkin
Scenario: cwd must lie under root
  Given a root of "/tmp/repo" and a cwd of "/tmp/elsewhere"
  When a Project is constructed
  Then it raises, and the message names both paths

Scenario: a Project is deeply frozen and shareable
  Given any validly constructed Project
  When Ractor.shareable? is asked about it
  Then it answers true, and every String field is frozen

Scenario: root and cwd are compared after symlink resolution
  Given a root of "/tmp/repo" and a cwd that is a symlink resolving to "/tmp/repo/sub"
  When a Project is constructed
  Then it is accepted, and #cwd reports the resolved path

Scenario: kind is a closed set
  Given a kind of :scratch
  When a Project is constructed
  Then it raises and names :project and :home

Scenario: detected_by is a closed set
  Given a detected_by of :guess
  When a Project is constructed
  Then it raises and names the five known rungs
```
→ spec file: `spec/lain/project_spec.rb`

**Escalation triggers:**
- `Ractor.shareable?` comes back false after `Guardable#check!` — the carrier is leaking
  `@errors` into the value, which `guardable.rb:90-96` claims it cannot. Stop; that claim is
  either wrong or this class is misusing the concern.
- `File.realpath` raises on a root that exists (permissions, a dangling mount). The lexical
  fallback `Paths#resolved` (`paths.rb:204-209`) uses is the precedent — but silently falling
  back changes what "cwd is under root" means. Stop and confirm before copying it.

---

### T4 — Extract agent construction out of `CLI::Wiring`          [wave 1] [risk: medium]

**Depends on:** none
**Files:** create `lib/lain/cli/wiring/agent_build.rb`, `spec/lain/cli/wiring/agent_build_spec.rb`;
modify `lib/lain/cli/wiring.rb`
**Reuse:** `CLI::Wiring::BaseTools` (`lib/lain/cli/wiring/base_tools.rb`) is the exact precedent —
a `module_function` module in the `wiring/` subtree holding one question.
**Shared-file wiring:** none.

Pure refactor, **no behavior change**. Move `#build_agent` (`:433`), `#agent_backing` (`:458`)
and `#spooled_provider` (`:471`) into `Wiring::AgentBuild`. This card exists only because
`cli/wiring.rb:18-48` says the class is at its budget and *"the NEXT card must extract before it
adds"* — T5 is that next card.

**`#switchboard` and its memo stay on `Wiring`.** `wiring.rb:488-489` is `@switchboard ||=
Switchboard.for(...)` and `wiring.rb:434` (inside `build_agent`) is its **only** call site — so
the memo is assigned as a side effect of building the agent. Three other things read it:
`#approvals` (`:189`), `assemble_surface` (`:534`), and the `-> { @switchboard }` thunk handed to
`ToolsetBuild` (`:390`), which becomes every subagent's gate policy. Move the assignment into a
module and all three read nil. So `AgentBuild.build` receives `board` as an argument; `Wiring`
keeps ownership of the memo. Note also that `#spooled_provider` has a second caller in
`build_toolset` (`:388`).

**Acceptance criteria:**

```gherkin
Scenario: the extraction changes no observable wiring
  Given the existing wiring specs
  When the suite runs after the extraction
  Then spec/lain/cli/wiring_spec.rb and spec/lain/cli_spec.rb pass unchanged

Scenario: the switchboard memo is still assigned by the time surfaces are built
  Given a wired chat
  When #approvals and the command surface are asked for
  Then neither is nil and neither raises

Scenario: a subagent's gate policy still resolves a live switchboard
  Given a wired chat that spawns a subagent
  When the subagent's gate policy is consulted
  Then it reads the same switchboard the parent holds

Scenario: Wiring drops below its class-length budget
  Given the extraction has landed
  When rubocop runs on lib/lain/cli/wiring.rb
  Then Metrics/ClassLength does not fire, with room for a new collaborator
```
→ spec file: `spec/lain/cli/wiring/agent_build_spec.rb`

**Escalation triggers:**
- If `board` cannot be passed in without also moving `#switchboard`, stop. Moving the memo is the
  failure this card is written to avoid, and `wiring.rb:410-418` already documents the same class
  of nil-capture bug for the `agent` local.
- `spec/lain/cli_spec.rb:159-160` asserts the tool stack's exact class list, and
  `spec/lain/cli/wiring_spec.rb:240,274,323,358,372-374` pin wiring behavior. If the extraction
  requires editing any of those, it is not a pure refactor — stop.

---

### T7 — Resolve the read-set against the worker's cwd, in one place          [wave 1] [risk: medium]

**Depends on:** none
**Files:** modify `lib/lain/session.rb`, `spec/lain/session_spec.rb`
**Reuse:** `WorkerEnv#resolve` (`worker_env.rb:63-65`) — the one cwd-resolution rule the two exec
arms already share; the edit-before-write contracts in `tools/edit_file.rb:35-37` and
`tools/write_file.rb:38-42`.
**Shared-file wiring:** none.

`Session.normalize_path` expands against process `Dir.pwd`, so under a non-default cwd (today
`Isolation::Worktree`; tomorrow every `lain up <path>` session) a relative path recorded names a
different file than the one read.

**It is a class method, and that is the crux.** `session.rb:78-84` documents why it is public:
`Session::Journaled#record_read` (`:395`) calls `Session.normalize_path(path)` so the journaled
path matches exactly what `#read?` will answer true for. A class method has no `worker_env`, so
making normalization cwd-relative without threading the cwd through would leave `Journaled`
journaling a `Dir.pwd`-relative path while the read-set stores a `worker_env.cwd`-relative one —
a silent divergence in the Journal, which is the experiment record.

So the signature becomes `normalize_path(path, cwd:)`, and `Journaled` passes
`@session.worker_env.cwd`. `Session::Null#worker_env` recomputes `WorkerEnv.default` per call
(`session.rb:349`) and must keep tracking `Dir.chdir`.

**Acceptance criteria:**

```gherkin
Scenario: a relative path records against the worker cwd
  Given a Session whose worker_env cwd is "/tmp/repo/sub"
  When "notes.md" is recorded as read
  Then the session reports "/tmp/repo/sub/notes.md" as read

Scenario: an absolute path is unchanged
  Given a Session whose worker_env cwd is "/tmp/repo/sub"
  When "/etc/hosts" is recorded as read
  Then the session reports "/etc/hosts" as read

Scenario: the journaled path equals the read-set path
  Given a journaling Session whose worker_env cwd is not the process directory
  When a relative path is recorded as read
  Then the journaled SessionRead path is the same string the read-set holds

Scenario: the edit contract matches whichever spelling was read
  Given a file read by absolute path through read_file
  When edit_file is called on the same file by a relative path
  Then the precondition is satisfied

Scenario: the null session still tracks the process directory
  Given Session::Null
  When the process directory changes and a path is resolved
  Then the new directory is used
```
→ spec file: `spec/lain/session_spec.rb`

**Escalation triggers:**
- If any caller of `Session.normalize_path` cannot supply a cwd, stop rather than defaulting it
  to `Dir.pwd` — a default here silently reintroduces exactly the divergence this card removes.
- `session_record/replay.rb:58` re-feeds recorded paths through `record_read` on resume. Recorded
  paths are already absolute, so replay should be unaffected. If a replay spec fails, the recorded
  shape is not what this card assumed. Stop.
- `Session::Journaled#record_read` journals `SessionRead` only on a path's first read
  (`session.rb:392-397`). If normalization changes which reads count as "first", the record's
  meaning shifts — stop rather than accepting a churned count.

---

### T8 — Classify a path as ordinary, gated, or denied          [wave 1] [risk: medium]

**Depends on:** none
**Files:** create `lib/lain/sensitivity.rb`, `spec/lain/sensitivity_spec.rb`
**Reuse:** `Approval::Risk::Credential::NAMES` (`approval/risk.rb:256-258`) as the precedent for
suffix-matched name rules and for the widen-never-sharpen argument (`risk.rb:66-72`);
`Config::Answers` (`lib/lain/config/answers.rb`) as the shape for a validated config table.
**Shared-file wiring:** `require_relative "lain/sensitivity"` in `lib/lain.rb`.

One pure function of a path to `:ordinary | :gated | :denied`, plus the reason. **No filesystem
access, no file reading, no entropy** — it decides from the path alone, so every arm in this
chunk can call it freely.

- **denied** — `~/.ssh/id_*` (without `.pub`), `~/.gnupg/**`, `~/.aws/credentials`,
  `~/.config/gh/hosts.yml`, `~/.netrc`, `*.kdbx`, `~/.password-store/**`, browser
  `Cookies`/`Login Data`/`key4.db`, `~/.docker/config.json`, `~/.kube/config`.
- **gated, credential-shaped** — `.env`, `.env.*`, `.envrc`, `*.pem`, `*.p12`,
  `credentials.json`, `secrets.y*ml`, `.git-credentials`, `.npmrc`, `.pypirc`, `.gitconfig`,
  `terraform.tfstate`, `*.tfvars`.
- **gated, out-of-scope** — `~/Downloads`, `~/Documents`, `~/Desktop`, `~/Pictures`. A different
  reason, reported differently, same gate.

Config may **add** entries and may never remove a denied one. `$HOME` is injected, never read
from `ENV` inside the classifier, so specs need no real home.

**Acceptance criteria:**

```gherkin
Scenario: a private key is denied and a public key is not
  Given the paths "<home>/.ssh/id_ed25519" and "<home>/.ssh/id_ed25519.pub"
  When each is classified
  Then the first is :denied and the second is :ordinary

Scenario: dotenv variants are gated with a credential reason
  Given ".env", ".env.local" and ".envrc" under a project root
  When each is classified
  Then each is :gated and the reason names credential shape

Scenario: a home directory is gated for a different reason
  Given "<home>/Downloads/report.pdf"
  When it is classified
  Then it is :gated and the reason is not credential shape

Scenario: config may widen but not narrow
  Given a config adding "*.secret" as denied and removing "<home>/.netrc"
  When both paths are classified
  Then "x.secret" is :denied and "<home>/.netrc" is still :denied

Scenario: a path that does not exist classifies normally
  Given "<home>/.ssh/id_ed25519" on a filesystem where nothing under <home> exists
  When it is classified
  Then it is :denied

Scenario: classification is lexical, not resolved
  Given a symlink "notes.md" whose realpath is "<home>/.ssh/id_ed25519"
  When the symlink path is classified
  Then it is :ordinary, because the classifier reads the name it was given

Scenario: an ordinary source file is ordinary
  Given "lib/lain/session.rb" under a project root
  When it is classified
  Then it is :ordinary
```
→ spec file: `spec/lain/sensitivity_spec.rb`

**Escalation triggers:**
- The "classification is lexical" AC records a real hole: a symlink dodges the classifier. That
  is deliberate — `Approval::Risk::OutsideRoot` (`risk.rb:192-232`) chose lexical matching so it
  agrees with `Workspace::Restore`, and a stat here would put I/O in a classifier contracted to
  do none. If closing the symlink hole seems necessary, **stop** — it is a reasoned divergence
  from an existing decision and needs a ruling, not an implementation.
- A `~` in a path must be refused lexically, never handed to `File.expand_path`.
  `risk.rb:214-220` records why: on an SSSD/LDAP host that is a network call. If a rule seems to
  need tilde expansion, stop.

---

### T9 — Give the read and write sides one credential-pattern table          [wave 1] [risk: medium]

**Depends on:** none
**Files:** create `lib/lain/credential_patterns.rb`, `spec/lain/credential_patterns_spec.rb`;
modify `lib/lain/middleware/refuse_secret_writes.rb`,
`spec/lain/middleware/refuse_secret_writes_spec.rb`
**Reuse:** `Middleware::RefuseSecretWrites::PATTERNS` (`refuse_secret_writes.rb:50-56`) is the
table being lifted; `Approval::Risk::Credential::SHAPES` (`risk.rb:265-273`) is a *second* copy
of the same idea.
**Shared-file wiring:** `require_relative "lain/credential_patterns"` in `lib/lain.rb`, before
`middleware`.

One table, **selected per consumer**: `CredentialPatterns.for(:write)` is exactly today's set;
`CredentialPatterns.for(:content)` is that plus dotenv/TOML/YAML assignment shapes, which T10
runs over file bytes.

The selection is the point. "One table so the sides cannot drift" and "the read side needs shapes
the write side must not gain" are both true, and a single undifferentiated constant can only
satisfy one of them — widening it silently starts refusing `memory_write` on any prose containing
`foo: bar`. One place to read, an explicit statement of which shapes each side uses.

The reserved `"decline:"` namespace assertion (`refuse_secret_writes.rb:80-82`) must keep firing
against the relocated table.

**Acceptance criteria:**

```gherkin
Scenario: the write side's active set is unchanged
  Given the four pattern names the write side uses today
  When CredentialPatterns.for(:write) is read
  Then it holds exactly those four, with the same regexps

Scenario: the existing write refusals still hold
  Given the current refuse_secret_writes spec suite
  When it runs against the extracted table
  Then every example passes with no assertion edited

Scenario: a widened shape does not reach the write side
  Given the content-side dotenv assignment shape
  When a memory_write body contains "note: remember this"
  Then it is not refused

Scenario: the reserved decline namespace is still guarded
  Given a pattern name beginning with "decline:"
  When the table is loaded
  Then loading raises and names the reserved namespace

Scenario: dotenv assignments are matched on the content side
  Given the line "ANTHROPIC_API_KEY=sk-ant-0000000000000000000"
  When CredentialPatterns.for(:content) is scanned against it
  Then a pattern matches and is named

Scenario: hyphenated prose is not a key
  Given the text "ask-someone-to-help-with-this"
  When either set is scanned
  Then nothing matches
```
→ spec file: `spec/lain/credential_patterns_spec.rb`

**Escalation triggers:**
- `refuse_secret_writes.rb:44-48` records a real bug the `sk-` lookbehind fixed: unanchored, it
  matched inside hyphenated prose and refused a benign write under a pattern name it never
  honestly matched. Any regex edit must keep that lookbehind.
- If `Approval::Risk::Credential::SHAPES` cannot be folded in without changing what `Risk`
  classifies as risky, stop — `Risk` stays dead this chunk, and silently widening it now would
  make a later card's behavior impossible to attribute.

---

### T13 — Journal what was refused and what was masked          [wave 1] [risk: low]

**Depends on:** none
**Files:** create `lib/lain/telemetry/secret_boundary.rb`,
`spec/lain/telemetry/secret_boundary_spec.rb`
**Reuse:** `Telemetry::WriteRefused` (`telemetry/turn_stream.rb:322-346`) and its
`Guards::WriteRefused` carrier (`:40-45`) — the exact precedent, including the rule that a record
names *what matched*, never the matched bytes; `Telemetry::Journalable` (`telemetry.rb:21-36`).
**Shared-file wiring:** `require_relative "telemetry/secret_boundary"` in `lib/lain/telemetry.rb`.

Two records. `ReadRefused(tool_use_id:, path:, reason:)` for T12's denials.
`ReadRedacted(tool_use_id:, path:, regions:, released:)` for T15's masking, where `regions` and
`released` are **counts**, not content.

**This deliberately widens `WriteRefused`'s precedent by carrying a `path`.** `WriteRefused`
holds only `tool_use_id` and `pattern` precisely to keep sensitive material out of the Journal,
and a path can itself be the finding (`/home/joel/.ssh/id_ed25519`). The trade is taken for
debuggability — a refusal you cannot attribute to a file is not actionable — and the `Guard`
validates `path` as well as `reason` so the widening is deliberate rather than incidental.

**Acceptance criteria:**

```gherkin
Scenario: a refusal record names its reason
  Given a ReadRefused constructed with a nil reason
  When it is constructed
  Then it raises and says the reason must name what refused

Scenario: a refusal record names its path
  Given a ReadRefused constructed with a nil path
  When it is constructed
  Then it raises

Scenario: records serialize to one NDJSON line each
  Given one of each record
  When each is journaled
  Then each parses back as a single JSON object carrying its derived type

Scenario: the derived journal types are stable
  Given the two records
  When their journal types are read
  Then they are "read_refused" and "read_redacted"

Scenario: a redaction record carries counts, not content
  Given a ReadRedacted for a file with three regions of which one was released
  When it is journaled
  Then it reports 3 and 1, and no field holds file bytes

Scenario: records are deeply frozen and shareable
  Given one of each record
  When Ractor.shareable? is asked
  Then both answer true
```
→ spec file: `spec/lain/telemetry/secret_boundary_spec.rb`

**Escalation triggers:**
- `spec/lain/telemetry_spec.rb:13-14` hardcodes an eleven-name list and `:68-79` a matching
  type-name table. Neither enumerates all 36 records, so new records are *not* forced through
  them. If adding to those lists appears necessary to make a spec pass, stop — that turns a
  rename-regression guard into a registry, which is a different decision.

---

### T2 — Resolve a project root by walking, refusing `$HOME` and inherited git env   [wave 2] [risk: high]

**Depends on:** T1
**Files:** create `lib/lain/project/resolver.rb`, `spec/lain/project/resolver_spec.rb`
**Reuse:** `Lain::Project` (T1); `Paths` (`lib/lain/paths.rb`) for the XDG dirs the refusal set
names, injected so a spec can point them anywhere; `WorkerEnv`'s explicit-`nil`-scrubs rule
(`worker_env.rb:8-20`); `CLI::IsolationBackend#repo_root` (`cli/isolation_backend.rb:142-149`) is
an existing upward `.git` walk — read it before writing a second one.
**Shared-file wiring:** `require_relative "project/resolver"` in `lib/lain/project.rb`.

Six rungs, first match wins, each an ancestor-or-self of cwd: explicit flag → `root =` in
`.lain/config.toml` → nearest ancestor with `.lain/` → nearest ancestor with a `.git` entry
(directory **or** the one-line pointer file a linked worktree uses) → *(rung 5 reserved,
deliberately empty)* → cwd itself, `detected_by: :none`.

**Rung 5 is deliberately empty.** Non-VCS markers (`package.json`, `Cargo.toml`, `Gemfile`) are
not planned: in a monorepo the nearest `package.json` names a *package*, not the project, so it
would fight rung 4 and usually lose the case the monorepo user wanted. Do not add rung 5 without
a new ruling.

The refusal set — `$HOME`, `/`, `/tmp`, `/var/tmp`, `/etc`, `/usr`, the three XDG bases, and any
directory on a different mount point from cwd — is a **stop rule on the walk**, so it holds
whichever rung would have produced it. Hitting one falls through to rung 6 and records which rung
was rejected.

The walk is our own; it never shells to `git rev-parse --show-toplevel`. If a future card does
shell to git, `GIT_DIR`, `GIT_WORK_TREE`, `GIT_COMMON_DIR` and `GIT_CEILING_DIRECTORIES` must be
scrubbed from the child.

**Acceptance criteria:**

```gherkin
Scenario: a monorepo subtree resolves to the repo top
  Given a git repository at "/tmp/repo" with a subdirectory "services/ingest"
  When the resolver runs with cwd "/tmp/repo/services/ingest"
  Then root is "/tmp/repo", cwd is unchanged, and detected_by is :git

Scenario: a .lain directory beats the repo top
  Given a git repository at "/tmp/repo" containing "/tmp/repo/services/ingest/.lain"
  When the resolver runs with cwd "/tmp/repo/services/ingest/src"
  Then root is "/tmp/repo/services/ingest" and detected_by is :lain_dir

Scenario: a bare dotfiles repo does not make $HOME the root
  Given GIT_DIR and GIT_WORK_TREE in the environment naming a bare repo with work-tree <home>
  And a cwd of "<home>/scratch" that is under no other repository
  When the resolver runs
  Then root is "<home>/scratch", detected_by is :none, and the report names the refused rung

Scenario: $HOME is refused even when a .git directory sits in it
  Given a ".git" directory directly in <home>
  And a cwd of "<home>/notes"
  When the resolver runs
  Then root is "<home>/notes" and detected_by is :none

Scenario: an explicit root may be $HOME
  Given an explicit root argument of <home> and a cwd of <home>
  When the resolver runs
  Then root is <home>, kind is :home, and detected_by is :flag

Scenario: a linked worktree's pointer file counts as a .git entry
  Given a linked worktree whose ".git" is a one-line "gitdir:" file
  When the resolver runs from inside it
  Then that worktree directory is the root and detected_by is :git

Scenario: the walk stops at a mount boundary
  Given a cwd whose parent directory is on a different device
  When the resolver runs and no marker is found below the boundary
  Then root is cwd and detected_by is :none
```
→ spec file: `spec/lain/project/resolver_spec.rb`

**Escalation triggers:**
- The `$HOME`-with-`.git` scenario passes only because the refusal set fires *after* rung 4
  matched. If an implementation makes rung 4 skip `$HOME` itself instead, the stop rule is no
  longer general — stop, because that is the whole reason it is a stop rule and not a
  git-detector special case.
- A spec needs to write to the real `$HOME` to exercise the refusal set. It must not. Stop and
  make the home directory an injected collaborator.
- If `cli/isolation_backend.rb:142-149` walks with different semantics (following symlinks,
  different ceiling), stop and reconcile. Two walks that disagree about "the repo root" is the
  bug this card exists to prevent, and T5 carries the second half of that reconciliation.

---

### T3 — Detect the dotfiles flavour behind a home-kind root          [wave 2] [risk: medium]

**Depends on:** T1
**Files:** create `lib/lain/project/dotfiles.rb`, `spec/lain/project/dotfiles_spec.rb`
**Reuse:** `Lain::Project` (T1); the `:seam` tag convention (CLAUDE.md, Testing) — this drives
real `git`, so it is a seam spec at its mirror path.
**Shared-file wiring:** `require_relative "project/dotfiles"` in `lib/lain/project.rb`.

Three named detectors answering one question — *where does an edit belong?* — and nothing else:

- **bare** — a `core.bare=true` repository (conventionally `~/.cfg`) whose work-tree is `$HOME`.
  The tracked file set is the editable surface.
- **stow** — `~/dotfiles/<pkg>/...` symlinked into `$HOME`. Resolving a symlinked path yields the
  package directory, which joins the editable surface so an edit lands in the repo rather than
  through the link into an untracked copy.
- **plain** — the Null Object. No special surface.

Flavour is a **convenience**. T8's classification and T12's refusals hold regardless of what this
answers, and that ordering is the requirement — a wrong flavour must never widen access.

**Acceptance criteria:**

```gherkin
Scenario: a bare repo with a home work-tree is detected
  Given a bare repository at "<tmp>/.cfg" whose work-tree is "<tmp>"
  When the flavour is detected for a home root of "<tmp>"
  Then it reports :bare and names the repository directory

Scenario: a stow package is followed through its symlink
  Given "<tmp>/dotfiles/zsh/.zshrc" symlinked to "<tmp>/.zshrc"
  When the flavour is detected for a home root of "<tmp>"
  Then it reports :stow and the editable surface includes "<tmp>/dotfiles"

Scenario: neither convention present
  Given a home root with no bare repository and no symlinks into a package tree
  When the flavour is detected
  Then it reports :plain and the editable surface is the root alone

Scenario: a wrong flavour cannot widen access
  Given a detector that reports :bare for a directory holding no repository
  When the editable surface is asked for
  Then it is empty rather than the whole home directory
```
→ spec file: `spec/lain/project/dotfiles_spec.rb`

**Escalation triggers:**
- Detection needs to shell to `git` to read `core.bare`. Every such call must scrub the four git
  env vars T2 names, or a leaked `GIT_DIR` makes this answer `:bare` for any directory at all.
- The stow detector wants to walk all of `$HOME` to find symlinks. It must not — that is an
  unbounded walk over a directory holding `~/.cache`. Stop and bound it to one level plus the
  known dotfile names.

---

### T10 — Find and content-address the sensitive regions in a file          [wave 2] [risk: high]

**Depends on:** T9
**Files:** create `lib/lain/sensitivity/regions.rb`, `spec/lain/sensitivity/regions_spec.rb`
**Reuse:** `CredentialPatterns.for(:content)` (T9); `Workspace::Snapshot`'s blob-framing idiom
(`workspace/snapshot.rb:75`) — `Ext.blake3_hex("blob #{bytesize}\0".b + bytes.b)`.
**Shared-file wiring:** `require_relative "sensitivity/regions"` in `lib/lain/sensitivity.rb`.

Two detectors over file content: the issuer-fixed credential patterns from T9, and a
Shannon-entropy run detector for high-entropy tokens the patterns miss.

**A region's identity is the digest of its own bytes, never its offset.** Digesting
`(start, length)` would make a line inserted above invalidate every region below it — whole-file
behavior wearing a region's name.

**Do not use `Canonical.digest` here.** `review/hunk.rb:10-14` settles this for the identical
problem: *"a hunk body is already bytes, and routing it through a JSON-native canonicalization
would normalize away differences the key exists to keep."* `Canonical.digest` runs
`JSON.generate` first, which can collide two byte sequences into one address and raises outright
on invalid encoding.

Entropy here is **triage, not a verdict**: it routes a file to review, and its false positives
(minified JS, lockfile hashes, UUID fixtures) cost one review each because T14 caches by digest
and T15 gives every masked region a release path. Widen the thresholds rather than sharpening
them; a miss is categorically worse than a prompt, which is the asymmetry `risk.rb:66-72` already
argues for.

**Acceptance criteria:**

```gherkin
Scenario: a dotenv key is one region
  Given a file with three ordinary lines and one line assigning an API key
  When regions are detected
  Then exactly one region is reported, covering the VALUE and not the name

Scenario: a region's digest survives an unrelated edit
  Given a file with one detected region
  When a comment line is inserted above the region
  Then the region's digest is unchanged

Scenario: a new secret is a new region
  Given a file whose regions have all been seen
  When a second key assignment is added elsewhere in the file
  Then the region set gains one digest and the existing digests are unchanged

Scenario: two regions differing only in escaping have different digests
  Given two regions whose bytes differ only by a backslash escape
  When each is digested
  Then the two digests differ

Scenario: a high-entropy token with no pattern is still found
  Given a file containing a 48-character base64 token with no recognizable prefix
  When regions are detected
  Then it is reported, with entropy named as the reason

Scenario: ordinary prose yields no regions
  Given a README of English prose
  When regions are detected
  Then the region set is empty

Scenario: undecodable bytes do not raise
  Given a file of UTF-16 bytes and a file of random binary
  When regions are detected on each
  Then neither raises and each returns a region set

Scenario: detection is deterministic
  Given the same file bytes
  When regions are detected twice
  Then the two region sets are equal, in the same order
```
→ spec file: `spec/lain/sensitivity/regions_spec.rb`

**Escalation triggers:**
- `risk.rb:322` shows why the undecodable-bytes AC is not paranoia: `valid_encoding?` answers
  true for every UTF-16 String, which then raises `Encoding::CompatibilityError` out of the first
  Regexp — and that is **not** an `ArgumentError`, so no naive rescue catches it. If the detector
  raises on any input, stop.
- `Ext.blake3_hex` is documented **not Ractor-safe** (`review/hunk.rb:17`), and
  `Tools::ReadFile#parallel_safe?` is true (`read_file.rb:33`) — parallel-safe tools fan out as
  sibling fibers (`agent/tool_runner.rb:225`). Fibers are not Ractors, so this should be fine;
  confirm rather than assume, and if digesting must move off the parallel path, stop.
- If entropy detection is visibly slow on an ordinary source file, stop and report the
  measurement rather than shipping it.

---

### T11 — Gate a sensitive path at the approval handler, not inside a tool          [wave 2] [risk: high]

**Depends on:** T8
**Files:** create `lib/lain/sensitivity/policy.rb`, `spec/lain/sensitivity/policy_spec.rb`;
modify `lib/lain/effect/handler/gate.rb`, `spec/lain/effect/handler/gate_spec.rb`
**Reuse:** `Sensitivity` (T8); `Effect::Handler::Gate#gated_tool_call?`
(`effect/handler/gate.rb:81-89`), which already holds both the effect and the resolved tool;
`Middleware::RefuseSecretWrites::NullOracle` (`refuse_secret_writes.rb:104-112`) as the
Null-Object-default shape.
**Shared-file wiring:** `require_relative "sensitivity/policy"` in `lib/lain/sensitivity.rb`;
`sensitivity:` injection into `Switchboard#gate` in `lib/lain/cli/switchboard.rb`.

`Gate` gains an injected `sensitivity:` collaborator answering `#gates?(effect)`, so
`gated_tool_call?` becomes `tool.requires_approval? || @sensitivity.gates?(effect)`. **Tier-1
tools are not touched.**

The policy owns the one piece of coupling this design needs: a declarative table of which input
field names a path per tool (`read_file`/`glob`/`grep`/`list_files`/`edit_file`/`write_file` →
`path`; `bash`/`core_exec` → `cwd`). One object holds it.

This is the **path** boundary and it is pre-read. Content cannot be judged here — that is T15,
post-read, and the two are deliberately separate.

The default is `Sensitivity::Policy::Null`, which gates nothing, so an unwired chat behaves
byte-identically to today.

**Acceptance criteria:**

```gherkin
Scenario: a gated path makes an ungated tool require approval
  Given a read_file effect naming ".env"
  When the gate is asked whether it handles the effect
  Then it does, and the approval policy is consulted

Scenario: an ordinary path is untouched
  Given a read_file effect naming "README.md"
  When the gate is asked whether it handles the effect
  Then it does not, and the effect falls through to the inner handler

Scenario: an already-gated tool stays gated regardless
  Given a bash effect and a sensitivity policy that gates nothing
  When the gate is asked whether it handles the effect
  Then it does, because the tool declares it

Scenario: the null policy preserves today's behavior exactly
  Given a gate constructed with no sensitivity policy
  When every shipped tool is offered
  Then exactly bash and core_exec are gated

Scenario: an unknown tool name is not gated by sensitivity
  Given an effect naming a tool the toolset does not hold
  When the gate is asked
  Then it declines and lets the inner handler raise its usual unknown-tool error

Scenario: a subagent's gate carries the same policy as its parent
  Given a chat wired with a real sensitivity policy
  When a subagent's gate is built
  Then it gates the same paths the parent's gate does
```
→ spec file: `spec/lain/sensitivity/policy_spec.rb`

**Escalation triggers:**
- `tools/subagent.rb:797` builds a second `Effect::Handler::Gate` with `@seam.gate_policy`. If a
  child gate constructed without the sensitivity policy would let a subagent read what its parent
  may not, stop — that is a privilege inversion, not a wiring omission to fix later. The last AC
  exists to catch it.
- `Approval::Rule::Call#gated?` (`approval/rule.rb:172`) is a **second reader** of
  `tool.requires_approval?` and will now disagree with the gate for a sensitive path. If that
  divergence changes any decision, stop and reconcile the two readers.
- If gating `read_file` makes it fail `spec/lain/tools/parallel_safety_spec.rb:115-140` (which
  pins the exact true/false partition over `ToolRegistry.shipped_names`), stop: this card must
  not change any tool's parallel-safety claim.

---

### T20 — Deny a command whose argv names a protected path          [wave 2] [risk: high]

**Depends on:** T8
**Files:** modify `lib/lain/approval/escalation.rb`, `spec/lain/approval/escalation_spec.rb`
**Reuse:** `Approval::Escalation::Triage` (`approval/escalation.rb:403-451`) and its existing
`Shell::Verdict` wiring; `Shell::Verdict::Decision#term` (`shell/verdict.rb:243-245`);
`Sensitivity` (T8).
**Shared-file wiring:** none.

**Which branch this touches, precisely.** `Decision#term` is populated **only on an allow**
(`shell/verdict.rb:243-245`; deny and abstain both carry `NO_TERM`). So the argv check can only
run on the allow branch — the one `escalation.rb:441` currently downgrades to abstain. This card
adds a **new deny on that branch**; it does not feed the existing deny arm, which reads
`decision.deny?` and is unreachable today because nothing in `lib/` constructs a restricting
`capability_set` (`escalation.rb:159-163`). An implementer who goes looking for the existing deny
arm to supply will find dead code.

**Read the argv words, never the raw command string.** `approval/rule.rb:36-52` and
`risk.rb:74-80` both name the same hole — the signals do not compose over a single field — and
reading a parsed term is the direction MA-1 points.

**Scope boundary:** deny only. A *gated* path in an argv stays an abstain, because `Triage`
already downgrades every allow to abstain, so it reaches a human regardless. A second gating
notion here would duplicate T11 without adding a decision.

**Acceptance criteria:**

```gherkin
Scenario: a literal read of a denied path is denied
  Given a bash call "cat <home>/.ssh/id_ed25519"
  When triage judges it
  Then it denies and the reason names the protected path

Scenario: an ordinary command still abstains
  Given a bash call "ls -la"
  When triage judges it
  Then it abstains, exactly as today

Scenario: an unparseable command still abstains
  Given a bash call the parser cannot fully cover
  When triage judges it
  Then it abstains and no path check is attempted

Scenario: a gated path is not denied here
  Given a bash call "cat .env"
  When triage judges it
  Then it abstains and reaches the human

Scenario: the deny is read off argv, not the string
  Given a command whose raw text contains a denied path inside a quoted argument the parser abstains on
  When triage judges it
  Then it abstains rather than denying on a substring match
```
→ spec file: `spec/lain/approval/escalation_spec.rb`

**Escalation triggers:**
- A path check that falls back to substring-matching the raw command string when the parse
  abstains would reintroduce exactly the false confidence `rule.rb:36-52` warns about. If the
  argv-only rule seems to miss too much, stop and report the gap.
- `Escalation`'s fault machinery suppresses an allow reached over a fault unless the decider is
  human (`escalation.rb:243-257`). If a raise from the sensitivity check turns a would-be deny
  into a fault-abstain, the protected path is now merely gated. Stop.

---

### T22 — Let the read-set distinguish a whole read from a partial one          [wave 2] [risk: medium]

**Depends on:** T7
**Files:** modify `lib/lain/session.rb`, `spec/lain/session_spec.rb`
**Reuse:** `Session`'s read-set (`session.rb:93-125`); the two edit-before-write contracts
(`tools/edit_file.rb:35-37`, `tools/write_file.rb:38-42`), which are the only readers.
**Shared-file wiring:** none.

**This card exists because T15 cannot be built without it.** `Tools::ReadFile` calls
`session.record_read` inside `#perform` (`read_file.rb:52`) — *below* the middleware — so by the
time `RedactSecretReads` decides to mask, the read is already recorded. The read-set is add-only
(`session.rb:93-101`): there is nothing to undo it with.

A model that saw only `<redacted:1>` and then writes the file clobbers every secret in it. So the
read-set gains a completeness bit: `record_read(path, complete: true)`, and `read?` answers true
only for a complete read. `partially_read?` answers the other case, so an error message can tell
a model *why* the edit was refused rather than claiming it never read the file.

Recording completeness at the Session rather than un-recording from the middleware keeps the
read-set add-only and monotone, which is what makes it safe to touch from parallel-safe tools.

**Acceptance criteria:**

```gherkin
Scenario: a complete read satisfies the edit contract
  Given a file recorded as read with complete true
  When edit_file is called on it
  Then the precondition is satisfied

Scenario: a partial read does not
  Given a file recorded as read with complete false
  When edit_file is called on it
  Then the precondition fails

Scenario: a partial read is distinguishable from no read at all
  Given one file recorded partially and one never read
  When each is asked about
  Then the first reports partially read and the second reports neither

Scenario: a later complete read upgrades a partial one
  Given a file recorded partially, then recorded complete
  When edit_file is called on it
  Then the precondition is satisfied

Scenario: a complete read is not downgraded by a later partial one
  Given a file recorded complete, then recorded partially
  When edit_file is called on it
  Then the precondition is still satisfied

Scenario: the default is a complete read
  Given a file recorded with no completeness argument
  When it is asked about
  Then it reports as completely read
```
→ spec file: `spec/lain/session_spec.rb`

**Escalation triggers:**
- The "not downgraded" AC is the monotonicity property the parallel-safe tools depend on. If an
  implementation makes completeness a plain overwrite, two sibling fibers reading the same file
  can race a complete read into a partial one. Stop.
- `Session::Journaled#record_read` journals only on first read (`session.rb:392-397`). If a
  partial-then-complete sequence journals once, twice, or with the wrong flag, the Journal no
  longer describes what the model saw — stop and settle the record's shape before proceeding.
- `write_file`'s contract is narrower than `edit_file`'s: it allows a create over a nonexistent
  path (`write_file.rb:38-42`). Confirm completeness does not accidentally block creates.

---

### T5 — Thread a resolved `Project` through the chat wiring          [wave 3] [risk: high]

**Depends on:** T1, T2, T4
**Files:** modify `lib/lain/cli/wiring.rb`, `lib/lain/cli/chat_launch.rb`,
`lib/lain/cli/isolation_backend.rb`; modify `spec/lain/cli/wiring_spec.rb`,
`spec/lain/cli/chat_launch_spec.rb`; create `spec/lain/project/root_defaults_spec.rb`
**Reuse:** `Project`/`Project::Resolver` (T1, T2); `Wiring::AgentBuild` (T4) for the headroom;
`spec/lain/project_dir_spec.rb` and `spec/output_discipline_spec.rb` as the two existing
AST-walking guard specs to model the new one on.
**Shared-file wiring:** none.

`Wiring` gains a `project:` keyword defaulting to a resolved Project, and passes it to the five
sites that today reach `Dir.pwd`: `Session.new(worker_env:)` (`:274`),
`IsolationBackend.resolve(root:)` (`:326`), `Command::Surface.new(root:)` (`:531-535`),
`EpicMount.for(root:)` and `ReviewSeams.for(root:)` (`:388-392`).

**Two extras this card owns, both recovered from the panel review:**

1. **The second walk.** `cli/isolation_backend.rb:142-149` ascends for `.git` with no ceiling and
   no refusal set. On a box with a `.git` in `$HOME` — the `~/.cfg` case this whole chunk is built
   around — `--isolation worktree` would still resolve `$HOME` as the repo and branch worktrees
   off the dotfiles repo, straight past T2's stop rule. `repo_root` must consult the same refusal
   set, or the boundary holds only at root detection and not where it matters.
2. **The guard spec** (draft R7). The ~35 remaining `root: Dir.pwd` defaults stay as defaults —
   they are what makes the library usable outside a CLI boot — but nothing new gets one. An AST
   walk over `lib/` fails on a *newly added* `root: Dir.pwd`, with the current set as an explicit
   allowlist. A documentation line does not stop the forty-first one.

**Acceptance criteria:**

```gherkin
Scenario: the session's working directory follows the project
  Given a Project with cwd "/tmp/repo/services/ingest"
  When a chat is wired
  Then the Session's worker_env.cwd is "/tmp/repo/services/ingest"

Scenario: root-consuming collaborators receive the project root, not Dir.pwd
  Given a Project with root "/tmp/repo" and cwd "/tmp/repo/services/ingest"
  When a chat is wired
  Then the isolation backend, command surface, epic mount and review seams all receive "/tmp/repo"

Scenario: the isolation repo walk honors the refusal set
  Given a ".git" directory in <home> and a project root of "<home>/scratch"
  When the isolation backend resolves its repo root
  Then it does not answer <home>

Scenario: the default is byte-identical to today
  Given no project is supplied
  When a chat is wired from a directory that is its own root
  Then the Session's worker_env equals WorkerEnv.default's

Scenario: a new Dir.pwd root default fails the guard
  Given a file in lib/ declaring a new "root: Dir.pwd" keyword default
  When the guard spec runs
  Then it fails and names the file and the method

Scenario: the existing root defaults do not fail the guard
  Given lib/ as it stands
  When the guard spec runs
  Then it passes
```
→ spec file: `spec/lain/cli/wiring_spec.rb`, `spec/lain/project/root_defaults_spec.rb`

**Escalation triggers:**
- `wiring.rb:310-313` documents a deliberate choice that the main chat's Session uses
  `WorkerEnv.default` because *"the user's own edits belong in the user's own tree."* This card
  changes that. If the comment's reasoning covers a case the Project's cwd breaks — particularly
  any interaction with `Isolation::Worktree#worker_env_for` — stop and confirm.
- `Command::Surface` gets no `root:` today and silently sits on `Dir.pwd`
  (`cli/command/surface.rb:46`). Passing a real root may move where `/meta`, `/review` and
  `/review-submit` look. If an existing spec pins the old location, stop.
- If `Metrics/ClassLength` fires on `wiring.rb` again, T4's extraction was not enough — stop
  rather than loosening the cop (CLAUDE.md forbids it).

---

### T12 — Refuse a denied path outright, loudly, before any approval          [wave 3] [risk: medium]

**Depends on:** T8, T11
**Files:** create `lib/lain/effect/handler/sensitivity.rb`,
`spec/lain/effect/handler/sensitivity_spec.rb`
**Reuse:** `Effect::Handler` (`lib/lain/effect/handler.rb`) and its `inner:` nesting;
`Effect::Handler::Gate#perform`'s refusal shape (`effect/handler/gate.rb:64-72`) — a denial is
*reported* as an error `Tool::Result`, never raised; `Sensitivity::Policy` (T11) for the
tool→path-field table; `Telemetry::ReadRefused` (T13).
**Shared-file wiring:** `require_relative "handler/sensitivity"` in `lib/lain/effect/handler.rb`;
insertion ahead of `Gate` in `Switchboard#gate` (`lib/lain/cli/switchboard.rb`).

A handler sitting **ahead of** `Gate`. A denied path is not approvable — no policy, no `--yolo`,
no `ApproveAll` lifts it — so it cannot be a `Gate` policy answer, which is boolean and always
approvable by construction.

The refusal is **loud**: `"refused: protected path <path>"`. It teaches the model the boundary so
it stops retrying variants. The message names the path but never the file's contents.

**Acceptance criteria:**

```gherkin
Scenario: a denied path is refused with a named reason
  Given a read_file effect naming "<home>/.ssh/id_ed25519"
  When the effect is interpreted
  Then the result is an error naming the path as a protected path
  And no file is read

Scenario: approve-all does not lift a denial
  Given the gate policy is ApproveAll
  When a read_file effect names a denied path
  Then it is still refused

Scenario: a gated path is not refused here
  Given a read_file effect naming ".env"
  When the effect is interpreted
  Then this handler declines and the effect reaches the gate

Scenario: the refusal names no file contents
  Given a denied path whose file exists and holds a key
  When the effect is refused
  Then the message contains the path and none of the file's bytes

Scenario: the refusal is journaled once
  Given a denied read
  When it is refused
  Then exactly one ReadRefused record is journaled, naming the path and the reason

Scenario: an ordinary path passes straight through
  Given a read_file effect naming "README.md"
  When the effect is interpreted
  Then this handler declines and the inner handler runs it
```
→ spec file: `spec/lain/effect/handler/sensitivity_spec.rb`

**Escalation triggers:**
- If placing this handler ahead of `Gate` means an `Effect::Approval` wrapper (which
  `gate.rb:66-67` unwraps) reaches it in a shape it does not expect, stop — the unwrapping
  contract belongs to `Gate` and must not be duplicated here.
- `tools/subagent.rb:797` gates children separately. If this handler is not in the child chain, a
  subagent can read what its parent cannot. Stop and report rather than shipping the parent-only
  arm.

---

### T14 — Give the run exactly one region ledger          [wave 3] [risk: medium]

**Depends on:** T10
**Files:** create `lib/lain/sensitivity/ledger.rb`, `spec/lain/sensitivity/ledger_spec.rb`
**Reuse:** `Sensitivity::Regions` (T10); `Session`'s read-set (`session.rb:93-125`) as the shape
for run-scoped, deliberately-mutable membership state;
`Approval::Risk::Classification#rememberable?` (`risk.rb:164`) for why this is session-scoped.
**Shared-file wiring:** `require_relative "sensitivity/ledger"` in `lib/lain/sensitivity.rb`;
one ledger constructed in `lib/lain/cli/switchboard.rb` and handed to **both**
`Approval::Queue`'s surfaces and `CLI::ToolGuard.stack` in `lib/lain/cli/tool_guard.rb`.

A set of released region digests, and one question: *given this file's current regions, which are
not yet released?* Every read re-runs the detector and diffs against the ledger, which is what
makes a newly-added secret prompt even in a file approved a minute ago.

**Ownership is this card's real content, not the data structure.** T15 (masking) reads the ledger
and T16 (the prompt) writes it, and they land in different waves through different files. Two
half-wirings produce two ledgers and a control that silently releases nothing. So one ledger is
constructed at the switchboard and injected into both arms, and there is an AC for it.

**Session-scoped by default, and that is the security property.** Persisting "yes, send
`.env.local`" across sessions is exactly the risky answer `Classification#keepsake` refuses to
mint (`risk.rb:150-158`).

**Acceptance criteria:**

```gherkin
Scenario: a released region is not asked about twice
  Given a file with two regions, both released
  When the same bytes are read again
  Then nothing is outstanding

Scenario: a new region in an approved file is outstanding
  Given a file whose two regions are released
  When a third key is added and the file is read
  Then exactly the new region is outstanding

Scenario: a removed region is dropped, not remembered
  Given a file whose two regions are released
  When one is deleted and the file is read
  Then nothing is outstanding and the ledger no longer holds the removed digest

Scenario: releases do not leak between files
  Given a region digest released for one file
  When a different file yields the same region digest
  Then it is outstanding for that file

Scenario: the masking arm and the approval arm share one ledger
  Given a wired chat
  When the redaction middleware and the approval surfaces are each asked for their ledger
  Then both answer the same object

Scenario: the ledger does not survive the session
  Given a ledger with releases
  When a new session is constructed
  Then nothing is released
```
→ spec file: `spec/lain/sensitivity/ledger_spec.rb`

**Escalation triggers:**
- If "releases do not leak between files" turns out to be wrong for the intended UX — a shared
  `Cargo.lock` hash approved once across a monorepo — stop and confirm. Keying by
  `(path, region_digest)` versus `region_digest` alone is a real security/UX trade.
- `Session` is explicitly *not* a value object and *not* frozen (`session.rb:4`), while
  everything else in this chunk is deeply frozen. If the ledger ends up on the Session, confirm
  the ownership deliberately — mixing lifetimes silently is how state outlives its run.

---

### T6 — Accept a path on `lain up` and a root on `lain chat`          [wave 4] [risk: medium]

**Depends on:** T2, T5
**Files:** modify `exe/lain`, `lib/lain/cli/up.rb`; modify `spec/lain/cli/up_spec.rb`
**Reuse:** `Project::Resolver` (T2); `Up::Cockpit` (`lib/lain/cli/up/cockpit.rb`) and its
`derived_socket`; `LainCLI.double_dash?` / `Boundary#chat_flags!` (`exe/lain:76-80, 102-107`).
**Shared-file wiring:** none.

`lain up [PATH]` and `lain chat --root PATH --cwd PATH`. PATH expands against `Dir.pwd`; a
non-directory is a refusal, never a silent fallback.

Two mechanical traps: `def up(*chat_args)` swallows everything and `chat_flags!` raises on any
trailing arg without a `--`, so the signature becomes `def up(path = nil, *chat_args)` while
still refusing a *second* stray positional. And `Up#default_state_path` (`up.rb:297`) and the
non-cockpit `new_session_args` (`up.rb:175-178`) do not read `cwd` — both must follow the
resolved project, or the HUD reads one project's `.lain/state.json` while the panes sit in
another.

**Acceptance criteria:**

```gherkin
Scenario: a relative path becomes the session cwd
  Given a launch from "/tmp" with the argument "repo/services"
  When the launch plan is built
  Then both panes are pinned to "/tmp/repo/services"

Scenario: the HUD follows the path, not the shell
  Given a launch from "/tmp" with the argument "repo"
  When the launch plan is built
  Then the status feed path is "/tmp/repo/.lain/state.json"

Scenario: the plain session is pinned too
  Given --no-nvim and a path argument
  When the launch plan is built
  Then the tmux new-session argv carries -c with the resolved path

Scenario: the nvim socket follows the resolved cwd
  Given two launches with different path arguments
  When each derives its socket
  Then the two socket paths differ

Scenario: a stray second positional is still refused
  Given "lain up /tmp/repo typo" with no -- separator
  When the command runs
  Then it raises and tells the user to pass chat flags after --

Scenario: a path that is not a directory is refused
  Given "lain up /etc/hostname"
  When the command runs
  Then it raises naming the path, and no tmux session is created
```
→ spec file: `spec/lain/cli/up_spec.rb`

**Escalation triggers:**
- `--nvim`'s `lazy_default: ""` greedily eats the next argv token — `Cockpit::SwallowedFlag`
  (`cockpit.rb:90-96`) exists because of it, and a positional PATH sits in the same argv
  position. If `lain up --nvim /tmp/repo` binds the path to `--nvim`, stop: that is a Thor
  ordering problem, not something to paper over with a heuristic.
- If honoring PATH means `Up` reads `Dir.pwd` in a third place not listed here, stop — the point
  is that all of `Up`'s root-shaped facts come from one value.

---

### T16 — Let a pending carry regions, and show them to a human          [wave 4] [risk: medium]

**Depends on:** T14
**Files:** modify `lib/lain/approval/queue.rb`, `lib/lain/frontend/approval_policy.rb`,
`spec/lain/approval/queue_spec.rb`, `spec/lain/frontend/approval_policy_spec.rb`
**Reuse:** `Approval::Queue::Pending` (`approval/queue.rb:47-92`); `Queue#admit` (`:163-169`);
`Frontend::ApprovalPolicy#prompt_for` (`frontend/approval_policy.rb:64-66`) and its **injected
reader** (`cli/switchboard.rb:181-183`), which is what keeps `lib/` off the terminal;
`Sensitivity::Ledger` (T14).
**Shared-file wiring:** none.

A **capability**, not a flow: `Pending` can carry a list of outstanding regions, and
`ApprovalPolicy` renders them. T15 is what constructs such a pending, because T15 is the only
object in the system that holds the file's bytes — the Queue sits *below* the read and has only a
path.

`Pending#decide` stays a pure decision. **The ledger is written by whoever settled the pending
(T15), not inside `decide`** — `queue.rb:107-115` rests its no-lock claim on every `Pending`
mutation being straight-line, and hanging a security-ledger write off it adds a second
responsibility to the one object that cannot afford one.

`lib/` may not touch `$stdout` (`spec/output_discipline_spec.rb`), so rendering stays in
`Frontend::ApprovalPolicy` behind the injected reader.

**Acceptance criteria:**

```gherkin
Scenario: the prompt names the file and the region count
  Given a pending carrying two outstanding regions for ".env"
  When the prompt is rendered
  Then it names the file and says two regions are outstanding

Scenario: an ordinary approval prompt is unchanged
  Given a pending carrying no regions
  When the prompt is rendered
  Then it reads exactly as it does today

Scenario: the prompt shows no secret bytes
  Given a pending whose regions hold an API key
  When the prompt is rendered
  Then the key's bytes do not appear in the rendered text

Scenario: deciding a pending does not touch the ledger
  Given a pending carrying regions and a ledger with no releases
  When the pending is approved
  Then the ledger is still empty, because releasing is the caller's move

Scenario: a region-carrying pending is still ordinary coordination state
  Given a pending carrying regions
  When it is decided from two fibers at once
  Then the first answer wins and the second reports that it did not
```
→ spec file: `spec/lain/frontend/approval_policy_spec.rb`

**Escalation triggers:**
- `spec/lain/approval/queue_concurrency_spec.rb` pins the no-lock claim
  (`approval/queue.rb:107-115`). If carrying regions requires a lock, stop — that invalidates a
  property the queue's design rests on.
- The prompt must not render secret bytes. If showing "what is being released" seems to require
  showing the values, stop: a masked preview's shape is a ruling, not a detail.

---

### T18 — Honor remembered answers from a root the user has consented to          [wave 4] [risk: high]

**Depends on:** T5
**Files:** create `lib/lain/project/consent.rb`, `spec/lain/project/consent_spec.rb`;
modify `spec/lain/cli/switchboard_spec.rb`
**Reuse:** `Approval::Remembered.from(config)` (`approval/remembered.rb:133-136`);
`Config.load(root:)` (`config.rb:79`); `Approval::Escalation.for` (`escalation.rb:168-170`),
whose `rules:` parameter already exists and is passed empty; `Paths#project_hash` and
`Paths#state_home` (`paths.rb:160,177`) for where consent is recorded.
**Shared-file wiring:** `rules:` argument into `Escalation.for` in `lib/lain/cli/switchboard.rb`.

`escalation.rb:156-158` states the blocker: *"T20's remembered answers need a project root the
switchboard does not hold."* T5 gives it one.

**But a root is not automatically a trusted root, and that is this card's real content.**
`Config::Answers` (`config/answers.rb:26-30`) accepts `[[approval.allow]]` entries naming a tool
and an input shape, and T18 makes them the **first deterministic rung** — short-circuiting before
the queue and before any human. Compose that with T2 rung 3, where the nearest ancestor `.lain/`
wins, and `git clone && lain up ./thing` grants whatever that repository's `.lain/config.toml`
pre-approved. The requirements draft called this Q-D and guessed it was paranoid; it was written
when nothing read that table.

So `[approval]` is honored only from a **consented** root. Consent is recorded once per root in
XDG state, keyed by `Paths#project_hash(root)`, and is granted by an explicit `--root`/`--cwd`
(`detected_by == :flag`) or by an interactive first-run confirmation. Everything else in
`config.toml` — `[epics]` and the rest — loads as it does today; only the pre-approval table is
gated, because it is the only table that can grant authority.

**Scope boundary:** the **read** side only. `Remembered::Persister` and `Approval::Risk` stay
unwired — the persister needs a live classification and a UI affordance this chunk does not
build.

**Acceptance criteria:**

```gherkin
Scenario: an unconsented root's approval table is ignored
  Given a cloned repository whose .lain/config.toml allows bash with any command
  And no recorded consent for that root
  When a bash call matching that entry is made
  Then the rules rung abstains and the call reaches the queue

Scenario: an explicitly named root is consented by that fact
  Given the same repository, opened with an explicit --root
  When a matching call is made
  Then the rules rung allows it

Scenario: consent survives into a later session
  Given a root consented to in an earlier session
  When a new session opens the same root and a matching call is made
  Then the rules rung allows it

Scenario: consent is keyed per root
  Given consent recorded for one root
  When a different root with the same config content is opened
  Then its approval table is ignored

Scenario: a remembered deny beats a remembered allow
  Given a consented root whose config both allows and denies the same call shape
  When the call is made
  Then it is denied

Scenario: a tool-wide refusal needs no consent
  Given an unconsented root whose config refuses the bash tool outright
  When any bash call is made
  Then it is denied, because a refusal grants no authority

Scenario: an absent config file changes nothing
  Given a project root with no .lain/config.toml
  When any call is made
  Then behavior is identical to today

Scenario: a malformed config does not prevent launch
  Given a .lain/config.toml whose [approval] table is malformed
  When a chat is launched
  Then it starts, the approval table is ignored, and the problem is reported once
```
→ spec file: `spec/lain/project/consent_spec.rb`

**Escalation triggers:**
- The "tool-wide refusal needs no consent" AC encodes the asymmetry this card rests on: config
  may always *restrict* and may only *grant* with consent. If an implementation gates both
  directions behind consent, an untrusted repo's `deny_tool` stops working and the safe direction
  is now the one being blocked. Stop.
- `approval/rule.rb:36-52` names a live hazard: a hand-written prefix rule such as
  `command.start_with?("git ")` would allow `git -c core.fsmonitor=id status`, which executes
  `id`. `Remembered` is safe because it matches an exact call shape, not a prefix — if the wiring
  makes any prefix or partial match possible, stop. That is MA-1 and this card must not open it.
- If the first-run consent prompt cannot be surfaced without a TTY (a headless or cron run),
  the answer must be "not consented", never "consented by default". If that ordering is awkward
  to implement, stop rather than inverting it.

---

### T15 — Mask unreleased regions, and give the human a way to release them   [wave 5] [risk: high]

**Depends on:** T10, T13, T14, T16, T22
**Files:** create `lib/lain/middleware/redact_secret_reads.rb`,
`spec/lain/middleware/redact_secret_reads_spec.rb`; modify `spec/lain/cli_spec.rb`
**Reuse:** `Middleware::RefuseSecretWrites` (`middleware/refuse_secret_writes.rb`) — the mirror
image, same phase, same seam, same journaling discipline; `Middleware::Base#downstream`
(`middleware.rb:60-70`); `Sensitivity::Regions` (T10), `Sensitivity::Ledger` (T14),
`Approval::Queue#admit`/`#adjudicate` (`approval/queue.rb:134,163`), `Queue::Pending`'s region
field (T16), `Session#record_read(complete:)` (T22), `Telemetry::ReadRedacted` (T13).
**Shared-file wiring:** `require_relative "middleware/redact_secret_reads"` in
`lib/lain/middleware.rb`; added to the tool-phase stack in `lib/lain/cli/tool_guard.rb`, with the
ledger and queue injected.

Sits in the tool phase at `ToolRunner#dispatch` and rewrites `env[:result]` **on the way out**, so
unreleased bytes never exist above the middleware — never in an `Event`, never in a digest, never
in the prompt-cache prefix. That is `RefuseSecretWrites`' own "there is no un-indexing it"
argument (`refuse_secret_writes.rb:10-14`) applied to the read side.

**Masking always comes with a release path.** Content cannot be judged before the read, so this
is the only boundary that can see a secret in an *ordinary*-classified file — a `.env` copied to
`notes.txt`, a key pasted into a fixture. When anything is masked, the middleware parks a pending
carrying the outstanding regions and awaits it, exactly as a gated call awaits its approval.
Approve and the full bytes are returned and the regions are released to the ledger; deny, defer or
time out and the masked projection stands. Without this the agent reads `Cargo.lock`, gets
`<redacted:1>` forever, and no one — model or human — has a move.

An unreleased region renders as `<redacted:N>`; a released one renders as its real bytes. So the
model gets the file's **structure** — for a `.env`, the keys — and partial approval falls out.

**A masked read is recorded incomplete** via T22, so `edit_file` refuses rather than letting a
model clobber secrets it never saw.

`Middleware::Env` is `fetch`-based (`middleware/env.rb:54-57`): this middleware calls
`downstream` and then merges, so it never short-circuits and can never leave `:result` unset.

**Acceptance criteria:**

```gherkin
Scenario: an unreleased region is masked
  Given a read of a file with one unreleased region and a surface that never answers
  When the result reaches the agent
  Then the region's bytes are absent and a placeholder stands in its place

Scenario: the surrounding structure survives
  Given a dotenv file with three assignments, none released
  When the result reaches the agent
  Then all three key names are present and no value is

Scenario: approving the parked pending returns the whole file
  Given a read of a file with one unreleased region
  When the pending is approved
  Then the result carries the region's real bytes
  And the region is released in the ledger

Scenario: an already-released region needs no pending
  Given a file whose every region was released earlier
  When it is read again
  Then no pending is parked and the content is byte-identical to the file

Scenario: an ordinary file parks nothing
  Given a read of a file with no regions
  When the result reaches the agent
  Then no pending is parked and the content is byte-identical to the file

Scenario: a masked read does not satisfy the edit contract
  Given a file read with at least one region masked
  When edit_file is called on it
  Then the precondition fails

Scenario: a released read does satisfy it
  Given a file whose every region was released during the read
  When edit_file is called on it
  Then the precondition is satisfied

Scenario: an unanswered pending falls toward masking
  Given a read whose pending is never decided
  When the queue's timeout elapses
  Then the masked projection is what reaches the agent

Scenario: the masking is journaled with counts
  Given a read with three regions of which one was released
  When the result reaches the agent
  Then one ReadRedacted record carries 3 and 1
```
→ spec file: `spec/lain/middleware/redact_secret_reads_spec.rb`

**Escalation triggers:**
- `spec/lain/cli_spec.rb:159-160` asserts `tool_middleware` is exactly
  `[Lain::Middleware::RefuseSecretWrites]`. This card adds a second, so that assertion must
  change — and it should be the *only* one that does. If other wiring specs break, the stack's
  shape is being altered in a way this card did not intend. Stop.
- Awaiting a pending inside tool-phase middleware blocks that tool's fiber. `Tools::ReadFile` is
  `parallel_safe?` (`read_file.rb:33`), so siblings run as concurrent fibers
  (`agent/tool_runner.rb:225`). If awaiting deadlocks the reactor or starves the queue's
  fail-closed timer, stop — that is the same failure `cli/repl/approval_surfaces.rb:43-49`
  documents for a bare `@input.gets`.
- Masking rewrites a `Tool::Result` whose `content` may be a String **or an Array**
  (`tool.rb:233-263`). Decide deliberately rather than assuming String; a `to_s` here would
  corrupt a legitimate result.
- If a masked read cannot be recorded incomplete because `record_read` already ran below the
  middleware with the default `complete: true`, then T22's default is wrong for this path. Stop
  and settle it rather than adding a removal API to the read-set.

---

### T17 — Let a local model triage parked reads, ahead of the human          [wave 5] [risk: high]

**Depends on:** T13, T16
**Files:** create `lib/lain/approval/secret_surface.rb`, `lib/lain/oracle/secret_read.rb`,
`spec/lain/approval/secret_surface_spec.rb`, `spec/lain/oracle/secret_read_spec.rb`;
modify `lib/lain/cli/repl/approval_surfaces.rb`,
`spec/lain/cli/repl/approval_surfaces_spec.rb`, `exe/lain`
**Reuse:** `Approval::AutoSurface` (`approval/auto_surface.rb`) — the template, including
`#watch(queue)`, the sweep loop, `AutoSurface::Pruning`'s identity-keyed seen-set, and
`VERDICT`'s three-way answer where `:defer` is a no-op; `Oracle::Definition` + `Oracle::Model`
(`oracle/definition.rb`, `oracle/model.rb`) for the typed schema and injected provider;
`Provider::Ollama` (`lib/lain/provider/ollama.rb`) constructed **directly**;
`CLI::Repl::ApprovalSurfaces#watch` (`cli/repl/approval_surfaces.rb:66-71`).
**Shared-file wiring:** `require_relative "approval/secret_surface"` in `lib/lain/approval.rb`;
`require_relative "oracle/secret_read"` in `lib/lain/oracle.rb`.

**This is a queue surface, not a middleware oracle, and that is what keeps the doctrine intact.**
`oracle/memory_save.rb:8-17` forbids a model round trip on the live tool-dispatch path. A surface
adjudicates pendings that are *already parked and already blocking*, asynchronously, racing the
human — which is what `AutoSurface` does and why it was allowed.

The schema carries `verdict`, `confidence` and `reason`. Confidence is journaled but is not
control flow on its own: a threshold routes, and the threshold is set from measurement, because a
local model's self-reported confidence is a rank, not a probability. `Telemetry::OracleAnswer`
already carries answer, model and wall clock, so calibration data accrues for free.

**The provider is constructed directly as `Provider::Ollama`, never through `Backend#provider`.**
`cli/backend.rb:167`'s `summarizer_provider` is *not* a pin — it is a user-settable knob with an
ollama default over `PROVIDERS = %w[anthropic ollama bedrock]`, so copying it would let
`--summarizer-provider anthropic` send the candidate secret to Anthropic to be judged, which is
the precise failure this whole rung exists to prevent. Neither a knob nor `Oracle::Router` may
move it, and there is an AC for each.

**Opt-in, default off**, via a `--secret-oracle` flag. Falling toward the human is structural:
`:defer` is a no-op, an unreachable ollama leaves the pending untouched, and `Queue`'s fail-closed
timeout (`queue.rb:227-231`) denies anything nobody answered.

**Acceptance criteria:**

```gherkin
Scenario: the surface is off by default
  Given a chat launched with no secret-oracle flag
  When the approval surfaces are started
  Then no secret surface is watching the queue

Scenario: a confident safe verdict releases the pending
  Given the surface is enabled and the oracle answers approve above the threshold
  When a lockfile read is parked
  Then the pending is approved and the surface is recorded as the decider

Scenario: a low-confidence verdict leaves it for the human
  Given the oracle answers approve below the threshold
  When a pending is parked
  Then it stays undecided and the human surface can still answer

Scenario: a defer verdict leaves it for the human
  Given the oracle answers defer
  When a pending is parked
  Then it stays undecided

Scenario: an unreachable local model leaves it for the human
  Given the oracle raises on every call
  When a pending is parked
  Then it stays undecided and the fault is journaled

Scenario: a provider knob cannot move the oracle off the local model
  Given every provider-selecting option set to a remote provider
  When the secret oracle is built
  Then it is built against the local ollama provider

Scenario: the router cannot move it either
  Given a router configured to send every oracle to a remote model
  When the secret oracle is built
  Then it is built against the local ollama provider

Scenario: the human wins a race with the oracle
  Given a pending answered by the human first
  When the oracle answers afterwards
  Then the human's answer stands and the surface recorded is the human's
```
→ spec file: `spec/lain/approval/secret_surface_spec.rb`

**Escalation triggers:**
- `cli/repl/approval_surfaces.rb:57-65` documents that its spec *"pins both the SIZE of this set
  and the class of every member."* Adding a fifth watcher will turn that spec red on purpose.
  Update the pin; do **not** relax it — it is an upgrade-detection guard.
- If the surface ends up called from `Middleware` or from any tool `#perform`, stop immediately:
  that is the synchronous path `oracle/memory_save.rb:8-17` forbids, and this card's entire
  justification collapses.
- `Approval::AutoSurface` may already be watching the same queue. Two LLM surfaces racing on one
  pending is a decision, not an accident — if both can answer the same sensitive read, stop and
  confirm which wins.
- `Oracle::Model#ask` is synchronous (`oracle/model.rb:49-55`) and the surface runs inside an
  `Async` task. A blocking HTTP call in the reactor stalls the queue's fail-closed timer. If it
  blocks, stop.

---

### T19 — Withhold sensitive paths from listings, and say how many          [wave 6] [risk: medium]

**Depends on:** T8, T15
**Files:** create `lib/lain/middleware/withhold_secret_paths.rb`,
`lib/lain/sensitivity/filter.rb`, `spec/lain/middleware/withhold_secret_paths_spec.rb`,
`spec/lain/sensitivity/filter_spec.rb`
**Reuse:** `Sensitivity` (T8); `Sensitivity::Policy` (T11) for the tool→field table;
`Middleware::RedactSecretReads` (T15) as the structural precedent — same phase, same seam;
`Tools::Grep::MAX_MATCHES` and `Found = Data.define(:rows, :capped)` (`tools/grep.rb:56-62`) as
the precedent for reporting truncation rather than hiding it.
**Shared-file wiring:** `require_relative "sensitivity/filter"` in `lib/lain/sensitivity.rb`;
`require_relative "middleware/withhold_secret_paths"` in `lib/lain/middleware.rb`; added to the
tool-phase stack in `lib/lain/cli/tool_guard.rb`.

**Its own middleware, not a second job for `RedactSecretReads`.** Masking region bytes inside one
file's content and filtering a list of paths are two questions with two result shapes, sharing
only a phase. Folding them together would make `RedactSecretReads`' name describe half of what it
does; the cost of keeping them apart is one more `Stack` entry.

`grep` must not print matching lines out of a gated file; `glob` and `list_files` must not
enumerate a denied directory. Filtering happens on the **result**, so no tier-1 tool gains a path
check.

**The filtering is always reported** — `"3 paths withheld (protected)"` — never silent. Silent
truncation reads as "that is everything," which is a lie the agent will act on, and it is the same
reasoning that made `grep` report `capped`.

**Acceptance criteria:**

```gherkin
Scenario: grep does not print lines out of a gated file
  Given a grep whose matches include a line from ".env"
  When the result reaches the agent
  Then that line is absent and the result says one match was withheld

Scenario: glob does not enumerate a denied directory
  Given a glob pattern matching files under "<home>/.ssh"
  When the result reaches the agent
  Then no path under it is listed and the count of withheld paths is reported

Scenario: an ordinary listing is untouched
  Given a glob matching only ordinary paths
  When the result reaches the agent
  Then the output is byte-identical to the tool's own

Scenario: withholding nothing says nothing
  Given a listing with no sensitive paths
  When the result reaches the agent
  Then no withheld-count line is added

Scenario: the withheld count does not name the paths
  Given a listing with two denied paths
  When the result reaches the agent
  Then the count is 2 and neither path appears

Scenario: a capped grep reports capping and withholding separately
  Given a grep that both hits its match cap and withholds a match
  When the result reaches the agent
  Then it reports both facts and the two counts do not contradict
```
→ spec file: `spec/lain/middleware/withhold_secret_paths_spec.rb`

**Escalation triggers:**
- `grep` already reports `capped` at `MAX_MATCHES = 200`. If withheld matches are counted against
  the cap — or a cap is reached only because of withheld rows — the two counts contradict each
  other. The last AC exists to force the decision; if it cannot be satisfied, stop.
- `tools/glob.rb:10-17` says honoring a pattern that escapes the root via `../` is deliberate.
  This card withholds *sensitive* paths, not *outside-root* ones. If the implementation starts
  confining to the root, stop.

---

### T21 — Make the docs say what the code now does          [wave 7] [risk: low]

**Depends on:** T11, T12, T15, T19, T20, T23
**Files:** modify `lib/lain/tools/glob.rb`, `lib/lain/tool/input.rb`,
`planning/project-root-and-secret-boundary.md`, `ROADMAP.md`
**Reuse:** the comment being corrected is `tools/glob.rb:10-17`; the adjacent claim is
`tool/input.rb:15-40`, on why a pattern scan cannot certify safety.
**Shared-file wiring:** none (`CLAUDE.md` is orchestrator-owned — see Integration checks).

Four documentation debts this chunk creates, each a place where a reader would otherwise be
actively misled:

1. `tools/glob.rb:10-17` says confinement belongs to "the tier system, `Effect::Handler::Gate`,
   and eventual OS confinement, never a path check inside a tier-1 tool." That is now **true and
   implemented** rather than aspirational. Rewrite it to name `Sensitivity::Policy` and
   `Effect::Handler::Sensitivity`, so the next reader finds the boundary instead of concluding
   there is none. It must **not** say tier-1 tools check paths — they do not.
2. `tool/input.rb:15-40` should name the read-side controls beside the write-side one, and repeat
   that neither certifies safety.
3. `planning/project-root-and-secret-boundary.md` — mark the six positions this chunk's grounding
   overrode, so the requirements draft is not mistaken for the design.
4. `ROADMAP.md` gains the index line for this plan.

**Acceptance criteria:**

```gherkin
Scenario: the glob comment no longer contradicts the code
  Given lib/lain/tools/glob.rb
  When its header is read
  Then it names where the path boundary now lives and does not claim there is none
  And it does not claim tier-1 tools check paths

Scenario: the requirements draft is marked where it was overridden
  Given planning/project-root-and-secret-boundary.md
  When its Q1 through Q4 sections and Q-D are read
  Then each names the ruling that overrode it and points at this plan

Scenario: the docs suites stay green
  Given the documentation edits
  When yard-lint and rubocop run
  Then no Documentation/DuplicateNamespaceComment or Style/Documentation offense is reported
```
→ spec file: verified by `bundle exec rubocop` and `yard-lint` via
`pre-commit run --all-files`; this card adds no spec, and its third AC is that check. The first
two ACs are verified by the panel's own re-read at integration check 4.

**Escalation triggers:**
- A YARD `@word` at the start of a wrapped comment line parses as a tag and fails the commit
  (CLAUDE.md, Known traps). Any prose referencing a keyword argument must be written inline.
- If rewriting the `Glob` header requires stating that tier-1 tools *do* check paths, stop — they
  do not, and a comment saying so would be false in the opposite direction.

### T23 — Construct the classifier, so the path boundary actually fires          [wave 7] [risk: high]

**Depends on:** T5, T8, T11, T12, T19
**Files:** modify `lib/lain/cli/wiring.rb`, `lib/lain/cli/switchboard.rb`,
`lib/lain/cli/tool_guard.rb`; modify `spec/lain/cli/wiring_spec.rb`,
`spec/lain/cli/switchboard_spec.rb`, `spec/lain/cli/tool_guard_spec.rb`
**Reuse:** `Sensitivity#initialize(home:, cwd:, rules: Rules.empty)` (T8);
`Sensitivity::Rules.from(table, path:)` (T8) for the config `[sensitivity]` table;
`Sensitivity::Policy.new(sensitivity:)` (T11); `Sensitivity::Filter` (T19);
`Project#root`/`#cwd` (T5), already held by `Wiring`.
**Shared-file wiring:** this card IS the wiring.

**Added 2026-08-09 by Joel's ruling, after T19's implementer found the gap and T19's panel
confirmed it empirically.** Every part of the path boundary is built and tested, and **none of it
runs**. `Switchboard.for` never passes `sensitivity:`, so the constructor's
`Sensitivity::Policy::Null.instance` default stands; `Null#gates?` is `false` unconditionally, and
`ToolsetBuild::LiveSensitivity` only delegates back to that same Null. Measured on the real
production board: `gates?("/proj/.env") => false`. **Nothing anywhere calls `Sensitivity.new`, and
nothing anywhere calls `Rules.from`**, so the config `[sensitivity]` table is parsed by nobody
either.

The chunk's own Intent says "a read of a credential-shaped path is **gated**, region-approved, and
journaled". Region-approved and journaled are true today — T15's `RedactSecretReads` calls
`Sensitivity::Regions.detect` directly and needs no classifier, and a read of a real key was
observed parking on the real `Approval::Queue`. Gated is not. This card is the difference.

**Why this is high risk and not a wiring chore.** Every card's specs pass because each injects its
own classifier; production injects Null. That is the chunk's recurring "green tests that do not
test their subject" pattern appearing at chunk scale, and it means **the delivered specs cannot
tell you whether this card worked**. The acceptance criteria below are therefore written against
the *production construction path*, not against an injected double.

**Two independent reasons the guard is dark, and both must be fixed.** T19's panel found the
production tool stack prints as `[RefuseSecretWrites, RedactSecretReads]` — `WithholdSecretPaths`
is not in it at all. A classifier alone would not wake it, and the stack entry alone would filter
with a Null. Assert the stack's class list *and* the classifier, or this card can half-land and
look done.

**Acceptance criteria:**

```gherkin
Scenario: the production board gates a credential-shaped path
  Given a Switchboard built the way a real chat builds one
  When it is asked whether a read of ".env" under the project root is gated
  Then it says yes, and the reason names a credential

Scenario: an ordinary path is still ungated
  Given the same board
  When it is asked about a read of "README.md"
  Then it says no

Scenario: the tool phase carries the path filter
  Given the tool-phase stack a real chat builds
  Then its class list contains WithholdSecretPaths
  And that middleware's filter is not the Null filter

Scenario: the config's sensitivity table reaches the classifier
  Given a project config declaring one denied pattern
  When the board classifies a path matching it
  Then it is denied, and the reason is the one the config gave

Scenario: a malformed sensitivity table refuses loudly at construction
  Given a project config whose sensitivity key is a string, not a table
  When the session is built
  Then it refuses with the NotATable message and names the config path

Scenario: no config means the built-in rules, not no rules
  Given a project with no sensitivity table at all
  When the board is asked about "~/.ssh/id_rsa"
  Then it is denied
```
→ spec files: `spec/lain/cli/wiring_spec.rb`, `spec/lain/cli/tool_guard_spec.rb`

**Escalation triggers:**
- `Sensitivity.new` takes `home:` and `cwd:` as **required** keywords with no `Dir.pwd` default,
  deliberately (recorded at the T8 API-change ruling below). If wiring it tempts you to add a
  default, stop — that default is the divergence this chunk exists to remove.
- `Switchboard.for` already takes a `rules:` keyword and it is **approval** rules (T18's consent),
  not sensitivity rules. If the two get conflated, stop and report; they are different vocabularies
  and one silently accepting the other is a security-relevant confusion.
- If making the path boundary live turns any existing spec red, that spec is describing the dormant
  behavior. Report the list before changing any of them — a spec that asserted "not gated" may have
  been asserting the bug.
- If a real classifier gates so much that ordinary work is unusable, stop and report the measured
  counts rather than widening the exempt list. T10 measured this flood once already.

---

## Discovered during execution (orchestrator-owned)

**Wiring conflict to settle at integration — `lib/lain.rb` load order.** T8 placed
`require_relative "lain/sensitivity"` at `:15` (leaf, needs only `Error` + `Pathname`); T9 placed
`require_relative "lain/credential_patterns"` at `:49`, before `middleware`. `sensitivity.rb` is a
leaf *today*, so both load — but T10 adds a `sensitivity/regions` child that consumes
`CredentialPatterns`, and `sensitivity.rb` is that subtree's index. The orchestrator moves
`lain/sensitivity` to sit after `lain/credential_patterns` when wiring the two cards together;
CLAUDE.md's rule is that a load-time `NameError` means the entry is too early.

**API change every downstream card must honour: `Sensitivity.new(home:, cwd:, rules:)`.** T8's panel
found that a relative path never reached the home-anchored half — `../../home/tester/.ssh/id_rsa`
classified `:ordinary` — which is not the symlink hole the card deliberately accepted, and T20
classifies **bash argv**, where relative paths are the norm. Ruling taken: inject `cwd:` and join
lexically before `cleanpath`, rather than document a precondition that T11, T19 and T20 would each
re-implement — three copies of one rule is the drift this chunk exists to prevent. It is a
**required** keyword with no `Dir.pwd` default, so **T11, T12, T19 and T20 must each supply it**.
No production caller exists yet, so nothing is broken today; the failure mode if a card forgets is
a loud `ArgumentError` at construction, which is the intended posture.

**The plan's git-env scrub list is INCOMPLETE, and names the wrong vars as the dangerous ones
(T3, 2026-08-07, pending panel confirmation).** T2's and T3's cards both say to scrub `GIT_DIR`,
`GIT_WORK_TREE`, `GIT_COMMON_DIR` and `GIT_CEILING_DIRECTORIES`. T3's implementer found that a
command-line `--git-dir` already beats `GIT_DIR`/`GIT_COMMON_DIR`, so those are not where the teeth
are — **`GIT_INDEX_FILE` and `GIT_CONFIG_*` are**. An inherited `GIT_INDEX_FILE` makes `git
ls-files` report *another repository's* files as this home's editable surface, and `GIT_CONFIG_*`
rewrites `core.worktree` underneath the detector. Any future card shelling to git must scrub the
wider set, not the four the cards name.

Same card: **`git ls-files` truncates paths against the PROCESS directory** — from `~/sub` a bare
home repo answers `deep.txt` rather than `sub/deep.txt`, which is both a short surface and paths
that rejoin to the *wrong file*. lain's cwd is routinely inside a home root, so any `ls-files` call
must pin its directory explicitly.

**A CORRECT FIX IN ONE PLACE CAN DELETE COVERAGE IN ANOTHER, and a green suite cannot show you
(twice this chunk).** T20: narrowing the argv rung to path-shaped words left "a gated path is not
denied here" passing via the *bare* rule instead of the *gated* one. T10: excluding quotes from a
region — a fix I ordered — removed the one-byte offset that had made `coalesced`'s rank precedence
observable, so the mutant killed in round 1 now survives and the rule is held by a comment alone.
Neither went red. **After any fix that changes a subject's shape, re-run the mutants that were
killed BEFORE it** — not just the suite.

**A ruling that NARROWS a subject can void an existing example without failing it (T20, 2026-08-07).**
When option (c) narrowed the argv rung to path-shaped words only, T20's "a gated path is not denied
here" example kept passing — but `cat .env` is a bare word, so it now abstained via the *bare* rule
rather than the *gated* rule it was written to exercise. The mutant that should have died survived,
and nothing went red. **After any orchestrator ruling that shrinks what a subject does, sweep the
spec for examples that still reach their assertion by a different route than the one they name** —
a green suite is not evidence the ruling left coverage intact.

**SELF-REFERENTIAL vacuity is the variant nobody looks for (T10, three instances in one card).**
A test artifact that derives from the thing it is testing cannot fail. (a) The panel's corpus
**included the file being mutated**, and the mutation `", _1[:rank]"` is exactly 11 characters — so
the "region offsets shift by 11 bytes" blocker was the mutation editing the bytes it was scanning;
excluding the subject gives zero differences. (b) A hex fixture sliced itself with
`described_class::HEX_LENGTH`, so it moved with the mutant and passed against any floor. (c)
`HEX_LENGTH` binds only upward, since it equals `TOKEN`'s `{20,}` minimum, so lowering it is
genuinely equivalent. **Rule: a fixture must use literals, and a corpus must exclude the subject.**

**FOUR mutation harnesses lied in this chunk, each differently — treat the harness as a subject
that needs its own canary.** (1) T10: `String#sub` reads `\0` in the *replacement* as a
backreference, so two mutants were **syntax errors scoring as kills**. (2) T2: the survival test was
`result.start_with?("4")`, so once the suite grew past 49 examples **every mutant was relabelled
"killed"** — it printed a false all-clear before the implementer caught it. (3) T10 again: three of
the *panel's* own probe mutations were **no-ops**, because their `sub` targets no longer existed
after a reshape, and a no-op scores as a kill. The invariant that catches all three: **every mutant
must assert it APPLIED (anchor present, text changed, exactly once), that the result still PARSES,
and the scoring must key on the failure count rather than on any string prefix** — plus a green
canary and a byte-identical restore check.

**A mutation harness that lies, found again (T10, 2026-08-07) — propagate this.** `String#sub`
reads `\0` in the *replacement* as a backreference, so two of T10's mutants were **syntax errors
scoring as kills**. Fixed with the block form plus a `ruby -c` validity check, which then exposed
**three genuine survivors**. This is the pattern already recorded across earlier chunks: the
harness is as capable of being vacuous as the specs it audits. **Every mutation pass in this repo
must assert two things per mutant — that the edit APPLIED, and that the result still parses** — and
should carry a green canary. T10 also found two of its own fixtures vacuous once the harness was
honest (a BOM example used a key an *unanchored* shape matched anyway; a blob-framing example
passed with the framing removed entirely).

**Carried into T5/T6 from T2's panel (2026-08-07).** T5 already owns reconciling
`IsolationBackend#repo_root`'s ceiling with the resolver's stop rule. Four additions:
- **The two walks diverge on more than the ceiling.** `IsolationBackend#initialize` does
  `File.expand_path(root)`; the resolver does `realpath`. A symlink whose *lexical* parent holds a
  `.git` its real parent does not gives `resolver -> /plain/leaf` (rung 6) against
  `repo_root -> /trap`. Harmless today because the single caller passes `Dir.pwd`, but the
  escalation trigger is about mechanics, not today's caller.
- **`Paths#runtime_dir` (`$XDG_RUNTIME_DIR/lain`) is not in the refusal set.** The card names three
  XDG bases; the `/tmp/lain` default is covered only incidentally by the `/tmp` literal.
- **`Resolver.call(cwd: <a regular file>)` returns a Project whose root IS that file.** `Project`
  does not check directory-ness either, so it is inherited — but `--root <file>` reaches the
  resolver, and T6 is the card that accepts a user-typed path.
- **`root: ""` is truthy**, so it takes rung 1 and raises `Unresolvable` on `realpath("")`. Loud,
  but "an empty flag means no flag" is the friendlier reading for a CLI.

**T22 RULINGS (2026-08-07), and one item ASSIGNED TO T15.** T22's escalation trigger fired for
real: once `read?` means *complete*, `Journaled#record_read`'s dedupe predicate breaks twice over —
a partial re-read journals a line per iteration (the flood its docstring calls "the escalation this
design closes without inventing batching"), and, worse, `Replay#session` folds `SessionRead` back
through `record_read(path)` at the new `complete: true` default, so **a resumed run would treat a
redacted read as whole and permit exactly the secret-clobbering write T22 and T15 exist to
prevent**. T22 lands in wave 2 and T15 in wave 5, so deferring would leave four waves of `main`
carrying that. Rulings: (1) T22 owns `telemetry/session_state.rb` and `session_record/replay.rb` —
nobody else is scoped to them, and "T15 will fix it" means nobody does; (2) journaling fires on a
read-set **state transition**, carrying the flag; (3) `fetch("complete", true)` for a pre-T22
journal, documented as a *historical fact* rather than a permissive default — no masking path can
have existed before T15, so an absent key is positive evidence of a whole read — with a key that is
present but not a strict boolean still raising, so `Replay`'s loud-beats-plausible posture survives.

**Assigned to T15:** `edit_file` still reports *"path was never read this session"* for a partially
read file, which is the misleading claim T22's card wants stopped — but the tools are outside T22's
Files list, and **no partial read can exist until T15 lands**, so the message is unreachable until
then. T15 owns making the refusal name the real reason via `partially_read?`.

**T11 RULING (2026-08-07) — the privilege inversion its escalation trigger predicted is REAL, and
the fix is a scope expansion, not a follow-up ticket.** `Tools::Subagent::ChildBuilder#gated`
(`subagent.rb:797`) builds its own `Effect::Handler::Gate` from `@seam.gate_policy`, and `Seam`
carries no sensitivity — so with the card's wiring list (sensitivity injected only into
`Switchboard#gate`) a `research_subagent`, which holds `base` and therefore `read_file`, would run
`read_file(path: ".env")` **ungated** while the identical call from the parent reaches the
escalation ladder. There is no in-scope route to fix it: `LivePolicy` answers exactly one message,
`call(effect, context)`, and the Gate never asks its policy anything else.

Granted: `Seam` gains a `sensitivity:` member defaulting to `Sensitivity::Policy::Null.instance`
(alongside its existing `UNGATED`/`Permits::All` defaults), and `ToolsetBuild#spawn_seam` passes a
third delegator over the **same `-> { @switchboard }` thunk** `LivePolicy` already uses — so parent
and child cannot resolve different switchboards, and sensitivity cannot go stale, by construction.
Files added to T11's scope: `lib/lain/tools/subagent.rb`, `lib/lain/cli/wiring/toolset_build.rb`.
Deferring this behind an `xit` was refused: it would turn a uniform absence of gating into a
specific documented bypass.

Also settled, so a later reader does not re-derive it: **T11's escalation trigger 2 does not fire.**
`Approval::Rule::Call`'s `Decision#gated` is written at `rule.rb:209` and read nowhere in `lib/` —
journaled description, not control flow — so the second reader's disagreement with the gate
changes no decision.

**T10 RULINGS (2026-08-07), taken after the implementer measured the flood rather than estimating
it.** The warning below was right and understated. Measured with `for(:content)` as the card
specified: **markdown 102/134 files (2588 regions), `lib/**/*.rb` 516/598 (5040), `spec/**/*.rb`
556/577 (14816)**. In Ruby the driver is not the yaml shape but `dotenv assignment`, because
`^ident = value` *is* Ruby assignment syntax. T15 would have parked a pending on essentially every
read. Three rulings:

1. **Gate the assignment shapes; issuer-fixed shapes (`sk-`, AKIA, PEM) always fire.** The gate is
   **name-substring OR value-shape** — the name matched as a *substring*, not on a word boundary,
   which is what preserves `DATABASE_PASSWORD=hunter2`. A value-shape-only gate is cheaper
   (`lib/` 8.0%) but structurally cannot see a low-entropy named secret, which is the exact miss
   `for(:content)`'s docstring exists to defend against.
2. **Split the entropy detector by charset: hex ≥3.0/len ≥20, base64 ≥4.2/len ≥24.** The naive
   single-threshold base64 detector's false positives were file paths and URLs, because `/`, `_`
   and `-` are in the base64url charset. Split, the residual is **zero across 598 `lib/` files**.
   The remaining residuals — blake3 digest fixtures in `spec/`, long URLs in markdown — are
   recorded as measured imprecision in the docstring rather than special-cased, following
   `credential_patterns.rb`'s own precedent.
3. **A region covers the VALUE, not the whole assignment — and T10's AC above was wrong, not
   T15's.** The two cards contradicted: T10 said "it covers the assignment", T15 requires that for
   a `.env` "all three key names are present and no value is". A whole-match region makes T15
   unsatisfiable unless it re-parses assignment syntax the detector already parsed. Consequence
   accepted and documented: two identical values in one file share a digest, which is the honest
   semantics — identical bytes are the same secret, so one release decision covers both. T14 keys
   by `(path, region_digest)`, so nothing leaks across files.

**T10 RULINGS, ROUND 2 (2026-08-07) — three more wire contracts T14 and T15 must build against.**
The panel re-measured the residual and the "narrowing crosses into T9" premise turned out wrong for
most of it: of 134 `lib/` regions, **50 are `yaml assignment` and 42 `dotenv assignment` — both
read-side-only `ASSIGNMENTS`** — against 42 for the write-side `credential assignment`. It read all
134 and **none is a credential**; 45 are under 8 bytes, 24 are pure punctuation (`)`, `,`, `>`),
4 are bare integers. So:
1. **A minimum-substance floor inside T10's gate**: a name-gated region qualifies only if its
   unquoted value is ≥8 bytes and holds an alphanumeric run, unless issuer-fixed.
2. **`yaml assignment` is VALUE-gated only.** `dotenv` keeps name-OR-value (that is what preserves
   `DATABASE_PASSWORD=hunter2`). Nothing real is lost: a named credential is still caught by
   `credential assignment`, and a real `secrets.yml` is gated by **path** at T8 before content
   matters. This is the "narrow at ITS end" T9's own docstring invites.
3. **A region EXCLUDES surrounding quotes.** Including them split one secret across two digests
   (quoted and unquoted differing, so T14's cache misses) and — decisively — meant T15 replacing
   `"sk-…"` with `<redacted:N>` would destroy the quoting that made the file parse, contradicting
   ruling 3's own "the structure survives" argument.
4. **The framing is `"sensitive-region-v1 #{length}\0"`, NOT `blob`, and that is confirmed
   deliberate.** House precedent is `Hunk`'s `hunk-content-v1`/`hunk-span-v1`, and
   `snapshot.rb:75`'s own comment says the header exists *to* domain-separate; reusing `blob` would
   have silently merged two content-addressing keyspaces.

**Known and documented for T14/T15, not defects:** a bare JWT splits into **three** entropy regions,
and its HS256 header segment is byte-identical across every such token ever issued — so under
content-addressed identity, releasing one JWT pre-releases that header at that path. And detection
costs ~1ms/KB on dense input (4.5s for a 4MB single base64 line, linear) — so the "runs per read
without a budget" claim holds only under a few hundred KB, and the consuming cards need a size cap.

**Carried into T10 as a measured warning, not a ruling.** T9's panel measured
`CredentialPatterns.for(:content)` against this repo's own markdown: the `yaml assignment` shape
`/^[ \t]*[A-Za-z_][A-Za-z0-9_-]*:[ \t]+\S+/` matches **54 of 60 files**, against 5 for
`for(:write)`. `"TODO: fix this"` matches, and journals as `"yaml assignment"`. T10's card argues
false positives "cost one review each because T14 caches by digest and T15 gives every masked
region a release path", and reasons from `risk.rb:66-72` that a miss is worse than a prompt — but
that argument was made about **entropy**, where the base rate is low. At 54/60 the cost is not one
review each; it is every prose file the agent reads. The distinction T9's panel drew is the one to
carry: the name-agnostic **dotenv** shape is justified by `DATABASE_PASSWORD=hunter2`; the **yaml**
shape, which needs only a colon and a space, is not equally justified by it. **T10 must measure its
region detector against ordinary repo prose and escalate if it floods** — do not let "widen, never
sharpen" import an argument from a different base rate.

**`Ractor::UnsafeError` in a suite run is EXPECTED NOISE, not a failure — do not ticket it.**
Two specs deliberately pin the recorded gap that `Ext` methods are main-Ractor-only:
`spec/lain/review/hunk_spec.rb:264` (`Ext.blake3_hex`) and `spec/lain/rust/fuzzy_spec.rb:200`
(`Fuzzy#match`), both asserting the raise. Ruby's Ractor machinery prints the error to stderr from
those *passing* examples, so it appears in a green run at the exact expected count. It is worth
recording because it looks alarming next to a truncated `parallel_tests` tail and invites exactly
the wrong diagnosis — **the example COUNT, not the presence of this message, is the signal**.
Relevant to T10, which digests region bytes with `Ext.blake3_hex`: `review/hunk.rb:14-18` is the
precedent, and it pins the constraint in a spec rather than leaving it to be rediscovered.

**A FIFTH approval surface that no card owned, found by T16's panel (2026-08-07) — the plan had a
hole, not just the card.** `Frontend::Neovim::ApprovalView#row_for` renders
`"#{requester}  #{tool}(#{input.inspect})"`, never consults `pending.outstanding`, and its
`#decide` is a full approval path signing `surface: "nvim"`. **A human approving in the editor would
release a file's secrets having been shown no warning at all** — on the surface Joel actually runs.
`approval_view.rb` appears in **no card** in this plan. **Granted to T16**, whose title is already
"…and show them to a human". Its parity comment at `:298-302` also became false the moment
`prompt_for` grew a third fact.

**ASSIGNED TO T17:** `Approval::AutoSurface` can approve a region-carrying pending with **no human
in the loop at all**. T17 is the card that deals with an LLM surface adjudicating secret reads, so
the ruling belongs there: **`AutoSurface` must abstain (`:defer`) on a pending carrying regions**
rather than answer it. It was built to prune ordinary approvals, not to release secrets.

**Two gaps T14 found that NO CARD OWNS — T15/T16/T17 must absorb them or they ship broken.**
1. **`Repl::ApprovalSurfaces` builds a SECOND `ApprovalPolicy`**, which needs the same ledger and is
   in nobody's Files list. This is the two-half-wirings bug T14 exists to prevent, one layer up:
   miss it and the surfaces a human actually answers through hold a different ledger from the one
   the masking arm reads.
2. **`--yolo` wires no queue at all**, so T15 has nowhere to park a pending. Masking with no release
   path is the dead end the plan's own ruling forbids, so T15 must decide deliberately what a
   masked read does under `--yolo` — return full bytes, refuse, or mask with no release — and say
   which.

**The rule T14 shipped to prevent two ledgers, which every later holder must honour:** `ledger:` is
a **required kwarg with no default and no Null Object**. A default is how the second ledger gets
constructed silently. T14 therefore staged its own wiring diff by when each part can land —
`sensitivity.rb` require plus the Switchboard construction now, `ToolGuard`/`AgentBuild` with T15,
`surface_kwargs` with T16 — because landing `ledger:` early would need a
`Lint/UnusedMethodArgument` disable inside the security wiring.

**The general form of T5's two regressions, worth stating once: A CARD THAT CHANGES WHAT A VALUE
MEANS BREAKS CODE IT NEVER EDITED.** T5 did not touch `epic.rb:318` or `epic_mount.rb:309` — it
changed what `@root` resolves to, and two spellings that had agreed *by accident* (both landing on
the working directory) began to disagree. The divergence is invisible in the diff, so only a sweep
finds it. Both instances were found that way, not by review:
1. the epic **container** (`lain epic status|queue|submit|land` still on `Dir.pwd` while the chat
   moved to the resolved root — fixed, all four now uniform);
2. the epic **journal directory** (`epic.rb:318`/`epic_mount.rb:309` key it `project_hash(@root)`
   while `epic_submit`/`land`/`queue` and `chronicle.rb` take `sessions_dir`'s `Dir.pwd` default —
   **reverted those two lines**, restoring the pre-T5 invariant on the axis the card never meant to
   touch, rather than half-doing the `sessions_dir` migration that is separately ticketed).

**And why neither had a failing spec: every epic spec injects `paths:` and `root:` TOGETHER**, so
the two keyings cannot disagree inside a fixture. A fixture that supplies both halves of a
relationship cannot test the relationship — the same family as this chunk's other vacuity findings.

**A PLAN DEFECT the cards could not have caught individually: T22 and T15 demanded opposite
outcomes from the same production sequence.** T22's landed AC says a complete read is **not**
downgraded by a later partial one (monotonicity, which the parallel-safe tools depend on); T15's
says a read with a masked region **must** fail the edit contract. Production runs exactly that
order — `ReadFile#perform` records complete at `read_file.rb:52`, *below* the middleware, and the
middleware then records partial — so the two ACs contradict. No ordering inside the middleware
reconciles them: recording before `downstream` still lets `ReadFile` add to `@complete` afterwards,
and the card forbids short-circuiting. **Found by T15's implementer with a probe, not by review of
either card**, and it would have been invisible in a unit spec that drove `record_read` on a fresh
session — which would have made both ACs green while production stayed broken.

**Settlement (2026-08-07):** a **third add-only set** on `Session::ReadSet` distinguishing
*"partial because only part was read"* from *"partial because bytes were WITHHELD from the model"*
— different facts, and only the second claims the model never saw those bytes.
`complete?(path) = @complete.include?(path) && !@masked.include?(path)`. No removal API, so the
trigger's ban holds; monotone fail-closed, so T22's sibling-fiber race cannot reopen; and
`record_read(complete: false)` never touches `@masked`, so every T22 AC stays green by
construction. Masking is recorded **only when the model actually received a masked projection** —
on approval the full bytes are returned and nothing is recorded — which is what keeps T15's
"a released read does satisfy it" reachable as written.

**Accepted residual, ticketed:** a path masked on an earlier read stays un-editable for the run even
if a later read is fully released. Over-strict and safe; clearing it needs either a removal or an
ordering two add-only sets cannot express.

**Follow-up tickets (not fixes in this chunk):**
- **`Paths#sessions_dir` keys session state on `project_hash(Dir.pwd)`**, so once a resolved root
  differs from cwd — which the resolver now makes ordinary — the sessions directory is keyed on a
  different value from the epic container. **Deliberately NOT changed in T5**: the keying decides
  where resumable session state lives, so moving it orphans every existing session. It needs a
  migration decision, not a keying change. Found by T5's panel, which also noted the declaration is
  a *positional* default (`def project_hash(dir = Dir.pwd)`) and so invisible to T5's guard until
  that guard was widened.
- **A FOURTH flaky spec, outside the nvim family**: `spec/lain/rust/canonical_spec.rb:167` failed one
  run in three for an agent whose card touched no Rust and no canonical code, and passes 23/0
  standalone three times. Different subsystem from the nvim seams, so possibly a second cause.
- **THREE real-nvim seam specs flake under parallel load** — all seen 2026-08-07, by four different
  agents, each on code none of them had touched: `frontend/neovim/thread_view_spec.rb:378` (a
  `set_buf` call count; failed **2 of 5 ISOLATED runs**, so not merely worker pressure),
  `frontend/neovim_runtime_spec.rb:884` (57/0 alone) and `frontend/neovim/buffers_spec.rb:329` (a
  `]]` motion's cursor landing; 5/5 alone). **Three distinct seams flaking on one day reads like one
  shared cause rather than three bugs** — that is the ticket's starting hypothesis. They make false
  REDs that get blamed on whatever diff is in flight; two agents this chunk had to stop and prove
  innocence. **Two more members, hit by the orchestrator while landing T17**:
  `frontend/neovim/diff_mode_spec.rb:283` (3/3 green isolated) and
  `frontend/neovim/changeset_diff_spec.rb:342` (an ECONNREFUSED, so the nvim process itself was
  gone). Three commit attempts failed on a *different* member each time, which is the family's
  signature and not a regression — but it cost three full suite runs, and **the load source was
  our own concurrency**: a review panel was running suites while the orchestrator ran the hook.
  Worth pricing into the schedule, not just diagnosing after the fact.
  **Record these by NAME, never by line number.** The four originally recorded as `up_spec.rb:115`
  and `:175` no longer point at the flaky examples — T6 and T20 grew that file by 454 lines and the
  live failure now reports at `:166`. A stale line number in a flake list is worse than no list:
  it reads as "not a known flake" and sends the next agent hunting a regression that is not there.
- **`Telemetry::SessionPin#pinned`'s "strict boolean" guard is not strict.** ActiveModel 8.1's
  `InclusionValidator` reads an Array value as "every member must be included", and `[].all?` is
  vacuously true — so `inclusion: { in: [true, false] }` accepts `[]`. Found by T22's panel on its
  own new field (closed there); `pinned` is the precedent it was copied from and has the identical
  hole. Any other `inclusion` guard over a boolean in this codebase shares it.
- **`Guards::Dropped` does not coerce its count**, so `Dropped.new(count: +"1")` stores a mutable
  String and `Ractor.shareable?` is **false** — a live deep-freeze violation in shipped
  `telemetry/turn_stream.rb`. Surfaced by T13's panel while probing the same class of bug in the
  new records; T13 closed its own door and does not own this one.
- **`WorkerEnv` does not expand its own `cwd`.** `WorkerEnv#initialize` is `cwd.dup.freeze` with no
  `expand_path`, so a *relative* worker cwd makes the base itself resolve against `Dir.pwd` at each
  call — reintroducing, one layer down, exactly the divergence T7 removes. T7's panel reproduced
  it. Unreachable today because `Isolation::Worktree#worker_env_for` builds an absolute path, but
  `lain up ../other-repo` is the entry point T6 adds. One-line fix, but it touches `WorkerEnv`'s
  spec surface, so it wants its own card — **and it should carry a second finding with it**:
  `cwd: nil` also resolves silently against `Dir.pwd`, because `nil.dup` is `nil`, so a `WorkerEnv`
  can hold a nil cwd and every read through it goes process-relative. T7's docstring says `cwd:` is
  "required, never defaulted" and the card's escalation trigger calls a `Dir.pwd` default exactly
  the divergence it removes — but the guard is a sentence, not a mechanism, and the mechanism
  belongs in `WorkerEnv`. Both predate T7 and neither is caused or cured by it.
- **T7 left one claim untested, for T22 to close in the same file.** `normalize_path`'s comment
  justifies its `.to_s` as covering "the Symbol and nil spellings a Set query may arrive in", but
  `resolve(nil)` and `resolve("")` both already yield `cwd`, so **a Symbol is the only input that
  discriminates** — and dropping the coercion leaves the file at 38/0. Add `:sym` to the
  equivalence example's spellings array, or drop the Symbol clause from the comment. Nothing
  reaches the read-set with a Symbol today, so it is a claim without a test rather than a defect.
- **The read-set has no reader.** Journal and read-set agree only because two independent call
  sites happen to call the same function with the same base; there is no `Session#reads` to compare
  against, which is why T7's byte-identity assertion has to borrow `#writes` as a proxy. Having
  `record_read` return the normalized path would let the decorator take the answer rather than
  re-derive it. **Fold into T22**, which is already in that file.
- **`Approval::Risk::Credential::SHAPES` carries a weaker form of the hyphenated-prose bug.**
  Its `\bsk-` is the unanchored shape that `refuse_secret_writes.rb:44-48` records as having
  refused benign prose under a pattern name it never honestly matched. T9 correctly did **not**
  fold it in: `Risk` is dead code this chunk, and widening it now would make a later card's
  behavior impossible to attribute. Found by T9's implementer, confirmed at review.
- **A non-UTF-8 path silently loses a security record.** `JSON.generate` raises on ASCII-8BIT
  bytes; `Journal#encode` (`journal.rb:256-265`) catches it and emits a `journal_error` line, so
  NDJSON parseability is safe — but the path and reason of a refusal are replaced by an exception
  string. `WriteRefused` has the identical property, so T13 introduces the *exposure*, not the
  mechanism: `pattern` comes from a fixed ASCII vocabulary while `path` is whatever bytes the
  filesystem hands T12. Wants one policy across every path-bearing record. Found by T13's panel.
- **A subagent's tool phase runs NO middleware, so neither secret guard reaches it** — the
  *second* half of the privilege inversion T11 fixed, by a different mechanism, and still open.
  `Tools::Subagent::ChildBuilder#spawn_agent` (`subagent.rb:756`) passes seven keywords and
  `instrumentation:` is not among them, so the child takes `Agent.new`'s `Collaborators::OMITTED`
  default and its `tool_middleware` is empty. **Verified by the orchestrator at both ends**, not
  taken on report, and confirmed by T15's panel: `ToolGuard.stack` has exactly one call site
  (`agent_build.rb:86`). **State it as path-kept, content-lost — "the tool phase is empty"
  over-reads as ungated.** T11 closed the *path* half, and the child keeps it: `child_handler`
  composes `gated(...)`, so a child's `read_file(".env")` does reach the escalation ladder. What
  the child loses is the **content** half, because the guards that mask and refuse are middleware.
  So the exposure is precisely the case T15 exists for: a child reading an **ordinary-classified**
  file whose sensitive regions would have been parked and masked for the parent gets them
  **unmasked** — and those bytes flow back into the parent's Timeline, and so into its digest and
  its cache prefix. T15's implementer found this while
  retracting its own false claim that `agent_build` covered it, which is the right way for a
  wrong comment to die. Predates this chunk on the write side — `RefuseSecretWrites` has always
  been missing there too — so T15 introduces neither the gap nor its exposure, and records it
  rather than widening its Files list a second time. Wants its own card: the fix is to thread
  instrumentation through `Seam` the way T11 threaded sensitivity, and it should be measured
  against the same question T11 answered — whether parent and child can resolve different ones.

## Integration checks

After the last wave, before the chunk is called done:

1. **Full suite.** `bundle exec rake pspec` — and check the example COUNT against a serial run,
   not just the exit status. A truncated `parallel_tests` run reports as a pass.
2. **Lints.** `bundle exec rubocop` and `pre-commit run --all-files`. `Metrics/ClassLength` must
   not fire on `cli/wiring.rb`; if it does, T4's extraction was insufficient and the fix is
   another extraction, never a config loosening.
3. **Rust unchanged.** `cargo test && cargo clippy --all-targets -- -D warnings`. This chunk
   touches no Rust; a failure means something unrelated drifted.
4. **`CLAUDE.md` (orchestrator-owned).** Add the project-root/cwd distinction and the two-boundary
   split (paths pre-read at the handler, content post-read at the middleware) to "Architecture, in
   one breath", and record the ruling that tier-1 tools do not check paths. One edit, after every
   card lands. **Four Known-traps entries earned during execution, to add in the same edit:**
   - **A class named for a top-level constant SHADOWS it for everything lexically inside the
     enclosing namespace.** Defining `Effect::Handler::Sensitivity` made `gate.rb`'s bare
     `Sensitivity::Policy` resolve to `Handler::Sensitivity::Policy` and die — for every caller
     omitting the keyword, i.e. most. `Module.nesting` order is not something anyone reasons about
     until it bites; root-qualify (`::Lain::Sensitivity`) at such a site.
   - **`pre-commit` exports `GIT_INDEX_FILE` into every hook**, so any spec fixture that shells to
     `git` without scrubbing builds against *lain's* index. It passes in every normal run and fails
     only at commit time. Thirteen of T2's examples were exposed; only the one that *commits*
     failed loudly. Scrub the wider set, not just `GIT_DIR` — a command-line `--git-dir` already
     beats that one, while `GIT_INDEX_FILE`, `GIT_COMMON_DIR`, `GIT_WORK_TREE` and `GIT_CONFIG_*`
     are the ones that actually redirect git.
   - **Mutation harnesses lie by default here.** Same-size mutants are the norm (`20`→`10`,
     `<=`→`<`) and collide with bootsnap's `(mtime-seconds, size)` iseq key, so they run against
     **stale bytecode**. Stamp a unique mtime per write; assert each mutant applied exactly once and
     still parses; score on the failure count, never a string prefix; use literal fixtures and
     exclude the subject from any corpus. Five harnesses lied in this chunk, each differently.
   - **`ls-files` truncates against the PROCESS directory**, so a home-repo surface read from a
     subdirectory is both short and rejoins to the wrong file. `-C <dir>` is the fix; `--full-name`
     is not sufficient.
5. **Journal integrity.** Run a real chat that triggers one denial, one gated read and one
   release, then `JSON.parse` every line of the resulting Journal. This chunk adds two record
   types and several refusal paths, and one stray write breaks NDJSON.
6. **Manual pass owed to Joel — the monorepo case.** `lain up ~/work/<monorepo>/services/<one>`:
   both panes land in the subtree, the HUD reads the repo-top `.lain/state.json`, a grep reaches
   across the repo, and the nvim socket differs from a sibling subtree's.
7. **Manual pass owed to Joel — the `$HOME` case.** `cd ~ && lain up` in a shell where the
   `~/.cfg` bare-repo alias env is live. Confirm the root is **not** `$HOME` by inference; that
   `lain up ~` explicitly does enter home kind; that `~/.ssh/id_*` refuses loudly; that
   `~/Downloads` gates; and that `--isolation worktree` does not branch off the dotfiles repo.
8. **Manual pass owed to Joel — the region cache.** Read a `.env`, release one region, add a new
   key, read again: only the new region prompts. Then read an ordinary file containing a pasted
   key and confirm it masks *and* offers a release.
9. **Manual pass owed to Joel — the consent rule.** Clone an unfamiliar repo carrying a
   `.lain/config.toml` with an `[[approval.allow]]` entry, open it without `--root`, and confirm
   the entry is ignored until consent is given.
