# Skills, role-binding, and the basic-tool floor

status: done
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds · Jeremy Evans · Sandi Metz · Richard Schneeman · Aaron Patterson (Ruby roster, `create-plan/references/rosters.md`)

## Intent

Give `lain chat` **skills** — named, slot-extensible, composable reusable-prompt scaffolds
invoked at the `you>` prompt (`/create-plan`, `/execute-plan`, `/critique`, and user-authored
ones) — dispatched through the already-built `repl_middleware` seam. A skill can be run in-line on
the current session (`/skill`) or bound to a role and delegated to a subagent (`@role/skill`
inherits parent context; `@role[/skill]` starts fresh). Delivering that requires closing the
**runtime-dead role-persona gap** (PS-3: the 7 role prompts render nowhere) and adds the
**basic tools** the model can only reach today through approval-gated `bash` (`write_file`,
`glob`, `grep`, web fetch/search) plus a `run_skill` tool for dynamic composition.

Satisfies the ROADMAP `[exp]` lines that already anticipate this: `/research`+`/plan` as a
sign-off flow (`grader-from-gherkin.md` GG-1), user-injectable `repl` middleware (ROADMAP:251,
TODO 44), the plan-iteration `COMMENT` slots (`/critique`, ROADMAP:276-279), the OM-5 role
catalog on prompt slots, and the prompt-slots partial mechanism (`prompt-slots.md`).

## Grounding

Verified against the code on **2026-07-17** by four parallel `Explore` passes; where the specs
described intent and the code diverged, the code is treated as source of truth.

- **Repl command seam exists, empty today.** `Repl#dispatch` (`exe/lain:513-517`) runs every typed
  line through `@middleware.call({ text:, agent: }) { |env| env.merge(response: respond(...)) }` —
  a real `Middleware::Stack` with the env contract `:text,:agent → :response` pinned at
  `middleware/env.rb:23` and the monoid laws pinned in `spec/lain/repl_middleware_spec.rb`. But
  `build_repl` (`exe/lain:239-243`) constructs `Repl` **without** `middleware:`, so the stack is the
  empty pass-through default (`exe/lain:444`). Populating it is net-new; the seam and its property
  tests are not.
- **No skill/command abstraction.** No `Command`/`Skill`/registry/`/name` parser anywhere in `lib/`
  or `exe/`. The lone existing slash string is `/inbox`, a hardcoded compare on the **reply**
  prompt (`HumanReplies#read_drained_answer`, `exe/lain:619`), not the `you>` prompt — out of
  scope here.
- **`Prompt::Slots` is solid and is the render engine to extend.** `lib/lain/prompt/slots.rb`:
  `KNOWN = %w[system]` plus a `role/*` namespace over 7 shipped templates
  (`prompt/templates/role/*.md`); user overrides at `.lain/slots/**`. Rendering goes through
  `Prompt::LockedBinding` — a **static Prism allowlist** that raises `Lain::Prompt::ImpureSlot`
  before evaluation (NOT the `NameError` the spec prose claims; `slots_spec.rb` pins the
  `ImpureSlot` behavior). `lib/lain/prompt.rb` already defines `CircularSlot` — reuse it for
  `include` cycle detection. PS-1/PS-2 done; PS-4/PS-5 not started (not in this chunk).
- **Role personas are runtime-dead (PS-3 gap).** `Role = Data.define(:name, :only)`
  (`lib/lain/role.rb`); `Role::Catalog` ships 7 complete roles — `dev`, `test_engineer`,
  `reviewer_sre`, `reviewer_security`, `reviewer_dba`, `researcher`, `court_clerk` — each with a
  quality one-paragraph persona at `prompt/templates/role/<name>.md` and a consistent `only`-set
  (reviewers correctly omit `edit_file`). **But `Role#prelude_segments`/`#prelude`/
  `Slots#render_role` have zero callers in `lib/`|`exe/`** — spec-only. The one wired subagent,
  `research_subagent` (`exe/lain:364-370`), uses `context_factory: -> { backend.context }`, so even
  `:researcher` applies its `only`-set but never its persona. The model cannot pick a role: the
  `subagent` tool's input is just `prompt:` and the policy is fixed at construction.
- **The spawn machinery for role-binding already exists.** `Tool::SpawnPolicy`
  (`lib/lain/tool/spawn_policy.rb`) = `Data.define(:prefix, :posture, :only)`. Prefix strategies
  `Fresh`/`Inherit`/`SiblingTemplate` are exactly the `@role[/skill]`-fresh vs `@role/skill`-inherit
  axis, and `SiblingTemplate`'s own doc names the intended hook: its template *is* "a role-invariant
  prelude, e.g. `Role#prelude_segments` position 0" (`spawn_policy.rb:100-106`). So role-binding
  lands on machinery the repo already built for it.
- **Tool floor is thin.** 9 tools wired via `Wiring#build_toolset` (`exe/lain:354-359`). PRESENT:
  `read_file`, `list_files`, `edit_file`, `bash`(tier-3, the only approval-gated tool),
  `todo_write`, `memory_read/write`, `subagent`, `ask_human`. **ABSENT:** `write_file`/create
  (`edit_file` mutates existing files only), `glob` (used internally by `list_files`, not exposed),
  `grep`/content-search, and any web fetch/search — all reachable only through gated `bash`. The
  approval gate (`Effect::Handler::Gate`) keys off `Tool#requires_approval?`, which only `bash`
  overrides to `true`.

## The one distinction this chunk rests on: config vs. behavior

The interview's load-bearing decision. A skill is split cleanly:

- **Configured / static (code + markdown):** the `Skill` value object (scaffold template, named
  slots, front-matter metadata), the invocation grammar (`/skill`, `@role/skill`, `@role[/skill]`),
  the dispatch middleware, role attenuation + persona rendering, and the `.lain/` on-disk layout.
  All of this is deeply frozen, `Ractor.shareable?`, pure, and carries **no behavior**.
- **Dynamic / agent:** everything after the scaffold is injected — the agent's reasoning, its tool
  calls, and any `run_skill` invocations it decides to make. The scaffold *guides*; the agent
  *acts*.

`Skill` therefore holds only data; there is no `Skill#call` that "does the work." Execution is
either (a) in-line: the middleware rewrites `env[:text]` and the ordinary agent turn runs, or
(b) delegated: a role subagent runs and returns a result. This split is an explicit acceptance
criterion of T1, not just prose.

## Invocation grammar (decided)

| Form | Meaning | Mechanism |
|---|---|---|
| `/skill args` | Run the skill **in-line** on the current session, under the session's existing role. No in-line role override. | Middleware rewrites `env[:text]` → rendered scaffold + `args`; normal turn runs. |
| `@role/skill args` | Spawn a **`role` subagent** that **inherits** the parent context and runs the skill. | `SpawnPolicy(prefix: :inherit, only: role.only)`, child context = `role.prelude_segments` + scaffold. |
| `@role[/skill] args` | Spawn a **`role` subagent** with a **fresh root** (no inherited context). | `SpawnPolicy(prefix: :fresh, only: role.only)`, otherwise as above. |

