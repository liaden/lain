# Chunk: survey dogfood cleanup — refusals, self-knowledge, and the comment sweep

status: in-progress
commit-mode: orchestrator-commits
language: ruby (with a substantial neovim-runtime Lua component)
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson
       (Ruby roster, `create-plan references/rosters.md`). **No Lua/nvim roster exists**; the
       panel reviews the Lua cards on general API/DX grounds and is told to say so rather than
       bluff — see Open decisions.

## Panel review — what changed

Reviewed by the Ruby roster 2026-08-25; verdict was **REQUEST CHANGES** with twelve blockers, and
every blocker spot-checked against the tree held. The plan below is the revision. What moved:

- **The sweep moved to the END.** It previously ran in waves 1-3 and rewrote the `file:line`
  grounding that eleven later cards depend on — `status_feed.rb:64-84` (C12's whole design),
  `wiring.rb:252,280-285` (C2's construction order), `hud.rb:44-62` (C7's jq trap). Code critical
  path drops from 6 to **3**.
- **`session_usage` moved out of `BaseTools`.** `base_tools.rb:11` says "the union a subagent role
  attenuates FROM is exactly this list, so it is built once and shared" — a thunk over the chat's
  agent would have made every subagent report its *parent's* spend. It now joins the main-agent-only
  append list, which also avoids an unlisted signature change across eight call sites.
- **`/introspect`'s registration was named in the wrong file.** Commands register in
  `cli/command.rb` (requires index) and `cli/command/surface.rb:135-139` (`#builtins`), not in
  `command/registry.rb`. As written the command would have shipped undispatchable.
- **The plan's own reuse exemplar was a dormant feature.** `Tools::ToolSearch` is constructed in
  exactly two places, both specs — `ToolSearch.new` appears nowhere in `lib/` or `exe/`. Verified.
  It is no longer cited as a pattern; C2 carries a production-path AC that ends at `exe/lain`.
- **Rust is out of the sweep.** ~2,400 `///`/`//!` lines in `ext/lain` and `crates/` are doc
  *attributes* under `#![deny(missing_docs)]`, not comments; deleting or orphaning one is a denied
  lint or a compile error.
- **The ticket ban now matches the sweep's scope.** Measured: `lib/` 731 references, **`spec/`
  1,323**. Banning repo-wide while sweeping only `lib/` would have made the rule false on landing.
- **T16 split.** Lazy stamping within the tab (C11) is deliverable; the stamp contract for a buffer
  `open_changeset` never opened is gated on Open decision 3 and is **not in this chunk**.
- **A new mechanical card (C1).** F31 was fixed at a site, F72 is the same defect at a second site,
  and converting three more sites invites a third. C1 makes it a rule with a spec, modelled on
  `output_discipline_spec.rb`.
- **Second revision, after the human confirmed the single commit.** The yard-lint objection was
  measured rather than assumed: the real `lib/` baseline is **27 violations, not 58**, and three of
  them are prose `@word`s YARD is reading as tags — CLAUDE.md's documented trap, live in the tree.
  Clearing the baseline joined the sweep's scope, so the one commit passes the hook honestly. The
  prose pass also **fanned out into eight disjoint-subtree cards** so "genuinely useful" can be
  applied to the whole tree rather than twenty files, still squashed into one commit. And planning
  turned up a live defect: **`git blame` fails outright today** — `blame.ignoreRevsFile` is
  configured and the file is absent — which C18 fixes independently of the sweep.
- **Dropped:** the `ToolUse` `delegate` swap (ActiveSupport's generated method carries a
  `rescue NoMethodError` for a nil target that a frozen `@hash` cannot have — it re-badges a loud
  failure, failing CLAUDE.md's own test for an AS import). The YARD tags and the rename survive.

## Intent

The 2026-08-25 paired `/survey` of lain over lain (`planning/survey-dogfood-2026-08-25.md`)
produced seven findings, nine enhancement notes and eleven human annotations
(`planning/qa-findings-round11-survey-2026-08-25.md`, `planning/survey-notes-2026-08-25.md`).
This chunk addresses all of the tiers the human selected: the comment/ticket-reference cleanup,
the refusal-delivery and unrouted-gesture defects, the **agent self-knowledge** gap that let a
model fabricate a telemetry table, the review-surface UX, QA coverage for the prompt/slot/role
extension API, and an ActiveSupport reuse pilot.

The headline is **F77**: asked for its own session usage, the agent invented a metrics table —
wrong model name, fabricated memory, CPU, RTT and network figures — while eight `turn_usage`
records carrying the true answer sat in the journal. On a bench whose deliverable is the
experiment record, an agent that confabulates telemetry contradicts the discipline from inside
the harness. T4 and T15 exist to make the true answer reachable and the false one unnecessary.

## Grounding

Verified 2026-08-25 against the live cockpit and the tree, by four parallel `Explore` passes
plus direct RPC reads of the running nvim.

**The refusal rail already exists and is the reuse for F72.** `_G.__lain.review_refused`
(`runtime/65_review.lua:236-247`) echoes via `nvim_echo` with `WarningMsg`, prepends `"lain: "`
itself, folds newlines to `" / "`, elides the *middle* to `v:echospace`, and copies the full
sentence into `:messages` with hit-enter suppressed. It returns the line actually displayed,
which is what specs assert on (`neovim_runtime_spec.rb:1307,1348,1471`). Discipline is pinned by
`spec/refusal_width_discipline_spec.rb`. **`define()` (`30_commands.lua:8-11`) does NOT rescue** —
its lone `pcall` guards the idempotent delete — so any `error()` inside a user-command callback
escapes to nvim, which appends `stack traceback:` and raises a hit-enter prompt that queues every
non-fast RPC request. `48_annotate.lua` has exactly four `error(` sites; `:291` is caught by
`pcall` and routed correctly, and **`:438`, `:442`, `:447` are the F72 gap**. 51_thread.lua's
post-F31 shape (`:660`, `:689`) is the worked example to copy: call the rail, `return`, leave the
buffer `modified`.

**No tool reads lain's own runtime state.** All 24 files in `lib/lain/tools/` were swept:
nothing touches accounting, usage, timeline, status feed or chronicle. `tool_search.rb:31` is the
only precedent for a tool holding a live collaborator, injected as a **thunk**
(`:96-98`, `@toolset.respond_to?(:call) ? @toolset.call : @toolset`) to break the construction
cycle — the toolset is built at `wiring.rb:401`, before the Agent at `:286`. The data exists:
`Agent#usage` delegates to `Accounting#usage` (`agent.rb:67-68`), a `Usage` Data of
`input_tokens`/`output_tokens`/`cache_creation_input_tokens`/`cache_read_input_tokens` with `#+`
(a monoid), `#total_tokens` and `#cache_hit_ratio` (`lib/lain/usage.rb:16-70`). Dollars are NOT
there — `Ledger#cost` + `PriceBook` own that (`lib/lain/ledger.rb:69`), and `Ledger` raises
rather than pricing an unknown model at zero.

**Registering a tool touches six places**, three of which fail loudly by name if missed:
`lib/lain/tools.rb` (unit index), `wiring/base_tools.rb:23` (child-inheritable) or
`wiring/toolset_build.rb:329` (main-agent-only), `mode/posture.rb:145 READ_ONLY` (**omission
silently removes the tool under `/mode plan`**), `spec/support/tool_registry.rb:42 BUILDERS`,
and `parallel_safety_spec.rb`'s `TRUE_TOOLS`/`FALSE_TOOLS` partition.

**F76's cause is documented, and it is a construction-order bug, not a counter bug.**
`status_feed.rb:64-84` records the "T13 KNOWN GAP": `inbox_count` retires only in `observe_turn`,
which waits for a `:turn` Event that never reaches this sink — `SessionRecord::Scribe#catch_up`
appends committed turns to the session journal, not the tee StatusFeed rides. `InboxView`
(`frontend/neovim/inbox_view.rb:332-352`) solves it correctly by retiring on `Telemetry::TurnUsage`
and resolving the causal chain against a live `Store`, but it is constructed *after* the Store
exists while StatusFeed is constructed *before* (`chat_launch.rb:70-71`). The doc prescribes a
late-bound Store thunk and explicitly rejects "retire on the human's reply" (breaks the parity
spec). **This is higher risk than the finding's LOW-MED suggested.**

**StatusFeed already consumes `Telemetry::TurnUsage`** (`observe_usage`, `:360-366`) — it just
uses it only for `slide_cache_deadline` and `occupancy`. A cumulative total needs no new wiring,
only a field in `observed` (`:499-504`), which is the change-token hash: a field placed in
`measures` instead would republish every second forever (`:467-472`).

**The status line has two writers.** `Up#configure_session` (`up.rb:906-909`) sets the tmux
option, and `plugin/tmux/scripts/lain-status` embeds `JQ_FILTER` **byte-for-byte**, pinned by
`spec/plugin/tmux_plugin_spec.rb:92`. Any filter edit must change both or that spec fails.

**The thread pane is the reusable "type into a buffer, `:w` to commit" pattern** for E1:
`buftype = "acwrite"` (nofile would refuse `:w` with E382 before `BufWriteCmd`), a required
`lain://…` name, `bufhidden = "hide"`, a `BufWriteCmd` on `pattern = PREFIX .. "*"`, and a
`lain_thread_rendered` **watermark** buffer-variable separating typed text from rendered text
(`51_thread.lua:553-561`, `:597`). Order is the correctness: rpcrequest first, clear `modified`
only after it returns. Critically, this shape **does not have** the async-ordering problem that
`48_annotate.lua:428-433` cites against `vim.ui.input`, because a `:w` is a discrete synchronous
event — so E1 is reachable without violating the constraint that rejected the obvious approach.

**Where docs and code disagreed, and which won:**

- `ollama-cloud-arm.md` §1's third case predicts a refusal that cannot occur —
  `ollama_tier.rb:238` states a summarizer tier is handed no base at all, and §2 of the same
  scenario documents the corrected behaviour. **Code won**; T10 fixes the scenario.
- **E3 is a recorded decision, not an oversight.** `00_constants.lua:33-39`: "lain://diff reuses
  nvim's own `diff` filetype so whatever treesitter/syntax a human's config attaches to it just
  works — no grammar shipped", and per-view filetypes were explicitly rejected. **Code won**;
  T14 is therefore an enhancement *against a stated position* and says so on the card.
- `plugin/nvim/doc/lain.txt:330-336` documents `:LainSurveyAdd` in the present tense as working.
  There is no `survey_add` route in `HumanReplies::Gestures#routes` (`human_replies.rb:842-851`);
  `Router#call` is `@routes[verb]&.call(...)`, a silent no-op, and the ack has already returned
  `true`. **Code won**; T6 makes the gesture and the doc tell the truth.
- `docs/rust-bindings.md`'s headline admits "capabilities Ruby has no good answer to" but rule #2
  operationalises only the asymptotic half. Recorded as E9; **not actioned in this chunk** —
  see Open decisions.

**Measurements this plan is sized against** (scripts re-runnable via T1's census):
`lib/**/*.rb` is 66,764 comment lines against 42,391 code lines (1.57:1); **YARD tags are only
6,801 of those (10%)**, so prose alone is 1.41:1 and 482 of 678 files (71%) have more comment
than code. The stated exemplar `lib/lain/timeline.rb` is **0.79** with a longest block of 24.
Plan-ticket tokens: ~182 distinct in ~1,080 citations; of the 40 most-cited, **32 resolve in
multiple documents** (`T3` in 36, `T15` in 18) and 3 resolve nowhere (`OM-6` ×16, `N-1` ×10,
`OM-3` ×8). The canonical plan `~/.claude/plans/jiggly-greeting-avalanche.md` defines **zero**.

## Orchestrator contract (plan-specific only)

Shared files — **orchestrator-owned, wiring diffs only, never in a card's Files list**:

- `lib/lain.rb` (load-order manifest)
- `lib/lain/tools.rb` (tools unit index)
- `lib/lain/cli/command.rb` (command requires index) **and**
  `lib/lain/cli/command/surface.rb` (`#builtins`, `:135-139` — where a command actually joins the
  shipped set; `command/registry.rb` only *holds* what Surface hands it)
- `lib/lain/cli/command/env.rb` + `lib/lain/cli/wiring.rb` (Env readers are added in pairs;
  `env.rb:106-108` states the rule)
- `lib/lain/cli/wiring/base_tools.rb`, `lib/lain/cli/wiring/toolset_build.rb`
- `lib/lain/mode/posture.rb` (`READ_ONLY`)
- **`spec/lain/frontend/neovim_runtime_spec.rb`** — 2,297 lines and shared by every Lua card.
  Append-only: a card hands back its examples as a diff rather than editing the file in its
  worktree, or three isolated branches produce three merge conflicts in one file.
- `spec/spec_helper.rb`, `spec/support/tool_registry.rb`, `spec/support/tags.rb`
- **`lib/lain/declarative.rb`** — created by D1 as the concern *and* its subtree index; D2 adds a
  require line to it in the same wave. Orchestrator-owned so D1 and D2 do not collide, and because
  its **manifest position is constrained**: `lain.rb:14-16` records that `guard` must sit *before*
  `config` ("a `guard` block builds its carrier by subclassing Guard as the class body evaluates"),
  and `declarative` inherits that. Note `canonical.rb` is required at `lain.rb:22`, **after** it — so
  D2's `:canonical` type must reach `Canonical.normalize` from a **method body only**; a class-body
  reference is a load-time `NameError`.
- **`spec/lain/comment_census_spec.rb`** — created by C15 and extended by C16 and all ten of
  C17a-j. Append-only and orchestrator-owned for the same reason `neovim_runtime_spec.rb` is.
- `.rubocop.yml`, `.pre-commit-config.yaml`, `lain.gemspec`

Deviations from the default process:

- **A wiring diff is squashed INTO its card's commit, never applied as its own.** CLAUDE.md is
  explicit: "A new lib file, its index/manifest line, and its spec land in the SAME commit",
  because pre-commit stashes unstaged tracked changes and specs load through `lain.rb`. Applying
  C2's `lib/lain/tools.rb` line as a separate commit makes the constant fail to resolve.
- **Baseline the example COUNT in the same environment you re-run it in.** `spec/support/tags.rb:140-150`
  silently excludes the whole `:nvim` set when nvim is absent from `PATH` ("Measured on a PATH with
  no nvim: 81 failures, zero skips"). A worktree without nvim moves the count ~81 for environmental
  reasons, and CLAUDE.md reads a count move as a dead worker.
- **Delete rather than deprecate, everywhere in this chunk.** lain has **no production users**, so
  there is no compatibility surface to preserve and no migration window to honour. A card that
  replaces a mechanism deletes the old one; a card that makes a spec redundant deletes that spec.
  The standing rule for every card: **cruft removed is part of the deliverable, and each deletion is
  named in the hand-off with its reason.** "Redundant" must mean *covered elsewhere*, never merely
  *gone* — a deleted example whose assertion has no new home is a lost test, and the hand-off has to
  show where it went.
- **Re-baseline the example count after wave 6.** Waves 4-6 legitimately move it: D3 adds and deletes
  examples, D4 removes 201 lines of spec. The sweep's ACs (C16, C17a-j) assert "the count equals the
  baseline", and that baseline is **the post-D4 count**, captured in the same environment it is
  re-run in — not the pre-chunk one. Without this the sweep cards fail for the right reason and an
  agent "fixes" them.
- **The sweep (C15-C17) runs LAST, in its own waves, with no other card in flight.** It rewrites
  comments across `lib/` and `spec/`, which is the grounding every other card cites.

## Open decisions

Execute-plan must **not** start a card gated on one of these.

1. **RESOLVED — one commit, and the hook passes rather than being bypassed.** The human confirmed
   one giant comment commit, explicitly to make it a `.git-blame-ignore-revs` entry later. The
   yard-lint objection dissolves on measurement: the real baseline is **27 violations in `lib/`**
   (17 W, 7 C, 3 E), not the 58 the hook's comment recalls, and **several are things the sweep
   fixes rather than risks** — 3 × `Warnings/UnknownTag` (`@context`, `@root`, `@bm25`: prose
   references YARD is parsing as tags, exactly CLAUDE.md's documented trap, live in the tree today)
   and 2 × `Documentation/EmptyCommentLine` (the blank-line-splits-a-docstring defect). So clearing
   the baseline is **in scope for the sweep**, the single commit passes `yard-lint --staged`
   honestly, and no `--no-verify` is needed. Each prose card leaves its own subtree clean.

2. **`survey_add` (B12) stays unwired.** C10 makes the gesture refuse honestly and marks the doc;
   accretion itself is a design question (`46_sidebar.lua:296-299`) and its own chunk.
3. **F73's out-of-corpus stamp contract is NOT in this chunk.** C11 delivers lazy stamping for
   buffers the round already knows. A buffer reached by `gf` that `open_changeset` never opened
   needs a `revision`/`side`/`path` triple, and `47_diff.lua:299-303` forbids deriving the
   repository-relative path in Lua ("that parser would be a second, silent spelling of
   `OLD_PREFIX`... no string surgery"). That card is deferred, not hidden.
4. **Whether `InspectionBinding` needs widening at all is unknown.** `Command::Env` already carries
   `agent` (so `Agent#usage` and the timeline are reachable) and `replies` (which
   `delegate :review_surface, :review_view, to: :review_editor` at `human_replies.rb:211` makes
   review state reachable). C12 must **determine this first** and report; a new `Env` reader is a
   two-file shared change and is not authorised in advance.
5. **The declarative adoption IS in scope, and it is an absorption rather than a pilot** — the
   human's ruling: adapt the pattern even at rough break-even provided the code is cleaner, and
   since lain has no production users, **delete the old mechanism rather than deprecating it**. Two
   foundation cards (**D1, D2**) and five migration cards (**D3a-e**) over 57 `Guard` subclasses, 11
   `Guardable` includers, 96 `check!` sites and 80 hand-rolled guards, then **D4** deletes `Guard`
   and `Guardable` outright.

   **No frozen-class or `Data` exclusion is needed**, and that is the point of the absorption: this
   never includes ActiveModel into the converted class, so `super()`-chained initializers,
   `Data.define` and self-freezing classes are all fine — verified by spike. The earlier
   ActiveModel-on-the-object design needed a 161-site exclusion set and excluded `Lain::Agent` by
   name; this one excludes nothing structurally.
6. **E9 (widening the Rust admission test's rule #2) is recorded, not actioned.** No card.
7. **No Lua/nvim review roster exists.** The panel reviews C1/C9/C10/C11/C14 on general grounds and
   is told to say so rather than bluff.

## Execution log (orchestrator)

- **Staleness check 2026-08-25 — PASS.** Wave-1 grounding re-verified against the tree: `48_annotate.lua:438,442,447` (and `:291` deliberately unprefixed), `65_review.lua:236-247`, `30_commands.lua:8-11`, `wiring.rb:252,280-285`, `toolset_build.rb:329`, `posture.rb READ_ONLY`, `agent.rb:350-358 wire_callers`, `restart.rb:148`, `status_feed.rb observe_usage`/`observed`, `tmux_plugin_spec.rb:92`, `tool_use.rb:41`, `role/catalog.rb BUILT_INS`. No drift.
- **`git blame` confirmed broken** (C18): `blame.ignoreRevsFile` resolves to the operator's global `~/.config/git/config`; the file is absent; `git blame README.md` dies.
- **Suite baseline, captured in the execution environment (nvim IS on `PATH`): `15899 examples, 0 failures, 15 pendings`.** Re-baseline after wave 6 per the contract.

- **Wave 1 LANDED 2026-08-25** — C1, C2, C3, C4, C5, C6, C7, C9, C18, in nine commits
  `7979eadd..3fc19ca4`. Full suite green at each commit through the real pre-commit gate;
  final count **15,983 examples, 0 failures, 15 pendings** against a 15,899 baseline. All nine
  worktrees retired.
- **Findings against THIS PLAN, from wave 1** (each cost an implementer real time):
  1. **C5's premise was false.** The plan quoted half a sentence: the comment continues "and kept
     for the reason {CLI::Resume#fork} records". The arm is unreachable AND deliberately retained.
     AC 3 was replaced with a spec pinning the defensive arm.
  2. **C6's AC 1 was already satisfied** before the card was written — the bidirectional drift
     guard existed and was green 14/14.
  3. **C2's registration list was wrong**: six claimed, **nine** actual. `wiring.rb` was missing
     entirely, and a ninth (`toolset_build_spec.rb`) does two-fifths of the guarding.
  4. **C4's AC 1 could not pin its own risk** — its wiring mistake raises before `Collaborators.new`
     is reached, so it passes under lazy delegation, the exact regression the card guards.
  5. **C1's cited worked conversion (`51_thread.lua:660`) is 131 columns**, over a bar of 80. The
     exemplar the card told every other site to copy was itself twice over.
  6. **C7's stop condition fired and the plan's framing of it was inverted** — the regenerated-turn
     worry was backwards; the real defect was a duck-typed dispatch admitting `OracleAnswer`.
- **Orchestrator process failure:** wave-1 worktrees were created 18 commits stale, and I
  dispatched one card's fix round and its re-review into the same worktree simultaneously.
  **Rule for waves 2-10: one agent per worktree at a time, and rescue hand-backs BEFORE
  `worktree remove`** — wave 1's were lost to it; their substance is reconstructed in
  `planning/followups-from-survey-dogfood-wave1.md`.
- **Eight follow-ups banked**, in that same file.

## Waves

```
Wave 1:  C1, C2, C3, C4, C5, C6, C7, C9, C18        (no unmet deps)
Wave 2:  C10 (←C1), C11 (←C1), C12 (←C2), C13 (←C7)
Wave 3:  C14 (←C11)
Wave 4:  D1, D2                                      — the Declarative foundation
Wave 5:  D3a … D3e (←D1, ←D2)                        — migrate + simplify, five subtrees
Wave 6:  D4 (←D3a…D3e)                               — delete Guard and Guardable
Wave 7:  C15                                         — the sweep begins only now
Wave 8:  C16 (←C15)
Wave 9:  C17a … C17j (←C16)                          — ten disjoint subtrees, ONE commit
Wave 10: C19 (←C17a…C17j, ←C18)
```

**Code critical path: C1 → C11 → C14 (3 deep).** The Declarative wing (waves 4-6) and the sweep
(waves 7-10) run after it, and the ordering is deliberate in both cases. The wing rewrites
constructors and deletes two units, so the sweep must see that tree, not the current one — a
declarative `attribute` line needs less prose than the imperative block it replaces, and pruning
comments that describe deleted code is wasted work done twice.

**The wing's own path is D1 → D3 → D4 (3 deep), and D4 is a real barrier**: `Guard` and `Guardable`
cannot be deleted until every one of D3a-e has landed, which is why D4 is its own wave rather than
riding along with the last migration.

No two same-wave cards share a file. `spec/lain/frontend/neovim_runtime_spec.rb` is append-only and
orchestrator-owned, which is what lets C10 and C11 share a wave; the ten wave-9 cards own strictly
disjoint subtrees of `lib/`.

**Wave 9 is a fan-out that lands as ONE commit.** The human wants a single
`.git-blame-ignore-revs`-able change; **ten** agents each rewriting a disjoint subtree, squashed by
the orchestrator, is how that is both broad and reviewable. Together with C16 they form the one
comment commit.

## Tasks

### C1 — Make `error()` in a user-command callback a spec failure, and convert every site   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/frontend/neovim/runtime/48_annotate.lua`,
`lib/lain/frontend/neovim/runtime/46_sidebar.lua`,
`lib/lain/frontend/neovim/runtime/62_approval.lua`,
`lib/lain/frontend/neovim/runtime/70_inbox.lua`,
`lib/lain/frontend/neovim/runtime/75_timeline.lua`,
`spec/lain/frontend/refusal_delivery_spec.rb` (create)
**Reuse:** `spec/output_discipline_spec.rb` is the shape — a spec that derives its subject set from
the tree and fails naming the violation. `spec/refusal_width_discipline_spec.rb` already does this
for refusal *width* and names `review_refused` as the rail; this card adds *delivery*.
`_G.__lain.review_refused` (`65_review.lua:236-247`); `51_thread.lua:660,689` is the worked
conversion.
**Shared-file wiring:** examples appended to `spec/lain/frontend/neovim_runtime_spec.rb` handed
back as a diff.
**Reachable from:** every `define()`d user command is created at attach by the runtime loader; the
new spec runs in the default suite.

**F31 was fixed at a site. F72 is the same defect at a second site. Converting three more sites
invites a third.** `define()` (`30_commands.lua:8-11`) does not rescue — its only `pcall` guards
the idempotent delete — so an `error()` inside a user-command callback reaches nvim, which appends
`stack traceback:` and raises a hit-enter prompt that queues every non-fast RPC request. Measured
across the runtime: **33 `error(` sites and 9 `vim.notify` sites**; only some are inside `define()`d
callbacks, and only those are in scope.

Write the gate first, let it fail naming the violations, then convert. **Drop the `"lain: "` prefix
from each converted message** — the rail prepends it (`:237`). `48_annotate.lua:291` is **not** a
violation: it is deliberately unprefixed and `pcall`ed by `:LainNoteDone`, which hands it to the
rail.

**Acceptance criteria:**

```gherkin
Scenario: the gate names a violation
  Given a runtime file with an error() call inside a define()d user-command callback
  When the refusal-delivery spec runs
  Then it fails naming that file and line

Scenario: no user-command callback raises
  Given the conversion has run
  When the refusal-delivery spec runs
  Then it passes with no violations

Scenario: annotating a non-review buffer refuses cleanly
  Given a buffer lain has not opened for review
  When :LainNote note hello runs
  Then the message area shows one line beginning "lain: "
  And ":messages" contains no "stack traceback:"
  And no hit-enter prompt is raised

Scenario: the prefix is not doubled
  Given any converted refusal fires
  Then the displayed line contains "lain: " exactly once
```
→ spec files: `spec/lain/frontend/refusal_delivery_spec.rb`,
`spec/lain/frontend/neovim_runtime_spec.rb`

**Escalation triggers:**
- A site is inside an `_G.__lain.*` **RPC entry point** rather than a `define()`d callback. There a
  raise legitimately becomes the RPC request's error and must NOT be converted — the gate's subject
  set must exclude them, and if it cannot distinguish the two, stop: a gate that over-reaches will
  be disabled by the next person.
- `spec/refusal_width_discipline_spec.rb` starts failing. A converted refusal that trips it is too
  **long**, not misrouted — shorten the sentence; do not widen the bar.
- The count of violations found is larger than the files listed above. Report it and stop rather
  than expanding scope silently — a 33-site conversion is a different card from a 9-site one.

---

### C2 — A `session_usage` tool, so the agent can answer what it has spent   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/tools/session_usage.rb` (create),
`spec/lain/tools/session_usage_spec.rb` (create), `spec/lain/cli/wiring_spec.rb`
**Reuse:** `lib/lain/tools/list_files.rb` for tool anatomy. `Agent#usage` (`agent.rb:67-68`) →
`Accounting#usage` (`accounting.rb:13`) → `Lain::Usage` (`usage.rb:16`, with `#total_tokens`,
`#total_input_tokens`, `#cache_hit_ratio`). For the late-bound collaborator, the working precedent
at this seam is `wiring.rb:252` — `parent = -> { agent.timeline }`, a thunk over a **local**,
explained at `:280-285`: "ASSIGNED, not merely returned: `parent` above closes over this local, and
the tools built between here and there read it at CALL time."
**Shared-file wiring:** one line in `lib/lain/tools.rb`; **one entry in the main-agent-only append
list at `lib/lain/cli/wiring/toolset_build.rb:329`** (NOT `base_tools.rb`); add `:session_usage` to
`lib/lain/mode/posture.rb:145 READ_ONLY`; one builder in `spec/support/tool_registry.rb:42`; one
name in `parallel_safety_spec.rb`'s `TRUE_TOOLS`.
**Reachable from:** `exe/lain chat` → `CLI::Wiring#build` → `#build_toolset` →
`ToolsetBuild#build`, which appends main-agent-only tools at `toolset_build.rb:329`, with the agent
thunk assigned at `wiring.rb:252`'s seam. **Not `BaseTools`** — `base_tools.rb:11` states "the union
a subagent role attenuates FROM is exactly this list, so it is built once and shared", so a thunk
over the chat's agent there would make every subagent report its **parent's** spend.

Nullary tool (`tool.rb:97` defaults `#input_schema` correctly, so no `Input` subclass). Reports the
four `Usage` fields plus totals. **Reports tokens, not dollars** — `Ledger` raises rather than
pricing an unknown model (`ledger.rb:107-109`), and the ollama-cloud arm has no entry in the
`PriceBook`; a dollar figure would be F77 with better manners. Says so in its description.

**Does NOT report a turn count.** `Accounting` holds `@usage` and `@last_turn_usage` and nothing
else; there is no turn counter, and `agent.iterations` counts loop iterations, which is a different
quantity. Reporting it as "turns" would be a wrong number in good formatting.

**Acceptance criteria:**

```gherkin
Scenario: the tool reports cumulative usage
  Given an agent that has observed two responses with known token counts
  When the model calls session_usage
  Then the result names input, output and both cache token totals
  And each equals the monoid sum of the two responses

Scenario: a fresh run reports zero rather than refusing
  Given an agent that has observed no responses
  When the model calls session_usage
  Then the result reports zero tokens

Scenario: it is reachable from the real entry point
  Given a Toolset built by CLI::Wiring#build_toolset for a live chat
  Then that toolset contains a tool named "session_usage"
  And calling it reports the agent Wiring actually constructed

Scenario: a subagent does not inherit the parent's accounting
  Given a subagent toolset attenuated from the base union
  Then it does not contain session_usage

Scenario: the tool survives plan mode
  Given the posture is switched to plan
  Then attenuating the live toolset does not raise Toolset::UnknownTool
```
→ spec files: `spec/lain/tools/session_usage_spec.rb`, `spec/lain/cli/wiring_spec.rb`

**Escalation triggers:**
- `Accounting#last_turn_usage` is **context occupancy, not spend** — `agent.rb:263,489-495` warns
  twice. If the implementation reaches for it, stop.
- The thunk resolves to `nil` at call time. Do not coalesce to `Usage::ZERO` — a fabricated zero is
  the defect this card exists to remove. Stop and fix the seam.
- Adding the tool to `BaseTools` looks simpler. It is not: it changes
  `BaseTools.build`'s signature across eight call sites (`docent_spec.rb:1037,1064`,
  `posture_spec.rb:109`, `toolset_build_spec.rb:109,118,135,173,469`) whose docstring exists to
  keep them "byte-identical", **and** it leaks the parent's accounting into every child.

---

### C3 — Document and rename `ToolUse.wrap`'s parameter   [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/response/tool_use.rb`, `spec/lain/response/tool_use_spec.rb`
**Reuse:** `lib/lain/tool/input.rb`'s YARD style for `@param`/`@return`/`@raise`.
**Shared-file wiring:** none
**Reachable from:** `Provider::Anthropic` / `Provider::Ollama` decode paths construct `ToolUse`
per tool call; no new construction.

`.wrap` carries ~14 lines of prose and **zero tags**, while its contract is entirely tag-shaped and
non-obvious: it accepts `[Hash, ToolUse]`, is idempotent on the second, returns `[ToolUse]`, raises
`ArgumentError` otherwise. Rename the `block` parameter so it does not collide with Ruby's block
concept, while keeping the wire vocabulary ("content block") legible in the refusal message.

**The `delegate :to_json, :fetch, to: :@hash` swap is deliberately NOT done.** ActiveSupport
generates a method wrapping the call in `rescue ::NoMethodError` to re-raise a
`DelegationError` diagnosing a nil target — impossible on an object that assigns `@hash` in
`initialize` and freezes. Forwarding is `(...)` either way, so there is no dispatch win to trade
for re-badging a loud failure. CLAUDE.md's test for an AS import is that it preserves loud failure;
this one does not.

**Acceptance criteria:**

```gherkin
Scenario: wrap is idempotent
  Given an existing ToolUse lens
  When wrap is called on it
  Then the same lens is returned

Scenario: wrap refuses a non-Hash naming the class
  Given a Symbol
  When wrap is called on it
  Then an ArgumentError names Symbol
  And the message quotes no value from the input

Scenario: the documented contract is machine-readable
  Given the source of ToolUse.wrap
  Then it carries @param, @return and @raise tags
```
→ spec file: `spec/lain/response/tool_use_spec.rb`

**Escalation triggers:**
- The rename reaches a caller outside this file. `.wrap`'s parameter is local, but if a keyword
  form is in use anywhere, a rename is an API change — stop.
- A YARD tag line would begin a comment line with `@`. Per CLAUDE.md, YARD reads a line-leading
  `@word` as a tag, so a prose reference to a keyword must stay inline.

---

### C4 — Collapse `Agent#wire_callers`' mirror assignments to delegation   [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/agent.rb`, `spec/lain/agent_spec.rb`
**Reuse:** `agent.rb:68`'s existing `delegate :usage, to: :@accounting` — same file, same idiom,
and here the target is genuinely retained rather than a method-local.
**Shared-file wiring:** none
**Reachable from:** `CLI::Wiring#build_agent` constructs every `Agent`; `wire_callers` runs in
`#initialize`.

The only run of three mirror-name assignments from one receiver in the tree. Retain the resolved
collaborators and delegate, **keeping the eager resolution** — `agent.rb:344-345`: "Both resolve
eagerly, so a wiring mistake raises HERE and not on the first turn."

**Acceptance criteria:**

```gherkin
Scenario: a wiring mistake still raises at construction
  Given collaborators naming both instrumentation: and a bare instrumented keyword
  When an Agent is constructed
  Then it raises during initialize, before any turn runs

Scenario: the collaborators answer identically
  Given an Agent built with injected model_caller, tool_runner and accounting doubles
  Then each reader returns the injected double

Scenario: usage still delegates
  Given an Agent that has observed a response
  Then agent.usage equals the accounting's cumulative usage
```
→ spec file: `spec/lain/agent_spec.rb`

**Escalation triggers:**
- Any `Metrics/*` cop trips on `Agent`. Per CLAUDE.md, **never loosen the limit** — extract; and an
  extraction is a different card.
- A spec asserts on `@model_caller` as an ivar rather than through a reader. Stop rather than
  re-adding an ivar to satisfy a structural spec.

---

### C5 — Settle the `Supervisor::Restart` rescue   [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/supervisor/restart.rb`, `spec/lain/supervisor/restart_spec.rb`
**Reuse:** the `Bench::Session::Corrupt` raise contract documented on `#call`.
**Shared-file wiring:** none
**Reachable from:** `Supervisor` restarts a killed actor on the real path; `#replay` is on it.

**Answer the reachability question first, then act on the answer — the card has one determinate
outcome, not a choice.** The rescue normalises `Store::MissingObject` into `Corrupt` and adds the
role name. The comment concedes the `MissingObject` arm is "defensive now that both folds
shape-check the causal edge". Determine whether it can still be reached. **If it can, pin it with a
spec that drives it** (nothing currently does). **If it cannot, remove the arm and the claim
together** — a rescue that catches an unreachable class is a comment that lies.

**Acceptance criteria:**

```gherkin
Scenario: a corrupt session record names the role
  Given a session record that fails to load as corrupt
  When a restart replays it
  Then Bench::Session::Corrupt is raised naming the role
  And the original message is preserved

Scenario: the original error survives as the cause
  Given a corrupt session record
  When the restart raises
  Then the raised error's cause is the original error

Scenario: the MissingObject arm is pinned by a driving spec
  Given Store::MissingObject is reachable through replay
  When a restart replays a record missing an object
  Then Bench::Session::Corrupt is raised naming the role
```
→ spec file: `spec/lain/supervisor/restart_spec.rb`
(If the arm proves unreachable, the third scenario is replaced by one asserting the rescue no
longer names a class it cannot catch — recorded on the card, not improvised.)

**Escalation triggers:**
- `Store::MissingObject` is reachable through a path the comment does not mention. The arm is then
  load-bearing and this is a documentation-only card.
- Removing the arm changes which error escapes to the supervisor's restart policy. The comment says
  the raise-vs-Result choice is "above this seam" — stop rather than converting it.

---

### C6 — A QA scenario for the prompt/slot/role extension API, and a drift guard   [wave 1] [risk: low]

**Depends on:** none
**Files:** `planning/qa/scenarios/prompt-slots-and-roles.md` (create), `planning/qa/README.md`,
`planning/qa/scenarios/ollama-cloud-arm.md`, `spec/lain/prompt/slots_spec.rb`,
`spec/lain/role_spec.rb`
**Reuse:** `planning/qa/scenarios/repl-commands.md` as the shape for a zero-model refusal-path
scenario; `role_spec.rb`'s `with_project` helper for `.lain/slots/` fixtures.
**Shared-file wiring:** none
**Reachable from:** the scenario is human-driven via the `manual-qa` skill; the drift spec runs in
the default suite.

No scenario drives the three-level project extension API, its `UnknownSlot` refusals
(`slots.rb:103,114,164`), or the 4096-token cache floor the shipped 364-byte default sits under.
Adds the drift guard that does not exist: `role_spec.rb` pins the filename mapping for **3 of 14**
roles by name and nothing iterates `Catalog::BUILT_INS`. Also corrects `ollama-cloud-arm.md` §1's
stale third bullet (see Grounding).

**Acceptance criteria:**

```gherkin
Scenario: every built-in role ships a template, and every template names a role
  Given Role::Catalog::BUILT_INS
  Then each role's slot_name has a shipped template file
  And every shipped role template file names a role in the catalog

Scenario: an unknown slot filename refuses loudly at each level
  Given a project with .lain/slots/systemm.md
  Then loading refuses with UnknownSlot naming the known slots
  And a .lain/slots/role/nosuchrole.md refuses naming the known roles

Scenario: the scenario is registered with its cost
  Given planning/qa/README.md
  Then it lists prompt-slots-and-roles.md with its question and cost
```
→ spec file: `spec/lain/prompt/slots_spec.rb`

**Escalation triggers:**
- Catalog and templates already disagree when the drift spec first runs. Measured 14/14 aligned on
  2026-08-25 — a mismatch means something changed since; report it as a finding, do not edit the
  catalog to match.
- The cache-floor step needs real quota. Mark it a **paid** step with its cost stated, per the QA
  bench's convention; if it cannot be driven free, say so rather than leaving it ambiguous.

---

### C7 — Session tokens on the HUD, and a status line that breathes   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/status_feed.rb`, `lib/lain/cli/up/hud.rb`,
`plugin/tmux/scripts/lain-status`, `spec/lain/status_feed_spec.rb`, `spec/lain/cli/up_spec.rb`,
`spec/plugin/tmux_plugin_spec.rb`
**Reuse:** `status_feed.rb:360-366` (`observe_usage`) already receives every `Telemetry::TurnUsage`
— no new subscription. `total_input_tokens` (`:387`) and `INPUT_TOKEN_FIELDS` (`:241`) already do
the token math.
**Shared-file wiring:** none
**Reachable from:** `ChatLaunch#open_chronicle` constructs the `StatusFeed`
(`chat_launch.rb:70-71,193`); `Up#configure_session` (`up.rb:906-909`) writes `status-right`.

Accumulate a cumulative token total in `observe_usage` and publish it in **`observed`** (the change
token, `:499-504`) — **not** `measures`, where a value republishes every second forever
(`:467-472`); an event-derived field absent from `observed` never publishes at all (`:490-496`).
Render it in `JQ_FILTER`, and add E8's trailing space **inside the jq expression** as a final
`+ " "`, not as trailing whitespace on the tmux option value.

**This creates a second accumulator for a number `Accounting` already owns, and that must be
reconciled rather than left to drift.** `Accounting#usage` sums `Response#usage`; this sums
`Telemetry::TurnUsage`. `usage.rb:11-13` states the rule ("correct aggregation requires summing over
*unique* turn digests"), and `TurnUsage` digests are non-unique across a regenerated turn. **A seam
spec must pin the two equal**, or the chunk that closes F76 — two surfaces disagreeing about a
count — recreates it for a different count.

The figure is **this machine's spend on this key**, not the plan's consumption. Label accordingly.

**Acceptance criteria:**

```gherkin
Scenario: the feed publishes a cumulative token total
  Given a StatusFeed that has observed two TurnUsage events
  Then the published state carries a total equal to their sum

Scenario: the total agrees with the agent's own accounting
  Given a real Agent and a StatusFeed fed from the same run
  When both are read after the same turns
  Then the published total equals Accounting#usage's total

Scenario: the total does not republish on a clock tick
  Given a StatusFeed with no new events
  When time passes and publication is attempted
  Then no new publication occurs

Scenario: the status line renders the total and ends with a space
  Given a state file carrying occupancy and a token total
  When the HUD filter is evaluated
  Then the output contains the total
  And the output ends with a single space

Scenario: the shipped tmux script matches the filter byte for byte
  Given plugin/tmux/scripts/lain-status
  Then it embeds Lain::CLI::Up::Hud::JQ_FILTER exactly
```
→ spec files: `spec/lain/status_feed_spec.rb`, `spec/lain/cli/up_spec.rb`,
`spec/plugin/tmux_plugin_spec.rb`, and the parity example as a `:seam` spec in
`spec/lain/seams/usage_parity_spec.rb` (create)

**Escalation triggers:**
- The two totals cannot be made to agree — e.g. a regenerated turn double-counts on one side.
  **Stop.** Publishing a second, differing number is the defect, not the feature; reconciling it is
  a design decision above this card.
- `spec/plugin/tmux_plugin_spec.rb:92` fails: the filter is embedded byte-for-byte in the shipped
  script, so **both writers change together**.
- The filter needs a `$` or a jq variable. `hud.rb:44-62` records that tmux 3.4 escaping plus jq 1.7
  grammar forbid both.

---

### C9 — Investigate language highlighting inside `lain://diff`   [wave 1] [risk: low]

**Depends on:** none
**Files:** `planning/notes/diff-highlighting-investigation.md` (create)
**Reuse:** `00_constants.lua:33-39` (the recorded decision), `spec/support/tags.rb:140-150` (why an
nvim-dependent assertion can pass or fail by machine).
**Shared-file wiring:** none
**Reachable from:** N/A — this card ships a written answer, not code.

**An investigation, not an implementation, because two of its three outcomes ship nothing.**
`00_constants.lua:33-39` records the decision: `lain://diff` reuses nvim's own `diff` filetype "so
whatever treesitter/syntax a human's config attaches to it just works — no grammar shipped", and
per-view filetypes were explicitly rejected. Determine and write down: (a) does a normal user
config already provide diff injection, making this a non-issue; (b) does injection require shipping
a query file, which would reverse the recorded decision; (c) can it be done without shipping one.
Note that any nvim-dependent spec is **silently excluded** when nvim is absent from `PATH`, so an
assertion here passes or fails by machine unless that is handled.

**Acceptance criteria:**

```gherkin
Scenario: the investigation answers all three outcomes
  Given the written note
  Then it states whether a stock config already provides diff injection
  And it states whether injection requires shipping a query file
  And it recommends implement, defer, or close-as-already-available, with the reason

Scenario: the machine-dependence of any future spec is recorded
  Given the written note
  Then it names spec/support/tags.rb's silent :nvim exclusion as a constraint on testing this
```
→ spec file: none — this card's deliverable is prose. **Stated deliberately**: an AC that cannot be
a spec belongs to an investigation card, and pretending otherwise is how a spike ships a dormant
assertion.

**Escalation triggers:**
- The answer is (c) and the implementation looks small. It still does not happen here — write the
  follow-up card instead, so it gets its own ACs and its own review.

---

### C10 — Make `:LainSurveyAdd` refuse honestly, and correct its documentation   [wave 2] [risk: low]

**Depends on:** C1
**Files:** `lib/lain/frontend/neovim/runtime/46_sidebar.lua`, `plugin/nvim/doc/lain.txt`,
`spec/plugin/nvim_plugin_spec.rb`
**Reuse:** `_G.__lain.review_refused` as C1 leaves it. **`spec/plugin/nvim_plugin_spec.rb` already
asserts on `doc/lain.txt`** at `:397,441,456,466,483,523,547,566,585` — including `:466`, "a new
command now fails this example BY NAME until doc/lain.txt names it". Extend it; **do not create a
second doc spec** (CLAUDE.md: one spec file per code file, never shard).
**Shared-file wiring:** none
**Reachable from:** the global `<leader>Lsa` keymap bound at attach (`46_sidebar.lua:331`).

There is no `survey_add` route (`human_replies.rb:842-851`); `Router#call`'s
`@routes[verb]&.call(...)` is a silent no-op and the ack has already returned `true`. Make the
gesture say accretion is not wired, and mark the `lain.txt` entries (`:330-336`, `:353-359`) as not
yet available. **Do not implement accretion** — Open decision 2.

**Acceptance criteria:**

```gherkin
Scenario: the gesture says it is not wired instead of acking silently
  Given a real file buffer and an open survey
  When :LainSurveyAdd runs
  Then the message area shows a refusal saying accretion is not yet wired
  And no rpcrequest for "survey_add" is sent

Scenario: the manual no longer describes it as working
  Given plugin/nvim/doc/lain.txt
  Then the :LainSurveyAdd entry states it is not yet available
  And it is distinguishable from entries for gestures that do work

Scenario: the existing wrong-buffer refusals stay distinct
  Given a lain:// view buffer
  When :LainSurveyAdd runs
  Then the refusal is about the buffer, not about accretion being unwired
```
→ spec files: `spec/lain/frontend/neovim_runtime_spec.rb`, `spec/plugin/nvim_plugin_spec.rb`

**Escalation triggers:**
- A `survey_add` route is found on the Ruby side after all. Then the finding was wrong — stop and
  report rather than adding a refusal to a working gesture.
- C1 left a `vim.notify` refusal in this file (`46_sidebar.lua:323-326`). Under snacks.nvim that is
  the plugin toast F72 complains about, in the gesture this card is making honest — if C1 did not
  cover it, say so rather than quietly converting it here.

---

### C11 — Keep a review alive across the nvim tab, for buffers the round knows   [wave 2] [risk: high]

**Depends on:** C1
**Files:** `lib/lain/frontend/neovim/runtime/48_annotate.lua`,
`lib/lain/frontend/neovim/runtime/47_diff.lua`
**Reuse:** `review_notes.stamp` (`48_annotate.lua:129`) stays the single membership test — extend
how a buffer *acquires* a stamp, never what the test reads. `review_diff.stamp`/`unstamp`/`withdraw`
(`47_diff.lua:304-336`). Tab-scoped state already exists: `vim.w[win].lain_review_slot`,
`review_panes` per tabpage (`41_layout.lua:285,407`).
**Shared-file wiring:** examples appended to `spec/lain/frontend/neovim_runtime_spec.rb`.
**Reachable from:** the `BufEnter` autocmd bound at attach (`48_annotate.lua:631`) and
`open_changeset` (`47_diff.lua:535`).

F73: `gf` out of a review buffer silently ends the review, because the new side is deliberately a
real editable buffer so LSP and treesitter attach (`47_diff.lua:184`) — which invites exactly the
navigation that drops the stamp. The human's direction: within the review's tabpage, do not end the
review.

**Scope is limited to buffers `open_changeset` has already opened in this round** — re-entering one
inside the tab re-acquires its stamp instead of leaving it withdrawn. A buffer the round has never
opened needs a `revision`/`side`/`path` triple that Lua may not derive (`47_diff.lua:299-303`
forbids the path surgery in terms), and that is **Open decision 3, deferred**.

**Acceptance criteria:**

```gherkin
Scenario: returning to a previously opened review buffer restores the keys
  Given a survey where two rows have been opened this round
  When I return to the first file's buffer inside the review tabpage
  Then the note keys are bound
  And :LainNote note hello places a marker on the cursor line

Scenario: a buffer the round never opened is not the review
  Given a survey open in a tabpage
  When I use gf to open a file no row has opened
  Then the note keys are not bound
  And :LainNote refuses naming how to open it from the sidebar

Scenario: a buffer outside the review tabpage is not the review
  Given a survey open in tabpage 1
  When I open a previously reviewed file in tabpage 2
  Then the note keys are not bound there

Scenario: the interleaving is pinned, not just the endpoints
  Given a stamped buffer, then <CR> opens the next row and withdraws it
  When I re-enter the earlier buffer inside the tab
  Then it carries the stamp the round gave it, with its original path and revision
```
→ spec file: `spec/lain/frontend/neovim_runtime_spec.rb`

**Escalation triggers:**
- The implementation needs to **derive** a repository-relative path from an absolute buffer name.
  `47_diff.lua:299-303`: "that parser would be a second, silent spelling of `OLD_PREFIX` with
  nothing pinning it to this one... no string surgery." **Stop** — that is Open decision 3, and the
  trigger fires on path *derivation*, not only on path-matching used as a membership test.
- Re-stamping fights `review_diff.unstamp`, whose rule is to withdraw from every buffer except the
  two under review (`47_diff.lua:319-326`). Two writers with opposite rules over one contract is a
  "wrong answer rather than a missing one" (`:310-318`) — if the two cannot be reconciled without
  changing `unstamp`'s meaning, stop.
- A `BufEnter` handler needs an RPC to learn the round's revision. That is a per-keystroke cost on a
  fast rail — stop.

---

### C12 — An `/introspect` command that answers about lain itself   [wave 2] [risk: high]

**Depends on:** C2
**Files:** `lib/lain/cli/command/introspect.rb` (create),
`spec/lain/cli/command/introspect_spec.rb` (create), `spec/lain/cli/command/surface_spec.rb`
**Reuse:** `lib/lain/cli/command/status.rb` for the command shape. **A command RETURNS a
`Lain::Renderable`; it does not hold a sink** — `command.rb:5-9`: "each RETURNS rendered text or a
Repl action, never output (the Repl's boundary renderer delivers it; output discipline holds
mechanically)." `Command::Env` already carries `agent` and `replies`.
**Shared-file wiring:** one leaf require in `lib/lain/cli/command.rb`; **one constructor in
`lib/lain/cli/command/surface.rb:135-139` `#builtins`** — this is where a command joins the shipped
set. `command/registry.rb` only holds what Surface hands it and is **not** where registration
happens.
**Reachable from:** `exe/lain chat` → `CLI::Wiring` → `Command::Surface#registry`
(`surface.rb:124`) built from `#builtins` → the REPL dispatches `/introspect`.

The human-facing half of the F75/F77 pair; C2 is the model-facing half. Reports provider/model, the
window and its **provenance**, cumulative usage, occupancy, whether a review is open with how many
annotations, and the journal path.

**First, determine what is already reachable (Open decision 4).** `Env#agent` gives usage and the
timeline; `replies` reaches review state via `human_replies.rb:211`'s
`delegate :review_surface, :review_view, to: :review_editor`. **Report what a new `Env` reader would
actually buy before asking for one** — it is a two-file shared change and is not pre-authorised.

Reports what it can prove and says what it cannot: a locally-summed figure is this session's spend,
not the subscription's. **No dollars** — same reason as C2.

**Acceptance criteria:**

```gherkin
Scenario: introspect is dispatchable from the real REPL
  Given a Command::Surface built by CLI::Wiring
  When "/introspect" is dispatched
  Then the introspect command handles it
  And it is listed by /help

Scenario: introspect reports the session's real usage
  Given a chat that has completed two turns
  When /introspect runs
  Then it reports the cumulative token totals
  And it names the model actually in use

Scenario: introspect reports review state
  Given a survey is open with annotations placed
  When /introspect runs
  Then it reports that a review is open and how many annotations it holds

Scenario: introspect is honest about what it cannot know
  Given the provider is ollama-cloud
  When /introspect runs
  Then the usage figure is labelled as this session's own spend
  And no plan-level or subscription-level quota is claimed

Scenario: introspect renders on a fresh chat
  Given a chat with no turns and no review
  Then /introspect renders without raising
```
→ spec files: `spec/lain/cli/command/introspect_spec.rb`,
`spec/lain/cli/command/surface_spec.rb`

**Escalation triggers:**
- **`Command::Surface#builtins` is already at its ABC budget** — `surface.rb:144-146`: "because
  `#builtins` reached its ABC budget, which is the same pressure saying the same thing." There is no
  `Metrics/AbcSize` override in `.rubocop.yml`, and `Metrics/ClassLength: Max: 110` applies to
  `Surface`. If adding a 15th constructor trips either, **extract — never loosen** — and that
  extraction is a separate card.
- Rendering wants a collaborator `Env` does not carry. Hand it to the orchestrator; do not widen
  `Env` from inside this card. And note `env.rb`'s own position that `NoApprovals` is "the one
  genuine Null Object" and every other reader is a required live collaborator — adding a second
  Null contradicts a written argument in the file being edited.
- The command reaches for a dollar figure. Stop.

---

### C13 — Make `inbox_count` and the inbox buffer agree   [wave 2] [risk: high]

**Depends on:** C7
**Files:** `lib/lain/status_feed.rb`, `lib/lain/cli/chat_launch.rb`,
`spec/lain/status_feed_spec.rb`, `spec/lain/frontend/neovim/inbox_view_spec.rb`
**Reuse:** `frontend/neovim/inbox_view.rb:332-352` — the *correct* retirement, consuming
`Telemetry::TurnUsage` and resolving `cited_by_chain` against a live `Store`. Port that answer; do
not invent one.
**Shared-file wiring:** `lib/lain/cli/wiring.rb` if the Store thunk must be threaded there.
**Reachable from:** `ChatLaunch#open_chronicle` (`chat_launch.rb:70-71,193`).

Measured live 2026-08-25: HUD `inbox_count: 2` while `lain://inbox` rendered one. The cause is at
`status_feed.rb:64-84` — `observe_turn` waits for a `:turn` Event that never reaches this sink,
because `SessionRecord::Scribe#catch_up` writes committed turns to the session journal rather than
the tee. The doc prescribes a **late-bound Store thunk** and explicitly rejects "retire on the
human's own reply" (breaks the parity spec).

**Acceptance criteria:**

```gherkin
Scenario: an answered question retires from the counter
  Given a StatusFeed that has observed a question to the human
  And the question is answered in a committed turn
  Then the published inbox_count is zero

Scenario: the counter and the buffer agree
  Given the same event stream driven through StatusFeed and InboxView
  Then inbox_count equals the number of questions the inbox view renders

Scenario: before the Store exists the counter still publishes
  Given a StatusFeed constructed before the Agent
  When a question arrives and no Store is bound yet
  Then inbox_count reports the pending question rather than raising
```
→ spec files: `spec/lain/status_feed_spec.rb`, `spec/lain/frontend/neovim/inbox_view_spec.rb`

**Escalation triggers:**
- The parity spec in `inbox_view_spec.rb` fails. It exists to pin these two against each other; a
  failure means the port changed the *view's* answer, which is the one already correct.
- Threading the Store thunk requires reordering construction in `ChatLaunch` or `Wiring`. That is a
  construction-order change on the live chat path — **escalate before doing it**; a mistake kills
  the pane at attach.
- `slide_cache_deadline` or `occupancy` changes. Both already ride `observe_usage`; retirement must
  not disturb either.

---

### C14 — Let a long note grow into a pane   [wave 3] [risk: medium]

**Depends on:** C11
**Files:** `lib/lain/frontend/neovim/runtime/48_annotate.lua`,
`lib/lain/frontend/neovim/runtime/52_note_compose.lua` (create)
**Reuse:** the thread pane, which already solves this — `buftype = "acwrite"` (nofile refuses `:w`
with E382 before `BufWriteCmd`), a required `lain://…` name, `bufhidden = "hide"`, a `BufWriteCmd`
on `pattern = PREFIX .. "*"`, the `lain_thread_rendered` **watermark** separating typed from
rendered text, and rpcrequest-then-clear ordering (`51_thread.lua:288-313,553-561,597,639-706`).
**Shared-file wiring:** examples appended to `spec/lain/frontend/neovim_runtime_spec.rb`; a loader
line if the runtime lists files rather than globbing.
**Reachable from:** a key bound alongside `NOTE_KEYS` (`48_annotate.lua:609`) in the same
stamp-gated `BufEnter` autocmd, so the pane is reachable exactly where a note is legal.

The cmdline is cramped for a long note. `vim.ui.input` is the approach `48_annotate.lua:428-433`
rejects — asynchronous under dressing plugins, so two overlapping prompts would put the placement
**sequence** at the mercy of typing speed, "and the sequence is this card's whole output". A
`:w`-committed scratch buffer does not have that problem: the write is discrete and synchronous.

**Assign the note's `seq` when the pane OPENS, not when it commits**, so a long note and a quick
cmdline note placed after it still hand back in the order the human placed them.

**Acceptance criteria:**

```gherkin
Scenario: a long note is typed in a pane and committed with :w
  Given a stamped review buffer with the cursor on a line
  When the compose pane is opened, text is typed, and :w runs
  Then a note is placed on that line with the typed text

Scenario: placement order follows when the pane was opened
  Given a compose pane is opened on line 10
  And a cmdline note is then placed on line 20
  And the compose pane is then written
  When :LainNoteDone hands back
  Then the line 10 note precedes the line 20 note

Scenario: an empty pane refuses in words
  Given an open compose pane with nothing typed
  When :w runs
  Then a refusal is echoed on the rail with no traceback
  And the buffer remains modified

Scenario: the short path is unchanged
  Given a stamped review buffer
  When <leader>Ln is pressed
  Then the cmdline is pre-filled with ":LainNote note " exactly as before
```
→ spec file: `spec/lain/frontend/neovim_runtime_spec.rb`

**Escalation triggers:**
- Reserving a `seq` at open time requires restructuring `review_notes.by_buf` or `placed`
  (`48_annotate.lua:385`). The placement sequence is the module's whole output; a half-migration
  corrupts it silently. Stop.
- The compose pane and the thread pane want the same window slot. `41_layout.lua:399-409` records
  that on a survey the thread pane already borrows the `old` slot; a second borrower needs a rule,
  not a race.
- The runtime loader lists files explicitly rather than globbing — then the new file is a shared
  wiring diff, not card scope.

---

### D1 — `Lain::Declarative`: one home for declared attributes, defaults, coercion and refusal   [wave 4] [risk: high]

**Depends on:** none
**Files:** `lib/lain/declarative.rb` (create), `lib/lain/declarative/carrier.rb` (create),
`lib/lain/declarative/validate_on_initialize.rb` (create), `spec/lain/declarative_spec.rb` (create),
`spec/lain/declarative/carrier_spec.rb` (create), `spec/lain/declarative/validate_on_initialize_spec.rb` (create)

**`carrier_spec.rb` exists because `spec/lain/guard_spec.rb` is the carrier's spec today** and D4
deletes it. Without a mirrored spec for `declarative/carrier.rb` the one-spec-file-per-code-file rule
is broken by this card and four of `guard_spec.rb`'s assertions land nowhere.
**Reuse:** **`lib/lain/guard.rb` and `lib/lain/guardable.rb` are the thing being replaced, and they
are the design to carry forward** — `Guard`'s docstring (`:8-16`) is the authority on why a frozen
value object must never include `ActiveModel::Validations` itself, and `Guardable#check!`
(`:96-105`) is the working validate-and-raise. This card moves that mechanism to a name that fits
what it does; it does not reinvent it.
**Shared-file wiring:** one line in `lib/lain.rb`, and `declarative.rb` becomes its subtree's index
requiring `declarative/*`.
**Reachable from:** included by every class D3a-e converts; those are already constructed on real
paths. D4 deletes the old names once nothing references them.

**Why a new name rather than extending `Guardable`.** `Guardable` is named for guard clauses, which
is one *use* of the machinery rather than the machinery. What the carrier actually provides is
declared attributes with defaults, coercion, validation, and a refusal — and once it also yields
settled values and wraps `initialize`, the old name describes a fraction of it.

**Three pieces, because there are genuinely two populations:**

1. **`Lain::Declarative`** — the concern. `declare raising: SomeError do … end` builds a carrier and
   evaluates the block in it, exactly as `guard` does today. Two entry points:
   - `check!(**attrs)` — validate a throwaway carrier and discard it. What `Guardable` does now,
     carried over unchanged for callers that only want the refusal.
   - **`settle!(**attrs)`** — validate, then **return the carrier's coerced, defaulted, deeply
     frozen attribute values**. This is the new capability and it is what makes declarative defaults
     reach an object that must not hold ActiveModel state.
2. **`Lain::Declarative::Carrier`** — what `Guard` becomes.
3. **`Lain::Declarative::ValidateOnInitialize`** — a `prepend`ed `initialize` that calls `super(...)`
   then validates, so a class that wants no hand-written constructor writes none.

**The real split is settle-values vs validate-only, NOT frozen vs unfrozen.** An earlier drafting
said a frozen value object cannot use the prepend; that is true only when it wants the settled
*values*, because it must control when `super` freezes. For validation alone the prepend is fine
even on a self-freezing class — the carrier is a separate object. `context/prune.rb`,
`context/cache_breakpoints.rb` and `context/purge_failed_inputs.rb` all freeze in `initialize` and
would take the prepend without complaint. Getting this backwards mis-routes D3's question 3, so it
is stated here in the terms the review actually uses.

**Measured population, so this card is not built on a guess.** Of the 58 `check!`-consuming files,
**~48 are `Data.define`** — and `super(**settle!(…))` is verified working on `Data` (see D3's
corrected trigger). So `settle!`'s population is the bulk of the tree, not a handful.
`ValidateOnInitialize`'s population is the small non-Data remainder and is genuinely thin; if D3
finds it empty, that is a finding and the piece should be dropped rather than kept for symmetry.

**Everything below was spiked against the installed activemodel 8.1.3, not designed on paper:**

- A carrier already applies declarative defaults and coercion — `Settled.new(name: "x").attributes`
  → `{"name" => "x", "count" => 7, "tags" => []}`. `check!` throws that work away; `settle!` keeps it.
- Defaults are **per-instance**: two constructions get two distinct `[]`.
- A frozen object built from settled values holds **only its own ivars** (`[:@name, :@count]`) — no
  `@errors`, no `@context_for_validation`.
- `Ractor.shareable?` on that object is `true` **provided the settled values are deep-frozen**, which
  is why `settle!` freezes them rather than leaving it to each caller to remember.
- The `prepend` shape works over `ActiveModel::Model`'s generated initializer **and** over a
  hand-written `def initialize(selector:)`, raising the declared class at construction in both.

**Acceptance criteria:**

```gherkin
Scenario: settle! returns coerced, defaulted values
  Given a class declaring an attribute with a default and one without
  When settle! is called with only the second supplied
  Then it returns both, the first holding its default

Scenario: settled VALUE attributes are deeply frozen
  Given a class whose settle! returns a String and an Array
  Then Ractor.shareable? holds for each of those values

Scenario: settle! refuses to freeze a live collaborator
  Given a declaration whose attribute holds an injected collaborator such as a Sink or an IO
  When settle! runs
  Then it refuses loudly rather than freezing that object
  And the refusal names the attribute

Scenario: a frozen value object stays shareable
  Given a value class that calls settle! before super and then freezes
  When it is constructed
  Then Ractor.shareable? holds for the instance
  And its instance_variables include no ActiveModel ivar

Scenario: check! still refuses as Guardable did
  Given a class declaring a refusal class and a presence validation
  When check! is called with that attribute blank
  Then it raises the declared class naming the attribute

Scenario: ValidateOnInitialize refuses at construction with no hand-written initialize
  Given a class including Declarative and ValidateOnInitialize and declaring a presence validation
  When it is constructed with that attribute blank
  Then it raises the declared class during initialization

Scenario: ValidateOnInitialize works over a hand-written initialize
  Given a class with its own initialize that also prepends ValidateOnInitialize
  When it is constructed invalid
  Then it still raises the declared class during initialization

Scenario: a missing declaration is not mistakable for a refused value
  Given a class including Declarative that never declares
  Then asking for its carrier raises a named error, not ArgumentError

Scenario: an undeclared Data value does not recurse into SystemStackError
  Given a Data.define including Declarative that never declares
  And whose initialize calls the carrier before super
  When it is constructed
  Then it raises the named error rather than recursing through new

Scenario: a declaration's constants resolve at validation time, not at class-body time
  Given a declaration whose validation set is a lambda citing a constant defined later in the manifest
  When the declaring file is required
  Then it loads without NameError
  And the constant resolves when validation runs

Scenario: the refusal class is answerable on both the includer and the carrier
  Given a class declaring a refusal class
  Then asking the includer and asking its carrier both answer that class

Scenario: an undeclared refusal defaults to ArgumentError
  Given a declaration that names no raising class
  When it refuses
  Then it raises ArgumentError

Scenario: an anonymous carrier can still name itself in an error
  Given a carrier built by the DSL rather than by subclassing
  When validation fails
  Then the error message is produced without raising on a missing model_name

Scenario: check! hands back nothing to hold
  Given a successful check!
  Then it returns nil, so no caller can retain the carrier
```
→ spec files: `spec/lain/declarative_spec.rb`,
`spec/lain/declarative/validate_on_initialize_spec.rb`

**Escalation triggers:**
- **Deep-freezing a collaborator is a process-wide hazard, not a style question.** Measured: a
  carrier attribute defaulting to `$stdout`, settled and deep-frozen, **freezes `STDOUT` and kills
  the interpreter's output for the rest of the process**. In a codebase whose central discipline is
  an injected `Lain::Sink`, this is live — `approval/gate.rb:18-23` declares `attribute :surface`
  and `check!`s a real `Review::Surface` through it. `settle!` must therefore distinguish value
  attributes from collaborator attributes and refuse the latter, which is why that is now an AC
  above and not only a trigger. If the distinction cannot be made, **stop** — a shallow `#freeze`
  would make the "deeply frozen" guarantee a lie in the shape of a promise.
- A carrier attribute uses a **stock** ActiveModel type. `:integer` casts `"3x"` to `3` **silently**
  (measured; `Integer("3x")` raises), which is precisely CLAUDE.md's disqualifier and the reason
  `StringInquirer` was rejected. Stock types are not to be used where silence matters — that is D2's
  subject, and a conversion reaching for one before D2 lands must stop.
- `NoGuardDeclared`'s existing reasoning (`guardable.rb:46-53`: a plain class raised the very
  `ArgumentError` a refusal raises, and a Data value recursed into `SystemStackError`) must survive
  the rename. If the new error loses either property, the rename has lost a hard-won diagnosis.

---

### D2 — Strict coercion types, because the stock ones fail silently   [wave 4] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/declarative/types.rb` (create), `spec/lain/declarative/types_spec.rb` (create)
**Reuse:** `ActiveModel::Type::Value` as the base; `Lain::Canonical.normalize` for the canonical type.
**Shared-file wiring:** one require line in `lib/lain/declarative.rb` (D1's subtree index).
**Reachable from:** declared by the carriers D3a-e write; reachable wherever those classes construct.

**Measured, and it decides the whole coercion question:**

```
ActiveModel::Type::Integer.new.cast("3x")  #=> 3
Integer("3x")                              #=> ArgumentError
```

Stock coercion does not preserve loud failure. `planning/survey-notes-2026-08-25.md` N3 named this
as "the question to answer first"; it is now answered, and the answer is that stock types are
unusable here wherever a malformed value must not pass.

Ship strict types that raise: a strict integer built on `Integer()`, and a `:canonical` type over
`Canonical.normalize` — the latter because that call appears in **14 constructor bodies** and is the
codebase's central invariant (deterministic bytes serving turn hashing *and* cache stability), so
declaring it beats re-asserting it.

**Lazy casting is neutralised by `settle!`, and that is worth stating.** A strict type raises on
*read*, not on construction — measured: `G2.new(n: "3x")` constructs, `.n` raises. Because `settle!`
reads every attribute to extract it, the raise lands during construction anyway. The extraction
pattern is what makes strict lazy types safe here.

**Acceptance criteria:**

```gherkin
Scenario: the strict integer refuses what Integer() refuses
  Given an attribute declared with the strict integer type
  When it is settled with "3x"
  Then it raises rather than returning 3
  And settling with "42" returns 42

Scenario: the refusal lands at construction, not first read
  Given a class calling settle! in its constructor with a strict-typed attribute
  When it is constructed with a malformed value
  Then the raise happens during construction

Scenario: the canonical type normalizes and stays shareable
  Given an attribute declared :canonical
  When it is settled with a nested hash holding symbol keys
  Then the returned value equals Canonical.normalize's output
  And Ractor.shareable? holds for it

Scenario: the stock/strict difference is pinned, not assumed
  Then a spec records that the stock :integer casts "3x" to 3
  And that the strict type raises on the same input
```
→ spec file: `spec/lain/declarative/types_spec.rb`

**Escalation triggers:**
- A strict type is wanted for something `Canonical.normalize` already handles. One coercion, one
  home — do not grow a second normalizer beside the one that owns determinism.
- The canonical type's output is not `Ractor.shareable?`. That breaks the invariant D1's `settle!`
  depends on; stop.

---

### D3a–D3e — Migrate every `Guard`/`Guardable` user, and convert the hand-rolled guards beside them   [wave 5] [risk: high]

**Depends on:** D1, D2
**Reuse:** D1's `Declarative`, D2's types. The existing `guard raising: X do … end` blocks are the
content.

**This is NOT a rename. Every migrated class gets reviewed against the whole new surface.** A card
that renames 27 carriers and changes nothing else has done the churn and skipped the point. For each
class, ask and record four questions:

1. **Can a default move into the declaration?** A `@x = x || Default.new` in the constructor, or an
   `OMITTED`-style sentinel, becomes `attribute :x, default: -> { … }` — reached through `settle!`.
2. **Can a coercion become a typed attribute?** `Canonical.normalize`, `Integer()`, `Array()` in a
   constructor body become D2's strict types, declared once where the attribute is.
3. **Can the hand-written `initialize` go away entirely?** If the class is not frozen and its
   constructor only assigns and validates, `ValidateOnInitialize` replaces it.
4. **Should `check!` become `settle!`?** Only if the class benefits from defaults or coercion
   reaching it; a class that just needs the refusal keeps `check!`.

The answers are the deliverable as much as the code is — a "no, because…" is a finding about where
the new surface does not reach, and those accumulate into whether the design is right.
**Shared-file wiring:** none per card; each owns its own subtree.
**Reachable from:** every migrated class is already constructed on a production path. **Each card
drives at least one converted class through its real construction site**, not through a double.

**Measured distribution — 57 `Guard` subclasses, 11 `Guardable` includers, 96 `check!` call sites,
80 hand-rolled guards**, partitioned by weight (`Guard/able ×3 + check! + hand-guards`):

| card | subtree (explicit globs, no residual) | Guard/able | `check!` | hand-guards |
|---|---|---:|---:|---:|
| D3a | `lib/lain/telemetry.rb` **and** `lib/lain/telemetry/**` | 27 | 27 | 0 |
| D3b | `lib/lain/review/**` + `lib/lain/approval/**` | 16 | 20 | 12 |
| D3c | `lib/lain/epic/**` + `lib/lain/forge/**` | 14 | 20 | 7 |
| D3d | `lib/lain/*.rb` (top level, **excluding `telemetry.rb`**) + `context/**` + `question.rb` + `question/**` + `mode/**` | 12 | 15 | 13 |
| D3e | `cli/**`, `provider/**`, `bench/**`, `config/**`, `tools/**`, `channel/**`, `compaction/**`, `compare/**`, `prompt/**`, `agent/**`, `memory/**`, `effect/**`, `middleware/**`, `plan/**`, `survey/**`, `sensitivity/**`, `shell/**`, `tool/**`, `exec/**`, `core/**`, `algebra/**`, `skill/**`, `oracle/**`, `grader/**`, `isolation/**`, `arm/**`, `frontend/**`, `structural/**`, `session_record/**`, `friction/**`, `workspace/**`, `supervisor/**`, `summarizer/**`, `status_feed/**`, `embedder/**`, `capability/**`, `journal/**`, `role/**`, `response/**`, `toolset/**`, `ledger/**`, `event/**`, `gherkin/**`, `project/**` | 1 | 14 | 48 |

**Two corrections a previous drafting got wrong, both caught by measurement:**

- **D3e was written as a residual** ("+ every remaining subtree") four lines above a paragraph
  banning residuals. It hid a live carrier — **`lib/lain/question/answer.rb:40`, `class Fields <
  Guard`** — under a row that recorded `0`, and D4's deletion AC had no explicit-glob owner proving
  it gone. `question/**` is now D3d's by name and every other subtree is enumerated.
- **`lib/lain/telemetry.rb` moved from D3d to D3a.** It holds `module Guards` (`telemetry.rb:46`)
  and the validate-then-freeze docstring, and — decisively — **`spec/lain/telemetry_spec.rb` is 931
  lines covering 22 lib files**, with only 4 spec files under `spec/lain/telemetry/`. Twenty-three of
  D3a's 27 carriers are pinned in that one file. Leaving it in D3d put the largest card in the wing
  in a different agent's spec file, in the same wave.

**Rename the vocabulary, not just the constants.** D3's naming AC previously asked only that
`Lain::Guard`/`Lain::Guardable` disappear. That leaves the tree's dominant namespace still named for
the deleted concept: **10+ `module Guards`** (`telemetry.rb:46`, `improvement.rb:101`,
`approval/gate.rb:11`, `approval/signoff_queue.rb:68`, `context/prune.rb:8`,
`context/cache_breakpoints.rb:5`, `context/purge_failed_inputs.rb:5`, `forge/reconcile.rb:94`, …)
and **`lib/lain/channel.rb:107`'s `class Guard < Lain::Guard`** — a class literally named `Guard`
surviving the deletion of `Guard`. Churn is wanted here; rename them in the same pass.

**`lib/lain/capability/guard.rb`'s `module Guard` is UNRELATED** and must survive. It is also a live
instance of CLAUDE.md's shadowing trap, and it will make a naive grep-based deletion check produce
false positives — D4's AC must exclude it by path.

**Files:** each card's own subtree, as enumerated above.

**`check!` is FOUR unrelated mechanisms sharing one name, and only one is Guardable's.** Question 4
of the review ("should `check!` become `settle!`?") is a category error against the other three, and
each is named here so no agent has to discover it:

- **`Review::Surface.check!(candidate)`** and **`Review::Partition::Strategy.check!(strategy)`** —
  duck probes, documented as *"a duck probe, not a base class"*. In **D3b**'s subtree. Not Guardable.
- **`Prompt::LockedBinding::Purity.check!(source, label)`** (`prompt/locked_binding.rb:104`) —
  positional, a purity check. In **D3e**'s subtree. Not Guardable.
- **`Epics::Gates.check!`** — likewise unrelated.

D3b and D3e must treat these as exclusions, not conversions.

**Delete as you go.** Per the human's ruling — lain has no production users and the freedom to
iterate is to be taken — a migrated class leaves **no** compatibility shim, and **redundant specs
are deleted rather than left passing**. A spec that only proved `check!` raised what `guard raising:`
declared is now D1's spec's job; a spec asserting a hand-rolled guard clause that no longer exists
goes with it. Removing a spec is a reviewable act: the hand-off names each deletion and why.

**Acceptance criteria** (each card, over its own subtree):

```gherkin
Scenario: every migrated class refuses exactly as before
  Given a class that previously raised a named error via check!
  When it is constructed with the same invalid input
  Then it raises the same class with a message naming the same attribute

Scenario: a converted hand-rolled guard keeps its named error
  Given a class whose constructor previously raised a named error inline
  When it is constructed invalid
  Then it raises that same named class, during construction

Scenario: frozen value classes stay shareable
  Given every migrated class in this subtree that freezes itself
  Then Ractor.shareable? holds for a constructed instance

Scenario: the subtree references the old names nowhere
  Given this card's subtree
  Then it contains no reference to Lain::Guard or Lain::Guardable

Scenario: it is built by its real caller
  Given the production construction site of one migrated class in this subtree
  When that site runs
  Then the object is built and the site behaves as its own spec asserts

Scenario: a constructor default became declarative where one existed
  Given a migrated class whose constructor built a default inline
  Then that default is declared on the attribute
  And two constructions omitting it receive distinct default objects

Scenario: every class was reviewed against the full surface, not just renamed
  Then the hand-off records, per migrated class, an answer to each of the four questions
  And a class left unchanged beyond the rename carries a stated reason

Scenario: deletions are named
  Then the hand-off lists every spec example and file deleted, with the reason
```
→ spec files: the existing spec at each migrated class's mirrored path. **No new spec files** — this
changes how objects are built, not what they do; a conversion needing a new spec file has changed
behaviour and should stop.

**Escalation triggers:**
- A migration would change **when** a refusal fires or **which class** it raises. Both are behaviour
  changes and the point is that neither happens. Stop.
- A class calls `check!` from somewhere other than its constructor. `check!` is documented as
  construction-time; another call site means the class is validating something else and the
  migration must not quietly relocate it.
- **(Corrected by measurement — the earlier draft of this trigger was wrong and would have stopped
  every agent in D3a.)** A previous version claimed `settle!` cannot serve a `Data.define` because
  `Data`'s generated initializer owns assignment. **It can, and the shape is `super(**settle!(…))`**
  — spiked against activemodel 8.1.3 on a real `Lain::Guard` carrier:

  ```ruby
  V = Data.define(:home, :depth, :tags) do
    def initialize(**kw) = super(**settle!(Carrier, **kw))
  end
  V.new(home: "near")   #=> #<data V home="near", depth=7, tags=[]>
  #   frozen? true · Ractor.shareable? true · instance_variables []
  V.new(home: nil)      #=> ArgumentError: home can't be blank
  ```

  `Data` owning assignment is precisely *why* handing it settled kwargs is correct. **This is the
  preferred shape for a Data value**, because it is the only way declarative defaults reach one.
  ~48 of the 58 `check!` consumers are `Data`, so this is the common case, not the exception.
- A spec looks redundant but is the only thing pinning a refusal's **wording**. Deleting it is a
  loss the hand-off must argue for, not a tidy-up.
- A simplification would change behaviour to fit the new surface — dropping a bespoke default,
  loosening a coercion, moving when a refusal fires. **The review looks for classes the new surface
  already fits; it does not bend classes to fit it.** Record it as "no" and move on.
- The four-question review keeps answering "no" across a whole subtree. That is a finding worth
  escalating, not a quiet outcome: it means `settle!` and `ValidateOnInitialize` are aimed at a
  population that does not exist, and D1 built more than the tree needs.

---

### D4 — Delete `Guard` and `Guardable`   [wave 6] [risk: low]

**Depends on:** D3a, D3b, D3c, D3d, D3e
**Files:** `lib/lain/guard.rb` (delete), `lib/lain/guardable.rb` (delete),
`spec/lain/guard_spec.rb` (delete), `spec/lain/guardable_spec.rb` (delete)
**Reuse:** none — this card removes.
**Shared-file wiring:** remove two lines from `lib/lain.rb`.
**Reachable from:** N/A — deletion. Its correctness is that nothing references the deleted names.

**No deprecation, no alias.** The human's ruling: there are no production users of lain, so the
freedom to iterate is real and cruft should go rather than accumulate a compatibility layer nobody
needs. The 201 lines of `guard_spec.rb` + `guardable_spec.rb` go with them — their content is D1's
spec's subject now, and keeping both would leave two specs pinning one mechanism.

**Acceptance criteria:**

```gherkin
Scenario: nothing references the deleted names
  Given the whole repository
  Then no file under lib/, spec/ or exe/ references Lain::Guard or Lain::Guardable

Scenario: the manifest no longer requires them
  Given lib/lain.rb
  Then it has no require line for guard or guardable

Scenario: the suite is whole
  When the full spec suite runs in the re-baselined environment
  Then there are no failures
  And the example count matches the post-wave-5 baseline minus the deleted examples, which the
  hand-off states as a number
```
→ spec file: none — a deletion whose assertion is the absence of references, checked by grep in the
AC and by the suite.

**Escalation triggers:**
- Any reference survives in `lib/`, `spec/` or `exe/`. That means a D3 card missed a site; report it
  to the orchestrator rather than migrating it here — this card deletes, it does not convert.
- The deleted spec files contain an example with no counterpart in D1's spec. Port it before
  deleting; "redundant" must mean covered elsewhere, not merely gone.

---

### C15 — Write the comment and ticket-reference policy, and build the census + stripper   [wave 7] [risk: medium]

**Depends on:** none structurally; **scheduled after all code work** so the sweep runs over the
final tree. **Gated on Open decision 1** (the one-commit / yard-lint question) — do not start until
the human has answered.
**Files:** `CLAUDE.md`, `bin/comment-census` (create), `spec/lain/comment_census_spec.rb` (create)
**Reuse:** `bin/lint-price-freshness`, `bin/lint-gherkin-docs` as the shape for a repo lint script.
**Shared-file wiring:** none
**Reachable from:** run by a human and by C16/C17's ACs. No runtime construction.

Three rules into `CLAUDE.md`: (a) density stated against the measured exemplar (`timeline.rb` at
0.79 prose:code, longest block 24) rather than a bare number; (b) **YARD tags exempt** — they are
10% of the mass and carry the skimmable shape; (c) plan-ticket references banned in comments,
**scoped to exactly what C16 sweeps** (`lib/`, `spec/`, the runtime Lua — **not** Rust, see below),
because a rule wider than its enforcement is false on landing. QA finding numbers (`F31`) stay
allowed: globally unique, durably documented.

**Builds the enforcement C16's central AC depends on**: a `--strip` mode emitting each file with
comments removed, per-language, so "the sweep changed no code" is a real diff and not an assertion.
A `#` inside a Ruby heredoc, regex or string is not a comment; the stripper must know that, and the
spec must prove it does.

**Acceptance criteria:**

```gherkin
Scenario: the census reports the prose/YARD split
  When I run "bin/comment-census"
  Then it prints code lines, YARD tag lines and prose comment lines separately

Scenario: the stripper knows a comment from a hash in a string
  Given a Ruby file containing a heredoc, a regex and a string each holding a "#"
  When I run "bin/comment-census --strip" on it
  Then those characters survive
  And only real comment lines are removed

Scenario: ticket references are found and finding numbers are not
  Given a comment citing "T15" and another citing "F31"
  When I run "bin/comment-census --tickets"
  Then the T15 site is listed and the F31 site is not

Scenario: the checker's scope matches the documented ban
  Given CLAUDE.md's ticket rule
  Then the directories it names are exactly those "--check-tickets" scans
```
→ spec file: `spec/lain/comment_census_spec.rb`

**Escalation triggers:**
- The ticket regex matches nvim error codes (`E95`, `E32`), encodings (`UTF-8`, `SHA-256`) or HTTP
  shapes. The first census run produced exactly these. If the classifier cannot exclude them
  without also excluding real tickets, **stop** — C16's entire safety rests on it.
- The stripper cannot be made correct for Lua or Ruby heredocs. Then C16's "no code changed" AC is
  unenforceable and the sweep must not proceed on an assertion.

---

### C16 — Sweep plan-ticket references out of comments   [wave 8] [risk: high]

**Depends on:** C15
**Files:** comment lines only, across `lib/**/*.rb`, `spec/**/*.rb`,
`lib/lain/frontend/neovim/runtime/*.lua`
**Reuse:** `bin/comment-census --tickets` for the site list, `--strip` for the no-code-changed gate.
**Shared-file wiring:** **the one exemption to the shared-file rule** — this card edits comments
*inside* orchestrator-owned files. Permitted only because it changes no code line in any file, and
that is enforced by the `--strip` diff, not asserted.
**Reachable from:** N/A — comment-only.

Measured: `lib/` **731** references, `spec/` **1,323**. Both are swept, because C15's rule covers
both. **Rust is excluded**: ~2,400 `///`/`//!` lines in `ext/lain` and `crates/` are doc
*attributes* under `#![deny(missing_docs)]` and `#[deny(clippy::missing_docs_in_private_items)]`
(`ext/lain/src/lib.rs:2,42`) — deleting one is a denied lint, orphaning one is a compile error, and
reflowing one can break an intra-doc link into another denied lint.

Where a reference carries the only pointer to a reason, replace it with the reason in words or a
durable path. **Never delete the surrounding sentence.**

**Acceptance criteria:**

```gherkin
Scenario: no ticket references remain in the swept scope
  When I run "bin/comment-census --check-tickets"
  Then it exits zero

Scenario: the sweep changed no code
  Given the pre-sweep and post-sweep trees
  When both are passed through "bin/comment-census --strip" and diffed
  Then the diff is empty

Scenario: load-bearing comments survive
  Then every "# frozen_string_literal: true" line is unchanged
  And every "# rubocop:disable" and "# rubocop:enable" directive is unchanged
  And every "# :nodoc:" and yard-lint directive is unchanged
  And every YARD tag line is unchanged
  And no blank comment line was introduced inside an existing docstring

Scenario: the suite is unaffected
  When I run the full spec suite in the same environment as the baseline
  Then the example count equals the baseline and there are no failures
```
→ spec file: `spec/lain/comment_census_spec.rb` (extended)

**Escalation triggers:**
- A `# rubocop:disable` or `# frozen_string_literal:` line is inside the edit set. These are
  **load-bearing** — `frozen_string_literal` changes behaviour silently. Stop; do not filter after.
- A blank comment line would be introduced mid-docstring. That splits it so only the adjacent block
  attaches — the exact defect `.pre-commit-config.yaml:80-85` says yard-lint exists for ("hiding
  `Compaction::Source`'s entire eleven-tag constructor docstring on an `attr_reader`").
- `trailing-whitespace` or `end-of-file-fixer` rewrites files and fails the commit. Both hooks
  modify in place; a ~60k-line reflow is the highest-yield source of trailing whitespace this repo
  will produce.
- The example count moves. `parallel_tests` reports only surviving examples, so a dead worker looks
  like a pass — and the `:nvim` set is silently excluded when nvim is off `PATH`.

---

### C17a–C17j — Prune and rewrite prose, one subtree each   [wave 9] [risk: high]

**Depends on:** C16
**Reuse:** C15's policy and `bin/comment-census`; `lib/lain/timeline.rb` (0.79 prose:code, longest
block 24) as the shape to move toward.
**Shared-file wiring:** the same comment-only exemption C16 carries.
**Reachable from:** N/A — comment-only.

**The mandate is "whatever comments remain are genuinely useful", not a ratio.** The ratio is how
progress is measured, never the goal — a card that hits 3.0 by deleting a reason has failed. Eight
cards over **strictly disjoint** subtrees, sized by comment mass so no agent carries more than
~11k lines:

| card | subtree | files | comment lines |
|---|---|---:|---:|
| C17a | `lib/lain/cli/**` | 97 | 11,265 |
| C17b | `lib/lain/*.rb` (top level only) | 83 | 7,222 |
| C17c | `lib/lain/review/**` | 45 | 6,981 |
| C17d | `lib/lain/frontend/**` + `lib/lain/context/**` | 45 | 6,185 |
| C17e | `lib/lain/provider/**` + `lib/lain/telemetry/**` | 84 | 5,736 |
| C17f | `lib/lain/tools/**` + `lib/lain/approval/**` | 52 | 6,654 |
| C17g | `lib/lain/compaction/**` + `lib/lain/bench/**` + `lib/lain/arm/**` + `lib/lain/grader/**` + `lib/lain/isolation/**` | 87 | 5,362 |
| C17h | `forge/**`, `oracle/**`, `agent/**`, `middleware/**`, `survey/**`, `project/**` | 56 | 4,878 |
| C17i | `shell/**`, `tool/**`, `sensitivity/**`, `plan/**`, `session_record/**`, `friction/**`, `memory/**` | 39 | 4,152 |
| C17j | `epic/**`, `effect/**`, `mode/**`, `question/**`, `workspace/**`, `exec/**`, `core/**`, `algebra/**`, `skill/**`, `config/**`, `supervisor/**`, `structural/**`, `compare/**`, `prompt/**`, `event/**`, `gherkin/**`, `summarizer/**`, `status_feed/**`, `embedder/**`, `capability/**`, `channel/**`, `journal/**`, `role/**`, `response/**`, `toolset/**`, `ledger/**` | 89 | 6,523 |

**`lib/lain/epic/**` was orphaned by every glob** — C17b is top-level `*.rb` only, so `epic.rb` was
swept and `epic/**` was not. It holds **15 files / 1,989 comment lines and two of the 27 yard-lint
baseline violations** (`epic/document.rb:375` unclosed backtick, `epic/scribe.rb:63` tag order),
which Integration check 4b requires cleared — so the chunk could not have passed its own gate. It is
C17j's. C17g's count was likewise a `55+` marker in a table claiming exactness; measured it is **87**.

**Every scope above is an explicit glob. None is a residual.** The previous drafting had seven
counted cards and one estimated residual ("~70 files / ~6,000 lines"); measured, that residual was
**169 files and 13,564 lines** — 3x the sizing rule the table is built on, and the largest card in
the plan by a wide margin. It is now C17h, C17i and C17j, each measured. A residual scope in a
fan-out table is always the card that eats the plan.

**Files:** each card's own subtree, comment lines only. **`ext/lain/` and `crates/` are excluded
from every card** — those `///`/`//!` lines are doc attributes under `#![deny(missing_docs)]`, and
the human asked for them to be left alone.

Keep the *reason*; cut restatement of what the code plainly does; relocate multi-paragraph
architectural argument to `ARCHITECTURE.md` or `docs/` with a one-line pointer left behind.
**YARD tags are preserved** — they are 10% of the mass, they carry the skimmable shape, and the
human named them as important. Where a `@tag` is *wrong* (see the ACs), fix it rather than delete it.

**Acceptance criteria** (each card asserts over its own subtree only):

```gherkin
Scenario: the subtree's prose comes down without losing reasons
  Given this card's subtree
  When I run "bin/comment-census" over it
  Then its prose-to-code ratio is lower than the pre-pass census
  And every file that fell by more than half is listed in the hand-off with what moved where

Scenario: the subtree is yard-lint clean
  Given this card's subtree
  When I run "bundle exec yard-lint" over it
  Then it reports no violations
  And any pre-existing Warnings/UnknownTag from a prose "@word" is fixed, not suppressed

Scenario: YARD tag coverage did not fall
  When I compare YARD tag line counts per file against the pre-pass census
  Then no file has fewer tag lines than before

Scenario: relocated reasoning is findable
  Given a file whose architectural argument was moved out
  Then the file retains a one-line pointer naming where it now lives
  And that destination contains the moved text

Scenario: no code changed
  Given the pre-pass and post-pass subtree
  When both are passed through "bin/comment-census --strip" and diffed
  Then the diff is empty

Scenario: the suite is unaffected
  When I run the full spec suite in the baseline environment
  Then the example count equals the baseline and there are no failures
```
→ spec file: `spec/lain/comment_census_spec.rb` (extended); the per-subtree assertions are shell
checks the card runs and records.

**Escalation triggers:**
- A comment slated for cutting is one this very survey depended on to reach a correct conclusion —
  `48_annotate.lua:428-433` (why the cmdline is synchronous), `46_sidebar.lua:283-290` (the unrouted
  verb), `status_feed.rb:64-84` (C13's whole design), `wiring.rb:252,280-285` (C2's construction
  order), `hud.rb:44-62` (C7's jq trap), `response/tool_use.rb`'s "Delegated, never inherited".
  **These are the prose E4 explicitly defends.** Keep them; report the file rather than meeting a
  number.
- A **reopened class** is involved: YARD keeps exactly one docstring and it must sit on the reopen,
  or the rest is silently discarded.
- A rewritten line would begin with `@word`. That is how the three live `Warnings/UnknownTag`
  violations got there; do not add a fourth.
- A blank comment line would be introduced mid-docstring — it splits the docstring so only the
  adjacent block attaches (`.pre-commit-config.yaml:80-85`).
- The subtree cannot be made yard-lint clean without touching code. Stop; that is a different card.

---

### C18 — Fix `git blame`, which is broken today   [wave 1] [risk: low]

**Depends on:** none
**Files:** `.git-blame-ignore-revs` (create)
**Reuse:** none — this is a one-line repair.
**Shared-file wiring:** none
**Reachable from:** every `git blame` invocation in the repository.

**Found while planning: `git blame` currently fails outright.** `blame.ignoreRevsFile` is configured
to `.git-blame-ignore-revs` and **the file does not exist**, so any blame dies with
`fatal: could not open object name list: .git-blame-ignore-revs`. Verified on `README.md`.

Create it with a header comment explaining what it is for. It lands empty of revisions; C19 adds the
first one. This card is independent of the sweep and should not wait for it — blame is broken now.

**Acceptance criteria:**

```gherkin
Scenario: blame works again
  Given the repository
  When I run "git blame" on any tracked file
  Then it succeeds and attributes lines

Scenario: the file explains itself
  Given .git-blame-ignore-revs
  Then it carries a comment saying what it is and how to use it
```
→ spec file: none — a repository-configuration repair with no Ruby subject. Verified by the command
in the AC and by Integration check 8.

**Already established, so the card does not open by rediscovering it:**
`git config --show-origin --get blame.ignoreRevsFile` resolves to
**`file:/home/tara/.config/git/config`** — the operator's **global** config. So blame is broken in
every repository of theirs that lacks the file, and lain's `.git-blame-ignore-revs` is a per-repo
fix for a global misconfiguration. Create the file here (lain needs it regardless, and C19 fills it),
and **say so in the hand-off** so the operator can decide whether to fix the global setting or add
the file to their other repos. Do not change the operator's global git config from inside this card.

**Escalation triggers:**
- Creating the file does not restore blame — then `ignoreRevsFile` is not the only thing wrong and
  the diagnosis above is incomplete.
- A revision listed in the file is not a valid object. Git fails the whole blame on a bad SHA, which
  would turn a convenience into the same outage this card is repairing.

---

### C19 — Record the sweep commit in `.git-blame-ignore-revs`   [wave 10] [risk: low]

**Depends on:** C17a–C17j, C18
**Files:** `.git-blame-ignore-revs`
**Reuse:** C18's file.
**Shared-file wiring:** none
**Reachable from:** every `git blame` invocation.

The point of landing the sweep as one commit: append its SHA so `git blame` skips it and keeps
attributing lines to whoever last changed the *code*. Runs after the squash, because the SHA does
not exist until then — so this is its own small commit, deliberately.

**Acceptance criteria:**

```gherkin
Scenario: the sweep is ignored by blame
  Given the comment sweep has landed as one commit
  When I run "git blame" on a file the sweep rewrote heavily
  Then no line is attributed to the sweep commit
  And lines are attributed to the commits that last changed their code

Scenario: the entry says what it is
  Given .git-blame-ignore-revs
  Then the sweep's SHA is preceded by a comment naming it and its date
```
→ spec file: none — see C18.

**Escalation triggers:**
- The sweep landed as more than one commit. Then every SHA must be listed, and the hand-off must say
  so — a partial list silently reintroduces the noise this card exists to remove.

## Integration checks

After the last wave:

1. **Full suite, checking the example COUNT as well as failures** — `bundle exec rake pspec`,
   **in the same environment the baseline was captured in** (nvim on `PATH` or not, consistently).
2. `bundle exec rubocop` (bare — **never name a `.toml` on the command line**);
   `cargo test && cargo clippy --all-targets -- -D warnings`.
3. `pre-commit run --all-files`.
4. `bin/comment-census` — record the final prose:code ratio; `--check-tickets` exits zero;
   `--strip` diff against the pre-sweep tree is empty.
4a. **The absorption's ledger.** Collate **D3a-e**'s hand-offs: for every migrated class, the answer
   to each of the four review questions; every simplification taken; every one declined with its
   reason; and every spec example or file deleted with where its assertion now lives. The ruling was
   to adopt at rough break-even for readability, so the deliverable is the record of what got
   cleaner — not a line-count win. A subtree that answered "no" to question 3 throughout is the
   evidence for whether `ValidateOnInitialize` should have been built at all.
4b. `bundle exec yard-lint lib/` — **zero violations**, against a measured pre-chunk baseline of 27
   (17 W, 7 C, 3 E). The single comment commit must pass `yard-lint --staged` on its own merits;
   no `--no-verify`.
4c. `git blame README.md` succeeds (C18), and blame on a heavily-swept file attributes no line to
   the sweep commit (C19).
5. **The manual pass, and it is the one that matters.** `lain up <path> -- --provider ollama-cloud`:
   - `:LainNote` in a non-review buffer → one clean `lain:` line, no `stack traceback:` (C1)
   - re-enter a previously opened review file inside the tab → keys still bound (C11)
   - the compose pane: open, type, `:w`; then `:w` again with nothing new (C14)
   - `<leader>Lsa` → an honest refusal, not a silent ack (C10)
   - `/introspect` → real usage, real review state, dispatchable from the REPL (C12)
   - **ask the model "what is my usage?" → it calls `session_usage` and reports the journal's
     numbers rather than inventing any (C2). This is F77's regression check and the reason the
     chunk exists.**
   - read the tmux status line: token total present, agrees with `/introspect`, line ends with a
     space (C7)
   - inbox counter and `lain://inbox` agree (C13)
6. **Re-drive `planning/qa/scenarios/survey.md` §1–§6** — zero-model, the regression gate for
   everything C1/C11/C14 touch.
7. Drive the new `prompt-slots-and-roles.md` scenario once (C6) and record it in
   `planning/qa/README.md`'s coverage table.
