# Epic orchestration — research

> Status: **draft — awaiting Joel's review** (gate 1 of the very flow it describes).
> Date: 2026-07-28. Inputs: five parallel research passes (spec-driven-development landscape,
> stacked-PR mechanics, lain substrate map, macOS portability audit, Linear API) plus the
> 2026-07-28 interview. Next step after review: `/critique`, then `/create-plan` for the first
> chunk.
>
> **Addendum 2026-07-29 (§3.10):** cross-analysis with `planning/tool-use-algebra.md` added
> five results that change details in §3.1, §3.2, §3.5, and §3.8 without changing their shape.

---

## 1. The questions

Joel's pre-LLM flow at Omada was a ten-command ladder: `/research` → `/create-epic` →
`/plan-epic` → `/iterate-epic` → `/create-epic-issues` → `/create-plan` → `/iterate-plan` →
`/implement-plan` → `/critique` → `/create-pr`. Lain already covers the single-issue tier
(create-plan / execute-plan / critique, shipped both as Claude skills and as lain skill
templates). The research questions:

1. What should the **epic tier** — research → epic → issue decomposition with blocking links →
   iteration (split/merge/add) — look like inside lain, and what does the field already know
   about it?
2. How does the flow stay **ADHD-gentle**: the value of the ladder is that each rung is a small
   description of a large thing, so the big picture stays holdable; going straight from research
   to implementation plans skips the orientation step. Yet it must also run **hands-off** when
   chosen.
3. How does the decomposition altitude itself become a **swept bench axis** — one-shot vs.
   single-plan vs. progressive epic — rather than a hardcoded pipeline? (Decided in interview:
   bench-native, not pragmatic-first.)
4. What does **stacked-PR discipline on plain GitHub** (no Graphite) require when the agent owns
   it, given a team culture of narrative, logical commits?
5. Where do artifacts live? (Decided: support both `.lain/` in-repo and XDG-style outside;
   **default outside**.)
6. What does the optional **Linear status-comment** integration need?
7. What breaks when lain runs **natively on the work MacBook** (M5 Pro, brew, ruby-install,
   plain tmux — no iTerm2 `-CC`), driving Bedrock?

---

## 2. Findings

### 2.1 The spec-driven-development landscape (2025–2026)

Every surveyed system — GitHub Spec Kit, AWS Kiro, OpenSpec, BMAD-Method, claude-task-master
(Taskmaster), Agent OS — converges on the same spine: **intent → requirements → design → task
decomposition → per-task execution → verification**, differing only in ceremony and enforcement.
Two capabilities Joel's flow needs are each present in only one or two tools, and **no tool has
both**:

- **A real blocking-link graph at the issue tier.** Taskmaster: `dependencies` arrays validated
  for existence and circularity, with a dependency-satisfied `next_task` query that gives the
  agent a deterministic work queue. Steve Yegge's **Beads** is the strongest prior art: an issue
  graph stored as JSONL in git (SQLite-backed locally), dependency types `blocks`, parent-child
  (arbitrary nesting), `related`, and — directly matching `/iterate-epic` — **`discovered-from`**
  (work found while doing other work links back to its origin). Agents query "ready work"
  (open, unblocked) as their queue.
- **An explicit epic-iteration step.** Only Beads' `discovered-from` and Spec Kit's `/converge`
  gesture at it; nobody has split/merge as first-class operations.

**Recurring failure modes** (each reported independently across multiple tools):