Composition: a skill's markdown may statically `include` another skill (inlined pre-agent,
cycle-guarded); the agent may also invoke a skill dynamically via the `run_skill` tool.

## Orchestrator contract (plan-specific only)

- **Shared files (orchestrator-owned, wiring diffs only):**
  - `lib/lain.rb` — one manifest line per new unit, placed by dependency order.
  - `lib/lain/tools.rb` — index lines for `write_file`, `glob`, `grep`, web tools, `run_skill`.
  - `lib/lain/prompt.rb` — index lines for the `Skill`/`Skill::Catalog`/`Skill::Invocation` units.
  - `exe/lain` — orchestrator-owned **for wiring**: `Wiring#build_toolset` (`:354-359`, add the new
    tools) and `build_repl` (`:239-243`, thread the skill-dispatch `Middleware::Stack` + role-spawn
    seam). **Documented exception:** the `Repl` control-flow change (converse/dispatch/deliver) is
    T-B0's owned scope — `Repl` is exe-resident and not lib-unit-tested, and B0 is the *only* card
    touching that surface, so there is no collision; it lists `exe/lain` under its **Files**
    deliberately. Every *other* card's `exe/lain` touch stays a one-line wiring diff.
  - `lib/lain/role/catalog.rb` — one-line `only`-set additions when a new tool joins a role
    (e.g. `write_file`/`glob`/`grep` → `dev`, `test_engineer`; `web_*` → `researcher`). Routed as
    orchestrator diffs so the four tool cards never collide on this file.
  - `lain.gemspec` — only if the packaged-file glob does not already cover
    `lib/lain/prompt/templates/**/*` (the role templates ship today, so likely no change — an
    integration check, not a card).
- **Deviations from default process:** none. The shipped-skill-content card (F1) is markdown, but
  its scaffolds encode real process and get the same panel review.

## Open decisions

Execute-plan must not start a card gated on one of these:

- **Web-tool safety model (gates E4 only).** The approval gate (`Effect::Handler::Gate`) wraps
  **only the top-level agent** — `ChildBuilder#spawn_agent` (`subagent.rb:350-357`) gives a subagent
  a `Live`/`RefusingHandler` with **no Gate**, which is exactly why the `researcher` child holds no
  `bash`: subagents get only tools safe to run un-gated. So `requires_approval?` is *not* a real
  lever for `web_*` on a subagent role. Decision baked into E4: **web tools are tier-1 un-gated,
  with safety from structure, not approval** — an egress byte-cap, a redirect cap, no auth headers,
  and an optional domain allowlist (shape validation via `Tool::Input`, per `tool/input.rb`'s
  "shape not safety" note). `researcher` may then hold them honestly. If the human instead wants
  egress **gated**, that is a strictly larger, separate change — push `Gate` into the subagent
  handler chain AND drop `web_*` from every subagent `only`-set — and is **deferred**, not this
  chunk. Decide before E4 starts; the default above needs no decision to proceed.
- **Skill role-allowlist (affects A1/B3 shape, not blocking).** May a skill's front-matter restrict
  which roles may run it (`@role/skill` refused if `role ∉ allowed`)? Default baked in: **optional
  `roles:` allowlist, empty = any role**. B3 honors it if present.
- **`orchestrator` role.** Deliberately **not** added. When `/execute-plan` runs in-line the current
  session *is* the orchestrator (it fans out via `@role/skill` / `run_skill` + the `subagent` tool),
  so no new catalog role is needed for the first cut. Revisit only if the bench shows a distinct
  orchestrator persona earns its place.

## Waves

- **Wave 1** (no unmet deps): A1, B0, B1, D1, E1, E2, E3, E4
- **Wave 2**: A2 (←A1), D2 (←D1)
- **Wave 3**: B2 (←A2, B1, B0)
- **Wave 4**: B3 (←B2, D2), C1 (←A2, B2), F1 (←A2)

Critical path: **A1 → A2 → B2 → B3** (skill value layer → rendering → in-line dispatch+wiring →
role-bound subagent execution). D1 → D2 is a parallel feeder into B3; B0 (the Repl delivery/rescue
seam) is a wave-1 prerequisite of B2 but off the critical path; the four tool cards (E*) and B1 run
entirely in parallel on wave 1. (F1 depends only on the renderer A2 — its scaffolds are authored
against the skill format, not the dispatch middleware; end-to-end expansion is exercised in the
integration checks, not as a card dependency.)

## Tasks

### T-A1 — `Skill` value object + `Skill::Catalog`          [wave 1] [risk: medium]

**Depends on:** none
**Files:** create `lib/lain/skill.rb`, `lib/lain/skill/catalog.rb`,
`lib/lain/prompt/templates/skill/.keep`; create `spec/lain/skill_spec.rb`,
`spec/lain/skill/catalog_spec.rb`
**Reuse:** `lib/lain/role.rb` + `lib/lain/role/catalog.rb` (the exact value-object + frozen-catalog
+ loud-`Unknown` shape to mirror); `Prompt::Slots.load`'s `.lain/**` disk-read convention
(`slots.rb:47-95`); `Telemetry::Journalable`/`Ractor.shareable?` frozen-value discipline.
**Shared-file wiring:** add `require_relative "lain/skill"` + `"lain/skill/catalog"` lines to
`lib/lain/prompt.rb` (or `lib/lain.rb` if load order demands) — orchestrator applies.

**Acceptance criteria:**

```gherkin
Scenario: a shipped skill loads with its metadata and scaffold
  Given a shipped skill dir lib/lain/prompt/templates/skill/create-plan/ with skill.md + front-matter
  When Skill::Catalog.load reads the catalog
  Then Skill::Catalog.fetch("create-plan") returns a Skill whose name, description, and raw scaffold
    match the files, and whose declared slots and includes are parsed from front-matter

Scenario: a user skill under .lain/skills overrides/extends the shipped set
  Given .lain/skills/triage/skill.md in the project root
  When the catalog loads
  Then fetch("triage") returns the user skill; a name colliding with a shipped skill resolves to the
    user version

Scenario: an unknown skill fails loudly naming the set
  When Skill::Catalog.fetch("nope") is called
  Then it raises Skill::Catalog::Unknown naming "nope" and the known skill names

Scenario: a Skill carries config only, no behavior
  Given any loaded Skill
  Then Ractor.shareable?(skill) is true, it is frozen, and it exposes no method that renders,
    spawns, or calls an agent (config-vs-behavior boundary)
```
→ spec files: `spec/lain/skill_spec.rb`, `spec/lain/skill/catalog_spec.rb`

