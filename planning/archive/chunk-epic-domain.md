# Epic domain — issue graph, stage gates, artifact home, skills

status: done
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson

## Intent

Build the epic tier under `planning/epic-orchestration.md` §3.1–§3.4/§3.7: a content-addressed
issue graph with blocking/related/discovered-from edges and split/merge operations, a
generalized fail-closed artifact gate with interactive / hands-off / deferred policies
(deferred = spike-first adjudication, scoped to one overnight stage, parking to a sign-off
queue), the two-home artifact store (`.lain/config.toml`-selected, XDG default), a
Journal-fold resume projection with `lain epic status`, and four thin skill templates. The
`/implement-epic` driver, stacked-PR mechanics, Linear, and bench arms are later chunks.

**Execution ordering (from the 2026-07-28 interview):** run this plan only after
`chunk-vsock-exec-transport.md`, `chunk-bench-arms-subcommand.md`, and the in-flight
`chunk-chat-ux-and-ui-fixes.md` have landed. Several grounded facts below name files that
chunk claims; the staleness check must re-verify them.

## Grounding

Verified 2026-07-28 against the working tree (two Explore passes; file:line cited per card):

- `Event::KINDS` is a closed set pinned by `spec/lain/event_spec.rb:20-32` and
  `spec/lain/telemetry_spec.rb:499-504`; lifecycle facts go through Journalable records,
  never new Store kinds. Epic state therefore rides the Journal.