1. **Spec drift** — implementation pivots, upstream artifacts don't update; the plan becomes
   fiction (Kiro's top complaint). OpenSpec's delta-then-archive-merge (changes are diffs
   against a baseline spec corpus, merged in on completion) is the only structural fix seen.
2. **Artifact bloat / token burn** — one measured report: 4,839 lines of markdown for ~1,000
   lines of code; full ceremonial SDD 10× slower than iterate-and-review for a mid-size feature
   (Scott Logic). Specs doubling in size feature-over-feature.
3. **Regeneration cascade** — edit the spec, regenerate plan and tasks, lose manual edits.
4. **Convention isn't enforcement** — agents skip stories out of order, fabricate status, blow
   through checklists that live only in prose (BMAD's dev agent picked story 1.4 with 1.1–1.3
   incomplete). Gates that bind are *mechanical*: tests, hooks, machine-validated dependency
   data.
5. **Decomposition fidelity loss** — PRD → tasks silently drops requirements; Spec Kit grew
   `/analyze` (cross-artifact coverage check) specifically for this.
6. **One-size workflow** — heavy pipelines over-engineer small fixes; every tool retrofitted a
   skip path (Quick Spec, Quick Flow, "skip planning if the diff is one sentence"). Scale
   adaptivity was bolted on everywhere; a new design should build it in — which is exactly
   what makes decomposition altitude a *router* question, i.e. a bench question.
7. **Session amnesia** — solved by progress files + git log (Anthropic), or a queryable tracker
   (Beads). The trend line runs from prose memory toward structured, queryable state.

**Structured data beats prose wherever an agent must query it or must not rewrite it.** Two
independent sources give the same reason: Anthropic's long-running-agents guidance keeps the
feature list as JSON with `"passes": false` fields *explicitly because markdown invites the
agent to rewrite scope*, and Yegge's Beads thesis is that markdown plans are unqueryable and
decay ("the 50 First Dates problem"). Human-facing prose and machine-facing structure are
different artifacts.

**Other findings worth keeping:**

- Kiro is the strongest-gated system (approve requirements.md → design.md → tasks.md in
  sequence, skippable via Quick Spec) and the most-criticized for not scaling down.
- BMAD's one durable idea: the **context-self-contained story file** — each story embeds its
  requirements slice, architectural constraints, ACs, and rationale so the implementing agent
  needs nothing else. (Lain's task cards already are this.)
- Agent OS v3 *abandoned* its rigid multi-command pipeline as models improved; what survived
  was standards/conventions injection. Ceremony is a depreciating asset; graph + gates are not.
- Anthropic's harness guidance: initializer-agent vs. coding-agent split; progress file + git
  log as memory; verify end-to-end, not unit-only; "plan when uncertain/multi-file/unfamiliar,
  skip when the diff is one sentence."
- Linear's agent-interaction SDK is the best-articulated **status vocabulary** in the field: a
  closed activity enum (`thought / action / elicitation / response / error`), session state
  *derived* from activities rather than self-reported, a liveness heartbeat, and
  delegation-not-assignment so a human stays accountable. This maps almost 1:1 onto lain's
  Journal + `ask_human` (elicitation) + StatusFeed derivation.
- **ADHD-relevant, published**: a single always-current "what's next" query beats a document the
  human must re-read; visible session state cuts the cost of context-switching away and back;
  small self-contained work units bound the attention any one step requires. The progressive
  ladder has empirical company.

### 2.2 Stacked PRs on plain GitHub

The mechanics work today with zero tooling: PR B targets branch A; only the bottom PR targets
`main`. The discipline the harness must own:

- **Retarget-on-merge**: when a PR's head branch is *merged and deleted*, GitHub retargets
  dependent PRs to the merged PR's base (behavior verified current, 2026). Deleting an
  *unmerged* branch auto-closes dependents — never do it. Enable delete-branch-on-merge.
- **The squash trap**: after a squash merge of layer A, a naive `git rebase main` of layer B
  replays A's original commits against their squashed result → phantom conflicts, and the
  retargeted PR shows a doubled diff until the cascade runs. The mandatory tool is
  `git rebase --onto origin/main <old-base-sha> layer-b`, with old-base SHAs recorded *before*
  the cascade starts. `git rebase --update-refs` (git ≥ 2.38) moves all intermediate branch
  refs in one rebase of the top; force-push `--force-with-lease`, ideally `--atomic`.
- **Landing sequence per merge**: merge bottom (branch auto-deleted → retarget fires) → fetch →
  `--onto` cascade upward → force-push each → verify each PR's diff shrank back to one layer.
- **`gh` covers creation and state, nothing stack-shaped**: `gh pr create --base <branch>`
  (base must exist on the remote first — push bottom-up), `gh pr edit --base`, `gh pr ready`,
  `gh pr view --json mergeStateStatus` (the field to poll), `gh pr merge --auto
  --delete-branch`. No chain listing, no rebase help, no cross-PR stack table — the harness
  renders and maintains those itself.
- **Worth borrowing from the no-SaaS tools**: git-machete's **declarative chain manifest** (a
  small text file as the single source of truth for the stack — exactly the right shape for a
  harness); spr's and jujutsu's **stable change-IDs decoupled from commit SHAs** (a commit
  trailer keyed to the issue survives every rewrite — the correct identity for issue ↔ PR ↔
  commits); jj's **automatic descendant restack** (amend layer 2, layers 3..n follow without
  ceremony); ghstack's never-force-push merge-commit representation (only if preserving
  reviewer diff history ever outweighs branch clutter); spr's collapse-and-merge-once landing
  (one CI-gated merge per landing wave instead of N cascading ones).
- **Failure modes + mitigations**: force-push marks review comments "outdated" (not deleted) —
  mitigate by cadence: respond to review feedback with *new commits*, restack only at landings;
  CI re-runs across the cascade — run full CI on the bottom PR only, lint/unit above; branch
  protections configured for all branches block mid-stack PRs — scope them to `main`;
  mid-stack conflicts — `git rerere` for replayed resolutions, and the agent **stops and hands
  conflicts to the human, never auto-resolves** (the published agent-skill precedent's rule,
  and lain already has the `merge_resolver` role for the escalation path); keep stacks ≤ 3–5
  layers and land the bottom aggressively.
- **GitHub's native "Stacked PRs" private preview (April 2026, waitlist-gated)** adds a stack
  map, merge-from-any-layer, auto-restack, and per-layer CI as-if-targeting-final. Design
  implication: build on the plain mechanics (they work everywhere today) but keep the chain
  model congruent — PR-targets-parent-branch, bottom-up merge — so the preview becomes a free
  upgrade, not a conflict.
- **Narrative commits**: the canon (Tekin Süleyman's "A Branch in Time", Chippindale's
  "Telling stories through your commits", Chris Beams on messages) distills to rules an agent
  can enforce: one logical change per commit, every commit green (bisectable); order
  pedagogically not chronologically (preparation → behavior change → wiring); subject = story
  beat, body = why + alternatives rejected; the stack of PR titles reads as the epic's table of
  contents. The structure recurses: commits narrate within a layer, layers within the stack —
  **issue decomposition, branch topology, and commit sequence are one artifact**, which is why
  the epic plan should design all three at once.