**Escalation triggers:**
- If parsing front-matter pulls in a YAML/markdown gem not already in the gemspec — stop; the repo
  keeps external deps in leaf files and this is a dependency decision, not a card call.
- If a shipped skill's scaffold must reference a non-content local (a date, a path) to be useful,
  it would trip `LockedBinding` purity — stop and confirm the slot-vs-arg boundary before adding a
  binding local.

### T-A2 — Skill scaffold rendering + `include` composition          [wave 2] [risk: medium]

**Depends on:** T-A1
**Files:** modify `lib/lain/prompt/slots.rb` (add a `skill` slot namespace + `render_skill`),
`lib/lain/prompt.rb` (nothing new if errors already defined); create
`lib/lain/skill/renderer.rb`; create `spec/lain/skill/renderer_spec.rb`, extend
`spec/lain/prompt/slots_spec.rb`
**Reuse:** `Slots#render_role`/`read_role_fills`/`ROLE_TEMPLATE_DIR` (`slots.rb:63-130`) as the
*pattern* for a namespaced slot region + `LockedBinding` render — **but note the data model differs:**
role slots are flat and one-per-role (`Dir.glob("role/*.md")`, `slots.rb:63-67`), whereas a skill has
**many holes**, so `skill/*` is two-level (`.lain/slots/skill/<skill>/<hole>.md`) over
directory-structured shipped templates (`templates/skill/<name>/`). This card writes a *new*
two-level loader; it does not reuse the flat role glob. `Prompt::LockedBinding` for pure ERB;
`Lain::Prompt::CircularSlot` (already in `prompt.rb`) for `include` cycle detection.
**Ownership boundary:** `Slots#render_skill` renders one hole through the locked binding (the pure,
leaf render); `Skill::Renderer` owns *composition* — assembling a skill's holes and resolving
`include` across skills (it holds the catalog; the binding never does). One renders, one composes;
they are not two homes for the same job.
**Shared-file wiring:** `require_relative` line for `lib/lain/skill/renderer.rb` in the prompt
index — orchestrator applies.

**Acceptance criteria:**

```gherkin
Scenario: a skill scaffold renders with its user slot fills injected
  Given shipped skill create-plan with a named hole "conventions"
  And .lain/slots/skill/create-plan/conventions.md exists
  When the skill is rendered
  Then the rendered scaffold contains the user's conventions markdown at the hole, verbatim

Scenario: a missing skill slot falls back to the shipped default
  Given no .lain/slots/skill/create-plan/conventions.md
  When the skill is rendered
  Then the shipped default fills the hole and rendering succeeds

Scenario: static include inlines another skill, cycle-guarded
  Given skill A includes skill B and B includes A
  When A is rendered
  Then B's scaffold is inlined into A, and the A→B→A cycle raises Lain::Prompt::CircularSlot naming
    the cycle (no infinite loop, no silent truncation)

Scenario: rendering is pure and byte-stable
  Given identical skill files and fills
  When rendered twice
  Then the output bytes are identical; an impure reference (Time.now) in a skill raises ImpureSlot
```
→ spec files: `spec/lain/skill/renderer_spec.rb`, `spec/lain/prompt/slots_spec.rb`

**Escalation triggers:**
- If `include` resolution needs the catalog but the catalog needs the renderer, that is a load-order
  cycle — stop; the manifest in `lain.rb` is where it must be broken, not with a scattered require.
- If an existing `slots_spec.rb` example pins that `KNOWN`/namespaces are exactly `system` + `role`,
  adding `skill` will break it — update that pin in the same card and note it (it is intended).

### T-B1 — `Skill::Invocation` grammar parser          [wave 1] [risk: low]

**Depends on:** none
**Files:** create `lib/lain/skill/invocation.rb`; create `spec/lain/skill/invocation_spec.rb`
**Reuse:** the loud-failure idiom of `Role::Catalog.fetch`; `Data.define` frozen-value shape.
**Shared-file wiring:** `require_relative` line for `lib/lain/skill/invocation.rb` — orchestrator
applies.

**Acceptance criteria:**

```gherkin
Scenario: a bare in-line invocation parses
  When "/create-plan add a write_file tool" is parsed
  Then the result names skill "create-plan", role nil, context nil, args "add a write_file tool"

Scenario: a role-bound inheriting invocation parses
  When "@researcher/create-plan foo" is parsed
  Then skill "create-plan", role "researcher", context :inherit, args "foo"

Scenario: a role-bound fresh-root invocation parses
  When "@researcher[/create-plan] foo" is parsed
  Then skill "create-plan", role "researcher", context :fresh, args "foo"

Scenario: ordinary text is not an invocation
  When "please create a plan for me" is parsed
  Then the result reports not-an-invocation (leaving env[:text] untouched downstream)

Scenario: a malformed invocation fails loudly
  When "@/create-plan" or "@researcher/" is parsed
  Then it raises Skill::Invocation::Malformed naming the offending input
```
→ spec file: `spec/lain/skill/invocation_spec.rb`

**Escalation triggers:**
- If a real user prompt can legitimately begin with `/` or `@` as content (e.g. a path, an email),
  the not-an-invocation rule must not swallow it — stop and confirm the disambiguation rule (leading
  token must match a known grammar shape) rather than guessing.

### T-B0 — Repl short-circuit delivery + dispatch-boundary rescue          [wave 1] [risk: high]

**Depends on:** none
**Files:** modify `exe/lain` (`Repl#dispatch`, `#converse`, `#deliver`, `:475-542`) so a middleware
that short-circuits (sets `env[:response]` without calling downstream `respond`) actually renders,
and a `Lain::Error` raised in the middleware chain renders instead of crashing the loop; add
`spec/lain/repl_delivery_spec.rb` driving the seam the way `repl_middleware_spec.rb#run_command`
mirrors `dispatch`.
**Reuse:** the existing `repl_middleware_spec.rb` `run_command` harness (mirrors `dispatch` without
a Thor instance); `@tty.render_response`/`render_error` (`frontend/tty.rb`); the `respond`→`deliver`
path (`exe/lain:524-542`) which today is the ONLY renderer.
**Shared-file wiring:** none — this card *owns* the scoped `Repl` control-flow change (Repl is
exe-resident and, per CLAUDE.md, not lib-unit-tested; the seam is exercised through the same
`run_command`-style harness the repl monoid spec already uses).

**Why this card exists:** today `Repl#converse` (`exe/lain:477-481`) throws away `dispatch`'s return
value, `respond` is the only thing that renders (and it *always* spends a model turn via
`@agent.ask`), and only the downstream `respond` block rescues `Lain::Error` — the dispatch boundary
does not. So a middleware that answers without a turn (unknown-skill notice, a folded `@role/skill`
result) has nowhere to render, and a `Skill::Invocation::Malformed` at `you>` crashes the REPL.
Every short-circuit AC in B2/B3 is unbuildable until this seam exists.