- `Plan::Document`/`Plan::Step` (lib/lain/plan/document.rb:24-33, step.rb:17-27) give the
  grammar idiom: module-scope regex constants, reserved-character totality ("same digest OR a
  loud rejection"), `STATUS_MARKS`/`MARK_STATUSES` one-map-both-directions, round-trip
  `parse_markdown(to_markdown).digest == digest` (spec/lain/plan_spec.rb:228).
- `Gherkin::Approval` (lib/lain/gherkin/approval.rb:94-147) is the gate pattern: asker duck
  is only `#ask(question) → Lain::Promise`; timeout → `Answer.deny("timeout")`; monotonic
  add-only registry; journals `Telemetry::GherkinApproval`. It stays untouched here.
- `Journalable#journal_type` = underscored class basename (lib/lain/telemetry.rb:23-35); the
  reader idiom is `Journal.records(entries, type:)` (journal.rb:140-143, lazy).
- `Lain::Ext::Prompt.from_toml(source)` exists (ext/lain/src/prompt.rs:1703) but is
  **prompt-config-shaped, not generic**: `RawConfig` requires `format` and is
  `#[serde(deny_unknown_fields)]` (prompt.rs:264-270) — it cannot read `[epics]`. Panel
  verification, corrected from the first grounding pass. T8 therefore uses a Ruby gem.
- Skill catalog is a directory scan of `lib/lain/prompt/templates/skill/*/skill.md`
  (skill/catalog.rb:45); front-matter keys read: `description`, `slots`, `includes`
  (catalog.rb:53-59); hole fills resolve project-override-first
  (prompt/skill_slots.rb:46-54); `spec/lain/skill/shipped_skills_spec.rb:13` pins an
  *include* list (`%i[create-plan execute-plan critique]`) and asserts non-empty slots +
  clean render for listed skills.
- Roles: adding one = a `BUILT_INS` line (role/catalog.rb:21-40) + a shipped template, pinned
  both directions by spec/lain/role_spec.rb:140-148. `auto_approver`'s contract
  (templates/role/auto-approver.md) is strict one-word APPROVE/DENY/DEFER, deny-when-unsure;
  `researcher` (role/catalog.rb:28) has `%i[read_file list_files web_fetch web_search]`.
  No new roles are needed by this plan.
- `Skill::RoleSpawn#call(role_name, context_mode, prompt)` (skill/role_spawn.rb:53-55) is the
  spawn seam; unknown role raises before any spend.
- CLI: the `friction` command is the two-line Thor pattern (exe/lain:285-286 +
  lib/lain/cli/friction.rb); `render` maps `Lain::Error` → `Thor::Error` (exe/lain:27-31).
  CLI (`lain.rb:59`) loads before `plan:66`, so CLI code references epic constants at call
  time only (the documented pattern at lib/lain/event.rb:182-184).
- `lib/lain.rb` order: the `epic` unit slots after `plan` (line 66); `config` can sit after
  `paths` (line 11) because it touches `Lain::Ext` only at call time (ext loads at line 75).
- `Paths` (lib/lain/paths.rb:157-197): `#state_home`, `#project_hash`, `#sessions_dir` is the
  ensure-dir-on-demand precedent. **Nothing reads a config file today.**
- **Files claimed by chunk-chat-ux-and-ui-fixes** — that chunk lands *before* this plan
  executes, so its claims lapse into a staleness obligation, not a standing prohibition:
  **re-verify each landed interface before citing or composing with it**, and prefer new
  epic-unit files over editing them regardless (dependency direction, not territory): `lib/lain/paths.rb`, `lib/lain/journal.rb`, `lib/lain/telemetry.rb`,
  `lib/lain/status_feed.rb`, `lib/lain/cli/wiring.rb`, `lib/lain/cli/command/help.rb`,
  `lib/lain/frontend/**`, `ext/lain/src/lib.rs`, `lib/lain/renderable.rb` (new there),
  among others. All epic record types live in the epic unit via `include Journalable` —
  zero telemetry.rb edits. Not claimed (safe): `exe/lain`, `lib/lain/cli/command.rb`,
  `lib/lain/cli/command/surface.rb`, `lib/lain/skill*`, `lib/lain/role*`,
  `lib/lain/prompt/templates/`.

Docs-vs-code disagreement found: `planning/epic-orchestration.md` §3.4 sketches
"`state.json`-equivalent" in the artifact home — grounded ruling here: runtime truth is the
Journal fold (T10); the home holds only human-facing markdown. The research doc's sketch
yields.

## Staleness check (2026-07-28, execution start)

Prerequisite chunks all `status: done` (vsock, bench-arms, chat-ux). Grounding re-verified;
four divergences, all absorbed:

1. **`Lain::Renderable` landed** (`lib/lain/renderable.rb`, required at `lib/lain.rb:58`,
   before `cli`). `render` in `exe/lain:27-31` still does `say block.call`, so a String is
   still valid. T11/T13 match the landed convention; the escalation trigger does not fire.
2. **Line drift only**: `friction` registration is `exe/lain:378-379` (plan said 285-286);
   `Journalable` is `telemetry.rb:21-33` (said 23-35); `Paths#ensure_dir` is `paths.rb:220`
   (said 180-186). `state_home:159`, `project_hash:176`, `sessions_dir:184` unmoved.
3. **`tomlrb` was not installed.** Reviewed at execution start: 2.0.4, MIT, racc-based, no
   runtime deps (`toml-rb` loses on its `citrus` dependency). Orchestrator lands the gemspec
   line + `bundle install` before wave 1 so T8 can require it.
4. **No collisions**: zero `Epic` constants in `lib/`, zero `.lain/config.toml` readers —
   chat-ux did not claim the file. `Approval::Queue` landed shape confirmed effect-scoped
   (`queue.rb:23-157`), design-reference only per T6.

**Baseline**: serial `bundle exec rspec` = **5801 examples, 0 failures, 2 pending**. The plan's
"count grows from 2513+" was stale; 5801 is the number the Integration checks compare against.

**Toolchain flake found at execution start (owed to Joel, not caused by this chunk).**
`bundle exec rake pspec` — the parallel runner the pre-commit hook uses — intermittently dies
with an MRI interpreter crash, roughly one run in three:

```
i18n-1.15.2/lib/i18n/config.rb:176: [BUG] should have cvar cache entry
update_classvariable_cache+0xe  vm_insnhelper.c:1614
```

A worker process aborts, so the run reports "Tests Failed" with a short example count (~4594)
and **zero actual failures**; rubocop is clean in the same run. Reproduced 4× in 6 runs with
this chunk's first (dependency-only) commit staged and 0× in 2 runs without it, then 2-of-3
clean *with* it — i.e. a pre-existing race in MRI 4.0.5's class-variable inline cache reached
through ActiveModel error-message generation (`Lain::Guard#check!` → i18n
`enforce_available_locales`) from a second thread, **not** a regression from this chunk. The
serial runner never hit it in any run. Mitigation used during this execution: retry the commit.
Not fixed here — a fix (warming the cvar on the main thread at spec boot, or pinning i18n's
`enforce_available_locales`) touches `spec/spec_helper.rb`, which no card owns.

**Two worktree facts every card's brief must carry** (both found the hard way in wave 1):

1. **Agent worktrees fork stale** — they are cut from the session's starting revision, not from
   current `main`. Wave 1's three worktrees all forked from `394d4d6`, several commits behind.
   Consequence: a card cannot see an orchestrator commit landed during this run (T8 could not
   see its own `tomlrb` gemspec line until it was copied in by hand). In `orchestrator-commits`
   mode this is mostly harmless — the orchestrator copies the card's *files* onto main and
   applies wiring to main's own revision — but any card that must *read* landed sibling work
   needs it copied in explicitly.
2. **The Rust extension is not built in a fresh worktree.** The first `rspec` dies on
   `LoadError: cannot load such file -- lain/lain`. Every brief must say: run
   `bundle exec rake compile` once before the red pass.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb` (two require lines:
  `config` after `paths`, `epic` after `plan`), `lib/lain/epic.rb` (T1 creates the skeleton
  as card scope; every later require addition is orchestrator wiring, so post-T1 cards never
  list it under Files), `lib/lain/approval.rb` (one require line),
  `lib/lain/cli.rb` (one require line), `exe/lain` (the `epic` subcommand registration),
  `lain.gemspec` (exactly one dependency line for T8's `tomlrb`, with the house-style
  justification comment), `.rubocop.yml` (none — never loosen), `spec/spec_helper.rb` (none).
- Deviations: T12 (skill templates) is prose-authoring — panel review reads the rendered
  templates for contradiction with the domain grammar instead of adversarial code probes.

## Open decisions

None gating. Deliberately out of scope (later chunks, per the research doc): the
`/implement-epic` driver, stacked-PR/`gh` tooling, Linear sink, bench altitude arms,
teammate-review-feedback policy, `Gherkin::Approval`→`Approval::Gate` convergence (follow-up
ticket, not this chunk).

## Waves

Wave 1: T1, T5, T8   (no unmet deps)
Wave 2: T2 (←T1), T6 (←T5)
Wave 3: T3 (←T2), T4 (←T1,T2), T7 (←T6)
Wave 4: T9 (←T4,T8), T10 (←T2,T6)
Wave 5: T11 (←T9,T10), T12 (←T3,T4,T9), T13 (←T6,T10)
Critical path: T1 → T2 → T4 → T9 → T11

## Tasks

### T1 — Define the Epic::Issue value          [wave 1] [risk: low]  ✅ LANDED `bed25fc`

**Depends on:** none
**Files:** `lib/lain/epic.rb` (new unit index, skeleton), `lib/lain/epic/issue.rb`,
`spec/lain/epic/issue_spec.rb`
**Reuse:** `Plan::Step`'s totality idiom (lib/lain/plan/step.rb:14-27: reserved-char
regexes, `TITLE_RULES` message+predicate pairs, `MalformedStep`-style error); `Canonical.digest`;
`Event#normalize_causal`'s sort+uniq+freeze for edge arrays (lib/lain/event.rb:170-172);
matchers `be_deeply_frozen`, shared examples `"a Regular value"`, `"canonical determinism"`.
**Shared-file wiring:** `lib/lain.rb` gains `require_relative "lain/epic"` after the `plan`
line (orchestrator).

`Epic::Issue = Data.define(:id, :title, :description, :status, :criteria, :blocks,
:related, :discovered_from)`. `STORED_STATUSES = %w[pending in_flight done abandoned]`
(closed; `ready` is a Graph-derived *predicate*, deliberately not a member — a closed set
containing a forbidden member is a special case, panel ruling). `criteria` is the Gherkin
**source text** (nullable) — the digest is one-way, so the value carries the source and
`#criteria_digest` derives it via `Gherkin::Criteria.parse(criteria).digest` (memoization
unnecessary; frozen value, cheap parse). This is what lets T4's fence round-trip verbatim.
Reserved characters mirror `Plan::Step` (backticks/newlines in ids; braces in titles).
`blocks`/`related` are sorted+uniq'd frozen id arrays; `discovered_from` a nullable id.
`#with_status`, `#canonical` (String keys, stable; `criteria` value-bearing), deep-frozen.

**Acceptance criteria:**

```gherkin
Scenario: construction refuses reserved characters loudly
  Given an issue id containing a backtick
  When Epic::Issue.new is called
  Then a MalformedIssue error names the field, the value, and the grammar it reserves
```
→ spec file: `spec/lain/epic/issue_spec.rb`

```gherkin
Scenario: edge order cannot change the digest
  Given two issues identical except blocks arrays in different orders
  When canonical digests are compared
  Then they are equal
```
→ spec file: `spec/lain/epic/issue_spec.rb`

```gherkin
Scenario: the value is deeply frozen
  Given a constructed issue
  Then it satisfies be_deeply_frozen and Ractor.shareable?
```
→ spec file: `spec/lain/epic/issue_spec.rb`

```gherkin
Scenario: stored status "ready" is refused
  Given status "ready"
  When Epic::Issue.new is called
  Then construction fails listing STORED_STATUSES and naming ready as derived
```
→ spec file: `spec/lain/epic/issue_spec.rb`

```gherkin
Scenario: criteria text is value-bearing and its digest derives
  Given two issues differing only in their gherkin criteria source
  Then their canonical digests differ and each #criteria_digest equals Gherkin::Criteria.parse(source).digest
```
→ spec file: `spec/lain/epic/issue_spec.rb`

> **Owed follow-up (raised by T1's panel, ruled at execution).** `Epic::Issue` and `Plan::Step`
> share an id grammar by *fact* (both delimit ids with backticks) and a title grammar by
> *coincidence* (Plan's brace rule serves its criteria-digest slot, which the epic grammar has
> no equivalent of). Ruling: pin `Epic::ID_RESERVED == Plan::ID_RESERVED` directly; pin the
> title rules **behaviorally** (a corpus through both constructors, verdicts compared) rather
> than by constant equality, which would assert a coupling that does not exist. The real fix is
> a **markdown identifier** object owning `ID_RESERVED`, the empty/whitespace rules, and the
> message lookup — it touches `lib/lain/plan/step.rb`, so it belongs to a card owning that
> file, not to T1. Carry this into the close-out ticket list.

**Escalation triggers:**
- `spec/lain/event_spec.rb` asserts no `Lain::Turn` constant; if any epic naming choice
  (`Epic::Store`, etc.) shadows or collides with an existing top-level constant, stop —
  T9 already renames its unit `Epic::Home` for exactly this reason.
- If the `lain.rb` slot after `plan` raises a load-time `NameError`, the dependency claim in
  Grounding is wrong — stop and report the actual constant chain.

### T2 — Build Epic::Graph queries          [wave 2] [risk: medium]  ✅ LANDED `525f9ee`

**Depends on:** T1
**Files:** `lib/lain/epic/graph.rb`, `spec/lain/epic/graph_spec.rb`
**Reuse:** `Plan::Document`'s value shape (Data + `include Enumerable` + frozen normalized
collections, lib/lain/plan/document.rb:42-73); `Canonical.digest`.
**Shared-file wiring:** one require line in `lib/lain/epic.rb` (orchestrator).

`Epic::Graph = Data.define(:issues)` (id-ordered). Construction validates: duplicate ids,
edges naming unknown ids, and cycles in `blocks` (loud, naming the cycle path). Queries, all
pure and deterministically ordered: `#ready` (status pending ∧ every blocker done),
`#waves` (maximal antichains of the blocks DAG, consistent with topological order),
`#blocked_by(id)` (derived inverse), `#digest`. Pure Ruby — this is per-session work; the
Rust five-rule test fails on rule 3.

**Acceptance criteria:**

```gherkin
Scenario: a cycle is refused at construction naming its canonical path
  Given issues b blocks c, c blocks a, a blocks b
  When Epic::Graph.new is called
  Then the error message contains exactly "a -> b -> c -> a" (rotation starting at the lexicographically smallest id — deterministic, house style)
```
→ spec file: `spec/lain/epic/graph_spec.rb`

```gherkin
Scenario: ready is open-and-unblocked
  Given a done blocker over one pending issue and an in_flight blocker over another
  When #ready is computed
  Then only the issue whose blockers are all done is returned
```
→ spec file: `spec/lain/epic/graph_spec.rb`

> **AC amended at execution (2026-07-28) — the original was unsatisfiable.** It read "a done
> blocker and a **pending** blocker over two pending issues". `#ready` is *pending ∧ every
> blocker done*, so a `pending` blocker with no blockers of its own is itself **vacuously
> ready** and appears in the result — "only the issue whose blockers are all done" can never
> hold. T2's implementer caught this and corrected the fixture; the panel rebuilt it literally,
> confirmed the result is `["pb", "u"]`, and ruled the card wrong rather than the code. A
> property probe over 200 random DAGs then pinned `ready == pending ∧ (blockers − done).empty?`.
> The blocker must be a non-`pending` status for the scenario to discriminate anything.

```gherkin
Scenario: waves are maximal antichains, not lazy singletons
  Given the diamond a blocks b, a blocks c, b blocks d, c blocks d
  When #waves is computed
  Then exactly three waves result and b and c share wave 2 (one-issue-per-wave topo order fails this spec)
```
→ spec file: `spec/lain/epic/graph_spec.rb`

```gherkin
Scenario: an edge naming an unknown id is refused
  Given an issue whose blocks names "ghost"
  When Epic::Graph.new is called
  Then the error names "ghost" and the referencing issue id
```
→ spec file: `spec/lain/epic/graph_spec.rb`

**Escalation triggers:**
- If antichain/topo computation tempts a petgraph binding, stop — the plan's ruling is pure
  Ruby (per-session, small n); escalate only with a measured counter-case.
- If `ready` semantics need issue state not in T1's closed `STATUSES`, stop; the status set
  is a design surface, not a card-local choice.

### T3 — Add split, merge, and discover operations to Epic::Graph          [wave 3] [risk: medium]  ✅ LANDED `f145e52`

**Depends on:** T2
**Files:** `lib/lain/epic/graph.rb` (extend), `spec/lain/epic/graph_ops_spec.rb`
**Reuse:** T2's construction validation (operations return `Graph.new`, so every op re-runs
the full validity check for free).
**Shared-file wiring:** none