- **Landing method interacts with narrative**: narrative multi-commit branches do not survive
  squash merge — the story lands on `main` only with rebase-merge or merge-commit. Coherent
  pairings: (a) one-logical-commit-per-PR + squash (narrative at PR granularity), or (b)
  multi-commit PRs + rebase/merge-commit landing. Joel's current team rebase-merges with
  fast-forward — pairing (b), where multi-commit narratives survive intact and the squash trap
  above never fires — but the design treats landing method as **configuration the discipline
  reads, never an assumption it bakes in**: both pairings (and their different cascade
  mechanics) stay supported.

### 2.3 What lain already has, and the gaps

The substrate is further along than expected. **Exists** (selected, with the interfaces the
epic layer would consume):

- **Subagents both modes** — `Tools::Subagent` (`#run`, `#fan_out` staggered, `#launch_actor`),
  `SpawnPolicy` (prefix strategy × attenuation posture × only-set), depth ceilings.
- **Supervisor/fleet (OM-6)** — `#adopt(role:, worker_id:)` leases isolation and registers;
  derived worker state; `Supervisor::Restart` replay-restart.
- **Human seams, two kinds** — `Tools::AskHuman` promise + inbox surfaces (`/inbox`,
  `lain://inbox`, `:LainReply`, dunst arrival) and `Approval::Queue` for tier-3 effects. And
  the crucial third: **`Gherkin::Approval`** (lib/lain/gherkin/approval.rb) — a fail-closed,
  content-addressed artifact gate (`#ensure_approved!` raising `NotApproved`, approval recorded
  against the criteria digest). This is the exact pattern every epic-stage gate needs,
  generalized from Gherkin criteria to any document digest.
- **Roles + skills** — 12-role catalog with attenuation and persona slots;
  `Skill::Invocation` grammar (`/skill`, `@role/skill`, `@role[/skill]`); lain-native ports of
  create-plan (5 phases), execute-plan, critique, gherkin-tests already shipped as templates.
- **Plan machinery** — `Plan::Document` round-trips markdown ↔ frozen value at the same digest;
  `Plan::Step` carries a `criteria_digest` into `Gherkin::Criteria`; task-card Gherkin fences
  are already machine-parseable by `Gherkin::Parse`. Seams, closures, runner, seam policies.
- **Isolation + handback** — detached worktrees, `Handback` anchoring worker HEADs to
  `refs/lain/worker/<id>` before reclaim, `WorkerHandoff` spawning `merge_resolver` on
  conflict, service leases (postgres/redis/compose).