**Acceptance criteria:**

```gherkin
Scenario: a middleware-supplied response renders without a model turn
  Given a repl-phase middleware that sets env[:response] and does NOT call downstream
  When a line is dispatched
  Then env[:response] is delivered to the TTY and @agent.ask is never called (zero turn spent)

Scenario: the normal downstream path still renders exactly once
  Given no short-circuiting middleware
  When a line is dispatched
  Then respond runs and its response is delivered exactly once (no double-deliver)

Scenario: an error raised in the middleware chain is rendered, not fatal
  Given a middleware that raises Lain::Error (e.g. Skill::Invocation::Malformed)
  When a line is dispatched
  Then the error is rendered to the TTY and converse continues to the next prompt (loop survives)
```
→ spec file: `spec/lain/repl_delivery_spec.rb`

**Escalation triggers:**
- `respond` currently calls `deliver` *internally* (`exe/lain:533,539-542`); restructuring so
  `dispatch` owns delivery risks double-render. If removing `respond`'s internal `deliver` breaks an
  existing repl/cli spec that asserts the render count, stop and reconcile — the "exactly once" AC is
  the invariant, not the call site.
- If output discipline tempts a `puts` in the middleware to render the short-circuit message, stop —
  that is the exact violation this card exists to prevent; the render must go through `@tty`.

### T-B2 — `SkillDispatch` middleware + in-line execution + repl wiring          [wave 3] [risk: high]

**Depends on:** T-A2, T-B1, T-B0
**Files:** create `lib/lain/middleware/skill_dispatch.rb`; create `lib/lain/cli/repl_middleware.rb`
(a lib-side, unit-testable builder that assembles the repl-phase `Middleware::Stack` with
`SkillDispatch` — construction lives in `lib`, never in the thin exe); create
`spec/lain/middleware/skill_dispatch_spec.rb`, `spec/lain/cli/repl_middleware_spec.rb`
**Reuse:** `Middleware::Base`/`downstream` (`middleware.rb:50-70`) and
`Middleware::RefuseSecretWrites` as the exact "subclass Base, override #call, freeze" template;
`Middleware::Stack` construction as done for `tool_middleware` (`exe/lain:396`); `CLI::Backend` as
the precedent for "lib owns the resolution, the exe just calls it"; the `repl_middleware_spec.rb`
monoid harness; `Skill::Invocation` (B1) + `Skill::Renderer` (A2).
**Shared-file wiring:** `lib/lain/middleware.rb` index line for `skill_dispatch.rb` (the directory
index at `:248-251`), and `lib/lain.rb` + `lib/lain/cli.rb` index lines for `repl_middleware.rb`; in
`exe/lain`, `build_repl` (`:239-243`) gains one line — `middleware: Lain::CLI::ReplMiddleware.build(
catalog:, renderer:)` — the genuine one-line wiring diff the orchestrator applies.

**Acceptance criteria:**

```gherkin
Scenario: an in-line skill invocation expands into the turn text
  Given the repl stack contains SkillDispatch and skill create-plan is loaded
  When the user types "/create-plan add a write_file tool"
  Then downstream receives env[:text] equal to the rendered create-plan scaffold with the args
    appended, and the ordinary agent turn runs on it (one timeline, session role unchanged)

Scenario: a non-skill line passes through untouched
  Given the repl stack contains SkillDispatch
  When the user types "please help me plan"
  Then env[:text] reaches downstream unchanged and a normal turn runs

Scenario: an unknown skill is reported, not sent to the model
  When the user types "/nope"
  Then the user sees a loud "unknown skill" message and no agent turn is spent

Scenario: SkillDispatch preserves the repl monoid
  Given the repl-phase "a monoid" shared example
  Then a stack with SkillDispatch still satisfies identity and associativity over :text,:agent→:response
```
→ spec file: `spec/lain/middleware/skill_dispatch_spec.rb`

**Escalation triggers:**
- `build_repl` currently passes **no** `middleware:` (`exe/lain:239-243`); if threading it requires
  `Wiring` to construct the catalog/renderer and that pulls session-scoped state (cwd, `.lain/`)
  into a place that runs before the session root is known — stop and confirm where the catalog
  loads (it must be one disk read at session start, like `Slots.load`).
- If any existing spec asserts the repl stack is empty/pass-through by default — this card changes
  that; stop and confirm before editing the pin.

### T-B3 — `@role/skill` and `@role[/skill]` subagent execution          [wave 4] [risk: high]

**Depends on:** T-B2, T-D2
**Files:** modify `lib/lain/middleware/skill_dispatch.rb` (route role-bound invocations to the
spawn seam); modify `lib/lain/cli/repl_middleware.rb` (thread the role-spawn seam into the builder);
extend `spec/lain/middleware/skill_dispatch_spec.rb`, `spec/lain/cli/repl_middleware_spec.rb`
**Reuse:** the role-selecting spawn seam + public run→result entry from T-D2;
`Tools::Subagent`/`Supervisor` already held by `Repl` (`@supervisor`, runs inside `Sync`);
`SpawnPolicy(prefix: :inherit|:fresh, only:)`.
**Shared-file wiring:** `CLI::ReplMiddleware.build` (the lib file B2 created) grows a `role_spawn:`
parameter, and `exe/lain`'s `build_repl` line grows to pass the `Skill::RoleSpawn` seam that
`Wiring` constructs from its session-scoped internals (provider, context_factory, union toolset,
parent, journal, supervisor). That is a genuine wiring diff the orchestrator applies — not a no-op.

**Acceptance criteria:**

```gherkin
Scenario: @role/skill spawns an inheriting role subagent
  When the user types "@researcher/create-plan foo"
  Then a subagent spawns with the researcher only-set and prefix :inherit, its child context begins
    with the researcher persona prelude followed by the create-plan scaffold, and its final result
    becomes env[:response]

Scenario: @role[/skill] spawns a fresh-root role subagent
  When the user types "@researcher[/create-plan] foo"
  Then the spawned subagent uses prefix :fresh (no inherited parent conversation), otherwise as above

Scenario: the folded result renders but does not move the parent head
  When "@researcher/create-plan foo" completes
  Then the subagent's final answer is delivered as env[:response] (via the T-B0 seam) and the parent
    session Timeline head is unchanged — the subagent's turns live attributed in the Store, not in
    the parent's rendered conversation (the OM-2 out-of-band contract)

Scenario: an unknown role is refused before any spawn
  When the user types "@nope/create-plan"
  Then it raises/reports Role::Catalog::Unknown and no subagent is spawned, no tokens spent

Scenario: a role not permitted by the skill is refused
  Given create-plan front-matter allows roles [researcher, dev]
  When the user types "@reviewer_security/create-plan"
  Then the invocation is refused naming the allowed set (only if a roles allowlist is present)
```
→ spec file: `spec/lain/middleware/skill_dispatch_spec.rb`