> **From T2's panel (2026-07-28) — a collision this card must resolve.** `split` as written
> rewrites only inbound **`blocks`** edges, and removes the original issue. But T2 validates
> `related` against known ids, so **any third party holding `related: [original]` makes the
> resulting `Graph.new` raise `MalformedGraph`.** `merge`'s card text says "every third-party
> edge naming a or b", which already covers this; `split`'s does not. Either `split` rewrites
> `related` edges too (the presumed intent — `EDGE_FIELDS` exists in T2 for exactly this), or
> T2's `related` check is a landmine. Rewrite both edge kinds, and spec a third party holding
> a `related` edge to the split issue.

All pure, returning a new Graph: `#split(id, into: [issue_a, issue_b])` — inbound `blocks`
edges point at every part; outbound edges carried by every part; each part's
`discovered_from` = the split id; the original is removed. `#merge(a, b, as: issue)` —
**every third-party edge naming a or b is rewritten to name the merged issue** (the
contract, not an accident: forgetting the rewrite trips T2's unknown-id error, which is the
wrong failure); a∪b's own edges union minus self-references; the merged issue's
`discovered_from` = nil unless given. `#add(issue, discovered_from: nil)`. Operations refuse
ids that don't exist (reusing T2's unknown-id error) and refuse producing a cycle (T2's
check).

**Acceptance criteria:**

```gherkin
Scenario: split preserves reachability
  Given x blocks y and y blocks z
  When y is split into y1 and y2
  Then x blocks both y1 and y2, and both block z, and both carry discovered_from y
```
→ spec file: `spec/lain/epic/graph_ops_spec.rb`

```gherkin
Scenario: merge drops self-edges
  Given a blocks b
  When a and b merge into c
  Then c has no edge to itself and inherits a∪b's other edges
```
→ spec file: `spec/lain/epic/graph_ops_spec.rb`

```gherkin
Scenario: merge rewrites third-party edges
  Given x blocks a and b blocks y
  When a and b merge into c
  Then x blocks c and c blocks y, and no edge names a or b anywhere in the graph
```
→ spec file: `spec/lain/epic/graph_ops_spec.rb`

```gherkin
Scenario: operations are pure
  Given any graph
  When any operation runs
  Then the original graph's digest is unchanged and the result is a different frozen value
```
→ spec file: `spec/lain/epic/graph_ops_spec.rb`

**Escalation triggers:**
- If split's edge-inheritance rule produces a cycle in a real fixture (it can, when a part
  must depend on its sibling), stop and confirm: the intended escape is expressing the
  sibling dependency explicitly in `into:` issues, not silently dropping edges.

### T4 — Round-trip the epic markdown grammar          [wave 3] [risk: high]  ✅ LANDED `a437b92`

> **From T1's hand-back (2026-07-28) — read before implementing.** `Gherkin::Criteria.parse`
> only finds scenarios *inside* ` ```gherkin ` fences; a fence-less body silently parses to
> zero scenarios. So `Issue#criteria` must carry the fence lines themselves, or T4's verbatim
> round-trip yields an empty-criteria digest. The grammar's "fence source text becomes
> `Issue#criteria`" must therefore include the fence delimiters, not just the fence body.

**Depends on:** T1, T2
**Files:** `lib/lain/epic/document.rb`, `spec/lain/epic/document_spec.rb`
**Reuse:** `Plan::Document` grammar idiom end-to-end (module-scope regex constants —
document.rb:28-33; one status map both directions — :24-25; round-trip-to-same-digest spec
shape — spec/lain/plan_spec.rb:216-240); `Gherkin::Parse` fences for optional inline criteria
(lib/lain/gherkin.rb:79-104).
**Shared-file wiring:** one require line in `lib/lain/epic.rb` (orchestrator).

Grammar (the card implements exactly this; deviations escalate):
`### [<mark>] \`<id>\` <title>` heading per issue (marks from one STATUS_MARKS-style map);
following lines until the next `###` (the last issue's body extends to EOF — stated so a
closing note is knowingly value-bearing, not silently absorbed) are the issue body: free
prose = `description` (preserved verbatim, trailing whitespace stripped — **unlike** Plan,
prose inside an issue is value-bearing); link lines `Blocks: \`a\`, \`b\``, `Related: ...`,
`Discovered from: \`x\``, each at line start; optional one ```` ```gherkin ```` fence whose
**source text becomes `Issue#criteria` and is re-emitted verbatim** (the digest is one-way —
T1 carries the source precisely so this round-trips). Any *other* line matching the
link-line shape `\A[A-Z][A-Za-z ]*: ` inside an issue body is **rejected loudly** naming
the known link kinds — an authored `Blocked by:` is author intent, and silently demoting it
to prose betrays totality (precedent: `Gherkin::Parse::COLON_TOKEN`, lib/lain/gherkin.rb:90).
Prose *outside* any issue heading (epic preamble) is ignored by parse, exactly like Plan.
`.parse_markdown` → `Epic::Graph` + preamble-independent digest; `#to_markdown(graph)`
emits; round-trip is total: same digest or a loud rejection naming the offending value.
`Blocked by:` is never emitted (derived; T11 renders it).

**Acceptance criteria:**

```gherkin
Scenario: the author-review loop round-trips, criteria fence included
  Given a graph with edges, statuses, descriptions, and one issue carrying gherkin criteria source
  When to_markdown is parsed back
  Then the digest equals the original graph's digest and the fence text is byte-identical
```
→ spec file: `spec/lain/epic/document_spec.rb`

```gherkin
Scenario: an authored Blocked by line is refused, not absorbed
  Given an issue body containing "Blocked by: `x`"
  When parse_markdown runs
  Then the error names the line, says blocked-by is derived, and lists the writable link kinds
```
→ spec file: `spec/lain/epic/document_spec.rb`

```gherkin
Scenario: issue prose is value-bearing
  Given two issues differing only in description text
  Then their graphs' digests differ
```
→ spec file: `spec/lain/epic/document_spec.rb`

```gherkin
Scenario: a link line naming an unknown id fails loudly at parse
  Given markdown where Blocks names an id with no heading
  When parse_markdown runs
  Then the T2 unknown-id error surfaces naming both ids
```
→ spec file: `spec/lain/epic/document_spec.rb`

```gherkin
Scenario: epic preamble prose is ignored both directions
  Given the same issues with and without a preamble paragraph
  Then parse yields equal digests
```
→ spec file: `spec/lain/epic/document_spec.rb`

**Escalation triggers:**
- If preserving description prose verbatim makes round-trip digests unstable (line-ending or
  trailing-space ambiguity), stop and propose the exact normalization rule rather than
  inventing one — this is the totality doctrine's edge.
- If `Gherkin::Parse`'s fence contract (rubric marker, KEYWORDS) doesn't fit an issue-level
  criteria block, stop; do not fork the Gherkin grammar.

### T5 — Generalize the artifact gate          [wave 1] [risk: medium]  ✅ LANDED `f263b11`