- **Bench** — DryReplay/LiveReplay, Compare with distributions and capability guards, the
  grader family (Fixture, Rubric, TestHarness-over-the-project's-framework, Verified/Refuter),
  `Arm::*` including orchestrator-worker and dual-ledger, ArmSweep/PlanSweep.
- **Provider::Bedrock is built** — `bedrock.rb` + `bedrock.rb` (default path), wired into
  the CLI, `aws-sdk-core` in the gemspec, env-only auth (`AWS_BEARER_TOKEN_BEDROCK`,
  `AWS_REGION`). Unit/parity specs exist; **the live integration pass (bedrock-provider.md
  checks 4–7) has never run** — the spec doc still says `in-progress`.

**Missing, concretely** (the epic chunk's shopping list):

- **A. No issue/epic domain.** Zero occurrences of epic/issue/PR/Linear in `lib/`.
  `Plan::Document` is deliberately flat: no dependency edges, no parent/child, no split/merge.
- **B. No graph computation.** Waves-as-maximal-antichains exist only as prose in the skills;
  nothing in `lib/` topo-sorts, computes antichains, or detects cycles. (The ROADMAP already
  lists `petgraph` as the causal-DAG crate; an issue graph is small enough that pure Ruby
  passes the five-rule binding test — this is per-session, not per-turn.)
- **C. No split/merge operations** on any work artifact.
- **D. No artifact writer.** Nothing writes a research/epic/plan doc to disk; `Paths` has no
  `plans_dir`/`docs_dir`. Note the existing ruling (status_feed.rb:14, ROADMAP): `.lain/` =
  project artifact, XDG = durable state — Joel's "default outside the repo" decision cuts
  across this for *epic* artifacts and needs a config seam (§3.4).
- **E. No `gh`, no branches.** Worktrees are `--detach` by design; handback refs live outside
  `refs/heads/` *on purpose* so they're unreachable by branch name. Stacked PRs need real
  branches and pushes — a sibling policy, not a rewrite of handback.
- **F. No tracker client.** `Tools::WebFetch` is GET-shaped.
- **G. No generic stage gate** — `Gherkin::Approval` is the shape to generalize. Note
  `AskHuman`'s documented single-pending-question invariant: concurrent gates need promises on
  events, not the `@pending` ivar.
- **H. Unattended-gate policy is a recorded open question** (grader-from-gherkin.md GG-1:
  standing approval / deferred sign-off). The epic flow forces this decision; §3.3 proposes the
  answer.
- **I. The chat path never calls `WorkerHandoff#reclaim`** (ROADMAP:833) — worker commits are
  never handed back from chat-driven fleets. The single most important missing wire; the epic
  flow cannot ship without it.
- **J. Crashed-worker worktrees leak** until `Supervisor#stop` (restart takes a new worker_id;
  B5 ticket). Accumulates over a multi-hour epic run.
- **K. No multi-stage resume.** Sessions resume; there is no "epic run: stage 3/6, issues 4/9
  merged" state that survives a restart.
- **L. Bedrock unproven live** — run the owed integration pass before an epic run depends on it.

### 2.4 macOS portability (native, plain tmux)

Two hard blockers, both cheap:

1. **`CLI::Up.pane_command` hardcodes `$HOME/.rubies/ruby-4.0.5/bin`** (up.rb:70-72; four call
   sites — `lain up`, cockpit, `/fork`, `/btw`; pinned byte-for-byte in three spec
   expectations). Any other ruby location makes every spawned pane fall back to system Ruby and
   die. Fix: `File.dirname(RbConfig.ruby)` — the codebase already uses `RbConfig.ruby` for
   exactly this reason elsewhere (cli/command/meta.rb:152).
2. **Spec-only `sun_path` overflow**: `spec/lain/core/client_spec.rb` and
   `spec/plugin/nvim_plugin_spec.rb` build ~115-byte socket paths via `Dir.mktmpdir` under
   macOS's `/var/folders/…` (limit: 104). Production paths are ~32 bytes and fine. Fix: short
   mktmpdir base or a named skip.

Degradations worth fixing in the same pass: `dunstify` → `Notify::Null` (designed degrade; the
TTY surface still answers — port via `alerter`, which blocks and prints the clicked action, or
`osascript display dialog`; `terminal-notifier` cannot serve `#decide`; journal a new
`SURFACE = "osascript"` value, never redefine `"dunst"`); `XDG_RUNTIME_DIR` fallback should be
`TMPDIR || /tmp` (macOS `TMPDIR` is per-user/per-boot — the XDG semantics — and avoids macOS's
3-day `/tmp` reaping, which would otherwise eat **worktree leases** mid-epic);
`Core::Child#prepare_runtime_dir` mkdir at 0755 should match Cockpit's 0700; the Rust `/proc`
liveness probes in tests are *silently vacuous* on macOS (use `kill(pid, 0)` via nix or cfg-gate
them); CI has no macOS leg, so none of this regresses visibly. Already portable: the whole
rb-sys/magnus build (`.bundle` handled), io-event picks kqueue, no file-watcher/clipboard/epoll
code exists, tmux plugin degrades with named reasons, every subprocess seam is an injected
`shell_out_factory:`.

### 2.5 Linear (optional status mirror)

Phase 1 is small: personal API key + one Faraday POST — `commentCreate(input: {issueId, body})`
with a markdown body; `issue(id:)` accepts `ENG-123` directly; rate limits (5k/hr) are
irrelevant at status-comment volume; `+++`-collapsible sections fold long logs; a bare issue URL
renders as a mention. No official Ruby SDK; the community gems lag the schema — plain Faraday,
no dependency. Threading via `parentId` supports one status thread per issue.

Linear's **Agents platform** (OAuth `actor=app`, webhook-driven sessions, typed activity feed,
10-second liveness contract) buys a distinct agent identity and delegation UX ("assign an issue
→ lain picks it up") — defer unless Linear should become a *control surface* rather than a
mirror. For the later create-epic-in-Linear phase: an epic maps to a **Project** (or a parent
issue + sub-issues below project scale); `issueCreate(parentId:)`, `projectCreate`, and
`issueRelationCreate(type: blocks)` cover creation and linking ("blocked by" is the inverse
view of `blocks`).

---

## 3. Ideas + tradeoffs

### 3.1 The epic graph: structured truth, markdown projections

Adopt the field's clearest lesson: the **issue graph is structured, content-addressed data; the
human-facing documents are projections of it**. This is lain's native idiom (event log +
projections) applied to work decomposition — Beads reached for git+JSONL because it lacked what
lain already has, a content-addressed Store.

- `Epic::Issue` — frozen value: id, title, 1–3-sentence description, state, size, optional
  `criteria_digest` (Gherkin), `blocks`/`blocked_by`/`related` edges, and **`discovered_from`**
  provenance (the iterate-epic move, borrowed from Beads).
- `Epic::Graph` — issues + edges; cycle detection, topo-sort, `ready` (open ∧ unblocked — the
  ADHD-critical "what's next" query), waves as maximal antichains (promoting what the
  create-plan skill does in prose into tested code); operations `split(issue, into:)`,
  `merge(a, b)`, `add(issue, discovered_from:)` — each a pure function returning a new graph,
  each an event, so iterate-epic is replayable and diffable.
- **Markdown round-trip** exactly like `Plan::Document`: `### `-per-issue grammar (title, blurb,
  `Blocks:`/`Blocked by:`/`Related:` lines — Joel's Omada `/plan-epic` format, now parseable),
  same digest both directions. The human edits the markdown in nvim; the parse *is* the review
  intake. Machine-validated edges answer "convention isn't enforcement" — an agent cannot skip
  an ordering that `ready` computes.

*Tradeoff*: a second work-artifact grammar beside `Plan::Document`'s. Alternative — extend
`Plan::Document` with edges — rejected: plans are ordered step lists inside one issue; the epic
graph is a different shape with different operations, and collapsing them re-creates the
"one-size workflow" failure. They meet at the seam where an issue's `criteria_digest` feeds
create-plan.

### 3.2 Decomposition altitude as the swept axis

The pipeline is `research → epic → issues → per-issue plan → implement → land`, but the bench
question is **where you enter it**. Arms:

- **one-shot** — no artifacts; the existing chat loop (baseline; correct for the 3-line fix).
- **plan-only** — existing create-plan/execute-plan (the current default).
- **epic-progressive** — the full ladder with gates.
- (later) **epic-hands-off** — same ladder, gate policy swapped (§3.3): measures what the
  human's intermediate judgment is worth, separately from what the *decomposition* is worth.

Held fixed: task, toolset, provider. Measured: grader score (per-issue Gherkin fixtures →
`Grader::TestHarness` in the worker env, rolled up per epic), tokens + cache-write (Ledger),
wall-clock, **rework** (issues re-opened, plan steps re-cut — countable from events),
**decomposition fidelity** (a coverage grader checking every research requirement traces to an
issue — the field's silent-drop failure made mechanical; the attested-context machinery is the
pattern), and gate round-trips (the friction being bought). Human answers are journaled, so
`DryReplay` substitutes recorded replies — an epic run is replayable offline like everything
else. The router question — *at what task size does each altitude pay?* — is then an
experiment, not a doctrine, and directly generalizes the ROADMAP's "pre-planning vs one-shot"
interest. Anthropic's one-sentence-diff heuristic and Scott Logic's 10× ceremony measurement
are the priors the bench gets to check.

### 3.3 Gates as policy objects (and the GG-1 answer)

Generalize `Gherkin::Approval` → `Approval::Gate` over **any artifact digest**: fail-closed
`ensure_approved!(digest)`, approval/denial recorded content-addressed, exactly the current
pattern. Stage gates (research doc, epic plan, per-issue plan, per-issue diff) each hold a gate;
**which surface answers it is policy**:

- `interactive` — inbox item; the run parks at the seam (`ask_human` promise; fibers make
  parking free). The gentle ladder.
- `hands-off` — auto-approve, recorded as such (an `auto_approver`-role decision, journaled, so
  a hands-off run is auditable and comparable).
- `deferred` — proceed *speculatively* past the gate but do not cross irreversible seams
  (push/PR/Linear) until the human signs the queue; O(1) fork makes the speculation cheap to
  abandon. This is the proposed **GG-1 answer**: unattended runs accumulate a sign-off queue
  rather than blocking or self-approving irreversibly.

Reversible-vs-irreversible is the line: implementation in a worktree is always safe to run
ahead; anything that leaves the machine (push, PR, Linear comment) is gated hard in every
policy. Gate policy is per-stage, per-epic, and an arm dimension (§3.2). ADHD framing: the
interactive arm is not overhead to minimize but the orientation mechanism — the bench can
measure what it costs, and `deferred` exists for overnight runs where the ladder is walked next
morning against work already done.

### 3.4 Artifacts: two homes, one convention

`Epic::Store` (naming TBD) resolves per config: default `$XDG_STATE_HOME/lain/epics/<project-hash>/<slug>/`,
opt-in `.lain/epics/<slug>/` (gitignored by default if in-repo). Layout per epic:
`research.md`, `epic.md` (the graph projection), `issues/<id>-<slug>.md` (self-contained,
BMAD-story-style: blurb + ACs + references + links), `plans/<id>.md` (create-plan output),
`state.json`-equivalent *derived from events, never hand-edited*. The default-outside decision
deliberately diverges from the ".lain/ = project artifact" ruling for one reason: work-repo
hygiene at the startup — nothing to leak into PRs. The config seam keeps the ruling intact for
projects (like lain itself) that want artifacts in-repo. Spec-drift mitigation is structural,
OpenSpec-style: issues carry deltas/status against the epic; landing an issue updates graph
state (an event), so the epic doc is always regenerable current truth, never a stale prose copy.

### 3.5 The stack: manifest, change-ids, cascade

A new unit (`Forge::Stack`, naming TBD) owning stacked-PR discipline on plain GitHub:

- **Chain manifest** (git-machete's idea): the epic graph already *is* the dependency source;
  the manifest is the projection choosing PR granularity — issue→PR by default, with the epic
  plan allowed to fold trivially-coupled issues into one PR (the "varies per epic" instinct,
  recorded not improvised). Rendered stack table injected into each PR body.
- **Change-ids** (spr/jj's idea): `Lain-Issue: <id>` commit trailer ties commits ↔ issue ↔ PR
  across every rewrite.
- **Branches for real**: a sibling of the handback policy that promotes a reclaimed worker ref
  into `refs/heads/epic/<slug>/<issue-id>` and pushes — handback's off-branch namespace stays
  for scratch work; only gate-approved work earns a branch name.
- **Mechanics encoded, least-privilege** (the published agent-skill precedent): `gh pr create
  --base <parent-branch>` bottom-up; `--onto` cascade with old-base SHAs recorded *before*
  cascading; `--update-refs` for the linear tail; `--force-with-lease --atomic`; restack **only
  at landings** (protects review comments); review feedback lands as new commits; `rerere` on;
  **conflicts stop and escalate** to the human (the `merge_resolver` role assists, never
  auto-pushes); `mergeStateStatus` polled via `gh pr view --json`. Dedicated tier-2 argv tools
  (`Tools::Gh`, git-stack verbs), not free-form bash — the model never improvises stack
  mutations.
- **Narrative commits**: the implementing subagent receives the issue's commit outline
  (preparation → change → wiring) as part of its brief — decomposition, branch topology, and
  commit sequence designed together at plan time. Landing method (rebase-merge, merge-commit,
  squash) is manifest configuration read from the target repo's settings, and narrative
  granularity adapts to it (§2.2) — one-commit-per-PR under squash, multi-commit stories under
  rebase/merge landing (the current workplace default: rebase + fast-forward).
- Forward-compatible with GitHub's native stacked-PRs preview by construction (same
  PR-targets-parent model, bottom-up merges).

*Tradeoff*: this is the largest genuinely-new surface (git + gh + GitHub behavior, hard to unit
test). Mitigations: the cascade is pure ref arithmetic testable against local fixture repos;
`gh` interactions are thin and injectable; the discipline document (§2.2) doubles as the spec.
A deliberate design constraint, per the 2026-07-28 interview: **do not over-fit to the current
workplace's process**. Everything a specific team decides — landing method, PR granularity,
stack depth norms, whether stacking is used at all — is a policy value in the manifest, tweaked
per-repo from usage; the unit encodes only GitHub's mechanics (retargeting, cascades, `gh`),
which are invariant.

### 3.6 Linear as a status Sink

A Journal/StatusFeed subscriber — the same pattern as the tmux HUD — mapping epic events
(issue started/landed/blocked, gate waiting, escalation) to `commentCreate` on the mapped
issue, markdown with collapsible detail, threaded under one status comment. Config: API key +
issue mapping in the epic manifest; absent config = `Null` (no caller checks). Linear's
activity vocabulary (thought/action/elicitation/response/error) is worth adopting as the
*internal* status enum even before—independent of—any Linear wiring, because it cleanly labels
what the inbox and HUD already show. The Agents-platform registration stays deferred (§2.5).

### 3.7 Resume is a projection

Epic runs span days. Stage transitions, gate decisions, issue state changes, and landings are
all events (they already would be: gates journal, `Lineage` writes spawn/message events,
closures record). "Epic state" is a fold over that log — the same shape as `StatusFeed` — so
resume is replay-to-current, the K gap closes without new machinery, and "stage 3/6, issues 4/9
merged, 1 gate waiting" is a query. This also gives the bench §3.2's rework metric for free.

### 3.8 `/implement-epic` and seeing the graph (added from 2026-07-28 review feedback)

**The driver.** `/implement-epic` is a loop over `Epic::Graph#ready`: for each ready issue the
Supervisor `#adopt`s a per-issue **orchestrator actor** (an actor-mode subagent in its own
worktree lease) which runs that issue's plan with its own internal parallelism (`fan_out`,
review panel). An issue landing is an event; the fold recomputes `ready`; newly unblocked
issues spawn. This is the dependency-satisfied scheduler the field validated (Taskmaster's
`next_task`, Kiro's waves), driven by the Supervisor machinery that already exists — plus the
existing tmux surface: one window per issue orchestrator (`chat --windows` already opens a
read-only `lain watch` viewer per spawn), HUD fleet count, gates arriving in the inbox.

**The graph view is a third renderer over the same fold** — ROADMAP's "one state feed, three
renderers" extended. The §3.7 projection already computes issue states; two visible altitudes,
same renderer: the epic's issue graph, and one issue's task-card wave DAG (nested `subgraph`s
when both are wanted at once).

- **Primary surface: a `lain://status` nvim buffer** (ruled in review, 2026-07-28: keep it out
  of the chat window — a png in chat scrollback is a stale snapshot the moment state changes,
  and reline can't redraw around it; a buffer re-renders live). It is one more
  journal-subscribing read-only projection beside `lain://timeline`/`inbox` — the
  `Frontend::Neovim` skeleton and `InboxView` are the exact precedent. Content: the fleet
  (agents, states, worktrees), the epic's issue graph, and the focused issue's task-card wave
  DAG — markdown with mermaid fences, re-rendered on epic events. `snacks.image` renders the
  fences in-buffer (`mmdc` is **already installed via brew** on Joel's machines — the same dep
  snacks assumes; kitty-protocol terminal required for in-buffer images, else the buffer shows
  the fences as text plus the glyph projection below). Later enrichment for free: cursor
  motion over an issue node jumping to its plan doc / worktree / tmux window — the
  "time-travel as editor motion" idiom applied to the fleet.
- **Canonical form stays mermaid source**, emitted deterministically by the projection (sorted
  ids, `classDef` per state: done / in-flight / pending / blocked / gated). One diagram
  source: the status buffer renders it, `epic.md` carries the same fences (GitHub renders
  them once committed).
- **Console is the secondary, on-demand surface**: `lain epic status` prints the pure-text
  projection (indented list, state glyphs, `ready` set first — needs nothing); an optional
  `--png` flag does mermaid → `mmdc` → `chafa` (auto-detects kitty/sixel/iTerm2, degrades to
  Unicode half-blocks anywhere) for a one-off look without the editor. All rendering is
  frontend-side subscribers — the agent never draws, output discipline holds.
- *Open item*: terminal choice (Linux alacritty has no graphics protocol — the ROADMAP already
  leans kitty; the Mac terminal is unchosen) now gates only in-buffer image quality, nothing
  functional.

### 3.9 Sequencing (proposed chunk boundaries)

> **Ordering constraint (Joel, 2026-07-28):** this whole feature set lands **after**
> `chunk-vsock-exec-transport.md` and `chunk-bench-arms-subcommand.md`; a separate agent is
> mid-flight on `chunk-chat-ux-and-ui-fixes.md`. Consequences: the prerequisites chunk below
> must not collide with the chat-ux chunk's surfaces (TTY/tmux/inbox files are that agent's
> until it lands); the vsock chunk's T4 (gating `cargo test` on vsock eligibility) is the same
> pre-commit concern the MacBook port hits, so the macOS fixes here should land after/with it
> rather than race it; and the bench-arms subcommand is a natural dependency for §3.2's
> altitude arms reporting anyway.

1. **Prerequisites chunk** (small, unblocks everything): Bedrock live pass (L); chat-path
   `WorkerHandoff#reclaim` wire (I); crashed-worker worktree reap (J); macOS blockers + the
   TMPDIR/0700/notify degradations (§2.4); CI macOS leg (or at least the two spec fixes).
2. **Epic domain chunk**: `Epic::Issue`/`Graph` + markdown round-trip + split/merge/discovered-from
   + `ready`/waves; `Approval::Gate` generalization + gate policies (GG-1 ruling); artifact
   store + paths; resume projection. Skills: `/research-epic`, `/plan-epic`, `/iterate-epic`,
   `/create-epic-issues` as lain skill templates driving the domain objects (skills own prose,
   `lib` owns graph/gates — the convention-isn't-enforcement split). The text-projection rung
   of the graph view (`lain epic status`) lands here too — it is the domain's cheapest render
   and the resume projection made visible.
3. **Stack chunk**: branch promotion, `Tools::Gh`, manifest, cascade, landing protocol. The
   `/implement-epic` driver (§3.8) lands here or immediately after — it needs the domain
   (chunk 2) plus landing (this chunk); the mermaid/png renderer rungs can trail as a small
   interface chunk beside it.
4. **Bench chunk**: altitude arms wired into `Compare`, coverage + rework graders, the router
   experiment. (Instrumentation-friendly seams are placed in chunks 2–3 from the start;
   this chunk is the measurement, not a retrofit.)
5. **Linear chunk** (optional, thin): the status Sink.

Overnight-run readiness (Joel's stated intent) arrives with chunk 2's `deferred` gate policy;
chunks can be developed with the existing execute-plan machinery — the flow builds itself only
after the domain exists.

### 3.10 The algebra the epic tier inherits (added 2026-07-29)

Cross-analysis with `planning/tool-use-algebra.md`, which worked through what algebraic and
categorical structure the Tool/ToolUse layer maintains and what more would pay. Five results
transfer, and each names the existing machinery it reuses and the chunk (§3.9) it lands in.

**The exchange law appears at its third altitude.** Tools within a turn commute when
`parallel_safe?` (ToolRunner's barrier semantics), workers within an arm commute when
isolated (the `par` law), and issues within an epic commute when neither blocks the other:
the final graph state must be independent of the order independent issues land in. That
property is what makes `/implement-epic`'s ready-loop correct, and its precondition is the
same one as the arm level, per-issue isolation (the worktree leases §3.8 already assigns).
One precision the driver needs: `ready` is monotone under *landings* (finishing an issue
never un-readies another) and deliberately NOT monotone under *graph edits* (a
`discovered_from` addition may block a currently-ready issue). That asymmetry is a reason
iterate-epic stays a distinct, gated operation rather than something the driver does
mid-wave. Lands with the epic domain chunk; the law is a property test over `Epic::Graph`.

**Two edge kinds, kept as separate as the Timeline keeps them.** `blocks` drives scheduling
the way `render_parent` drives rendering; `discovered_from` is provenance the way
`causal_parents` is. The rule to carry over from ARCHITECTURE's "Two parent edges": `ready`,
waves, and topo-sort read `blocks` only, so recording provenance can never move the
schedule. Stating it up front keeps a later contributor from "enriching" the ready query
with provenance edges, the exact drift the Timeline's split exists to prevent.

**Split and merge carry fibers.** `split(issue, into:)` and `merge(a, b)` should record
preimages (which issues each result came from), the same discipline as compaction
replacements' `causal_parents`. Two consumers: iterate-epic becomes auditable by
re-derivation (the `Compaction::DerivationAudit` pattern applied to graph edits), and §3.2's
decomposition-fidelity grader becomes a cover check, every research requirement tracing
through the fibers to at least one issue, so a silent drop is a red grader rather than a
review hope. Epic domain chunk.

**PR granularity is a DAG quotient with a checkable condition.** §3.5 lets the manifest fold
trivially-coupled issues into one PR. Folding is a quotient of the issue graph, and the
quotient is a DAG only if each PR's issue set is convex under blocking: if `a` blocks `b`
blocks `c` and `a`, `c` share a PR, then `b` must too. A non-convex grouping creates a PR
that transitively blocks itself, surfacing as an unlandable stack with no error naming the
cause. The manifest should refuse it at write time, in one place, the posture `Toolset#only`
takes toward absent names. Stack chunk; pure graph arithmetic, unit-testable with no `gh`.

**The markdown round-trip earns a shared law group.** `Plan::Document` already round-trips
markdown to a frozen value at the same digest, and §3.1 adopts the identical pattern for the
epic grammar. tool-use-algebra B6 proposes a round-trip law group (`from_h`/`to_h`
isomorphism with the digest as oracle) for typed content blocks; the epic grammar and
`Plan::Document` are its second and third consumers. Design the group once, in the algebra
vocabulary, and hold all three to it, so "the parse is the review intake" (§3.1) rests on a
law rather than on each grammar's own diligence.

**The altitude arms are one ladder term, entered at different rungs.** one-shot, plan-only,
epic-progressive, and epic-hands-off decompose as prefixes of a single sequential term
(research → epic → issues → per-issue plan → implement → land) with a gate decorator per
stage, and gate policy (§3.3) as a parameter. That matches the term-algebra ruling in
tool-use-algebra B3: policies are evaluator parameters, never term structure. Two practical
consequences. The §3.2 arm list grows by grammar instead of by a fifth hand-written arm. And
`/implement-epic` is the *dynamic* case of B3's term evaluator: the term is recomputed from
the graph as `discovered_from` events land, where a bench arm evaluates a static one, so the
two share machinery deliberately: isolation as the `par` precondition, `Ledger`
re-attribution at joins, and a topology audit checking the recorded causal DAG against the
term that predicted it. Bench chunk, with the seams placed in the domain chunk as §3.9
already requires.

---

## 4. References

**Spec-driven development**: Spec Kit — https://github.com/github/spec-kit ·
https://github.com/github/spec-kit/blob/main/spec-driven.md · Scott Logic critique —
https://blog.scottlogic.com/2025/11/26/putting-spec-kit-through-its-paces-radical-idea-or-reinvented-waterfall.html ·
spec-kit #860 (long-term user report), #2687 (token budget) · Kiro — https://kiro.dev/docs/specs/ ·
Kiro critiques — https://dev.to/aws-builders/brilliant-broken-and-frustrating-my-deep-dive-into-amazons-kiro-ai-ide-the-flawed-junior-gn5 ·
https://martinfowler.com/articles/exploring-gen-ai/sdd-3-tools.html · OpenSpec —
https://github.com/Fission-AI/OpenSpec/ · BMAD — https://github.com/bmad-code-org/BMAD-METHOD
(issues #2003, #1002, #1688) · Taskmaster — https://github.com/eyaltoledano/claude-task-master
(discussion #864 on silent requirement drops) · Agent OS —
https://buildermethods.com/agent-os/workflow (v3 migration notes) · Beads —
https://github.com/steveyegge/beads ·
https://steve-yegge.medium.com/the-beads-revolution-how-i-built-the-todo-system-that-ai-agents-actually-want-to-use-228a5f9be2a9

**Anthropic guidance**:
https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents ·
https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents ·
https://code.claude.com/docs/en/best-practices

**Stacked PRs**: retargeting —
https://github.blog/changelog/2020-05-19-pull-request-retargeting/ · native preview —
https://github.github.com/gh-stack/ · https://github.com/github/gh-stack · squash trap —
https://www.nutrient.io/blog/how-to-handle-stacked-pull-requests-on-github/ ·
https://www.putzisan.com/articles/resolving-merge-conflicts-rebasing-stacked-branches ·
git-rebase (`--update-refs`, `--onto`) — https://git-scm.com/docs/git-rebase · tools —
https://github.com/ejoffe/spr · https://github.com/ezyang/ghstack ·
https://github.com/VirtusLab/git-machete · https://docs.jj-vcs.dev/latest/github/ ·
comparison — https://github.com/gitext-rs/git-stack/blob/main/docs/comparison.md · agent
discipline — https://github.com/callstackincubator/agent-skills/blob/main/skills/github/references/stacked-pr-workflow.md ·
https://codex.danielvaughan.com/2026/04/16/stacked-prs-coding-agents-gh-stack-sapling-codex-skill/ ·
CI — https://graphite.com/docs/stacking-and-ci

**Narrative commits**: https://tekin.co.uk/2019/02/a-talk-about-revision-histories ·
https://blog.mocoso.co.uk/posts/talks/telling-stories-through-your-commits/ ·
https://cbea.ms/git-commit/ · https://dhwthompson.com/2019/my-favourite-git-commit

**Linear**: https://linear.app/developers/graphql · https://linear.app/developers/agents ·
https://linear.app/developers/agent-interaction · https://linear.app/docs/mcp ·
https://linear.app/docs/parent-and-sub-issues · https://linear.app/docs/issue-relations ·
https://linear.app/developers/rate-limiting

**ADHD / attention**: https://fiftyfiveandfive.com/resources/ai-for-adhd/ ·
https://dev.to/terrizoaguimor/i-have-adhd-and-i-keep-losing-context-so-i-taught-my-ai-to-remember-for-me-afl ·
https://www.bodenfuller.com/writing/adhd-brains-built-for-ai-coding

**Internal**: `planning/tool-use-algebra.md` (the §3.10 cross-analysis: exchange law,
edge-kind split, fibers, quotient condition, round-trip laws, ladder terms) ·
`planning/specs/orchestration-model.md` (OM-1/OM-6, open questions) ·
`planning/specs/grader-from-gherkin.md` (GG-1) · `planning/specs/plan-shaped-compaction.md` ·
`planning/specs/bedrock-provider.md` (owed integration checks 4–7) ·
`planning/specs/chunk-orchestration-arms-isolation.md` (B5, B9, fan_out ticket) ·
`references/firecracker-microvm-isolation.md` (libkrun as the macOS isolation answer) ·
ROADMAP §Interface (inbox, StatusFeed), ROADMAP:832-833 (chat-path handback gap) ·
`lib/lain/gherkin/approval.rb` (the gate pattern) · `lib/lain/plan/document.rb` (the round-trip
pattern) · `lib/lain/cli/up.rb:70` + `lib/lain/paths.rb:162` + `lib/lain/notify.rb:81` +
`spec/lain/core/client_spec.rb:12` (the macOS items).
