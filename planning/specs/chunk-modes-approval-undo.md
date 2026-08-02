# Chunk — interaction modes, approval triage, and workspace undo

status: draft (awaiting Joel's review)
commit-mode: orchestrator-commits
language: ruby
panel: Torvalds, Evans, Metz, Schneeman, Patterson (one review agent embodies all)

---

## Intent

Give Lain a **mode system**: one exclusive posture governing how the agent's output is
interpreted, plus orthogonal composable layers — Emacs' major/minor split, with Vim's mutual
exclusion kept for the one job it earns. Hang three things off that spine:

1. **The posture ladder** — `plan` (no mutating capability at all), `manual`, `accept-edits`,
   `auto` — where a posture resolves to a toolset attenuation, a gate policy, and a snapshot
   scope.
2. **Cheap undo**, so `auto` is safe for the reason `first-class-concepts.md:161-165` already
   argues: a lain-owned shadow git repo detects *which* paths a turn changed — including the
   ones `bash` mutated, which today's write-set scope structurally cannot see — and lain's own
   content-addressed `Store` holds the bytes.
3. **Approval triage**, a deterministic layer *below* the existing human/LLM escalation ladder:
   parse a shell command to an AST, return **allow / deny / abstain**, and execute an allowed
   term as reconstructed argv so the shell never sees a string. Abstention falls through to the
   machinery that already exists.

The through-line is the one the emacs research produced: **the unit of policy is an answer to
one question, not a mode you are in**, and a layer that has nothing to say must be free.

---

## Grounding

Verified 2026-07-30 against `4e3e109` by four parallel exploration passes plus three research
passes. Every line reference below was read, not recalled.

**What exists.**

- `Effect::Handler::Gate` (`lib/lain/effect/handler/gate.rb:55`) gates on **tier**, reading
  `Tool#requires_approval?` off the inner handler's tool. Policy duck is
  `#call(effect, context) -> Boolean` — two-valued (`gate.rb:51`, spec-pinned at
  `spec/lain/effect/handler/gate_spec.rb:115-126`).
- `Approval::Queue` (`lib/lain/approval/queue.rb:101`) is that policy in practice: parks a fiber,
  first surface to answer wins, fail-closed on timeout (`:218-222`) and abandonment (`:168-174`).
- `Approval::AutoSurface` (`lib/lain/approval/auto_surface.rb:53`) is the LLM stand-in. Its
  verdict grammar is **already three-valued** — `VERDICT = /\A(approve|deny|defer)\.?\z/i`
  (`:42`) — with deny-when-unsure doctrine at `:21-25`. It observes `queue.each`, never
  `dequeue`, so it cannot steal from the human.
- `Approval::PolicySwitch` (`lib/lain/approval/policy_switch.rb:23`) is the delegating value
  `/yolo` flips. `Context::ModelSwitch` and `CLI::GoalDriver` are the same shape.
- `Middleware` is a property-tested monoid (`spec/lain/middleware_spec.rb:38-43`, group at
  `spec/support/shared_examples/monoid.rb:46`). Four phases; `repl` is the human-input phase.
- `Workspace::Snapshot` (`lib/lain/workspace/snapshot.rb:108`) and `Workspace::Restore`
  (`lib/lain/workspace/restore.rb:117`) both exist and work.
- `Ext::TreeSitter.query(src, lang, query)` (`ext/lain/src/lib.rs:1781`) accepts `"bash"` today —
  `ast-grep-language`'s `builtin-parser` feature pulls `tree-sitter-bash 0.25.1`
  (`Cargo.lock:1213-1219`). **No new dependency is required.**

**What does not exist — the findings that shaped this plan.**

- **There is no allowlist or denylist anywhere.** Not in `.lain/`, not in `Config`, not in Ruby.
  The gating unit is the tool, never the command string, and `lib/lain/tool/input.rb:15-40`
  argues that deliberately: *"A `format:` validator that 'only permits safe commands' is a
  comforting lie."*
- **Today's default is already "accept edits."** `edit_file`, `write_file` and `memory_write` all
  answer `requires_approval? => false`. Only `Tools::Bash` (`bash.rb:69`) and `Tools::CoreExec`
  (`core_exec.rb:72`) override it. The missing rung is *below* the default, not above it.
- **Subagents have no gate at all.** `Tools::Subagent::Spawn#child_handler`
  (`lib/lain/tools/subagent.rb:537-540`) builds a bare `Effect::Handler::Live`. Roles `:dev`,
  `:reviewer_sre`, `:reviewer_security`, `:reviewer_dba` all hold `bash`
  (`lib/lain/role/catalog.rb:22-27`). bash is gated for the parent and ungated for every child.
- **Undo cannot see bash.** `Agent#perform_tools` passes `paths: @session.writes`
  (`agent.rb:401`), and `Session#record_write` has exactly two callers — `edit_file.rb:68` and
  `write_file.rb:68`. `Tools::Bash` records nothing. The code names its own gap,
  `snapshot.rb:51`: *"write-set only … out-of-band mutations (e.g. bash) outside that set are
  not captured."* Worse than a coverage gap: `restore.rb:119` computes
  `doomed = in_force.keys - target.keys`, so a bash-created file is in neither set and restore
  leaves it standing silently.
- `Workspace::Restore` has **no command binding** — `Supervisor::Restart` (`restart.rb:177-178`)
  is its only caller in `lib/`.
- `CLI::ReplMiddleware.build` (`lib/lain/cli/repl_middleware.rb:27-32`) hardcodes a
  single-element `Stack`. `Middleware::Stack` is already mutable and Sidekiq-shaped
  (`middleware.rb:83-155`); only the factory refuses extension.
- **No mode vocabulary exists in code.** `--yolo`, `--auto-approve`, and `/yolo` are the whole
  surface. "auto mode" appears once in the corpus, in a planning doc.

**Measured, not assumed** (this box, 2026-07-30):

| Thing | Measurement |
|---|---|
| Shadow bare `GIT_DIR` + `GIT_WORK_TREE`, `git add -A` on this repo | 365 ms cold, **8–9 ms warm**, 9.7 MB store, project dir byte-identical |
| `git status --porcelain -z -uall` | 17 ms — but compares against the *user's* index, so their commit moves your baseline |
| `Ext::TreeSitter.query` with a combined bash query | 3.38 ms/call (query *compilation*, no cache — fine once per bash call) |
| `[(ERROR)(MISSING)]` vs `bash -n` over 32 constructs | agreement on all 32 |
| Strict-literal verdict over a 32-command corpus of real lain commands | abstains on 8/32; the 24 accepted reconstruct argv byte-identically to bash |
| `time { echo PWNED; }` under `sh -c` vs reconstructed argv | prints `PWNED` / exits 127, `"time: cannot run {"` |
| `git -c core.fsmonitor=id status --short` | fully literal, zero ERROR nodes, `bash -n` clean — **executes `/usr/bin/id`** |

**Collision check.** `planning/specs/chunk-tool-algebra-lenses-partition.md` is drafted,
panel-reviewed, and unexecuted; its gate (chunk B) landed at `3e8502e`. It owns `Toolset#==`
(T1), the attenuation laws and no-join reading (T7), posture equivalence (T3), the block lenses
(T4/T8/T9), and `IntervalPartition` (T5/T10). **No card here may touch `lib/lain/toolset.rb`,
`lib/lain/tool/spawn_policy.rb`, or the block-hash hotspots.** The pipeline algebra
(`planning/tool-use-algebra.md:137-181`) and `Dispatch::Plan` (B1) are free ground — neither is
built, neither is in a chunk spec — and T18 below implements the tier-safety half of the former.

---

## Design

### One exclusive slot, many layers

The emacs research is unambiguous: Evil implements Vim's *entire* modal state machine as one
globalized minor mode occupying one tier of Emacs' lookup chain, so the layered model expresses
the exclusive one and not the reverse. Vim's mutual exclusion earns its keep in exactly one
place — **the same token must have exactly one interpretation** — so one exclusive slot governs
how model output is interpreted, and everything else layers.

```
posture (exactly one)   plan | manual | accept_edits | auto
layers  (any number)    +auto_approve +goal +vi +notify …
```

Layers must commute and be idempotent — Emacs states this as a convention
(*"it should be possible to activate and deactivate minor modes in any order"*); we make it a
property test, because this repo already property-tests `Middleware` as a monoid and `Timeline`
as a meet-semilattice.

**Any layer that can change an outcome must render a lighter.** A silently-active policy is a
bug, and T2 pins it as one.

### The ladder, and why the edits rung is undo rather than a new declaration

`requires_approval?` declares *"the model controls the command string"* (`gate.rb:13-16`),
explicitly **not** read-versus-write. Joel's ruling: do not add a `mutates?` axis — `bash`
mutates too, and a per-tool mutation flag would be wrong for exactly the tool that matters. So
the `accept_edits` and `auto` rungs buy their safety from **reversibility**, which is the
coupling `ROADMAP.md:307` has had open since 2026-07-17.

| Posture | Toolset | Gate policy | Snapshot scope | Lighter |
|---|---|---|---|---|
| `plan` | read-only `only(...)` set | `DenyAll` | `WriteSet` (nothing mutates) | `PLAN` |
| `manual` | full | `Triage → Queue` | `WriteSet` | `MAN` |
| `accept_edits` | full | `Triage → Queue` | `ShadowGit` | *(none — the default)* |
| `auto` | full | `Triage → ApproveAll` | `ShadowGit` | `AUTO` |

`plan` is capability attenuation, not a gate: the model's rendered schema does not contain
`edit_file`, so there is nothing to ask about. That is "tools are capabilities, not permissions"
applied to a mode.

### Triage: three-valued, and honest about it

The rule that dissolves the `tool/input.rb:15-40` objection is Joel's: **the triage layer may
abstain.** A regex that says "safe" is making a claim it cannot support. A parser that says
"I do not fully understand this" is making no claim at all. So:

```
Shell::Parse  →  Shell::Verdict  →  allow(term) | deny(reason) | abstain(reason)
                                        │            │              │
                                   run the term   refuse       fall through to
                                   as argv        loudly       Approval::Queue
                                                                (AutoSurface races
                                                                 the human; timeout
                                                                 denies)
```

Abstention is cheap and expected — 8/32 on a real corpus. The layer's job is to be *right when
it answers*, not to answer often.

Two non-negotiables, both from measured experiments:

1. **Execute the reconstructed argv, never the original string.** If an allowed term is re-run
   through `sh -c`, every parser/shell disagreement is a live bypass — demonstrated with
   `time { echo PWNED; }`. Re-emitting turns a misparse into a broken command instead of an
   attacker-chosen one. This is also what makes the accepted subset genuinely tier 2: there is
   no string for the model to control.
2. **Every failure mode routes to abstain, never to a fallback.** Parser raise, `DumpCapped`,
   `EncodingError`, length cap, unknown node kind, uncovered bytes. Claude Code's issue #34220
   is the shipped counterexample: a `dlopen` failure made the parser return null and every check
   silently downgraded to a legacy path.

**What an allow verdict does and does not mean.** It answers *"is this command syntactically
literal and fully understood?"* — not *"is it safe?"* `git -c core.fsmonitor=id status` passes
every structural test and executes `id`; git's protected configuration covers exactly four
settings and `core.fsmonitor` is not one of them. The verdict must be described this way in
code and in the journal, and the program denylist (T17) is where that residual risk is managed.

### Undo: a shadow repo lain owns

jj cannot do this — `jj workspace add` refuses a non-empty directory, so `.jj/` always lands in
the user's tree, and colocation detaches their HEAD and ignores their index. Cline's shape is
right (`references/oss-inspiration.md:105-124`) and plain git delivers it:

```
GIT_DIR=$XDG_STATE_HOME/lain/workspace/<project-digest>   (bare, lain-owned)
GIT_WORK_TREE=<project root>
per turn:  git add -A                      # 8–9 ms warm; honours the project's .gitignore
           git diff-index --name-status --cached <prev_tree>
```

Git is only the **change detector**; the bytes still land in lain's blake3 `Store`, so the
Workspace Timeline stays lain's own DAG exactly as `first-class-concepts.md` §7 designs it.
A lain-owned baseline also fixes the flaw in asking the user's repo: if they commit between
turns, `git status` stops reporting the paths the agent touched.

---

## Cards

### T1 — Declare the four postures as a value family [wave 1] [risk: medium]

**Depends on:** none
**Files:** create `lib/lain/mode/posture.rb`; create `spec/lain/mode/posture_spec.rb`
**Reuse:** `lib/lain/capability/policy.rb:23-99` — the exact house shape for a named-strategy
family (public `NAMES` so errors can list valid options, `.for(name)` raising `ArgumentError`
naming them, `private_constant :STRATEGIES` declared *after* the subclasses).
`lib/lain/role.rb:21` for the frozen-`Data` idiom.
**Shared-file wiring:** none (T3 creates `lib/lain/mode.rb` as the unit index)

A `Posture` is **declaration only** — it names an attenuation set, a gate-policy symbol, a
snapshot-scope symbol, and a lighter. It constructs no collaborators; T8 resolves the symbols.
Keeping it inert is what makes it testable without a Toolset, a queue, or a filesystem.

```gherkin
Scenario: the four postures are the closed set
  Given the Posture family
  When I ask for its names
  Then I get exactly plan, manual, accept_edits and auto

Scenario: an unknown posture fails loudly and names the alternatives
  Given the Posture family
  When I ask for a posture named :turbo
  Then it raises ArgumentError whose message lists all four valid names

Scenario: plan declares a read-only capability set
  Given the plan posture
  When I ask which tools it permits
  Then edit_file, write_file, memory_write, bash and core_exec are absent

Scenario: only the default posture is silent
  Given each of the four postures
  When I ask each for its lighter
  Then accept_edits has none and the other three each render a distinct one

Scenario: a posture is a frozen value
  Given any posture
  Then Ractor.shareable? answers true for it
```
→ spec file: `spec/lain/mode/posture_spec.rb`

**Escalation triggers:**
- If `Role::Catalog`'s existing `only`-sets (`lib/lain/role/catalog.rb:22-46`) already express a
  read-only set that `plan` should reuse rather than restate — stop and confirm which is
  canonical, because two hand-maintained read-only lists is the defect this card would create.
- `Capability::Policy` and `Approval::Gate::Policy` (`approval/gate/policy.rb:27`) use *different*
  named-strategy shapes. If the reviewer prefers the latter, stop — the choice affects T8.

---

### T2 — Layers that commute, with a lighter each [wave 1] [risk: medium]

**Depends on:** none
**Files:** create `lib/lain/mode/layer.rb`; create `spec/lain/mode/layer_spec.rb`
**Reuse:** `spec/support/shared_examples/monoid.rb:79` — the `"a commutative monoid"` shared
group (a `LayerSet` under union is commutative, idempotent, with the empty set as unit).
`lib/lain/capability/degraded_set.rb:168` for the frozen-sorted-symbol-set idiom with
`==`/`eql?`/`hash`.
**Shared-file wiring:** none

Emacs states order-independence as a convention. We make it a property. The set of active
layers determines behavior; the sequence that produced it does not.

```gherkin
Scenario: enabling layers in either order gives the same set
  Given an empty LayerSet
  When I enable :goal then :notify, and separately :notify then :goal
  Then the two resulting sets are equal

Scenario: enabling twice changes nothing
  Given a LayerSet holding :goal
  When I enable :goal again
  Then the set is unchanged

Scenario: disabling a layer that was never enabled is not an error
  Given an empty LayerSet
  When I disable :goal
  Then the set is still empty and nothing was raised

Scenario: a layer that can change an outcome renders a lighter
  Given every declared layer
  When I ask each whether it can alter an approval or capability outcome
  Then every layer answering yes returns a non-empty lighter

Scenario: an unknown layer name fails loudly
  Given an empty LayerSet
  When I enable :nonsense
  Then it raises an error naming the declared layers
```
→ spec file: `spec/lain/mode/layer_spec.rb`

**Escalation triggers:**
- If the `"a commutative monoid"` group's `generator:`/`equal:` contract cannot express a
  `LayerSet` without weakening the group for its five existing users — stop; do not edit the
  shared group.
- If any candidate layer turns out **not** to commute with another (e.g. two layers both
  claiming the gate policy slot), stop and escalate: that is the design telling you the thing is
  a posture, not a layer.

---

### T3 — The Mode value, and the posture it can always describe [wave 2] [risk: low]

**Depends on:** T1, T2
**Files:** create `lib/lain/mode.rb` (the value **and** this subtree's require index); create
`spec/lain/mode_spec.rb`
**Reuse:** `lib/lain/context.rb` for the "a file plus its sibling directory is that subtree's
index" pattern named in CLAUDE.md § Requires.
**Shared-file wiring:** one `require_relative "lain/mode"` line in `lib/lain.rb`, placed after
`lain/telemetry` (line 22) and before `lain/approval` (line 51)

`#describe` is Emacs' `C-h m`: the posture, then every active layer **in precedence order**,
each with its lighter. The layered model's known cost is "why did that happen"; this is the
payment.

```gherkin
Scenario: a Mode is one posture and a set of layers
  Given the manual posture and layers :goal and :notify
  When I build a Mode from them
  Then it reports the manual posture and both layers

Scenario: describe names the posture and every active layer in precedence order
  Given a Mode in accept_edits with :auto_approve and :goal enabled
  When I describe it
  Then the output names accept_edits first, then each layer with its lighter, in a stable order

Scenario: describe on a bare Mode still names the posture
  Given a Mode with no layers enabled
  When I describe it
  Then the output names the posture and states that no layers are active

Scenario: a Mode is a frozen value
  Given any Mode
  Then Ractor.shareable? answers true for it
```
→ spec file: `spec/lain/mode_spec.rb`

**Escalation triggers:**
- A load-time `NameError` when `lib/lain.rb` requires `lain/mode` means the entry is too early —
  report the exact constant, do not move the line by trial.
- If `#describe` needs to name a *collaborator* (a live toolset, a queue) to be useful, stop:
  the value has acquired a dependency it must not have, and the describe belongs on T8's
  resolution instead.

---

### T4 — The mode switch, journaled like every other live switch [wave 3] [risk: medium]

**Depends on:** T3
**Files:** create `lib/lain/mode/switch.rb`; modify `lib/lain/telemetry/switches.rb`; create
`spec/lain/mode/switch_spec.rb`
**Reuse:** `lib/lain/approval/policy_switch.rb:23-45` — copy its shape exactly. It is a
**delegating value the holder already has**, never a setter on the holder.
`lib/lain/telemetry/switches.rb:17-23` (`Telemetry::PolicySwitch`) is the record template.
**Shared-file wiring:** none (`telemetry/switches.rb` is already required at
`lib/lain/telemetry.rb`)

`chunk-ui-ux-tmux-nvim.md:704-719` records the rule this must follow: a switch is a delegating
value, and if a spec pins the holder's policy as immutable, **stop — that spec is the design
speaking**.

```gherkin
Scenario: switching records where the change came from
  Given a Switch holding the manual mode and a recording journal
  When I switch to auto with surface "tty"
  Then the journal holds a mode_switch record naming manual, auto and tty

Scenario: the switch delegates rather than mutating what it holds
  Given a Switch holding a Mode
  When I switch to a different Mode
  Then the original Mode value is unchanged

Scenario: switching to the mode already held still journals
  Given a Switch holding the plan mode
  When I switch to plan with surface "editor"
  Then a record is written, so a transcript shows the redundant request
```
→ spec file: `spec/lain/mode/switch_spec.rb`

**Escalation triggers:**
- `Telemetry::Journalable#journal_type` derives the wire discriminator from the class basename
  (`telemetry.rb:21-36`), so `ModeSwitch` becomes `"mode_switch"`. If that name already appears
  in a recorded journal fixture with a different shape, stop — it is a wire break.
- If any field is mandatory, it needs a `Telemetry::Guards::` carrier
  (`telemetry/approval_pending.rb:5-19`) because validation cannot live on a frozen `Data`.

---

### T5 — Widen the command environment for the two new commands [wave 4] [risk: high]

**Depends on:** T4
**Files:** modify `lib/lain/cli/command/env.rb`, `lib/lain/cli/command/surface.rb`; modify
`spec/lain/cli/command/env_spec.rb`, `spec/lain/cli/command/surface_spec.rb`
**Reuse:** `lib/lain/cli/command/env.rb:15-44` — the closed `Data` with a nil-refusing
constructor, and `Env::YoloApprovals` (`:39`) as the precedent for a Null member rather than a
nilable one.
**Shared-file wiring:** one `Env.new(...)` argument-list diff in `lib/lain/cli/wiring.rb`
(orchestrator-owned — see Shared files)

`Command::Env` is nil-free by contract; every new member must be either always-present or a
Null Object. This card exists separately so T6 and T14 each touch only their own command file.

```gherkin
Scenario: the environment exposes the mode switch and the restore seam
  Given a fully assembled command environment
  Then it answers mode_switch and restore

Scenario: a nil member is refused by name
  Given the command environment constructor
  When I build one with a nil mode_switch
  Then it raises ArgumentError naming mode_switch

Scenario: the environment is assembled exactly once per run
  Given a command surface
  When I read its env twice
  Then both reads return the same object
```
→ spec file: `spec/lain/cli/command/env_spec.rb`

**Escalation triggers:**
- `lib/lain/cli/wiring.rb:19-21` carries a loud comment that the class is at its
  `Metrics/ClassLength` budget with *"single-digit headroom, which is not room for a feature:
  EXTRACT FIRST."* If the one-line `Env.new` diff trips the cop, **stop and escalate** — do not
  loosen the metric, and do not extract on your own initiative.
- If `Workspace::Restore`'s constructor (`restore.rb:101`, needs `projection:`, `store:`, `root:`)
  cannot be satisfied at `Env` assembly time because the store is not yet live, stop: the member
  must become a factory or a Null, and that changes T14's shape.

---

### T6 — The `/mode` command and a reset that works from anywhere [wave 5] [risk: medium]

**Depends on:** T4, T5
**Files:** create `lib/lain/cli/command/mode.rb`; create `spec/lain/cli/command/mode_spec.rb`
**Reuse:** `lib/lain/cli/command/yolo.rb:12-55` — the closest existing command, and the one
whose behavior `/mode` partly subsumes. `lib/lain/cli/command/registry.rb:46` for dispatch;
commands return `String | Renderable | :quit | nil` and never print (`cli/repl.rb:163-172`).
**Shared-file wiring:** one `require_relative` in `lib/lain/cli/command.rb`; one line in
`Command::Surface#builtins` (`cli/command/surface.rb:99`)

Vim's own docs lead with the *reset*, not the display: *"If for any reason you do not know which
mode you are in, you can always get back to Normal mode by typing `<Esc>` twice."* `/mode!` is
that — valid from every posture, always lands in `plan`.

```gherkin
Scenario: bare /mode reports the current posture and layers
  Given a session in accept_edits with :goal enabled
  When I run /mode
  Then the rendered output names accept_edits and the goal layer

Scenario: /mode plan switches the posture
  Given a session in auto
  When I run /mode plan
  Then the switch now holds the plan posture and the change is journaled

Scenario: /mode +auto_approve enables one layer without touching the posture
  Given a session in manual
  When I run /mode +auto_approve
  Then the posture is still manual and the auto_approve layer is enabled

Scenario: /mode! returns to the most restrictive posture from any posture
  Given a session in auto with three layers enabled
  When I run /mode!
  Then the posture is plan

Scenario: an unknown posture is a recoverable error, not a crash
  Given any session
  When I run /mode turbo
  Then a Lain::Error is rendered naming the valid postures and the repl continues
```
→ spec file: `spec/lain/cli/command/mode_spec.rb`

**Escalation triggers:**
- `Command::Registry::Collision` (`registry.rb:18`) raises at **wiring** time if two commands
  claim one name. If `/mode` collides with a skill named `mode` in the shipped library, stop —
  command dispatch precedes skill dispatch (`repl.rb:143`) and the skill would become
  unreachable.
- If `/mode!` cannot parse — `Skill::Invocation.parse` (`registry.rb:84`) owns the grammar and
  may reject the trailing `!` — stop and escalate rather than editing the shared grammar;
  `chunk-compaction-tiers-pins-isolation.md:316-320` deliberately deferred a modifier grammar.

---

### T7 — Surface the posture where the human cannot lose it [wave 4] [risk: low]

**Depends on:** T4
**Files:** modify `lib/lain/frontend/prompt_composer.rb`, `lib/lain/prompt/default.toml`; modify
`spec/lain/frontend/prompt_composer_spec.rb`
**Reuse:** `PromptComposer::RunState#to_h` (`prompt_composer.rb:345-399`) — the variable roster a
prompt format writes against. `RunState` returns **nil, never zero**, for a reading with nothing
to say (`:342-344`), and a `( … )` group in the format elides when every variable inside is
empty — so the default posture costs nothing.
**Shared-file wiring:** none

Neovim's `'showmode'` has no effect when `'cmdheight'` is zero, which is why `'showcmdloc'`
exists. Posture display must live in chrome the human cannot accidentally turn off, and must not
scroll away in the transcript.

```gherkin
Scenario: a non-default posture renders in the prompt
  Given a session in plan
  When the prompt is composed
  Then the rendered line contains the plan lighter

Scenario: the default posture renders nothing
  Given a session in accept_edits with no layers
  When the prompt is composed
  Then the prompt is byte-identical to one composed with no mode support at all

Scenario: active layers render their lighters
  Given a session in manual with :auto_approve enabled
  When the prompt is composed
  Then the rendered line contains both the manual lighter and the auto_approve lighter

Scenario: a renderer fault degrades to plain text rather than losing the prompt
  Given a renderer that raises
  When the prompt is composed
  Then the plain text is returned and a warning is emitted once
```
→ spec file: `spec/lain/frontend/prompt_composer_spec.rb`

**Escalation triggers:**
- If adding `"mode"` to `RunState#to_h` changes the bytes of a prompt composed under the default
  format, stop — `prompt_composer.rb:220-227` puts composed state *above* the editor line
  precisely so the styled text is never re-sanitized, and a byte change there is a regression.
- `RunState` is constructed at `cli/wiring.rb:167-169`. If reading the mode requires threading a
  new collaborator through `Wiring`, that is a wiring diff, not this card's scope — escalate.

---

### T8 — Publish the posture on the tmux HUD [wave 4] [risk: medium]

**Depends on:** T4
**Files:** modify `lib/lain/status_feed.rb`, `lib/lain/cli/up/hud.rb`; modify
`spec/lain/status_feed_spec.rb`
**Reuse:** `StatusFeed#observed` (`status_feed.rb:417-421`) for event-derived fields;
`#measures` (`:427-430`) for clock readings. Putting one in the other's half is the documented
failure (`:157-165`, `:407-414`).
**Shared-file wiring:** none

```gherkin
Scenario: the posture appears in the published state
  Given a status feed observing a mode_switch record
  When the state is published
  Then the written JSON holds the new posture

Scenario: a posture change triggers a publish
  Given a status feed that has already published
  When a mode_switch record arrives
  Then a new file write occurs

Scenario: an unchanged posture does not trigger a publish
  Given a status feed that has already published
  When an unrelated record arrives
  Then no new file write occurs

Scenario: the feed never raises into the agent's turn
  Given a status feed whose publication path is unwritable
  When a mode_switch record arrives
  Then nothing is raised
```
→ spec file: `spec/lain/status_feed_spec.rb`

**Escalation triggers:**
- `cli/up/hud.rb:47-63` documents two hard constraints on `JQ_FILTER`: **no `$` may appear**
  (tmux 3.4 escapes it) and **no `… as $x` binding** (jq 1.7 rejects it). If the posture cannot
  be rendered within those, stop.
- `StatusFeed` is constructed in `CLI::ChatLaunch#open_chronicle`, **before `Wiring` exists**
  (`status_feed.rb:22-26`), so it can carry no field it could only learn by asking a live Agent.
  If the mode is not reachable as a journal record at that point, escalate — do not reach
  forward.
- `plugin/tmux/scripts/lain-status:25` and `plugin/nvim/lua/lain/config.lua` read the same file
  and are pinned in lockstep. A key change is a three-file change.

---

### T9 — Resolve a Mode into live collaborators [wave 3] [risk: medium]

**Depends on:** T3
**Files:** create `lib/lain/mode/resolution.rb`; create `spec/lain/mode/resolution_spec.rb`
**Reuse:** `lib/lain/toolset.rb:75` (`#only`, returns a new frozen Toolset, raises `UnknownTool`
on an absent name); `lib/lain/effect/handler/gate.rb:41-52` (`ApproveAll`/`DenyAll`);
`lib/lain/approval/queue.rb:125` as the queue policy.
**Shared-file wiring:** none

The one place a posture's declared symbols become objects. Pure: it takes a base toolset and a
queue and returns a resolution; it wires nothing.

```gherkin
Scenario: plan attenuates the toolset rather than gating it
  Given the plan posture and the full base toolset
  When I resolve it
  Then the resolved toolset does not include edit_file, write_file or bash

Scenario: auto resolves to an approve-all gate policy
  Given the auto posture
  When I resolve it
  Then the gate policy approves without consulting the queue

Scenario: manual resolves to the queue
  Given the manual posture
  When I resolve it
  Then the gate policy is the approval queue

Scenario: the reversible postures select the covering snapshot scope
  Given the accept_edits and auto postures
  When I resolve each
  Then both select the shadow-git scope, and plan and manual select the write-set scope

Scenario: a posture naming a tool the base toolset lacks fails loudly at resolution
  Given a posture whose only-set names a tool absent from the base toolset
  When I resolve it
  Then it raises Toolset::UnknownTool naming that tool
```
→ spec file: `spec/lain/mode/resolution_spec.rb`

**Escalation triggers:**
- `Toolset` is frozen at construction and attenuation is **monotone** — `spec/lain/toolset_spec.rb:46-66`
  pins that a dropped capability cannot be regained. If resolution appears to need a *widening*
  (e.g. leaving `plan` restores `bash`), stop: the resolution must rebuild from the base
  toolset, never re-grant on an attenuated one.
- Do **not** add `==` to `Toolset` even if a spec would be easier with it — that is
  `chunk-tool-algebra-lenses-partition.md` T1.

---

### T10 — Bind the mode to the live gate and toolset [wave 4] [risk: high]

**Depends on:** T9
**Files:** modify `lib/lain/cli/switchboard.rb`; modify `spec/lain/cli/switchboard_spec.rb`
**Reuse:** `lib/lain/cli/switchboard.rb:34-47` — the existing single place where the gate policy
is chosen (`@approvals = yolo ? nil : Approval::Queue.new`). This card generalizes that
two-valued flag into the posture ladder while keeping `--yolo` working as an alias for `auto`.
**Shared-file wiring:** one `Switchboard.for(...)` argument diff in `lib/lain/cli/wiring.rb`
(orchestrator-owned)

```gherkin
Scenario: --yolo still means auto
  Given a switchboard built with the yolo option
  Then its posture is auto and tier-3 calls are approved without a queue

Scenario: switching posture at runtime changes what the gate does
  Given a running session in manual with a parked approval
  When the posture switches to auto
  Then subsequent tier-3 calls are approved without parking

Scenario: switching to plan removes the capability rather than gating it
  Given a running session in manual
  When the posture switches to plan
  Then a subsequent render's tool schema does not contain edit_file

Scenario: /yolo off from a session started in auto still fails loudly
  Given a session started with --yolo
  When I disable yolo
  Then it raises, because there is no prior policy to restore
```
→ spec file: `spec/lain/cli/switchboard_spec.rb`

**Escalation triggers:**
- `Effect::Handler::Gate` is **construction-fixed** by design and holds no Toolset —
  `spec/lain/effect/handler/gate_spec.rb:97-113` includes a spec that Gate *refuses* a
  `toolset:` kwarg. If binding the posture appears to need Gate to learn about toolsets, stop:
  the attenuation must happen where the toolset is built, not at the gate.
- Changing the live toolset mid-session has no seam today (`Agent` receives `toolset:` at
  construction, `wiring.rb:236`). If a posture switch cannot take effect without rebuilding the
  Agent, **stop and escalate** — a `RefusingHandler`-shaped decorator
  (`tools/subagent/refusing_handler.rb:24`) may be the answer, but that is a design call.

---

### T11 — Gate the children too [wave 5] [risk: high]

**Depends on:** T10
**Files:** modify `lib/lain/tools/subagent.rb`; create `spec/lain/tools/subagent_gate_spec.rb`
**Reuse:** `lib/lain/tools/subagent.rb:537-540` (`child_handler`, which builds
`Effect::Handler::Live` with no gate); `lib/lain/effect/handler/gate.rb:55` (`inner:` chaining is
already how gates compose).
**Shared-file wiring:** none

Today `bash` is gated for the parent and ungated for every child holding it — roles `:dev`,
`:reviewer_sre`, `:reviewer_security` and `:reviewer_dba` all do (`role/catalog.rb:22-27`).

```gherkin
Scenario: a child holding bash gates exactly as the parent does
  Given a parent in manual and a child spawned with the dev role
  When the child issues a bash call
  Then the call parks on the same approval queue the parent uses

Scenario: a child in plan posture cannot hold bash at all
  Given a parent in plan
  When a dev-role child is spawned
  Then the child's toolset does not include bash

Scenario: the merge_resolver role still runs unattended
  Given a parent in accept_edits
  When a merge_resolver child is spawned and edits a file
  Then no approval is requested, because that role holds no gated tool

Scenario: a refused call is reported to the child as a tool error, never raised
  Given a child whose bash call is denied
  Then the child receives a tool_result marked as an error
```
→ spec file: `spec/lain/tools/subagent_gate_spec.rb`

**Escalation triggers:**
- `role/catalog.rb:47-52` documents that `:merge_resolver` deliberately holds **no bash** because
  it is *"spawned unattended, must never hit the approval gate."* If adding a gate makes any
  currently-unattended spawn park forever, stop — that is a deadlock, not a stricter default.
- If a child's approval must be attributable to the child rather than the parent,
  `Approval::Queue.new(requester:)` (`queue.rb:101`) takes it — but changing the default
  `"agent"` string may break `spec/lain/approval_spec.rb`'s journal assertions. Check first.
- `chunk-tool-algebra-lenses-partition.md` T3 adds `subagent_posture_equivalence_spec.rb`. If it
  has landed by the time this card runs, re-verify no assertion there depends on the child
  handler chain having exactly one layer.

---

### T12 — Make the snapshot scope a swappable object [wave 1] [risk: high]

**Depends on:** none
**Files:** create `lib/lain/workspace/snapshot/scope.rb`; modify
`lib/lain/workspace/snapshot.rb`; modify `spec/lain/workspace/snapshot_spec.rb`
**Reuse:** `lib/lain/tool/spawn_policy.rb:230-232` — `.resolve` accepting an instance *or* a
short name, with a private `REGISTRY` and a loud `Unknown`. `Snapshot#write(timeline:, paths:)`
(`snapshot.rb:108`) keeps its signature; the scope is injected at `#initialize` alongside `root:`.
**Shared-file wiring:** ~~one `require_relative "snapshot/scope"` line in
`lib/lain/workspace.rb`~~ — **CORRECTED AT EXECUTION (2026-08-02): none.** This card creates
`workspace/snapshot/`, so by CLAUDE.md § Requires `snapshot.rb` *becomes* that subtree's index
and requires `snapshot/*` itself. The panel surveyed every `lib` file with a same-named sibling
directory: ~90 self-index, one anomaly (`epic/review.rb`). The `effect.rb` → `effect/handler` →
`handler/*` precedent is exact and at the same depth. Following the card literally would have
left `snapshot.rb` with a sibling directory it does not index — the state the policy forbids.
The line goes at the **top** of `snapshot.rb`, because the class body evaluates
`SCOPE_NOTE = Scope::WriteSet::NOTE` at load time. **Zero orchestrator-owned files touched.**

`Scope::WriteSet` must reproduce today's behavior **byte-for-byte**, including the exact
`snapshot_scope` note that rides every payload — the default arm is a refactor, not a change.

```gherkin
Scenario: the default scope is byte-identical to today
  Given a snapshot writer with no scope specified
  When it writes a snapshot for a given write-set
  Then the event digest equals the digest produced before this card

Scenario: the scope names itself in the payload
  Given a snapshot written under any scope
  When I read the payload
  Then snapshot_scope holds that scope's own note, not a hardcoded string

Scenario: an unknown scope name fails loudly
  When I resolve a scope named :everything
  Then it raises an error naming the registered scopes

Scenario: a scope instance passes through resolution unchanged
  Given a scope object
  When I resolve it
  Then the same object is returned
```
→ spec file: `spec/lain/workspace/snapshot_spec.rb`

**Escalation triggers:**
- `spec/lain/workspace/snapshot_spec.rb:176` asserts the exact `snapshot_scope` string and that
  only write-set paths are captured. `:320` and `:329` assert that a run of read-only tool turns
  snapshots **nothing**. If the default arm changes any of these, stop — the refactor has become
  a behavior change.
- `spec/lain/workspace/snapshot_spec.rb:190` pins that a write-set file mutated out of band by
  bash **is** re-captured, because `entry` hashes current bytes. Preserve that.

---

### T13 — A shadow git repo that sees what bash did [wave 2] [risk: high]

**Depends on:** T12
**Files:** create `lib/lain/workspace/snapshot/scope/shadow_git.rb`; create
`spec/lain/workspace/snapshot/scope/shadow_git_spec.rb`
**Reuse:** `lib/lain/isolation/worktree.rb:162-166` — the `git(*)` runner with an injected
`shell_out_factory` and `GIT_CONTEXT_SCRUB` (`:56-59`), passing an **argv Array**, never a
string. `lib/lain/paths.rb:158-160` for XDG state resolution and `:177` for `project_hash`.
**Shared-file wiring:** none — but **this card DOES own a require line, and its placement is
load-bearing (corrected at execution, 2026-08-02).** T12 landed `snapshot/scope.rb` as the
`scope/` subtree's index, so `require_relative "scope/shadow_git"` goes **at the TOP of
`lib/lain/workspace/snapshot/scope.rb`**, which is this card's to edit. It must NOT go at the
bottom: `Scope::REGISTRY` is built and **frozen inside the module body**, so a bottom require
cannot register a short name — `Scope.resolve(:shadow_git)` then raises `Scope::Unknown` while
only a passed *instance* resolves. (`effect/handler.rb`'s bottom-placement precedent does not
transfer: its children subclass the class body; `ShadowGit` subclasses nothing.) Add `ShadowGit`
to `REGISTRY` in the same edit.

The store is lain-owned and lives under XDG state, **never** in the user's project. Git is only
the change detector; bytes go into lain's own blake3 `Store` exactly as today.

```gherkin
Scenario: a file created by bash is detected
  Given a project where a shell command created a file no lain tool recorded
  When the scope computes the changed paths for that turn
  Then the new file's path is in the set

Scenario: a file deleted by bash is detected
  Given a project where a shell command deleted a tracked file
  When the scope computes the changed paths for that turn
  Then the deleted file's path is in the set

Scenario: the user's repository is untouched
  Given a project that is itself a git repository with staged and unstaged changes
  When the scope runs for several turns
  Then the project's git status output is unchanged and no new object exists in its .git

Scenario: gitignored files are not captured
  Given a project whose .gitignore excludes a build directory
  When a shell command writes into that directory
  Then those paths are absent from the changed set

Scenario: a turn that changed nothing yields an empty set
  Given a turn whose tools only read
  When the scope computes the changed paths
  Then the set is empty and no snapshot is written

Scenario: a project that is not a git repository still works
  Given a project directory with no .git at all
  When the scope runs
  Then changed paths are still detected against the lain-owned store

Scenario: a git failure degrades loudly rather than silently capturing nothing
  Given a git invocation that exits non-zero
  When the scope computes the changed paths
  Then a Lain::Error is raised naming git's stderr
```
→ spec file: `spec/lain/workspace/snapshot/scope/shadow_git_spec.rb`

**Escalation triggers:**
- `spec/lain/project_dir_spec.rb` parses every file in `lib/` and fails any expression that
  re-composes `.lain` paths (`project_dir.rb:26-29`). This card writes under **XDG state**, not
  `.lain/` — if `Paths` has no seam for a per-project state directory, stop and escalate rather
  than composing a path inline.
- Git's stat cache has a racy-timestamp case: a file rewritten within the same second at the
  same size. Write a spec for edit → snapshot → edit-again-same-second → snapshot. If it fails,
  escalate — the mitigation is git's content-compare, and if it is not firing the scope is
  unsound.
- `snapshot.rb:13-16` records that the `Store` is an in-memory Hash and snapshots live only as
  long as the process (W4 debt). If widened scope makes memory growth visible in the suite,
  report the measurement — do not silently cap the scope.

---

### T14 — `/undo`, binding the restore that already exists [wave 5] [risk: medium]

**Depends on:** T5, T12
**Files:** create `lib/lain/cli/command/undo.rb`; create `spec/lain/cli/command/undo_spec.rb`
**Reuse:** `lib/lain/workspace/restore.rb:117` (`#restore(turn:, force:)`) — complete and
tested, with `NoSnapshot`, `Dirty`, `EscapesRoot`, `PartialApply` already defined. Its only
caller today is `Supervisor::Restart` (`restart.rb:177-178`).
**Shared-file wiring:** one `require_relative` in `lib/lain/cli/command.rb`; one line in
`Command::Surface#builtins`

Files and conversation are independently rewindable and always have been — `restore.rb:11-14`
notes that `Restore` never sees a Timeline, so "restore files, keep conversation" is free.
`/undo` is the files axis; `/rewind` is already the conversation axis.

```gherkin
Scenario: undo restores the workspace to the previous turn
  Given a session whose last turn modified two files
  When I run /undo
  Then both files hold their prior contents and the conversation is unchanged

Scenario: undo refuses when the workspace is dirty
  Given a session where a managed file was edited outside lain since the snapshot
  When I run /undo
  Then a Lain::Error is rendered naming the dirty path and nothing is written

Scenario: forced undo proceeds past dirtiness
  Given the same dirty workspace
  When I run /undo!
  Then the restore completes

Scenario: undo with no snapshot yet is a clean message, not a crash
  Given a fresh session that has taken no snapshot
  When I run /undo
  Then a Lain::Error explaining there is nothing to restore is rendered and the repl continues

Scenario: a symlink is refused even when forced
  Given a managed path that is a symlink
  When I run /undo!
  Then the restore refuses and nothing is written
```
→ spec file: `spec/lain/cli/command/undo_spec.rb`

**Escalation triggers:**
- `Restore` keeps a stateful `@in_force` ledger and is documented as **one instance per session**
  (`restore.rb:31-37`). If `Command::Env` hands out a fresh `Restore` per invocation, the ledger
  resets and forward re-restore stops being clean — stop and escalate to T5's `Env` shape.
- `restore.rb:154-193` refuses out-of-root paths and symlinks **unconditionally**, and dirtiness
  only when not forced. Do not add a fourth refusal or waive an existing one.
- If the snapshot in force was written under `WriteSet` but the session is now in a `ShadowGit`
  posture, the restore target may be narrower than the user expects. Report this in the
  command's output rather than silently restoring a subset.

---

### T15 — Parse a shell command, and know when you have not [wave 1] [risk: high]

**Depends on:** none
**Files:** create `lib/lain/shell.rb` (unit index), `lib/lain/shell/parse.rb`; create
`spec/lain/shell/parse_spec.rb`
**Reuse:** `Lain::Ext::TreeSitter.query(src, lang, query)` (`ext/lain/src/lib.rs:1781`) — accepts
`"bash"` today, no new dependency. `lib/lain/tools/file_symbols.rb:110` is the precedent for
calling `Ext::TreeSitter` directly rather than through `Structural::Matcher` (whose
`SUPPORTED_LANGUAGES` excludes bash by design and must not be widened — it would widen the
code-search tools too).
**Shared-file wiring:** one `require_relative "lain/shell"` line in `lib/lain.rb`, after
`lain/structural`

This card is **mechanism only** — it reports what the tree contains. It makes no safety
judgement; T16 does.

Use `TreeSitter.query`, not `AstGrep.dump`: `dump` truncates at 64 KiB (`astgrep.rs:225`), and
84 KB of padding followed by `echo $(id)` produces a dump with no `command_substitution` in it.
Cap the command length before parsing regardless.

```gherkin
Scenario: a clean literal command parses to its argv
  Given the command "git status --short"
  When I parse it
  Then the reconstructed argv is git, status, --short and nothing is reported broken

Scenario: a pipeline parses to its stages in order
  Given the command "grep -r foo . | wc -l"
  When I parse it
  Then two stages are reported, in source order

Scenario: an incomplete command is reported broken
  Given the command "if true; then"
  When I parse it
  Then it is reported broken, because a MISSING node is present

Scenario: a missing node is caught even though it is not an ERROR node
  Given the command "a &&"
  When I parse it
  Then it is reported broken

Scenario: every non-whitespace byte is accounted for
  Given the command "myprog $"
  When I parse it
  Then coverage is incomplete, because the bare dollar is an anonymous token

Scenario: a numeric argument is not silently dropped
  Given the command "head -20 file"
  When I parse it
  Then the reconstructed argv contains -20

Scenario: a command longer than the cap is refused rather than truncated
  Given a command exceeding the length cap
  When I parse it
  Then it is reported broken and no query is issued

Scenario: invalid encoding is reported broken rather than raising
  Given a command containing invalid UTF-8
  When I parse it
  Then it is reported broken
```
→ spec file: `spec/lain/shell/parse_spec.rb`

**Escalation triggers:**
- `[(ERROR)(MISSING)]` must be **one query with both node types**. tree-sitter's own docs state
  that `(ERROR)` queries do not match MISSING nodes. If a reviewer proposes simplifying to
  `has_error()`, stop — `astgrep.rs:78-96` already records that `has_error()` alone let `")"`,
  `"def"`, `"1 +"` and `"[1,"` through as silent zero-matches.
- `Ext::TreeSitter.query` returns captures **FLAT, with no per-match grouping**
  (`treesitter.rs:11-13`). Reconstructing which stage a word belongs to needs byte-range
  containment in Ruby. If that proves impossible without a new ext capability, **stop** — do not
  write Rust on this card.
- tree-sitter-bash issue #315 is open: `$FOO/$BAR/` yields a corrupted `command_name` (`"$FOO/$"`)
  with **zero** ERROR or MISSING nodes. The byte-coverage check is what catches it. If a spec
  shows coverage passing on that input, escalate.
- If parsing raises anything not already anticipated, it must be caught and reported broken. A
  raise escaping this object becomes an agent-visible crash.

---

### T16 — The three-valued verdict [wave 2] [risk: high]

**Depends on:** T15
**Files:** create `lib/lain/shell/verdict.rb`; create `spec/lain/shell/verdict_spec.rb`
**Reuse:** `Approval::AutoSurface`'s doctrine, stated at `auto_surface.rb:21-25`: *"an ambiguous
answer MUST fall toward defer, never toward approve."* This card is the same doctrine one rung
lower and deterministic.
**Shared-file wiring:** none (T15 created the index)

The verdict answers **"is this command syntactically literal and fully understood?"** — not
"is it safe." That distinction must appear in the class documentation and in every journaled
record, because `git -c core.fsmonitor=id status` satisfies every structural test and executes
`id`.

Allowlist node **kinds**; do not denylist metacharacters. Three detection tiers exist and the
third is the one a designer forgets:

- structurally tagged (`command_substitution`, `expansion`, `process_substitution`,
  `heredoc_redirect`, `file_redirect`, `variable_assignment`, `subshell`, `function_definition`,
  `arithmetic_expansion`) — a node-kind check;
- literal `command_name` only (`eval`, `source`, `.`, `alias`, `xargs`, `sh`, `bash`, `env`,
  `sudo`, `find`, **`time`**, **`coproc`**, `nice`, `timeout`, `nohup`, `setsid`, `stdbuf`,
  `watch`, `awk`, `sed`, `tar`, `rsync`, `less`, `git`) — a name denylist, because these run
  programs named in their arguments;

  > ⚠️ **`time` ADDED AT EXECUTION (2026-08-02), and it is not a cosmetic addition.** Every
  > sibling of `time` was already on this list; `time` was the omission. T15's panel found, and
  > the orchestrator verified, that **tree-sitter-bash does not model `time` as a keyword**, so
  > a `time` prefix degrades its entire tail to plain `word` nodes inside an ordinary `command`:
  >
  > ```
  > "time { echo PWNED; }"   broken=false  covered=true   argv=[["time","{","echo","PWNED"],["}"]]
  > "time rm -rf /tmp/x"     broken=false  covered=true   argv=[["time","rm","-rf","/tmp/x"]]
  > ```
  >
  > Both are **structurally clean and fully covered** — the most innocuous kind set the grammar
  > can produce — so neither the node-kind tier nor the byte-coverage backstop says anything
  > about them. The first is the very command this plan's Grounding measured as the reason to
  > execute reconstructed argv, and the Gherkin below requires it to abstain; without `time` on
  > this list, **nothing in the design makes it abstain**. The second is worse: it is genuinely
  > literal, so its argv reconstructs faithfully and `/usr/bin/time` runs `rm`.
  >
  > The lesson generalises past this one name: **byte coverage is not a total check.** It
  > catches an anonymous keyword only where the grammar *lexes* it as one. Any leading command
  > word tree-sitter does not model as a keyword has the same effect, so this list is the only
  > thing standing between "structurally clean" and "runs its arguments" — which is exactly why
  > the card already says it must never be described as exhaustive.
  >
  > **Two more facts the panel measured, both of which change how this list is APPLIED:**
  >
  > 1. **Apply the denylist to EVERY stage's `argv[0]`, never to `stages.first`.** `time` is
  >    reachable in a non-leading stage and all three of these are `covered=true`:
  >    `echo hi; time { rm x; }` → `argv0s=["echo","time","}"]`; `ls | time rm x`;
  >    `true && time rm -rf /tmp/x`. A first-stage-only check is no check.
  > 2. **`coproc` is the same family** and belongs on the list beside `time`. Twelve bash
  >    reserved words reach covered-and-unbroken as a leading token (`}`, `do`, `done`, `elif`,
  >    `else`, `esac`, `fi`, `in`, `then`, `]]`, `time`, `coproc`); `coproc` is the one that
  >    actually runs its argument. It is benign in *execution* only because no `coproc` binary
  >    exists, so a reconstructed argv degrades to ENOENT — which is luck, not a defence.
- word **text** only (glob, tilde, brace) — no node kind exists.

```gherkin
Scenario: a fully literal command is allowed
  Given the command "ls -la"
  Then the verdict is allow and carries the reconstructed term

Scenario: command substitution abstains
  Given the command "echo $(id)"
  Then the verdict is abstain, naming command substitution

Scenario: a glob abstains, even though it is a plain word node
  Given the command "rm *"
  Then the verdict is abstain

Scenario: a tilde abstains
  Given the command "ls ~/secret"
  Then the verdict is abstain

Scenario: a program that runs its arguments abstains even when structurally clean
  Given the command "find . -exec rm {} +"
  Then the verdict is abstain, because find is on the name denylist

Scenario: a broken parse abstains
  Given a command the parser reported broken
  Then the verdict is abstain

Scenario: incomplete byte coverage abstains
  Given a command whose parse did not cover every non-whitespace byte
  Then the verdict is abstain

Scenario: a brace group that the parser splits abstains
  Given the command "time { echo hi; }"
  Then the verdict is abstain
  # AMENDED AT EXECUTION: this scenario passes ONLY via the `time` name denylist entry.
  # Verified against the landed parser: this command is broken=false, covered=true, so the
  # node-kind tier and the coverage backstop both say nothing. Do not implement it by
  # special-casing braces -- write it so the denylist is what makes it abstain, and add a
  # second example proving the same for a command with no braces at all.

Scenario: a literal command behind a program-runner prefix abstains
  Given the command "time rm -rf /tmp/x"
  Then the verdict is abstain, because time is on the name denylist
  # The dangerous half of the pair above: fully literal, fully covered, structurally clean,
  # and its reconstructed argv executes faithfully -- /usr/bin/time runs rm. Nothing but the
  # denylist stands between this and an allow.

Scenario: an explicit denial is distinguishable from an abstention
  Given a command naming a tool the session's capability set excludes
  Then the verdict is deny, not abstain, and carries a reason

Scenario: the verdict never claims safety
  Given any allow verdict
  When I read its reason text
  Then it states that the command is literal and understood, and does not state that it is safe
```
→ spec file: `spec/lain/shell/verdict_spec.rb`

**Escalation triggers:**
- If a proposed rule would make the verdict *allow* something the strict-literal corpus abstained
  on, stop. The measured baseline is 8 abstentions in 32; widening the allow set is a separate,
  reviewed decision, not an optimization.
- The name denylist is hand-maintained and therefore incomplete by construction — `sudoers(5)`
  has said so since the 1990s. Do **not** present it as exhaustive in code or docs; a comment
  claiming completeness is the defect.
- `git` is on the denylist for a measured reason (`core.fsmonitor`, `include.path`,
  `alias.<new-name>`). If a reviewer argues `git status` is obviously safe, escalate rather than
  removing it — the repro is `git -c core.fsmonitor=id status --short`.

---

### T17 — Run the term, never the string [wave 3] [risk: high]

**Depends on:** T16
**Files:** create `lib/lain/shell/pipeline.rb`; modify `lib/lain/tools/bash.rb`; create
`spec/lain/shell/pipeline_spec.rb`; modify `spec/lain/tools/bash_spec.rb`
**Reuse:** `planning/tool-use-algebra.md:137-181` designs exactly this — *"a list of argv arrays
plus one combinator, and stdlib `Open3.pipeline` runs it with no shell anywhere … The term form
matters: `[["grep", "pattern"], ["rspec"]]`, never a `"grep pattern"` string that gets
re-split."* `lib/lain/tools/bash.rb:44-48` (`.render_output`) so both paths format identically.
**Shared-file wiring:** none

This is the card that makes T16's verdict sound. An allowed term executes as reconstructed argv;
the shell never sees a string, so a misparse degrades to a broken command rather than an
attacker-chosen one.

The algebra doc's trap applies: **pipeline safety is not the conjunction of per-stage safety**,
because pipe opens a second channel — a program that executes its stdin (`sh`, `ruby`, `psql`)
is fine alone and unsafe downstream. Stages downstream of a pipe need a stronger predicate,
defaulting to refusing.

```gherkin
Scenario: an allowed term runs without a shell
  Given the command "printf hi"
  When it is dispatched
  Then the output is hi and no shell process was spawned

Scenario: a misparse fails safe rather than executing
  Given the command "time { echo PWNED; }"
  When it is dispatched
  Then PWNED does not appear in the output and the result reports a non-zero status

Scenario: an allowed pipeline runs stage by stage
  Given the command "printf 'a\nb\na\n' | sort | uniq -c"
  When it is dispatched
  Then the output holds the counted, sorted lines

Scenario: a stage that executes its stdin is refused downstream of a pipe
  Given the command "echo whoami | sh"
  When it is dispatched
  Then it does not execute, because sh is not permitted downstream of a pipe

Scenario: an abstained command still reaches the existing gate
  Given the command "echo $(id)"
  When it is dispatched
  Then it goes through the shell path and requests approval as it does today

Scenario: output is byte-identical across both paths
  Given a command that both paths can run
  When each runs it
  Then the rendered exit status, stdout and stderr are byte-identical

Scenario: the term path honours cwd and the worker environment
  Given a session whose worker env names a cwd
  When an allowed term runs
  Then it runs in that directory with that environment
```
→ spec file: `spec/lain/shell/pipeline_spec.rb`

**Escalation triggers:**
- `Tools::Bash#requires_approval?` must stay `true` for the string path. If a reviewer suggests
  flipping it because the term path exists, **stop** — the flag describes the tool, and the tool
  still has a string path.
- `crates/lain-core/src/exec.rs:202` sets `.stdin(Stdio::null())`, so `Tools::CoreExec` cannot
  carry a pipeline without a protocol change. Scope this card to the `Tools::Bash` /
  `Mixlib::ShellOut` / `Open3` arm only; if `CoreExec` appears to need the same treatment,
  escalate — it is a separate card and a Rust change.
- If the term path and the string path produce different output for the *same* accepted command
  (trailing newline, exit status, stderr interleaving), stop: byte-identical rendering is what
  keeps this a transparent optimization rather than a behavior change.
- Do not add a `stdin_safe?` method to `Lain::Tool`. The predicate here is over **program
  names**, not lain tools; putting it on `Tool` would collide with the algebra chunk's
  declaration work.

---

### T18 — Approval rules as predicates over parsed input [wave 1] [risk: medium]

**Depends on:** none
**Files:** create `lib/lain/approval/rule.rb`, `lib/lain/approval/rule_chain.rb`; create
`spec/lain/approval/rule_chain_spec.rb`
**Reuse:** `lib/lain/tool/input.rb:41-110` — a rule's subject is the **validated `Tool::Input`
object**, never a raw hash and never a string. `lib/lain/toolset.rb:36` for the `include
Enumerable` idiom.
**Shared-file wiring:** one `require_relative` pair in `lib/lain/approval.rb`

Emacs' keymap lookup chain, applied: a rule that has nothing to say about a call returns
nothing, and the next rule is consulted. Most policy engines force a total function; the chain
lets each rule be partial. **The deciding rule's identity travels with the decision** — "denied"
is not an experiment record; "denied by *this rule* at *this tier*" is.

```gherkin
Scenario: a rule that says nothing lets the next one decide
  Given a chain whose first rule has no opinion about read_file
  When a read_file call is evaluated
  Then the second rule's decision is returned

Scenario: the first decisive rule wins
  Given a chain whose first rule allows and whose second denies
  When a call matching both is evaluated
  Then the decision is allow

Scenario: a decision names the rule that made it
  Given a chain that denies a call
  When I read the decision
  Then it names the deciding rule

Scenario: a chain with no opinion returns no decision
  Given a chain of rules none of which match
  When a call is evaluated
  Then no decision is returned, so the caller escalates

Scenario: a rule sees the validated input object, not a raw hash
  Given a rule inspecting a call
  When it is evaluated
  Then the object it receives responds to the tool's declared fields

Scenario: a raising rule does not take down the chain
  Given a rule that raises
  When a call is evaluated
  Then the failure is recorded and the chain continues to the next rule
```
→ spec file: `spec/lain/approval/rule_chain_spec.rb`

**Escalation triggers:**
- If a rule needs to see a raw command **string** to be useful, stop and escalate. That is the
  prefix matching this design exists to avoid; the shell path is T15/T16's job and it reaches
  the chain as a parsed term or not at all.
- The last-rule-raising scenario is deliberately lenient where the rest of this chunk is
  fail-closed. If the reviewer argues a raising rule should deny rather than be skipped,
  escalate — it is a real design question and the answer changes the ACs.

---

### T19 — Risky by structure, and never rememberable [wave 2] [risk: medium]

**Depends on:** T18
**Files:** create `lib/lain/approval/rule/risk.rb`; create `spec/lain/approval/rule/risk_spec.rb`
**Reuse:** the Emacs `risky-local-variable` design — a risky value *"is **never** entered
automatically into `safe-local-variable-values`"*, and the `!` key applies everything but marks
only the **non-risky** ones for the future. The code enforces it; it is not a convention.
**Shared-file wiring:** none

Risk is **structural and name-shaped**, computed without running anything: a path resolving
outside the project root, a URL, a shell string, a credential-shaped token. Anything classed
risky is approvable per-call and **never persistable from the prompt**. To persist one you must
edit the config by hand, deliberately, outside the moment of pressure — which is exactly when a
user is impatient and pattern-matching.

```gherkin
Scenario: a path outside the project root is risky
  Given a call naming a path that resolves above the project root
  Then it is classed risky

Scenario: a URL argument is risky
  Given a call carrying a URL
  Then it is classed risky

Scenario: an ordinary in-root path is not risky
  Given a call naming a file inside the project
  Then it is not classed risky

Scenario: a risky call can be approved
  Given a risky call and a human who approves it
  Then the call proceeds

Scenario: a risky call cannot be remembered
  Given a risky call approved by a human who asked to remember the answer
  Then nothing is persisted, and the response says why

Scenario: a non-risky call approved with remember is persisted
  Given a non-risky call approved by a human who asked to remember the answer
  Then the answer is persisted
```
→ spec file: `spec/lain/approval/rule/risk_spec.rb`

**Escalation triggers:**
- Risk classification must not require running the tool, loading a plugin, or a network call —
  Emacs' rule is that a safety predicate *"should be efficient and should ideally not lead to
  loading any libraries."* If a classifier needs any of those, stop.
- If path classification needs to resolve symlinks to be correct, check
  `workspace/restore.rb:178-187` first: it refuses symlinks by `lstat` **unconditionally**, and
  the two must not disagree about what "outside the root" means.

---

### T20 — Remember yes, and remember no [wave 3] [risk: medium]

**Depends on:** T18, T19
**Files:** create `lib/lain/approval/remembered.rb`; modify `lib/lain/config.rb`; create
`spec/lain/approval/remembered_spec.rb`; modify `spec/lain/config_spec.rb`
**Reuse:** `lib/lain/config.rb:57-155` — `Config::Epics` is the five-part per-table pattern, and
its class doc at `:57-62` explicitly anticipates this: *"other top-level tables are coming …
each one earns exactly this shape — one small class that knows its own keys, its own allowed
values, and raises its own named errors."* Unknown tables are already tolerated (`:10-13`), so
adding `[approval]` needs no parser change. `lib/lain/status_feed/publication.rb:61-66` for the
mkdir_p + tmp + atomic-rename write.
**Shared-file wiring:** none

Almost every tool-approval UI offers only permanent-yes. A user repeatedly asked about something
they will never want has no way to say so, so they answer `n` forever or eventually answer `y`
out of fatigue. Give them both. And three denial strengths, per Emacs'
`ignored-local-variable-values` / `ignored-local-variables` / `inhibit-local-variables-regexps`:
deny this call, deny this tool entirely, never evaluate this class at all.

Persistence goes to `.lain/config.toml` — greppable, diffable, reviewable in a PR, revocable
where every other setting lives. For a bench that matters twice: the approval set is part of the
experimental configuration and must be recorded with everything else.

```gherkin
Scenario: a remembered yes is applied without asking again
  Given a persisted allow for a specific call shape
  When that call shape recurs
  Then it is allowed without reaching a human

Scenario: a remembered no is applied without asking again
  Given a persisted deny for a specific call shape
  When that call shape recurs
  Then it is denied without reaching a human

Scenario: a denial takes precedence over an allow for the same shape
  Given both a persisted allow and a persisted deny for one call shape
  When that call occurs
  Then it is denied

Scenario: a tool-wide denial outranks a call-specific allow
  Given a persisted allow for one call and a tool-wide denial for its tool
  When that call occurs
  Then it is denied

Scenario: the file is written atomically
  Given a persistence write interrupted after the temporary file is created
  Then the existing config file is intact

Scenario: a malformed approval table fails loudly and names the file
  Given a config file whose approval table is not a table
  When the config is loaded
  Then a named error is raised carrying the path

Scenario: an absent approval table means no remembered answers
  Given a config file with no approval table
  When the config is loaded
  Then the remembered set is empty and nothing is raised
```
→ spec file: `spec/lain/approval/remembered_spec.rb`

**Escalation triggers:**
- `Config` is frozen and constructed with `freeze` in `#initialize` (`config.rb:191`), and `EMPTY`
  is `private_constant`. Adding a member touches `attr_reader`, `initialize`, `==`, `#hash` and
  `EMPTY` — if any existing `Config` equality spec breaks, stop; equality uses `instance_of?`,
  not `is_a?`, and that is deliberate.
- `Config.load` reads `<root>/.lain/config.toml` by composing the path inline (`:166`) rather
  than through `ProjectDir`, and `project_dir.rb:19` names `config.rb` as a known straggler. Do
  **not** fix that here — it is a separate cleanup and would widen this card.

---

### T21 — The escalation ladder, named and journaled [wave 5] [risk: high]

**Depends on:** T10, T16, T18
**Files:** create `lib/lain/approval/escalation.rb`; modify `lib/lain/cli/switchboard.rb`; create
`spec/lain/approval/escalation_spec.rb`
**Reuse:** everything below it already exists — `Approval::RuleChain` (T18),
`Shell::Verdict` (T16), `Approval::Queue` (`queue.rb:125`), `Approval::AutoSurface`
(`auto_surface.rb:66`), the fail-closed timeout (`queue.rb:218-222`).
`lib/lain/effect/handler/gate.rb:51` — the ladder must still present as
`#call(effect, context) -> Boolean`, so Gate is unchanged.
**Shared-file wiring:** none (T10 already owns the `Switchboard.for` diff)

This is the "middleware wrapping the human" idea in the repo's own idiom: the ladder is a value,
each rung is named, and every verdict is attributed to the rung that made it. It is also the
composability Joel asked for — a rung that abstains must not change the outcome, so rungs
compose without ordering surprises among the abstaining ones.

```
Shell::Verdict / RuleChain  →  AutoSurface (if the layer is on)  →  human  →  timeout (deny)
       deterministic                 LLM                          the user   fail-closed
```

```gherkin
Scenario: a deterministic allow settles without reaching anything above it
  Given a call the rule chain allows
  When it is evaluated
  Then it is approved and no queue entry is created

Scenario: a deterministic deny settles without reaching anything above it
  Given a call the rule chain denies
  When it is evaluated
  Then it is refused and no queue entry is created

Scenario: an abstention parks for the surfaces above
  Given a call the rule chain abstains on
  When it is evaluated
  Then it parks on the approval queue exactly as it does today

# ADDED AT EXECUTION (2026-08-02), from T18's panel. T18 ships fault-poisoning: a rule
# that raises suppresses a later ALLOW (it may still deny), because the panel proved plain
# skip-and-continue lets one broken rule flip deny into allow with a Decision that is
# to_h-identical to a clean one. That makes the fault RECORD the only trace, so a chain
# wired with the default Faults::Null is silently lenient. It must not be reachable here.
Scenario: the ladder is wired with a real fault recorder, never the Null
  Given the escalation ladder as this card wires it
  When a rule in the deterministic rung raises
  Then the fault reaches a journal-backed recorder, and the run is not silently lenient

# Also from T18's panel: `decision&.allow?` is falsey for BOTH "denied" and "abstained",
# and this chunk's whole premise is that those are different outcomes.
Scenario: abstention is distinguished from denial by absence, not by falsiness
  Given a denied call and an abstained call
  When each decision is inspected
  Then abstention is recognised by asking whether a decision exists, never by !allow?

# THE SHARPEST FORM OF THE ABOVE, found by T18's panel and the reason this card cannot
# treat `nil` as one thing. T18 ships fault-poisoning, so a chain answers nil for TWO
# non-interchangeable reasons: "no rule had an opinion", and "an allow was suppressed
# because a rule faulted". A rung that WRAPS a chain collapses the second into the first:
#
#   inner = RuleChain.new([Raiser, Allower])      # poisons correctly -> nil
#   outer = RuleChain.new([Delegating.new(inner), Allower])
#   outer.decide(call)                            # => :allow, over a real recorded fault
#
# This card builds exactly that shape, and its own text promises "a rung that abstains
# must not change the outcome, so rungs compose without ordering surprises". Under
# poisoning that promise needs a second half: a fault must not be LAUNDERABLE either.
Scenario: a fault cannot be laundered into an abstention by a wrapping rung
  Given a rung that delegates to a rule chain in which a rule raises before an allow
  When the ladder evaluates the call
  Then the ladder does not approve it, and the fault is still attributed to its rung

Scenario: the auto-approve layer only sees what the deterministic rung abstained on
  Given the auto_approve layer enabled and a call the rule chain allows
  Then no role is spawned to adjudicate it

Scenario: every decision names the rung that made it
  Given decisions produced at each rung
  When I read the journal
  Then each record names its rung

Scenario: an abstaining rung does not change the outcome
  Given a ladder and the same ladder with an always-abstaining rung inserted anywhere
  When the same call is evaluated against both
  Then the outcome and the deciding rung are the same

Scenario: the ladder remains fail-closed
  Given a call that reaches the timeout with no answer from any surface
  Then it is denied
```
→ spec file: `spec/lain/approval/escalation_spec.rb`

**Escalation triggers:**
- `Effect::Handler::Gate`'s policy duck is two-valued and **spec-pinned**
  (`spec/lain/effect/handler/gate_spec.rb:115-126`). The ladder must resolve three values
  internally and hand Gate a Boolean. If it looks like Gate's duck needs widening, **stop** —
  `Approval::Queue` already keeps `:approve`/`:deny` symbols internally and collapses them at
  `queue.rb:128`; do the same.
- `Gate#perform` renders every denial identically (`"approval denied for tool …"`,
  `gate.rb:70`), so timeout, human `n`, auto-deny and rule-deny are indistinguishable to the
  model. If a card reviewer wants the reason surfaced to the model, escalate — that changes what
  the model sees mid-turn and is a bench-visible change.
- If a rung's failure (a spawn error, a config read error) could be read as an approval, stop.
  Deny-when-unsure is the doctrine at `auto_surface.rb:21-25` and it applies to every rung.

---

### T22 — Make the mode a comparable axis [wave 4] [risk: medium]

**Depends on:** T4
**Files:** modify `lib/lain/compare.rb` or `lib/lain/compare/` as the guard lives; modify
`spec/lain/compare_spec.rb`
**Reuse:** `lib/lain/capability/guard.rb:38` (`Guard.guard!`) — the existing refusal to compare
runs whose capability sets differ. The posture is the same kind of fact: comparing a `plan` run
against an `auto` run is apples to oranges.
**Shared-file wiring:** none

Lain is a study bench; a mode that is not comparable is a feature, not an axis. This is small
and it is what keeps the chunk honest to the repo's premise.

```gherkin
Scenario: runs under the same posture compare
  Given two recorded runs both in accept_edits
  When I compare them
  Then the comparison proceeds

Scenario: runs under different postures refuse to compare
  Given one run in manual and one in auto
  When I compare them
  Then it refuses, naming both postures

Scenario: the posture appears in a comparison report
  Given a comparison of two runs
  When I read the report
  Then the posture each run used is stated

Scenario: a run recorded before modes existed still compares
  Given a recorded run whose journal holds no mode record
  When I compare it with another such run
  Then the comparison proceeds
```
→ spec file: `spec/lain/compare_spec.rb`

**Escalation triggers:**
- The last scenario is the one that will break. If existing journal fixtures under
  `spec/fixtures/` have no mode record and the guard treats "absent" as a distinct posture,
  every existing comparison spec fails. Absent must mean absent, not a fifth posture.
- `DryReplay` must reproduce a recorded run byte-identically. If threading the posture into
  `Compare` changes a replayed request's bytes, **stop** — purity and cache-hit are the same
  constraint.

---

### T23 — Open the repl phase for extension [wave 1] [risk: low]

**Depends on:** none
**Files:** modify `lib/lain/cli/repl_middleware.rb`; modify `spec/lain/repl_middleware_spec.rb`
**Reuse:** `lib/lain/middleware.rb:83-155` — `Stack` is *already* the mutable, inspectable,
Sidekiq-shaped container with `#use`, `#insert_before`, `#insert_after`. Only the factory
(`repl_middleware.rb:27-32`, one hardcoded member) refuses extension.
**Shared-file wiring:** none

The deterministic layer around user input that Joel described already has four phases and a
property-tested monoid behind it; the `repl` phase simply has no door. This card is the door,
and it is what a future symmetric `Principal` hangs off.

```gherkin
Scenario: the default stack is unchanged
  Given the repl middleware built with no extras
  Then it holds exactly the skill dispatch middleware

Scenario: an extra middleware is appended in order
  Given the repl middleware built with two extras
  When a turn passes through
  Then both run, in the order given, outside the skill dispatch

Scenario: an extra that short-circuits without setting a response fails loudly
  Given an extra middleware that returns without calling downstream
  When a turn passes through
  Then a recoverable error is rendered naming the fault

Scenario: both keywords stay required
  When I build the repl middleware without a library
  Then it raises, because a defaulted library would read the skill tree twice
```
→ spec file: `spec/lain/repl_middleware_spec.rb`

**Escalation triggers:**
- `repl_middleware.rb:18-26` documents that both keywords are required on purpose — a defaulted
  `library` would let `/help`, this dispatch, `Tools::RunSkill` and the system prompt each read
  the skill tree. Do not add a default while adding the extension seam.
- `Middleware::Stack#call` folds `@middlewares.reverse`, so **the first member is outermost**
  (`middleware.rb:134-141`). If a spec assumes the opposite, fix the spec, not the fold.

---

## Waves and the critical path

| Wave | Cards |
|---|---|
| 1 | T1, T2, T12, T15, T18, T23 |
| 2 | T3, T13, T16, T19 |
| 3 | T4, T9, T17, T20 |
| 4 | T5, T7, T8, T10, T22 |
| 5 | T6, T11, T14, T21 |

**Critical path** (length 5, and there are two of equal length):
`T1/T2 → T3 → T4 → T5 → T6` and `T1/T2 → T3 → T9 → T10 → T11`. The mode value has to exist
before it can be switched, the switch before the command environment can carry it, and the
environment before the command can use it; symmetrically, resolution must precede binding and
binding must precede the subagent gate. The undo path (`T12 → T13`) and the shell path
(`T15 → T16 → T17`) are both shorter and run alongside.

T21 is the chunk's convergence point — it needs the ladder's bottom rung (T18), the shell verdict
(T16), and the live gate binding (T10).

## Shared files — orchestrator-owned

No card lists these under **Files**; each hands back a one-line diff.

- `lib/lain.rb` — the load-order manifest. Three new entries: `lain/mode` (after `lain/telemetry`,
  before `lain/approval`), `lain/shell` (after `lain/structural`).
- `lib/lain/cli/wiring.rb` — **at its `Metrics/ClassLength` budget** with a loud comment saying
  so (`:19-21`). Two diffs: the `Env.new(...)` argument list (T5) and `Switchboard.for(...)`
  (T10). If either trips the cop, the orchestrator escalates rather than extracting.
- `lib/lain/cli/command.rb` and `Command::Surface#builtins` — **two cards in wave 5 (T6, T14) each
  register a command here.** Neither lists these under **Files**; each hands back its
  `require_relative` line and its one-line `builtins` entry. `Command::Registry::Collision`
  (`registry.rb:18`) raises at wiring time if the orchestrator applies a duplicate name, so a
  mistake here fails loudly rather than silently shadowing.
- `lain.gemspec`, `.rubocop.yml`, `spec/spec_helper.rb`, `spec/support/**`.

The remaining unit index files (`lib/lain/approval.rb`, `lib/lain/workspace.rb`,
`lib/lain/telemetry.rb`) are edited by the card that adds the file, per CLAUDE.md § Committing —
a new lib file, its index line, and its spec land in the **same** commit. Those are safe to leave
with their cards because no two same-wave cards touch the same index.

## Integration checks

- Full `bundle exec rspec` green, with the example count **above** a re-baseline taken at the
  chunk's first commit. Do not trust the count written in `ROADMAP.md`.
- `bundle exec rubocop` clean at default metrics. No `Metrics/*` limit loosened. If a cop trips,
  an object is missing.
- `cargo test && cargo clippy --all-targets -- -D warnings` — this chunk writes no Rust, so both
  must be unchanged. If either moves, something reached into `ext/lain` that should not have.
- `pre-commit run --all-files`.
- `spec/output_discipline_spec.rb` green — several cards touch frontend-adjacent code.
- `Bench::DryReplay` produces a **zero byte diff** on a recorded fixture. The mode must not enter
  a rendered request.
- `Ractor.shareable?` holds for `Mode`, `Mode::Posture`, `Mode::LayerSet`, and the new telemetry
  record.
- **Manual pass owed to Joel** (a plan cannot assert these):
  1. `lain up`, switch through all four postures with `/mode`, confirm the prompt and the tmux
     HUD both track, and that `/mode!` returns to `plan` from each.
  2. In `accept_edits`, run a `bash` command that creates and deletes files no lain tool touched,
     then `/undo`. Confirm the tree is restored **and** that `git status` in the project is
     exactly as it was.
  3. Run a session's worth of ordinary commands and read the journal: confirm the abstention rate
     is roughly the measured 25%, and that every approval names the rung that decided it.

## Open decisions

None of these gate a card.

- **Should `ShadowGit` become the scope for every posture** once its cost is measured in a real
  session? T12's seam makes that a one-line change; the plan defaults it to the reversible
  postures only.
- **Is the program denylist (T16) maintainable by hand?** `planning/tool-use-algebra.md:374-381`
  sketches B5, a least-privilege recommender that mines the Journal — the same machinery could
  propose denylist entries from observed use. Follow-up, not this chunk.
- **Where should the `Ext::TreeSitter` seam live?** `Shell::Parse` becomes the third direct
  caller (after `Tools::FileSymbols` and the structural tools). If a fourth appears, extract.
- **The symmetric `Principal` abstraction.** Joel's stated long-term direction: human and agent
  as `Principal`s with their own middleware stacks and mailboxes, so "agent acting for the user"
  is one delegating to another. T21 and T23 are its two prerequisites; the abstraction itself
  needs `orchestration-model.md:147-161`'s open questions ruled first.

## Deliberately out of scope

- **`Grep` and `respect_ignores`.** Measured this session: `lain-core` already links ripgrep's
  own crates (`ignore`, `grep-regex`, `grep-searcher` — `crates/lain-core/Cargo.toml`), and an
  equivalently-configured `rg` is **1% faster**, not meaningfully different. The real finding is
  that `respect_ignores` is hardcoded `false` (`grep.rb:187-191`) and `CoreSearch` is not wired
  into `base_tools.rb` at all, so production runs the 4.45 s Ruby arm. Turning ignores on is
  **46× warm, 365× cold**, and cuts the searched set from 87,232 files to 1,168.
  `chunk-review-correctness-cost.md:875-880` deliberately deferred this and says *"turning it on
  is its own feature card."* It is Ruby **and** Rust and needs both panels — **its own chunk.**
- **The pipeline algebra proper** (`tool-use-algebra.md:137-181`) and `Dispatch::Plan` (B1). T17
  implements the tier-safety half — argv terms, no shell — but the monoid, the term
  `Tool::Input`, and plan-level approval are a separate feature chunk.
- **Anything owned by `chunk-tool-algebra-lenses-partition.md`**: `Toolset#==`, the attenuation
  laws, posture equivalence, the block lenses, `IntervalPartition`.
- **A `Tool#mutates?` declaration.** Ruled out by Joel: `bash` mutates too, and the flag would be
  wrong for exactly the tool that matters. Reversibility carries the edits rung instead.

## References

- `~/.claude/plans/jiggly-greeting-avalanche.md:120-125` (capabilities not permissions),
  `:455-470` (the tier axis), `:478-484` (validators check shape, not safety)
- `planning/first-class-concepts.md:161-172` — approval strictness × checkpoint granularity as a
  swept axis; the open coupling this chunk closes
- `references/oss-inspiration.md:105-124` — Cline's shadow git repo, the shape T13 adopts
- `planning/tool-use-algebra.md:137-181` (pipeline algebra), `:256-259` (plan-level approval),
  `:374-381` (B5)
- `planning/epic-orchestration.md:336-350` — `interactive` / `hands-off` / `deferred` gate
  policy, the nearest existing mode taxonomy
- `planning/specs/chunk-ui-ux-tmux-nvim.md:704-719` — the switch-is-a-delegating-value rule
- `ROADMAP.md:307` — the `--yolo` × Workspace-Timeline coupling, open since 2026-07-17
- Emacs: [Minor Modes](https://www.gnu.org/software/emacs/manual/html_node/elisp/Minor-Modes.html) ·
  [Active Keymaps](https://www.gnu.org/software/emacs/manual/html_node/elisp/Active-Keymaps.html) ·
  [Safety of File Variables](https://www.gnu.org/software/emacs/manual/html_node/emacs/Safe-File-Variables.html) ·
  [Narrowing](https://www.gnu.org/software/emacs/manual/html_node/elisp/Narrowing.html)
- Vim: [vim-modes](https://vimhelp.org/intro.txt.html#vim-modes) ·
  [operator](https://vimhelp.org/motion.txt.html#operator) ·
  [complex-repeat](https://vimhelp.org/repeat.txt.html#complex-repeat)
- jj (evaluated and declined for T13): [git-compatibility](https://docs.jj-vcs.dev/latest/git-compatibility/) ·
  [workspace/add.rs](https://github.com/jj-vcs/jj/blob/main/cli/src/commands/workspace/add.rs)
- Shell-AST prior art: [OpenAI Codex `bash.rs`](https://github.com/openai/codex/blob/main/codex-rs/shell-command/src/bash.rs) ·
  [buried bare repos + `core.fsmonitor`](https://github.com/justinsteven/advisories/blob/main/2022_git_buried_bare_repos_and_fsmonitor_various_abuses.md) ·
  [CVE-2026-45033 (Copilot CLI)](https://github.com/github/copilot-cli/security/advisories/GHSA-9ccr-r5hg-74gf) ·
  [Anthropic on sandboxing](https://code.claude.com/docs/en/sandboxing)