**Depends on:** none
**Files:** `lib/lain/approval/gate.rb`, `spec/lain/approval/gate_spec.rb`
**Reuse:** `Gherkin::Approval` as the template, near-verbatim (lib/lain/gherkin/approval.rb:
94-162: constructor `journal:, timeout:, clock:`; `#call(artifact, asker:)`; `#approved?`;
`#ensure_approved!`; timeout → deny attributed `"timeout"`; monotonic add-only Set);
`Journalable` (telemetry.rb:23-35); asker duck `#ask → Lain::Promise`; approval_spec's test
doubles (`scripted_asker`, spec/lain/gherkin/approval_spec.rb:21-33).
**Shared-file wiring:** one require line in `lib/lain/approval.rb` (orchestrator).

`Approval::Gate` gates any artifact answering `#digest` (and `#gate_question`, the
human-facing rendering — the Criteria-specific rendering is the only part that doesn't
generalize). Signature ruled here, not guessed in a wave: `Gate#call(artifact, asker:,
stage:, epic_slug:, policy: "interactive")` — T5 ships only the asker-delegating path;
T6's policies wrap it. New Journalable record `Approval::GateDecision =
Data.define(:artifact_digest, :epic_slug, :stage, :approved, :answered_by, :policy,
:latency, :evidence_digest, :reason)` (`evidence_digest` and `reason` nullable, populated by
T7; `epic_slug` is the queue partition key T6 needs) — journal type `"gate_decision"`.

> **`reason` added at execution (2026-07-28, orchestrator ruling on a panel blocker).** The
> shape as planned answered what / where / verdict / who / how / how-long but never *why*, so
> a denial carried no rationale. Under this card's own "designed once, complete on day one"
> rule it could not be added later without a migration — and T7 is specified to park a failed
> researcher spawn "with an error note", which had nowhere to live. Nine members, not eight. **Durable wire shapes
are designed once, complete on day one** — panel ruling; T6/T7 populate, never extend.
Class comment must disambiguate the namespace's three gates (`Approval::Gate` artifact
gate · `Effect::Handler::Gate` · `Gherkin::Approval`) for grep survivors.
`Gherkin::Approval` is NOT modified; convergence is a named follow-up ticket in the close-out.

**Acceptance criteria:**

```gherkin
Scenario: an unapproved digest refuses to pass
  Given a gate with no decisions
  When ensure_approved! is called with an artifact
  Then NotApproved names the digest
```
→ spec file: `spec/lain/approval/gate_spec.rb`

```gherkin
Scenario: a timeout denies and attributes itself
  Given an asker that never resolves and a short timeout
  When the gate is called under a reactor
  Then the journaled gate_decision has approved false and answered_by "timeout"
```
→ spec file: `spec/lain/approval/gate_spec.rb`

```gherkin
Scenario: approval is monotonic
  Given approve then deny for the same digest
  Then approved? remains true and both decisions are journaled
```
→ spec file: `spec/lain/approval/gate_spec.rb`

**Escalation triggers:**
- If generalizing forces a change to `Gherkin::Approval`'s public surface after all, stop —
  that file has a full spec pinning it and this card's contract says untouched.
- `AskHuman` holds one pending question per instance (ask_human.rb:38-43); if a test scenario
  needs two concurrent gates on one asker, that's the documented invariant, not a bug —
  use two asker instances.

### T6 — Gate policies, stages, and the sign-off queue          [wave 2] [risk: high]  ✅ LANDED `29404c5`

**Depends on:** T5
**Files:** `lib/lain/approval/gate/policy.rb`, `lib/lain/epic/stage.rb`,
`lib/lain/approval/signoff_queue.rb`, `spec/lain/approval/gate/policy_spec.rb`,
`spec/lain/epic/stage_spec.rb`, `spec/lain/approval/signoff_queue_spec.rb`
**Reuse:** `Approval::Queue`'s parked-item enumeration shape (lib/lain/approval/queue.rb:
69-156) as the design reference (not a dependency — that class is effect-scoped and
chat-ux-adjacent); `Journalable`; T5's `GateDecision`.
**Shared-file wiring:** require lines in `lib/lain/approval.rb` and `lib/lain/epic.rb`
(orchestrator).

`Epic::Stage`: closed ordered set `%w[research epic_plan issue_plan implementation]`, value
object with `#next`, unknown names loud. Policies (each `#decide(artifact, gate:, stage:)`):
`Interactive` — delegates to the asker (T5 path). `HandsOff` — approves immediately,
journaled `answered_by: "hands_off"` so the run is auditable. `Deferred` — does NOT approve:
enqueues a content-addressed parked item (artifact digest, epic slug, stage, question,
evidence digest when T7 supplies one) onto `Approval::SignoffQueue`, journals the decision
as `answered_by: "deferred"`, `approved: false`; callers holding irreversible actions still
hit `ensure_approved!` and refuse. **Stage-boundary rule (the interview ruling):** a stage's
gates may only open when every earlier stage's queue partition is drained —
**partitions are keyed (epic_slug, stage)**, so two concurrent epics never block each
other's boundaries; `SignoffQueue#drained?(epic_slug, stage)`; violation raises naming the
undrained epic and stage. The queue is rebuildable from the Journal (parked = deferred
decision with no later terminal decision for the same digest+epic+stage).

**Acceptance criteria:**

```gherkin
Scenario: hands-off approves audibly
  Given the HandsOff policy
  When a gate decides
  Then approved? is true and the journal shows answered_by "hands_off" and policy "hands_off"
```
→ spec file: `spec/lain/approval/gate/policy_spec.rb`

```gherkin
Scenario: deferred parks without approving
  Given the Deferred policy
  When a gate decides
  Then approved? is false, the queue holds one item for that digest and stage, and ensure_approved! still raises
```
→ spec file: `spec/lain/approval/gate/policy_spec.rb`

```gherkin
Scenario: deferral never crosses a stage boundary within an epic
  Given an undrained research-stage queue item for epic "alpha"
  When an epic_plan-stage gate opens for "alpha"
  Then it raises naming "alpha" and the research stage
```
→ spec file: `spec/lain/epic/stage_spec.rb`

```gherkin
Scenario: epics do not block each other's boundaries
  Given an undrained research-stage item for "alpha" and none for "beta"
  When an epic_plan-stage gate opens for "beta"
  Then it proceeds
```
→ spec file: `spec/lain/epic/stage_spec.rb`

```gherkin
Scenario: the queue is a fold, not a file
  Given journal entries with a deferred decision then an approve for the same digest and stage
  When the queue is rebuilt from those entries
  Then it is drained
```
→ spec file: `spec/lain/approval/signoff_queue_spec.rb`

**Escalation triggers:**
- If any check needs state broader than one (epic_slug, stage) partition — cross-epic
  ordering, global drains — stop; that is scope creep past the interview ruling.
- `Approval::Queue` (the tier-3 effect queue) must not be extended or reused directly; if
  the implementation drifts toward it, stop — it is effect-scoped and edited by the chat-ux
  chunk (re-verify its landed shape before even citing it).

### T7 — Spike-first adjudication for deferred gates          [wave 3] [risk: high]  ✅ LANDED `9827fdd`

**Depends on:** T6
**Files:** `lib/lain/approval/gate/adjudicator.rb`, `lib/lain/role/catalog.rb` (one
`BUILT_INS` line), `lib/lain/prompt/templates/role/gate-adjudicator.md`,
`spec/lain/approval/gate/adjudicator_spec.rb`, **`lib/lain/approval/gate.rb`** (see the
scope ruling below)