**Escalation triggers:**
- Spawning from inside repl middleware must stay within the Repl's existing `Sync`/supervisor
  (`exe/lain:497-503`); if the middleware runs outside a reactor, the spawn will fail — stop and
  confirm the execution context rather than opening a second reactor.
- If `@role/skill` result folding double-commits to the timeline (the subagent's within-turn
  gate-2 commit plus the middleware's `:response`), stop — that is the OM-2 turn-boundary invariant;
  confirm the fold path with the subagent tool's final-result-only contract.

### T-C1 — `run_skill` tool (dynamic composition)          [wave 4] [risk: medium]

**Depends on:** T-A2, T-B2
**Files:** create `lib/lain/tools/run_skill.rb`; create `spec/lain/tools/run_skill_spec.rb`
**Reuse:** `Tool` base + `Tool::Input` (`tool/input.rb`); `Skill::Renderer` (A2) for rendering;
`Tools::Subagent`'s `max_depth`/depth-refusal pattern (`subagent.rb:165-170`) as the precedent for
the dispatch-time recursion ceiling.
**Execution model (decided):** `run_skill` is NOT the repl `env[:text]` path (that boundary is the
`you>` prompt, unavailable mid-loop). It renders the named skill's scaffold + args and returns that
text **as its `tool_result` to the calling agent** — the skill's guidance becomes the next thing the
same agent reads, a continuation, not a spawn. (`@role/skill`-style delegation stays the repl
surface's job via B3; `run_skill` is the in-agent composition primitive.)
**Shared-file wiring:** index line in `lib/lain/tools.rb`; add `run_skill` to
`Wiring#build_toolset` (`exe/lain:354-359`) — orchestrator applies.

**Acceptance criteria:**

```gherkin
Scenario: the agent invokes a skill at runtime
  Given the toolset contains run_skill and skill critique is loaded
  When the model calls run_skill(name: "critique", args: "the plan at planning/specs/foo.md")
  Then the rendered critique scaffold + args return as the tool_result the calling agent next reads

Scenario: run_skill on an unknown skill returns a loud tool error, not a crash
  When the model calls run_skill(name: "nope")
  Then the tool returns Tool::Result.error naming the unknown skill and the loop continues

Scenario: static include cycles are caught at render time
  When a skill invoked via run_skill includes itself transitively
  Then the CircularSlot guard fires and the tool returns an error, not a hang

Scenario: dispatch-time recursion is bounded
  Given run_skill has been invoked to a configured depth ceiling within one agent lineage
  When a further run_skill would exceed it
  Then the tool refuses with a depth error (analogous to Subagent max_depth), so a skill that keeps
    calling run_skill cannot recurse without bound
```
→ spec file: `spec/lain/tools/run_skill_spec.rb`

**Escalation triggers:**
- The dispatch-time ceiling (model calls run_skill → reads a scaffold that says call run_skill …) is
  distinct from `CircularSlot` (render-time `include`). If the run-depth cannot be threaded through
  the tool without session state it does not have, stop and confirm where the counter lives before
  inventing one.

### T-D1 — Render role persona into a spawned child (close PS-3)          [wave 1] [risk: medium]

**Depends on:** none
**Files:** modify `lib/lain/tools/subagent.rb` (`ChildBuilder#spawn_agent`, `:350-357`) to build the
child system prompt from the role prelude; possibly modify `lib/lain/role.rb` only if a helper is
missing; extend `spec/lain/tools/subagent_spec.rb`, add `spec/lain/role_prelude_wiring_spec.rb`
**Reuse:** `Role#prelude_segments(slots:)` (`role.rb:54-56`) and `Slots#render_role`
(`slots.rb:122-130`) — already built and tested, just unconsumed; `SpawnPolicy::SiblingTemplate`'s
documented intent that its template is `Role#prelude_segments` position 0 (`spawn_policy.rb:100-106`).
**Shared-file wiring:** none (behavioral wiring inside the subagent tool).

**Acceptance criteria:**

```gherkin
Scenario: a spawned role subagent's system prompt carries its persona
  Given a subagent constructed with a role (e.g. researcher) and a Slots
  When it spawns
  Then the child's rendered system prompt begins with the role-invariant prelude and then the
    researcher role slot (prelude_segments order), not merely the parent's top-level system slot

Scenario: the persona renders as two distinct blocks, cache-marked on the shared bulk
  Given the child uses prelude_segments (NOT the joined prelude String)
  When it renders
  Then the system is two separate blocks — segment 0 the role-invariant bulk, segment 1 the role
    tail — and the cache breakpoint sits on segment 0, so heterogeneous siblings share the warm
    prefix (the CE-4 win prelude_segments exists for; a fused String must fail this)

Scenario: a role slot override reaches the spawned child
  Given .lain/slots/role/researcher.md overrides the researcher persona
  When a researcher subagent spawns
  Then the child's system prompt reflects the override, and sibling roles are unaffected

Scenario: the existing research_subagent still spawns and stays read-only
  Given the chat-default research_subagent
  When it spawns
  Then its only-set is still {read_file, list_files} and its persona now applies (no capability change)
```
→ spec files: `spec/lain/tools/subagent_spec.rb`, `spec/lain/role_prelude_wiring_spec.rb`

**Escalation triggers:**
- `research_subagent`'s `context_factory: -> { backend.context }` (`exe/lain:366`) renders the
  top-level system slot; injecting the role prelude must not **double** the top-level system bulk
  (prelude_segments already includes `render("system")`). If it would, stop — reconcile so the child
  system is prelude-only, not prelude+context.system.
- If a spec pins the current child system bytes/digest (cache identity), this card changes them
  intentionally — update the pin in-card and flag it.

### T-D2 — Role-selecting, context-mode spawn seam          [wave 2] [risk: medium]

**Depends on:** T-D1
**Files:** create `lib/lain/skill/role_spawn.rb` (a seam: `(role_name, context_mode, prompt)
→ subagent result`); modify `lib/lain/tools/subagent.rb` to expose a **public synchronous
run-one-prompt→result entry** (today `#perform` is `protected` and dispatched only through the
effect handler / actor `launch_actor`; there is no direct call path a seam can use); create
`spec/lain/skill/role_spawn_spec.rb`, extend `spec/lain/tools/subagent_spec.rb`
**Reuse:** `Role::Catalog.fetch` + `Role#spawn_policy(prefix:)` (`role.rb:42-44`); the collaborator
set `research_subagent` assembles (`exe/lain:364-370` — provider, context_factory, union toolset,
parent thunk, journal, supervisor); T-D1's persona-in-child rendering.
**Shared-file wiring:** `lib/lain.rb`/prompt-index line for `role_spawn.rb`. **The seam needs the
session-scoped collaborators that live private inside `Wiring`**, so it is constructed in `exe/lain`
from those internals and handed to `CLI::ReplMiddleware.build` (see B3) — that is a real wiring diff,
not a no-op.

**Acceptance criteria:**

```gherkin
Scenario: the seam spawns a chosen role at call time with an inherit prefix
  When the seam is asked to run role "dev" with context :inherit and a prompt
  Then a subagent spawns with the dev only-set, prefix :inherit, and the dev persona in its system

Scenario: the seam honors the fresh context mode
  When asked to run role "dev" with context :fresh
  Then the spawned subagent uses prefix :fresh (no inherited parent conversation)

Scenario: the seam runs the prompt to a single final result
  Given a role subagent built by the seam
  When it is asked to run a prompt
  Then it returns that child's final answer synchronously (a public run→result entry), without the
    caller needing the effect-handler dispatch path or the actor launch path

Scenario: an unknown role fails loudly before spawning
  When asked to run role "nope"
  Then Role::Catalog::Unknown is raised naming the catalog and nothing spawns
```
→ spec file: `spec/lain/skill/role_spawn_spec.rb`

**Escalation triggers:**
- Today `Tools::Subagent` fixes its policy at construction and the model cannot choose a role; this
  seam adds call-time role selection. If that conflicts with a spec asserting policy is
  construction-fixed, stop — the two must be reconciled (call-time selection is additive, the
  model-facing `subagent` tool stays construction-fixed).

### T-E1 — `write_file` tool          [wave 1] [risk: medium]

**Depends on:** none
**Files:** create `lib/lain/tools/write_file.rb`; create `spec/lain/tools/write_file_spec.rb`
**Reuse:** `Tools::EditFile` (`tools/edit_file.rb`) for the `Tool`+`Tool::Input`+`Tool::Contracts`
shape and the session read-set contract; `Tool::Result.ok/error`.
**Shared-file wiring:** index in `lib/lain/tools.rb`; add to `Wiring#build_toolset`
(`exe/lain:355`); add `write_file` to `dev`/`test_engineer` `only`-sets in `role/catalog.rb` —
all orchestrator diffs.

**Acceptance criteria:**

```gherkin
Scenario: write_file creates a new file
  Given path new.rb does not exist
  When write_file(path: "new.rb", content: "x") is called
  Then new.rb is created with content "x" and the result is ok

Scenario: write_file overwriting an existing file requires it was read this session
  Given existing.rb exists and was not read this session
  When write_file(path: "existing.rb", content: "y") is called
  Then the tool returns an error requiring a prior read (mirroring edit_file's read-before-write),
    not a silent clobber

Scenario: write_file is a structured tier-1 tool, un-gated
  Then write_file.requires_approval? is false (no model-controlled command string)
```
→ spec file: `spec/lain/tools/write_file_spec.rb`

**Escalation triggers:**
- If reusing `edit_file`'s read-set contract for overwrite makes first-time *creation* impossible
  (no prior read of a nonexistent file), stop — creation must be allowed while overwrite is guarded;
  confirm the create-vs-overwrite split.

### T-E2 — `glob` tool          [wave 1] [risk: low]

**Depends on:** none
**Files:** create `lib/lain/tools/glob.rb`; create `spec/lain/tools/glob_spec.rb`
**Reuse:** `Tools::ListFiles` (`tools/list_files.rb:53` already uses `Dir.glob` internally) for the
tool shape and sorted-output discipline.
**Shared-file wiring:** index in `lib/lain/tools.rb`; add to `Wiring#build_toolset`; add `glob` to
`dev`/`test_engineer` `only`-sets — orchestrator diffs.

**Acceptance criteria:**

```gherkin
Scenario: glob returns matches in deterministic order
  Given files a.rb, b.rb, sub/c.rb
  When glob(pattern: "**/*.rb") is called
  Then it returns [a.rb, b.rb, sub/c.rb] sorted deterministically

Scenario: glob with no matches returns an empty, non-error result
  When glob(pattern: "*.nope") is called
  Then the result is ok with an empty list, not an error

Scenario: glob is tier-1 and un-gated
  Then glob.requires_approval? is false
```
→ spec file: `spec/lain/tools/glob_spec.rb`

**Escalation triggers:**
- If `Dir.glob` can escape the project root via an absolute or `../` pattern, stop and confirm the
  root-confinement rule (shape-not-safety per `tool/input.rb`, but a silent escape is worth a check).

### T-E3 — `grep` tool          [wave 1] [risk: low]

**Depends on:** none
**Files:** create `lib/lain/tools/grep.rb`; create `spec/lain/tools/grep_spec.rb`
**Reuse:** the `Tool`+`Tool::Input` shape from `read_file`/`list_files`; `Bm25`/`Memory` are not
relevant (this is literal content search, not ranked retrieval).
**Shared-file wiring:** index in `lib/lain/tools.rb`; add to `Wiring#build_toolset`; add `grep` to
`dev`/`test_engineer` (and optionally reviewer) `only`-sets — orchestrator diffs.

**Acceptance criteria:**

```gherkin
Scenario: grep returns matching lines with file:line locations
  Given foo.rb contains "needle" on line 3
  When grep(pattern: "needle", path: ".") is called
  Then the result includes foo.rb:3 and the matching line text

Scenario: grep with no matches returns an ok empty result
  When grep(pattern: "zzz", path: ".") matches nothing
  Then the result is ok and empty, not an error

Scenario: grep output is bounded
  Given a pattern matching thousands of lines
  When grep is called
  Then output is capped and the cap is reported (no unbounded result flooding the turn)
```
→ spec file: `spec/lain/tools/grep_spec.rb`

**Escalation triggers:**
- If implementing grep by shelling to `rg`/`grep` (tier-3) rather than in-Ruby scanning, stop —
  that reintroduces the approval gate this tool exists to avoid; confirm the pure-Ruby vs shell
  decision (default: pure-Ruby, tier-1).

### T-E4 — `web_fetch` + `web_search` tools          [wave 1] [risk: high]

**Depends on:** none
**Files:** create `lib/lain/tools/web_fetch.rb`, `lib/lain/tools/web_search.rb`; create
`spec/lain/tools/web_fetch_spec.rb`, `spec/lain/tools/web_search_spec.rb`
**Reuse:** `Tool`+`Tool::Input`; `faraday` (already a leaf-file dependency in the provider layer) as
the HTTP client; the `Effect::Handler::Gate`/`requires_approval?` model for the egress decision.
**Shared-file wiring:** index in `lib/lain/tools.rb`; add both to `Wiring#build_toolset`; add
`web_fetch`/`web_search` to the `researcher` `only`-set in `role/catalog.rb` — orchestrator diffs.

**Acceptance criteria:**

```gherkin
Scenario: web_fetch retrieves a URL's text content
  Given an injected HTTP client returning a page for https://example.com
  When web_fetch(url: "https://example.com") is called
  Then the result is ok and contains the page's text (client injected in specs — no live network)

Scenario: web tools are tier-1 with structural bounds, not approval
  Then web_fetch.requires_approval? is false, and a response exceeding the byte-cap or redirect-cap
    is truncated/refused by the tool itself (no auth headers ever sent), not by an approval prompt

Scenario: a fetch error is a loud tool error, not a crash
  When the injected client raises or returns non-2xx
  Then the tool returns Tool::Result.error naming the failure and the loop continues

Scenario: web_search returns ranked results from an injected search backend
  When web_search(query: "ruby frozen string") is called
  Then it returns titled, linked results from the injected backend
```
→ spec files: `spec/lain/tools/web_fetch_spec.rb`, `spec/lain/tools/web_search_spec.rb`

**Escalation triggers:**
- **Gated by the Web-tool safety Open decision above** — proceed on the tier-1-with-bounds default;
  do NOT reach for `requires_approval? => true` (it is a no-op on the subagent that owns these tools;
  see the Open decision) without the human electing the larger subagent-gating change.
- If `web_search` requires a third-party API key/endpoint, stop — that is a new configuration and
  credential surface (like the provider keys), not a card-local choice.
- Output discipline: a fetched page must never be `warn`/`puts`'d; it returns as a `Tool::Result`.

### T-F1 — Author the three shipped skills          [wave 4] [risk: medium]

**Depends on:** T-A2
**Files:** create `lib/lain/prompt/templates/skill/create-plan/skill.md`,
`.../execute-plan/skill.md`, `.../critique/skill.md` (+ their front-matter and any default slot
partials); create `spec/lain/skill/shipped_skills_spec.rb`
**Reuse:** the process encoded in the user's Claude Code `/create-plan`, `/execute-plan`,
`/critique` skills, **adapted to lain** — rspec (not a generic framework), the `planning/specs/`
convention, the real `Role::Catalog` names, the `@role/skill` + `run_skill` composition this chunk
adds. `grader-from-gherkin.md`/`plan-shaped-compaction.md` are the design source for what the plan
and critique scaffolds should ask for.
**Shared-file wiring:** none (content under `lib/`, packaged by the existing template glob — see the
gemspec integration check).

**Acceptance criteria:**

```gherkin
Scenario: the three skills load and render
  When Skill::Catalog.load runs
  Then create-plan, execute-plan, and critique are present, each renders to non-empty scaffold text,
    and each declares at least the named slots its front-matter promises

Scenario: create-plan's scaffold drives a plan, not code
  When /create-plan is expanded
  Then its scaffold instructs grounding-before-planning, Gherkin acceptance criteria, and writing to
    planning/specs (adapted from the source skill), and references lain's real roles

Scenario: a user slot extends a shipped skill
  Given .lain/slots/skill/create-plan/conventions.md
  When create-plan renders
  Then the user conventions appear at the declared hole
```
→ spec file: `spec/lain/skill/shipped_skills_spec.rb`

**Escalation triggers:**
- If a shipped scaffold wants dynamic data (today's date, the repo's branch) it cannot get it via a
  pure slot (`LockedBinding` forbids it) — stop; such data must arrive as `args` or a tool call, not
  a binding local.

## Execution record (in-progress)

Landed on `main`, leaf-first, each full-suite-green via the pre-commit hook. **Wave 1 complete (8/8).**

| Card | Commit | Notes |
|---|---|---|
| T-E2 glob | `ba8f4d4` | no-confinement decision verified consistent with all sibling tools; `role_spec` union fixture grows per tool |
| T-E3 grep | `e125782` | pure-Ruby, lazy `MAX_MATCHES` cap; deliberately does NOT record a session read |
| T-E1 write_file | `ece5c3c` | create-vs-overwrite split; empty-content fix via a new `Tool::Input#field blank_ok:` carve-out (panel BLOCKER) |
| T-B0 repl delivery | `5fb5100` | dispatch owns delivery; guards the omitted-`:response` KeyError so a buggy short-circuit can't kill the REPL (panel SHOULD-FIX) |
| T-D1 role persona | `68da9cb` | persona into child via injected `Role::Persona` (Null default); ≤4-cache-mark invariant pinned pending (see tickets) |
| T-A1 Skill value object | `f9fe941` | config-only Data value + Catalog; front-matter loud-failure via `Skill::Catalog::Malformed` (panel SHOULD-FIX) |
| T-B1 invocation parser | `4bc3eae` | orchestrator applied `module Skill`→`class Skill` at integration (reopen the Data value class — cross-card collision) |
| T-E4 web tools | `3acee32` | streaming byte-cap (panel BLOCKER), redirect-crash fix; researcher gains web egress; `base_tools` extracted (AbcSize) |

**⚠️ Decision surfaced at E4 landing — for Joel's awareness:** the plan's D1 AC4 ("researcher stays
`{read_file, list_files}`, no capability change") and E4 ("add `web_*` to the researcher only-set")
are in tension. Resolved per the Open decision's clear intent ("researcher may then hold them
honestly", tier-1 structural safety): the chat's default `research_subagent` (`:researcher` role)
now holds **un-gated `web_fetch`/`web_search`** — structurally bounded (byte/redirect caps, scheme
guard, host allowlist, no auth headers), never approval-gated (a subagent handler carries no Gate).
No tree-mutating capability added. The specs that pinned the pre-E4 researcher set (`backend_spec`,
`role_prelude_wiring_spec`, `subagent_spec`) were grown to match. If you'd rather the default chat
researcher NOT reach the network, drop `web_*` from `:researcher` and this reverts cleanly.

**Wave 2 complete (2/2).**

| Card | Commit | Notes |
|---|---|---|
| T-D2 spawn seam | `e7fc7b9` | public sync `Subagent#run` (no effect-handler/actor path); forwards `observer:` so `@role/skill` lineage reaches the scribe (panel SHOULD-FIX) |
| T-A2 skill rendering | `a7211aa` | render-vs-compose split; splices pre-rendered fragments via block-gsub so a verbatim fill never re-enters ERB (panel SHOULD-FIX: silent double-eval mangle); extracted `Prompt::SkillSlots` |

Infra note: ALL worktrees fork from the session-start commit, not live `main` — dependent-wave
agents `git merge main` first (baked into wave-3+ briefs). A2 self-healed; D2 escalated (correctly).

**Wave 3 complete (1/1).**

| Card | Commit | Notes |
|---|---|---|
| T-B2 skill dispatch | `867375f` | `SkillDispatch` (in-line `/skill`, pass-through, unknown short-circuit, malformed-propagates, role-bound stub for B3); `CLI::ReplMiddleware.build` owns the one catalog disk-read; wired live into `build_repl` (panel BLOCKER: was dead code without the exe kwarg) |

**Wave 4 complete (3/3). ALL 13 CARDS LANDED.**

| Card | Commit | Notes |
|---|---|---|
| T-F1 shipped skills | `7f79cb6` | create-plan/execute-plan/critique authored; real process, real roles; run_skill description corrected (panel: conflated with render-time `includes:`) |
| T-C1 run_skill | `0a6a41f` | in-agent continuation; recursion bound renamed to a truthful `MAX_INVOCATIONS=64` budget (panel: was mislabeled "depth"); main-agent-only |
| T-B3 role-bound dispatch | `adac210` | `@role/skill`/`@role[/skill]` fold a persona'd one-shot subagent; OM-2 head-invariance proven with a real seam; 4-part exe wiring applied + smoke-tested |

Plus `4d668e7` — `bin/demo-skills`, the automatable manual-demo half (10/10 green).

### Integration checks — all green (2026-07-17)

- `bundle exec rspec` → **2677 examples, 0 failures, 2 pending** (1 pre-existing; 1 = D1's ≤4-cache-mark invariant pin).
- `bundle exec rubocop` → clean, 467 files, **no `Metrics/*` loosened** — every trip paid by extraction (`base_tools`, `run_skill`, `role_spawn_seam`, `Prompt::SkillSlots`, `build_repl` reflow).
- `Ractor.shareable?` → true for `Skill` and `Skill::Invocation`; `SkillDispatch` frozen (verified live).
- Output discipline (`spec/output_discipline_spec.rb`) → green; the new tools/middleware write to `Tool::Result`/`Channel`/`Response`, never `$stdout`.
- Gemspec → packages via `git ls-files`, so the tracked `templates/skill/**` .md files ship; no gemspec change (as predicted).
- `bin/demo-skills` → in-line `/create-plan`, unknown `/nope` short-circuit, and `@researcher/create-plan` (OM-2 head unchanged, unknown-role refused before spawn) all pass live over the real catalog + mock provider.

**Still owed to Joel (human, not automatable):** the interactive pass in a scratch project —
`/create-plan …` in-line, then `@researcher/create-plan …` vs `@researcher[/create-plan] …`, confirming
by eye that (a) in-line stays one timeline under the session role, (b) `@role` runs spawn a persona'd
subagent, (c) fresh vs inherit differ in what the child sees. `bin/demo-skills` covers the mechanics;
this is the feel-it-in-the-REPL confirmation.

### Follow-up tickets (execution-surfaced, none blocking)

- **Role tail double cache-mark (5 > 4 cap)** — pinned pending in `role_prelude_wiring_spec.rb`; fix (role tail in a seed message) lives in Context/CacheBreakpoints; MUST land before persona is wired into `exe/lain`.
- **`edit_file` empty-`old_string` quirk** — same `presence`-treats-`""`-as-blank issue `write_file`'s `blank_ok:` fixed; apply there if it bites.
- **`Skill::Invocation` bracket-without-slash gap** — `@r[create-plan]` (no inner `/`) parses as not-an-invocation, not `Malformed`.
- **`Skill::Invocation::Malformed` message** — could name the expected shapes like `Catalog::Unknown` does.
- **A2 authored-NUL scaffold-token collision** — untypeable in markdown; optional opaque-token hardening.
- **B3 NIT: role-bound skips `known?`** — `@researcher/nonexistent` surfaces via `Catalog::Unknown` propagation, not the friendly in-line short-circuit (still loud, 0 tokens; asymmetric).
- **B3 NIT: `expand` before role `fetch`** — an unknown-role line renders the scaffold before failing (no tokens; reorder for tidiness).
- **`web_search` real backend** — ships Null-backed (empty results); inject a real search backend when a provider/key is chosen.
- **`roles:` allowlist** — B3 AC5 is a no-op today (`Skill` has no `roles:` field); add the field + enforcement if per-skill role restriction is wanted.

Additional follow-up ticket: **A2 authored-NUL scaffold-token collision** — a scaffold literally
embedding the ` `-delimited fragment sentinel collides with the splice; untypeable in normal
markdown, self-inflicted (trusted content). Optional hardening: opaque per-render token, or
assert-absent the sentinel in `skill.scaffold` before rendering.

### Follow-up tickets (execution-surfaced)

- **Role tail double cache-mark (5 > 4 cap).** `Context#cache_marked` marks the last block, so a role child's tail gets a second mark on top of the seam's segment-0 mark; a long role child emits 5 `cache_control` blocks, past Anthropic's 4-cap → latent 400. Prescribed fix: role tail in a seed **message** after the breakpoint (per `SpawnPolicy::SiblingTemplate`'s own doctrine), one system block → one mark. Lives in Context/CacheBreakpoints. Pinned pending in `role_prelude_wiring_spec.rb`; MUST land before persona is wired into `exe/lain`.
- **`edit_file` empty-`old_string` quirk.** Same `presence: true` treats `""`-as-blank issue write_file's `blank_ok:` fixed; `edit_file`'s `new_string: ""` deletion path shares it. Narrow, latent; apply `blank_ok:` there too if it ever bites.
- **`Skill::Invocation` bracket-without-slash gap.** `@researcher[create-plan] foo` (brackets, missing inner `/`) parses as not-an-invocation rather than `Malformed`; a bracket is a stronger "attempted the grammar" signal than the leading-`/`-token heuristic credits. Outside B1's ACs; tighten the disambiguation if it matters.
- **`Skill::Invocation::Malformed` message shape.** Unlike `Catalog::Unknown` (which lists the known set), Malformed names the input but not the expected shapes (`/skill`, `@role/skill`, `@role[/skill]`). Cheap loud-failure polish.

## Integration checks

After the last wave:

- `bundle exec rspec` green (full suite; the new specs load through `require "lain"` — group each
  new lib file with its manifest/index line and spec in one commit per the repo's untracked-spec
  trap).
- `bundle exec rubocop -a` clean; **no `Metrics/*` limit loosened** — if `SkillDispatch` or the
  renderer trips one, extract a collaborator (the config-vs-behavior split makes the seams obvious).
- `Ractor.shareable?` holds for `Skill`, `Skill::Invocation`, and any new frozen value (spec'd in
  T-A1/T-B1).
- **Manual demo (human, owed to Joel):** in a scratch project, `/create-plan …` in-line, then
  `@researcher/create-plan …` and `@researcher[/create-plan] …`, and confirm (a) the in-line run
  stays on one timeline under the session role, (b) the `@role` runs spawn a persona'd subagent, (c)
  fresh vs inherit differ in what the child sees. A `bin/demo-skills` against the mock provider is
  the automatable half.
- **Gemspec check:** confirm the packaged-file glob covers `lib/lain/prompt/templates/skill/**` (the
  role templates ship today, so likely already covered — verify, don't assume).
- Output discipline (`spec/output_discipline_spec.rb`) still green — the new tools and middleware
  write to `Tool::Result`/`Channel`/`Sink`, never `$stdout`.