> **Scope expanded at execution (2026-07-28, orchestrator ruling).** T6's implementer found
> that `Gate#call` hardcodes `evidence_digest: nil, reason: nil`, so this card's two required
> outcomes — a terminal decision carrying the evidence digest, and a park carrying an error
> note — have no path through the gate today. T7 therefore **does** get to edit
> `lib/lain/approval/gate.rb` to accept and forward both, which is a *populate* of the
> nine-member wire shape T5 shipped, **not** a widening of it. Adding a member is still
> forbidden. `lib/lain/approval/gate.rb` also owns `require_relative "gate/*"` for its own
> subtree (the Requires rule: a file with a sibling directory is that subtree's index), so
> this card adds its adjudicator require there, not in `lib/lain/approval.rb`.
**Reuse:** `Skill::RoleSpawn#call(role_name, context_mode, prompt)` (skill/role_spawn.rb:
53-55) with role `researcher` (evidence) and a **new sibling role `gate_adjudicator`** —
same `only:` set as `auto_approver`, same strict one-word APPROVE / DENY / DEFER contract
and deny-when-unsure doctrine, but a persona that describes *artifact* adjudication with
evidence (the shipped auto-approver persona says "a tool call is waiting on your verdict",
templates/role/auto-approver.md:2-4 — reusing it verbatim misdescribes the task on every
spawn; panel ruling). Role+template land together — spec/lain/role_spec.rb:140-148 pins
the pairing both directions. `auto_approver` itself is untouched. `Canonical.digest` for
evidence content-addressing.
**Shared-file wiring:** one require line in `lib/lain/approval.rb` (orchestrator).

The interview refinement: before a deferred gate parks, it tries to answer itself.
`Adjudicator#call(artifact, stage:, epic_slug:)`: (1) spawn `researcher` with the gate
question and the artifact's path/content → evidence text, journaled and content-addressed;
(2) spawn `gate_adjudicator` with question + evidence → strict one-word parse (trimmed;
multi-token or unrecognized → DEFER); (3) APPROVE/DENY → a terminal `GateDecision`
(`answered_by: "gate_adjudicator"`, T5's `evidence_digest` field populated);
DEFER → park to the SignoffQueue **with the evidence digest attached**, so the morning
review shows question + spike evidence + the model's hesitation. A researcher spawn failure
parks with an error note — fail closed, never approve on missing evidence.

**Acceptance criteria:**

```gherkin
Scenario: a clean APPROVE closes the gate with evidence
  Given a researcher stub returning evidence and an adjudicator stub returning "APPROVE"
  When the adjudicator runs
  Then the gate is approved, answered_by is "gate_adjudicator", and the decision carries the evidence digest
```
→ spec file: `spec/lain/approval/gate/adjudicator_spec.rb`

```gherkin
Scenario: prose around the verdict is hesitation
  Given an adjudicator stub returning "APPROVE — because the spec says so"
  When the verdict is parsed
  Then the outcome is DEFER and the item parks with the evidence digest
```
→ spec file: `spec/lain/approval/gate/adjudicator_spec.rb`

```gherkin
Scenario: no evidence, no approval
  Given a researcher stub that raises
  When the adjudicator runs
  Then the item parks with an error note and the gate is not approved
```
→ spec file: `spec/lain/approval/gate/adjudicator_spec.rb`

**Escalation triggers:**
- `Subagent#run` is synchronous one-shot (subagent.rb:134-138); if the adjudicator turns out
  to need reactor/actor context (deadlock, `NotRunning`), stop and report — the card assumes
  the plain `RoleSpawn` path suffices.
- If the one-word contract must change to carry a rationale, stop — the strict parse is the
  safety property (prose reads as hesitation); a rationale channel is a design change, not a
  card-local tweak.

### T8 — Read .lain/config.toml          [wave 1] [risk: low]  ✅ LANDED `ac8c9bc`

**Depends on:** none
**Files:** `lib/lain/config.rb`, `spec/lain/config_spec.rb`
**Reuse:** the `tomlrb` gem (pure-Ruby TOML 1.0 parser, no runtime deps of its own) —
external requires stay in the leaf file that uses them, per the Requires policy.
**Shared-file wiring:** `lib/lain.rb` gains `require_relative "lain/config"` after the
`paths` line; `lain.gemspec` gains one `spec.add_dependency "tomlrb"` line with a
justification comment matching the house style (both orchestrator).

Parser ruling (panel blocker resolved): `Ext::Prompt.from_toml` is **prompt-config-shaped,
not generic** — its `RawConfig` deserializer requires a `format` field and is
`#[serde(deny_unknown_fields)]` (ext/lain/src/prompt.rs:264-270), so it structurally cannot
read an `[epics]` table. A new `Ext::Toml` binding fails the five-rule binding test on
rule 3 (config reading is per-session, never hot per-turn), so the parser is a small Ruby
gem, not Rust. `Lain::Config.load(root: Dir.pwd)`: absent file → `Config.empty` (all
defaults); malformed TOML → loud `Config::Malformed` naming the path (wrapping the gem's
parse error); unknown top-level tables tolerated (other consumers are coming — chat-ux's
prompt config may converge here later); unknown keys *inside* `[epics]` are loud (typo
protection). `#epics_home` → `:xdg` (default) | `:repo`; any other value loud, naming the
two allowed.

> **Naming ruled at execution (2026-07-28, orchestrator).** The TOML key is `home` inside
> `[epics]`; the Ruby reader stays `#epics_home`. The card pinned only the reader, and the
> panel caught that `[epics] epics_home` stutters — `epics.epics_home` — while the card's own
> Gherkin types the typo as `hoem`, a typo of `home`, not of `epics_home`. Settled before any
> config file exists in the wild, because renaming afterwards is a migration.

**Acceptance criteria:**

```gherkin
Scenario: absence is all defaults
  Given a root with no .lain/config.toml
  When Config.load runs
  Then epics_home is :xdg and nothing raises
```
→ spec file: `spec/lain/config_spec.rb`

```gherkin
Scenario: a typo inside [epics] is loud
  Given config.toml with [epics] hoem = "repo"
  When Config.load runs
  Then the error names "hoem" and the known keys
```
→ spec file: `spec/lain/config_spec.rb`

```gherkin
Scenario: an unknown table is tolerated
  Given config.toml with a [prompt] table
  When Config.load runs
  Then it loads and epics_home is the default
```
→ spec file: `spec/lain/config_spec.rb`

**Escalation triggers:**
- If `tomlrb` fails dependency review (maintenance, licence, or a transitive surprise),
  stop and propose the alternative (`toml-rb`, or a generic `Ext::Toml` despite rule 3)
  rather than silently swapping — the gemspec comment must record why the winner won.
- If chat-ux's landed T13 introduced its own config-file reader or claimed
  `.lain/config.toml` for prompt settings, stop and converge rather than shipping two
  readers of one file.

### T9 — Resolve the epic artifact home          [wave 4] [risk: medium]  ✅ LANDED `c11f6ca`

**Depends on:** T4, T8
**Files:** `lib/lain/epic/home.rb`, `spec/lain/epic/home_spec.rb`
**Reuse:** injected `Paths` (`#state_home`, `#project_hash` — lib/lain/paths.rb:159,
176-178; **compose, never edit** — chat-ux claims paths.rb); `ensure_dir`-on-demand shape
(paths.rb:220 -- **correction, found at execution: `#ensure_dir` is PRIVATE**, below `private`
at paths.rb:198. It is reusable as a *shape* only; the part callers actually see is the
`Paths::Unwritable` error class. Any later card handed this Reuse line needs the same
correction.); T4's Document for epic.md read/write; T1's id grammar for filenames.
**Shared-file wiring:** one require line in `lib/lain/epic.rb` (orchestrator).

`Epic::Home.resolve(config:, paths:, root:)` → `:xdg` ⇒
`<state_home>/epics/<project_hash>/<slug>/`; `:repo` ⇒ `<root>/.lain/epics/<slug>/`.
Layout: `research.md`, `epic.md`, `issues/<id>.md`, `plans/<id>.md`. **Slugs and issue-id
filenames get a filesystem grammar, not the markdown one** (panel ruling — T1 reserves
backticks, but `../escape` and `a/b` are directory problems): `/\A[a-z0-9][a-z0-9-]*\z/`,
refused loudly otherwise; issue ids used as filenames pass the same check at write time.
Readers/writers for each artifact; `#write_epic(graph)` goes through
`Document#to_markdown` and `#read_epic` through parse — the round-trip *is* the validation.
Nothing here writes runtime state (that is T10's Journal fold; the research doc's
"state.json-equivalent" sketch yields, per Grounding).

**Acceptance criteria:**

```gherkin
Scenario: both homes resolve per config
  Given configs with epics_home xdg and repo
  When Home.resolve runs for each
  Then paths are under state_home/epics/<hash>/ and <root>/.lain/epics/ respectively
```
→ spec file: `spec/lain/epic/home_spec.rb`

```gherkin
Scenario: the epic artifact round-trips through the home
  Given a graph written with write_epic
  When read_epic runs
  Then the graph's digest is unchanged
```
→ spec file: `spec/lain/epic/home_spec.rb`

```gherkin
Scenario: path traversal cannot escape the home
  Given the slugs "../escape", "a/b", and ".hidden"
  When Home.resolve runs for each
  Then each is refused naming the filesystem grammar, and nothing outside the home is touched
```
→ spec file: `spec/lain/epic/home_spec.rb`

**Escalation triggers:**
- Re-verify `Paths`' public signatures at execution — chat-ux edits that file; if
  `state_home`/`project_hash` moved or changed arity, stop and re-ground before composing.
- If repo-mode needs a `.gitignore` write, stop — mutating the user's ignore file is a
  policy question, not a card decision; propose and wait.

### T10 — Journal records and the progress fold          [wave 4] [risk: medium]  ✅ LANDED `ec5c988`

**Depends on:** T2, T6
**Files:** `lib/lain/epic/records.rb`, `lib/lain/epic/progress.rb`,
`spec/lain/epic/records_spec.rb`, `spec/lain/epic/progress_spec.rb`
**Reuse:** `include Journalable` (telemetry.rb:23-35 — include from the epic unit; zero
telemetry.rb edits); `Journal.records(entries, type:)` lazy reader
(journal.rb:140-143; idiom at spec/lain/gherkin/approval_spec.rb:40-41);
`Event::Projection`'s pure-fold shape (event/projection.rb:23-59) — offline refold is fine
at epic scale, no StatusFeed-style incrementalism.
**Shared-file wiring:** one require line in `lib/lain/epic.rb` (orchestrator).

> **From T6's panel (2026-07-28) — write this into the code, it is a real trap.** T6's
> `SignoffQueue.from_journal` **raises** on a malformed record rather than skipping it (refusing
> is the only rule that is safe in both directions: a skipped *deferral* reads as drained just
> as a misread terminal does). The ergonomic response — `rescue => SignoffQueue.new` — makes
> **every partition read drained**, which is maximally fail-open, and `Policy::Drained` now
> exists as a legitimized object with exactly that semantics. So: **a failed queue rebuild
> aborts the session. It never degrades to an empty queue, and `Policy::Drained` is never a
> fallback for a rebuild that failed** — it is only for a caller that legitimately has no queue.
> Spec the abort path.

Records (journal types are the underscored basenames): `Epic::IssueTransition`
(`epic_slug, issue_id, from_status, to_status`) → `"issue_transition"`;
`Epic::StageTransition` (`epic_slug, stage, event` ∈ started/completed) →
`"stage_transition"`. `Epic::Progress.fold(entries, graph:)` → a frozen value: per-issue
effective status (journal transitions overlay the parsed graph — the Journal is runtime
truth), current stage, `#ready` (delegating to Graph with the overlay), pending gate items
(the T6 queue fold re-exposed), and `#summary` ("stage epic_plan — 4/9 done, 2 in flight,
1 gate parked"). **Superseded-id rule (panel: T3 and the loud-unknown rule fight without
it):** a transition naming an id absent from the current graph is *historical, not an
error*, when some current issue's `discovered_from` chain reaches that id (split/merge
leave exactly this lineage); such transitions fold as inert history — they never affect
any current issue's status or `ready`. An absent id with **no** lineage is loud — a
drifted doc is an error, not a shrug.

**Acceptance criteria:**

```gherkin
Scenario: transitions overlay the document
  Given a graph where a is pending and a journal transition a pending->done
  When Progress.fold runs
  Then a's effective status is done and ready reflects it
```
→ spec file: `spec/lain/epic/progress_spec.rb`

```gherkin
Scenario: a transition for an unknown issue is loud
  Given a journal transition naming "ghost" with no discovered_from lineage to it
  When Progress.fold runs
  Then the error names "ghost" and the epic slug
```
→ spec file: `spec/lain/epic/progress_spec.rb`

```gherkin
Scenario: a split issue's history is inert, not an error
  Given issue y was split into y1 and y2 (discovered_from y) and an old transition names y
  When Progress.fold runs
  Then it succeeds and y1's and y2's statuses are untouched by y's history
```
→ spec file: `spec/lain/epic/progress_spec.rb`

```gherkin
Scenario: records journal under their discriminators
  Given an IssueTransition written to a journal
  When Journal.records filters type "issue_transition"
  Then exactly that record round-trips with string keys
```
→ spec file: `spec/lain/epic/records_spec.rb`

**Escalation triggers:**
- Re-verify `Journalable`'s location/shape at execution — chat-ux claims telemetry.rb; if the
  module moved, follow it, and if `journal_type` derivation changed, stop (the type strings
  here become durable journal discriminators the moment they ship).
- If fold performance actually matters on a real journal (it should not at epic scale),
  measure before optimizing; do not copy StatusFeed's incremental machinery on speculation.

### T11 — Ship lain epic status          [wave 5] [risk: low]  ✅ LANDED `16e80b4`

**Depends on:** T9, T10
**Files:** `lib/lain/cli/epic.rb`, `spec/lain/cli/epic_spec.rb`
**Reuse:** the `friction` command pattern exactly (exe/lain:285-286 two-line registration +
lib/lain/cli/friction.rb returning a String, `Lain::Error` → `Thor::Error` via `render`,
exe/lain:27-31); T9 Home, T10 Progress; `Plan::Document`'s glyph idiom (STATUS_MARKS) for
the text projection.
**Shared-file wiring:** `exe/lain` two lines + `lib/lain/cli.rb` one require line
(orchestrator).

> **From T2's panel (2026-07-28).** `Graph#waves` is deliberately **status-blind** — a graph
> whose entire first wave is `done` still reports that wave as "start here". That is correct
> as a DAG layering and is what T2's card asked for, but this card renders waves to a human
> who wants the *residual* work. Compute the remaining-work view here from `Progress`' effective
> statuses rather than treating `#waves` output as the display list, and do not "fix" `#waves`.

`lain epic status [SLUG]`: resolve config → home → read `epic.md` → **discover journals
explicitly** (panel: "the journal(s)" hides the hard part): glob every `*.ndjson` under
`paths.sessions_dir` for this project, stream each through `Journal.records` filtered to
this `epic_slug`, order by the `ts` field across files — an epic spans days and sessions,
and the newest-session shortcut (the `friction` precedent) would silently drop last week's
transitions → `Progress.fold` → text projection: summary line first, then the `ready` set,
then remaining issues indented by wave with glyphs and derived `blocked-by` annotations.
No slug + exactly one epic in the home → it; ambiguity → list the slugs (loud, helpful).
Read-only; deterministic given fixed inputs. CLI references epic constants at call time
only (CLI loads before the epic unit — Grounding).

**Acceptance criteria:**

```gherkin
Scenario: the projection is deterministic and ready-first
  Given a fixture home and journal
  When lain epic status runs twice
  Then output is byte-identical and the ready section precedes the waves
```
→ spec file: `spec/lain/cli/epic_spec.rb`

```gherkin
Scenario: no epics is a named message
  Given an empty home
  When lain epic status runs
  Then the message names the resolved home path and how to start (no stack trace)
```
→ spec file: `spec/lain/cli/epic_spec.rb`

**Escalation triggers:**
- chat-ux introduces `Lain::Renderable` and converts `/help`; if by execution time CLI
  commands are expected to return Renderables rather than Strings, match the landed
  convention — stop only if `render` in exe/lain no longer accepts a String.
- If `output_discipline_spec` flags the new file, the writer is misplaced — CLI classes
  return strings; only the frontend prints.
- If per-project journal discovery cannot scope by `sessions_dir` alone (e.g. `--resume`
  moved files, or ephemeral `.btw.ndjson` sessions should be excluded), stop and confirm
  the glob contract rather than widening it silently.

### T12 — Author the epic-tier skill templates          [wave 5] [risk: medium]  ✅ LANDED `0fb840a`

**Depends on:** T3, T4, T9
**Files:** `lib/lain/prompt/templates/skill/research-epic/{skill.md,conventions.md}`,
`.../plan-epic/{skill.md,conventions.md}`, `.../iterate-epic/{skill.md,conventions.md}`,
`.../create-epic-issues/{skill.md,conventions.md}`,
`spec/lain/skill/shipped_skills_spec.rb` (extend the pinned list)
**Reuse:** catalog directory-scan contract (skill/catalog.rb:45 — a `skill.md` in a template
dir IS registration; no other wiring); front-matter shape from create-plan/skill.md:1-5
(`description:` + `slots: - conventions`); hole-override resolution
(prompt/skill_slots.rb:46-54); shipped_skills_spec's include-list + renders-clean assertions
(spec/lain/skill/shipped_skills_spec.rb:13,39,53-67); the T4 grammar and T9 layout as the
facts the prose teaches.
**Shared-file wiring:** none (`lain.gemspec` ships `lib/` automatically, gemspec:35-38)

Four thin templates — the domain carries the weight, the prose stays instructional
(the interview ruling: skills dumber, abstractions stronger; fidelity to the old Omada
commands is explicitly not required):
- **research-epic** — begins with a *proactive interview* (the interview ruling: Joel kicks
  this off; the skill's first act is asking the questions that scope intent), then
  investigation, then writes `research.md` to the epic home and requests the research gate.
- **plan-epic** — reads `research.md`, decomposes into the epic grammar (teaches the T4
  heading/link-line format by example), writes `epic.md`, requests the epic_plan gate.
- **iterate-epic** — reads `epic.md`, applies split/merge/add with `Discovered from:`
  provenance, re-emits via the grammar (round-trip keeps it honest), re-requests the gate.
- **create-epic-issues** — walks approved `epic.md`, writes self-contained `issues/<id>.md`
  files (description + Gherkin ACs + references + links) — the BMAD-story property: an
  implementer needs nothing else.
Each declares `slots: [conventions]` with a shipped conventions.md default documenting the
override path (mirroring create-plan/conventions.md:7-8). All four names join
shipped_skills_spec's list so slots-nonempty + renders-clean are enforced.

**Acceptance criteria:**

```gherkin
Scenario: the four skills are catalog-visible and render
  Given the shipped catalog
  When each of research-epic, plan-epic, iterate-epic, create-epic-issues is fetched and rendered
  Then each renders without raising and declares a conventions slot
```
→ spec file: `spec/lain/skill/shipped_skills_spec.rb`

```gherkin
Scenario: a project override replaces a conventions fill
  Given .lain/slots/skill/plan-epic/conventions.md in a temp root
  When the catalog loads from that root and plan-epic renders
  Then the override text appears in the scaffold
```
→ spec file: `spec/lain/skill/shipped_skills_spec.rb`

```gherkin
Scenario: the grammar the templates teach parses
  Given the epic-markdown example embedded in plan-epic/skill.md
  When Epic::Document.parse_markdown consumes it
  Then it yields a valid graph (the doc teaches only truth)
```
→ spec file: `spec/lain/skill/shipped_skills_spec.rb` (T12's own file — cross-card spec
ownership was a panel finding; T4's document_spec is never edited here)

**Escalation triggers:**
- If a template needs a hole beyond `conventions` (e.g. a per-project epic policy slot),
  stop — new hole names are API surface for every user's `.lain/slots/`, not a prose
  convenience.
- If teaching the grammar by example requires the example to break T4's parser, the grammar
  is wrong, not the doc — stop and reconcile with T4's owner via the orchestrator.

### T13 — Ship the sign-off drain surface          [wave 5] [risk: medium]  ✅ LANDED `3d16d55`

**Depends on:** T6, T10
**Files:** `lib/lain/cli/epic_queue.rb`, `spec/lain/cli/epic_queue_spec.rb`
**Reuse:** the `friction` two-line Thor pattern (exe/lain:285-286); T6's SignoffQueue fold;
T10's journal-discovery contract exactly as T11 specifies it (same glob, same ordering);
`Journal.open` (journal.rb:53) for appending the terminal decision as a fresh session file —
the fold reads all files, so a decision journaled from a one-shot CLI lands in the same
truth the next fold sees; T5's `GateDecision`.
**Shared-file wiring:** `exe/lain` registration lines + `lib/lain/cli.rb` require line
(orchestrator; lands with T11's as one nested `epic` Thor class, wired once).

> **Same rule as T10 (T6's panel, 2026-07-28):** this card also rebuilds the queue by folding
> journals, so it inherits the same prohibition — **a failed rebuild aborts; it never degrades
> to an empty queue, and `Policy::Drained` is not a fallback.** A drain surface that silently
> shows "nothing parked" because the fold blew up is the worst possible failure here: it is the
> screen a human reads *specifically* to decide that nothing is outstanding.

Panel finding: T6 builds the queue and T7 parks items with evidence, but no card let the
human *drain* it — the morning review had no surface. `lain epic queue [SLUG]` lists parked
items (stage, question, artifact digest, evidence digest, age), ready-to-review first.
`lain epic approve DIGEST` / `lain epic deny DIGEST` append a terminal `GateDecision`
(`answered_by: "human"`, `policy: "signoff"`) — the queue is a fold, so draining is
journaling, nothing mutates. An unknown digest is loud, listing the parked ones. This is
the interview's morning flow: question + spike evidence + the model's hesitation, decided
over coffee.

**Acceptance criteria:**

```gherkin
Scenario: approving a parked item drains it
  Given a parked deferred item for digest D
  When lain epic approve D runs and the queue refolds over all journals
  Then the partition is drained and the terminal decision shows answered_by "human" and policy "signoff"
```
→ spec file: `spec/lain/cli/epic_queue_spec.rb`

```gherkin
Scenario: an unknown digest is loud and helpful
  Given no parked item for digest X
  When lain epic approve X runs
  Then the error names X and lists the digests that are parked
```
→ spec file: `spec/lain/cli/epic_queue_spec.rb`

```gherkin
Scenario: the listing leads with what needs the human
  Given two parked items and one already-terminal digest
  When lain epic queue runs
  Then exactly the two parked items render, each with stage, question, and evidence digest
```
→ spec file: `spec/lain/cli/epic_queue_spec.rb`

**Escalation triggers:**
- If appending from a one-shot CLI collides with a live session's journal conventions
  (locking, WAL, resume selectors treating the drain file as a resumable session), stop —
  the decision record's home is a design question, not a workaround.
- If approve/deny need the artifact content (not just its digest) to render a confirmation,
  stop before reaching into the epic home for it — confirmation UX is T11's projection
  territory; keep this card append-only.

## Close-out (2026-07-28)

**All 13 cards landed**, in dependency order, each TDD red-first with a full persona-panel
review and (where findings were substantive) one re-review.

| Commit | Card |
|---|---|
| `cefc406` | dependency leaf (`tomlrb`) |
| `bed25fc` | T1 `Epic::Issue` |
| `f263b11` | T5 `Approval::Gate` |
| `ac8c9bc` | T8 `Lain::Config` |
| `525f9ee` | T2 `Epic::Graph` |
| `29404c5` | T6 gate policies, stages, sign-off queue |
| `f145e52` | T3 split / merge / discover |
| `a437b92` | T4 markdown round-trip |
| `9827fdd` | T7 spike-first adjudication |
| `ec5c988` | T10 journal records + progress fold |
| `c11f6ca` | T9 epic artifact home |
| `16e80b4` | T11 `lain epic status` |
| `0fb840a` | T12 four skill templates |
| `3d16d55` | T13 sign-off drain surface |

**Integration checks — all pass.** Full serial suite **6441 examples, 0 failures, 2 pending**
(baseline 5801); `bundle exec rubocop` clean at default metrics across 885 files, `.rubocop.yml`
never touched and no `Metrics/*` limit loosened in any card; `spec/output_discipline_spec.rb`
green with the three new CLI files; `pre-commit run --all-files` green including the Rust legs.

**Scripted end-to-end fixture pass (run, not assumed).** Wrote a 5-issue epic through
`Epic::Home` (digest round-tripped), journaled one stage transition, three issue transitions and
a deferred-then-approved gate pair, then ran the CLI: `lain epic status` showed the journal
overlaying the document — stage advanced to `epic_plan`, `docs` moved to `[~]` and left the
ready set, `ship` named both its blockers with both listed — and `lain epic queue` reported
`folded 1 journal … 6 lines, 2 gate records` with the partition drained.

**What the panels caught that green suites had passed.** Every wave-1 card handed back green and
every one still had a defect where a value passed its own constructor and failed its own
contract later: T1's fence-less criteria digesting as zero scenarios (one content address shared
by every malformed issue); T5's gate registering approval *before* journaling it, failing **open**
in the one class whose job is failing closed; T8's wrong-typed config value escaping as
`NoMethodError` past the CLI's error mapping. Later waves repeated the shape — T6's sign-off fold
branching on an unguarded field so a truncated line **drained a parked sign-off**, and its
boundary rule shipping with no caller at all; T7's empty spike counting as evidence and approving,
then again through the narrower door of `String#strip` being ASCII-only (U+00A0); T4's grammar
silently changing 230 of 572 generated digests; T10's derived `epic_slug` folding a *different*
epic's journal onto the graph.

**Corrections the plan itself needed.** T2's `#ready` AC was unsatisfiable as written (a
`pending` blocker is vacuously ready) — amended. T3's `split` card omitted the `related` rewrite
that T2's validation makes mandatory. `GateDecision` gained a ninth member (`reason`) and
`GateEvidence` two (`question`, `latency`) under the plan's own designed-once rule. The
`[epics]` TOML key became `home`, not `epics_home`. `Paths#ensure_dir` was documented as reusable
but is private.

**Two defects found in *landed* code by later cards** — the argument for reconciling duplication
rather than ticketing it: T13's extraction of shared journal discovery found `Dir.glob` treating
its own directory argument as a pattern, so a state path containing `[` matched nothing and
`lain epic status` reported a live epic as untouched; and wiring the `epic` subcommand exposed
that the bench flag-coverage spec enumerated command classes by hand, now derived from Thor's
subcommand registry.

## Manual passes still owed to Joel

1. Walk a toy epic through `/plan-epic` → `/iterate-epic` in a live chat session.
2. Flip `[epics] home = "repo"` in `.lain/config.toml` and confirm both homes — **read the
   policy decision above first**, because `/.lain/` is git-ignored and repo mode is currently
   invisible to git, which is the only thing repo mode is for.
3. Drain one deferred-gate morning queue end-to-end: `lain epic queue`, read the evidence,
   `lain epic approve`, confirm `lain epic status` shows the stage unblocked. Note ticket 9 —
   until `Policy::Adjudicated` lands there is no spike evidence to read, because nothing
   constructs an `Adjudicator`.

## Follow-up tickets raised during execution (2026-07-28)

These came out of panel review and are **deliberately not** in this chunk's scope. Carry them
into the close-out.

1. **A shared markdown-identifier object.** `Epic::Issue` and `Plan::Step` duplicate
   `ID_RESERVED`, the empty/whitespace rules, and the grammar-message lookup as independent
   literals. T1 pins the id constants equal and pins the *title* rules behaviorally (they only
   coincide). The real fix owns them once — it touches `lib/lain/plan/step.rb`, so it belongs
   to a card owning that file. (T1 panel.)
2. **`Gherkin::Approval` → `Approval::Gate` convergence.** Named in the plan's Open Decisions;
   still owed. T5 deliberately left `Gherkin::Approval` untouched. (Plan text + T5 panel.)
3. **Emittable-shape predicates belong on `Epic::Issue`, not `Epic::Document::Writer`.**
   T1 accepts prose-wrapped criteria fences byte-verbatim; T4's `Writer` refuses them. The
   refusal is loud and well-named, but `split`/`merge` can mint a `Graph` that is valid,
   content-addressed, and **can never be rendered for review**, with the failure appearing in
   the rendering path rather than at construction. Move the predicates so construct and emit
   agree. (T4 panel.)
   **Widened by T9:** `Epic::Home` adds a second caller with a *third* grammar. An issue id can
   pass T1's markdown grammar and fail T9's filesystem grammar (`Upper`, `a b`), so a graph can
   be valid and content-addressed yet contain an issue whose story file can never be written.
   Whatever object ends up owning "is this issue emittable" must answer for the filesystem name
   too, not only the markdown one.
4. **`Policy::Adjudicated` — collapse the two `ensure_open!` call sites.** T6 checks the stage
   boundary on `Policy`'s base class; T7's `Adjudicator` is not a `Policy` and never reaches
   `Policy#decide`, so it calls `ensure_open!` itself. Both are correct today and neither is
   redundant, but they are two literal call sites that can drift. (T7 panel.)
5. **`Adjudicator::AlreadyDecided` guards the wrong object.** It keys on `@terminal`, which is
   per-`Adjudicator` instance, so a *second* Adjudicator over the same `Gate` re-adjudicates
   freely: after an APPROVE, a fresh instance journals a DENY while `Gate#approved?` stays true.
   The registry that already knows the digest is `Gate`'s — but that registry is add-only
   *approvals* and cannot answer "has this been decided" for a DENY without new state, which is
   a design change to a landed, mutation-tested class rather than a card-local tweak. Pairs
   naturally with ticket 4. (T7 panel.)
6. **Provenance lineage reaches exactly ONE hop, so structural edits orphan history.**
   `Epic::Progress`' superseded-id rule accepts a journal transition naming a vanished issue
   only when a **live** issue's `discovered_from` names it directly. T10's panel proved the
   recursion is inert: `superseded` is provably `{i.discovered_from : i live}` (replacing the
   walk with one hop leaves 445 examples green). The true boundary is **any structural edit
   that removes the last live issue whose one-hop link names the id** — not "two edits", which
   was T10's first reading. Concretely: `merge` orphans at **one** edit, because it passes no
   `discovered_from` override and the field is single-valued, so an arrival declaring none
   orphans both parents and declaring one always orphans the other. Split-then-split is lossy
   only when no sibling survives; split-then-merge and merge-then-split both refuse. Failure
   direction is correct (refuses, never silently accepts), but on a twice-iterated epic this is
   a false positive on real history. The fix is provenance inheritance in `graph.rb` — plausibly
   a multi-valued `discovered_from`, which is a value-shape change to a landed, mutation-tested
   class. Wants its own card. (T10 + panel.)
7. **`Epic::Document.parse_markdown` hands back plausible partial graphs on corrupt input.**
   Found by T9's panel probing `read_epic`: of five on-disk corruptions, **four parse silently**
   — truncated mid-file yields 1 of 2 issues, a mangled heading yields 1 issue, an empty file
   yields 0 issues; only a flipped id edge raised. The round-trip law T4 established governs
   *emitted* markdown; it says nothing about arbitrary corrupted input, so "parse is the
   validation" is not the guarantee callers assume. Either the parser detects truncation
   (a trailing marker, or a count the document carries) or every caller must stop claiming it.
   T9's comment has been corrected in the meantime. (T9 panel.)
8. **`Guard#check!` raises `ArgumentError`, not `Lain::Error`, so a corrupt record escapes the
   CLI's error renderer as a backtrace.** Raised by T11, scoped by its panel: the blast radius
   is **not** "any corrupt line in any journal" — `attributable?` filters records naming another
   epic before the fold sees them, so it is one corrupt line naming *this* epic or naming none.
   The fix belongs in `Guard#check!` / `Refold`, **not** in the CLI: T11's own spec asserts
   `ArgumentError` escapes for an unattributable record, so a rescue there would contradict a
   landed spec, and a blanket `rescue ArgumentError` around a fold would swallow the `Progress`
   constructor's genuine misuse errors. (T11 + panel.)
9. **`Policy::Adjudicated` is unlanded, so the deferred-gate spike flow has no caller.** Beyond
   ticket 4's "two `ensure_open!` call sites": `Gate::Adjudicator` is constructed **nowhere** in
   `lib/` — only in its own spec. `Policy::Deferred#decide` parks the question and never spikes
   or adjudicates. So spike-first adjudication ships as tested, working machinery with nothing
   wiring it to the policy that would use it. Found by T12's panel, which caught three skill
   templates describing the *union* of the two paths as current behaviour. Until this lands,
   `deferred` means "park without approving", not "try to answer itself first" — which is a
   material difference for the overnight-run intent in the research doc. (T12 panel.)
10. **The `i18n` cvar-cache MRI crash in `rake pspec`.** Pre-existing, unrelated to this chunk,
   cost a retry on most commits in this run. Fix would touch `spec/spec_helper.rb`, which no
   card owns. See the Staleness section for the reproduction. (Orchestrator.)

> **POLICY DECISION OWED TO JOEL — repo mode is currently a no-op for its own purpose.**
> This repo's `.gitignore` line 21 is `/.lain/`, and T9 resolves repo mode to
> `<root>/.lain/epics/<slug>/`. So epics written in repo mode are **silently untracked** —
> which defeats the only reason repo mode exists (artifacts visible in PR review). T9 correctly
> did not touch `.gitignore`: the card's escalation trigger rules that mutating a user's ignore
> file is a policy question, not a card decision. Joel's owed manual pass is specifically "flip
> `[epics] home = "repo"` and confirm both homes", so he will walk straight into this.
> Options, none taken: (a) negate the ignore for `/.lain/epics/`, (b) resolve repo mode
> somewhere already tracked, (c) keep it and accept repo mode means "local, out of XDG" rather
> than "committed". This needs Joel, not the orchestrator.

## Integration checks

- `bundle exec rspec` — full default suite green (count grows from 2513+; measure, don't
  assume); `bundle exec rubocop` clean at default metrics; `pre-commit run --all-files`.
- `spec/output_discipline_spec.rb` stays green with the new CLI file.
- End-to-end fixture pass (orchestrator, scripted): write a 5-issue epic through
  `Epic::Home`, journal three transitions and one deferred+approved gate, run
  `lain epic status`, confirm the summary/ready/waves output matches the fold.
- Manual passes owed to Joel: walk a toy epic through `/plan-epic` → `/iterate-epic` in a
  live chat session; flip `[epics] home = "repo"` in `.lain/config.toml` and confirm both
  homes; drain one deferred-gate morning queue end-to-end — `lain epic queue`, read the
  spike evidence, `lain epic approve`, confirm `lain epic status` shows the stage unblocked.
- Staleness gate at execution start (beyond the standard check): confirm chunk-chat-ux,
  chunk-vsock, and chunk-bench-arms are landed; re-verify `Paths` signatures, `Journalable`
  location, and whether `Renderable` changed the CLI string convention.
