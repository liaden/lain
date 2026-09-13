# Simplify 14 — take the code-review product out of the study bench

status: **declined 2026-09-13 by the human** — see the ruling below
commit-mode: orchestrator-commits
language: ruby (with real Lua in the nvim runtime)
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson; TJ DeVries joins for the Lua

## The ruling

**Declined 2026-09-13 by the human**, and recorded in a sibling plan rather than here:
`planning/specs/simplify-07-frontend-dedup.md:833`, under *"The simplify-14 question, answered"* —
*"14 is unlikely to run, so T3 goes ahead as written. The rails it tables include the seven the review
surface uses; if 14 is ever revived it will delete a table rather than a scatter, which is the cheaper
direction to discover."* simplify-07 closed its chunk on that basis and `88c13d54` is in HEAD. This note
exists so a reader looking 14 up finds the decline here instead of finding `draft` and deferring
something on its account — simplify-10's T1 was deferred that way until the decline surfaced.

**The plan is kept, not deleted, because reviving it is still coherent.** Nothing it would remove has
been removed. As of 2026-09-13 the four groups T1 names are all still present in
`spec/lain/frontend/neovim_runtime_spec.rb`:

| group | lines | code | examples |
|---|---|---|---|
| *"the review round trip"* (`:1169`) | 199 | 89 | 5 |
| *"the refusal rail's width"* (`:1368`) | 372 | 204 | 10 |
| *"a review that survives the tabpage"* (`:2648`) | 432 | 266 | 10 |
| *"a long note grown in a pane"* (`:3080`) | 533 | 362 | 12 |
| **total** | **1,536 (42.5% of the file)** | **921** | **37 of 102 (36.3%)** |

Two further groups touch modules this plan would delete without being named for deletion: *"a user
command that refuses"* (`:2478`, citing `65_review`, `46_sidebar`, `47_diff`) and *"folds"* (`:2294`,
citing `51_thread`). **The blast radius was always larger than four groups** — which is why simplify-10
was right to sequence around 14 while it was live, and why a revival needs a fresh grounding rather than
this document's numbers.

## Intent

Eight Lua modules — **66.6% of all runtime Lua**, including a 775-line conversation panel ported from
octo.nvim — plus ~350 Ruby lines and ~7,200 spec lines implement a native code-review surface inside the
editor: diff panes, inline annotation extmarks, LSP-diagnostic projection, and comment threads swapped on
cursor movement.

**Nothing in `bench/`, `arm/`, `compare/`, `grader/` or `telemetry/` reads an annotation, a diff
placement, a thread or a note.** It makes no context strategy, tool design or orchestration tactic
swappable, observable or comparable. It is a well-built product in a repository whose stated deliverable is
a bench.

This plan removes it and keeps `Review::Surface::Text`, so `/review` still works.

Delivers: **−1,370 code lines of Lua, ~−350 of Ruby, ~−7,200 of spec** — the largest single spec-mass
recovery available, for the least coupling in the repository.

## Grounding

Verified 2026-09-12 against the working tree at `d2bb133c`. `code` is non-blank, non-comment.

**The eight Lua modules, and what fraction they are.** Runtime Lua totals **2,056 code lines** across 24
files (in 3,819 lines of comment and blank). These eight are **1,370 of them — 66.6%**:

| module | code |
|---|---|
| `48_annotate.lua` | 847 raw / inline annotation extmarks |
| `47_diff.lua` | 789 raw / native diff panes |
| `51_thread.lua` | 775 raw — **"ported from octo.nvim"**, 258 code |
| `52_note_compose.lua` | 390 raw |
| `41_layout.lua` | 391 raw / tabpage layout |
| `65_review.lua` | 336 raw / the review rail |
| `46_sidebar.lua` | 274 raw |
| `49_diagnostics.lua` | 283 raw / LSP-diagnostic projection |

**`49_diagnostics.lua` is already simplify-03's T1** — the deletability map's `diagnostics` row has
`consumers: []` and the project's own spec certifies its removal. If 03 has landed, seven remain.

**The Ruby side.** `frontend/neovim/review_view.rb` (475 code), `frontend/neovim/changeset_diff.rb`,
`frontend/neovim/thread_view.rb`, `RpcThread::ReviewWrite` (`rpc_thread.rb:499-732`), and
`review/surface/neovim.rb` — roughly **350 code lines**.

**The specs.** `thread_view_spec.rb` 1,976 + `review_view_spec.rb` 1,660 + `diff_mode_spec.rb` 1,314 +
`annotate_spec.rb` 1,076 + `changeset_diff_spec.rb` 663 + `layout_spec.rb` 539 ≈ **7,200 lines**. Plus the
review groups inside `spec/lain/frontend/neovim_runtime_spec.rb` — `"the review round trip"` (`:1145`),
`"the refusal rail's width"` (`:1344`), `"a review that survives the tabpage"` (`:2624`), and
`"a long note grown in a pane"` (`:3056`).

**The mandate test, which is why this plan exists.** `grep` for annotation, diff-placement, thread and note
concepts across `lib/lain/bench/`, `lib/lain/arm/`, `lib/lain/compare/`, `lib/lain/grader/` and
`lib/lain/telemetry/` finds **nothing**. The surface's own comment prose is about nvim API fidelity —
extmark lifetimes, tabpage restoration, `CursorMoved` debouncing — which are the concerns of a product.

**The repo already planned for this removal.** `spec/lain/review/deletability_spec.rb` (493 lines) holds a
machine-checked map, and three of its seven rows are this surface:

- **`thread`** (`:99-116`) — files `runtime/51_thread.lua`, `frontend/neovim/thread_view.rb`,
  `thread_view_spec.rb`; consumers `review/surface/neovim.rb` and its spec, with the rationale at
  `:104-107` that `#annotate`/`#thread` are **the port's messages**, so this row is *"a rewrite not a
  removal"*. Edits named: `frontend/neovim.rb`'s require and `__lain.set_thread`;
  `neovim_runtime_spec.rb`'s command and function lists; `plugin/nvim/doc/lain.txt`'s `*:LainThread*` and
  `*lain://thread*` tags. **`forces: %w[docent]`.**
- **`docent`** (`:117-138`) — `review/docent.rb`, `prompt/templates/role/diff-docent.md`, its spec;
  consumers `cli/command/review.rb`, `cli/command/survey.rb`, `cli/wiring/toolset_build.rb`; edits in
  `review.rb`, `role/catalog.rb`, `role_spec.rb`.
- **`diagnostics`** (`:75-91`) — `consumers: []`, already simplify-03's.

**What survives, and it is the reason `/review` keeps working.** `Review::Surface::Text` is the other
implementation of the same port. The changeset model — `review/{source,changeset,marks,hunk,anchor,partition,bounds,submit}`
— is untouched: it is what produces a review, not what draws one.

**The Lua loader makes this cheap.** `frontend/neovim/runtime_loader.rb:140-158`'s `#module_names` globs
`Dir.children(@modules).grep(/\.lua\z/)`, so **eight files come out without touching a loader**. But
`#refuse_collisions` (`:170-178`) enforces that two modules cannot share a load position, and `#prefix_of`
(`:160-168`) enforces the `NN_name.lua` shape — so the removal leaves **gaps** in the numeric sequence,
and the card must confirm nothing asserts the sequence is contiguous.

**The rails to remove from the transport.** `rpc_thread.rb`'s Lua constants for this surface:
`OPEN_REVIEW` (`:70`), `REVIEW_REFUSED` (`:72`), `SET_REVIEW` (`:85-86`), `REVIEW_FOCUS` (`:94`),
`REVIEW_SETTLED` (`:104`), `OPEN_CHANGESET` (`:115-116`), `SET_THREAD` (`:122`) — seven of the thirteen —
with their `post_*` methods (`:219`, `:223`, `:241`, `:248`, `:253`, `:255`, `:259`) and seven mirror
inlet methods (`:413`, `:417`, `:423`, `:427`, `:431`, `:433`) with their refusal constants (`:340`,
`:346`, `:347`, `:348`, `:349`, `:355`, `:363`). Plus `ReviewWrite` (`:499-732`) entire, and its entries in
`Router` (`:755-821`).

**Provenance that must be respected.** `51_thread.lua` is *"ported from octo.nvim"*, and
`planning/human-in-the-loop-review-research-2026-08.md` records that **licences were checked** across
tuicr, octo.nvim and codediff.nvim, with an 11-entry decision log. Deleting ported code is
straightforward; deleting the record of *why it was permissible* is not — the research doc should be
annotated rather than silently invalidated.

**Where docs and code will disagree after this lands.** `plugin/nvim/doc/lain.txt` documents
`:LainReviewOpen`, `:LainNote`, `:LainNoteDone`, `:LainThread` and the `lain://thread` and
`lain://review` buffers. `planning/human-in-the-loop-review-research-2026-08.md` says the surface was
*"built out as `specs/chunk-review-surface.md"`*, and that chunk doc is one of the 49 simplify-01's T8
archives. Both need correcting here, not later.

**What this does NOT touch.** `simplify-07` deliberately excluded `review_view.rb` from its shared
`ListView` for this plan's sake — so if this plan is **declined**, 07's T1 grows a third caller and the
`HELD` reconciliation goes from two values to three. And the **epic** review path
(`Epic::Review`, `SignoffQueue`) is a different mechanism on a different surface; simplify-12 owns it.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb`, `lib/lain/review.rb`,
  `lib/lain/frontend/neovim.rb`'s require block, `lib/lain/review/surface.rb`,
  `lib/lain/role/catalog.rb`, `lain.gemspec`, `.rubocop.yml`.
- **The Lua modules need no wiring diff** — the loader globs the directory. But the **protocol-history
  comment** at `frontend/neovim.rb:25-124` names several of the functions being removed, and that is a
  shared-file edit.
- This plan and **simplify-07 must not run concurrently**. 07 restructures `rpc_thread.rb`'s rails into a
  table (its T3) and consolidates the row rings (its T1); this plan deletes seven of those rails and one
  of those rings. **Sequence 14 first** — deleting is cheaper than restructuring-then-deleting.
- **simplify-03's T1 should land first** so `49_diagnostics.lua` and the `prefill` pair are already gone
  and this plan handles seven modules rather than eight.

## Open decisions

- **This whole plan is one decision, and it is the human's.** Everything below is written on the premise
  that the changeset-review surface is descoped. The evidence for it is the mandate test; the evidence
  against it is that somebody uses it daily, which no measurement in this repository can see.
- **Whether `Review::Docent` goes with it.** The deletability map's `thread` row carries
  `forces: %w[docent]`, and simplify-12's T7 would otherwise rewrite `Docent` (418 code lines, reopened six
  times) over the `Ask` register. **If this plan lands, 12's T7 shrinks by one client.** T5 executes the
  `docent` row; if the human wants to keep the docent role on the text surface, T5 covers only `thread`.
- **Whether the whole review domain follows.** `review/` is 3,009 code lines against ~16,600 spec, and a
  prior audit ranked it as serving the agent rather than the bench. This plan removes only the **editor
  surface**, keeping the changeset model and the text surface. Removing the domain is a larger decision
  with a much larger blast radius, and it is not proposed here.

## Waves

Wave 1: T1, T2
Wave 2: T3 (←T1, T2)
Wave 3: T4 (←T3)
Wave 4: T5 (←T4), T6
Critical path: T1 → T3 → T4 → T5

T6 runs last deliberately: it is the card that proves `/review` still works, and it should test the finished
state rather than an intermediate one.

## Tasks

### T1 — Delete the seven Lua modules   [wave 1] [risk: medium]

**Depends on:** none
**Files:** delete `lib/lain/frontend/neovim/runtime/41_layout.lua`, `46_sidebar.lua`, `47_diff.lua`,
`48_annotate.lua`, `51_thread.lua`, `52_note_compose.lua`, `65_review.lua`; delete
`spec/lain/frontend/neovim/{diff_mode,annotate,layout}_spec.rb`; modify
`spec/lain/frontend/neovim_runtime_spec.rb`; modify `plugin/nvim/doc/lain.txt`
**Reuse:** nothing — this is removal. The loader globs the directory, so no manifest edit.
**Shared-file wiring:** the **protocol-history comment** at `lib/lain/frontend/neovim.rb:25-124` names
functions these modules define; T3 owns the constants, but the history comment is edited here
**Reachable from:** deliberately **removed from production** — that is the deliverable. AC 1 asserts the
injected runtime no longer offers these functions, driven against a **live editor**, which is the only
thing that proves a Lua module is gone.

`49_diagnostics.lua` is **simplify-03's T1**; if 03 has not landed, add it here and say so.

**Remove the review groups from `neovim_runtime_spec.rb`** — `"the review round trip"` (`:1145`),
`"the refusal rail's width"` (`:1344`), `"a review that survives the tabpage"` (`:2624`), and
`"a long note grown in a pane"` (`:3056`). Note simplify-10's T1 may be splitting that file at the same
time; **sequence 14 first**, since deleting a group is cheaper than relocating it and then deleting it.

**The `NN_` sequence will have gaps.** `runtime_loader.rb:170-178`'s `#refuse_collisions` forbids two
modules sharing a position but says nothing about contiguity — confirm nothing asserts contiguity before
assuming the gaps are fine.

**Annotate the research record rather than invalidating it.**
`planning/human-in-the-loop-review-research-2026-08.md` records that licences were checked for the
octo.nvim port; that check is why `51_thread.lua` was permissible, and the doc should say the port was
removed rather than silently describing code that no longer exists.

**Acceptance criteria**

```gherkin
Scenario: the injected runtime offers no review functions
  Given a live editor with the runtime injected
  When its lain functions are listed
  Then no review, diff, annotation, thread or note function is present

Scenario: the runtime still loads with gaps in its load order
  Given the remaining modules with non-contiguous numeric prefixes
  When the runtime source is built
  Then it builds

Scenario: the surviving editor surfaces still work
  Given a live editor with the runtime injected
  When a chat renders, an approval is parked, and a question is asked
  Then each appears in its buffer

Scenario: the plugin help documents no removed command
  When the plugin help is read
  Then it names no review, note or thread command
```
→ spec files: `spec/lain/frontend/neovim_runtime_spec.rb` (AC 1-3, `:nvim`-tagged),
`spec/plugin/nvim_plugin_spec.rb` (AC 4)

**Escalation triggers**
- **AC 1 needs a real editor.** A Lua module can be deleted from disk and still be in a *running* nvim's
  memory; only an injected-runtime inspection proves it is gone. Do not accept this card on a Ruby-only
  spec.
- If a surviving module **requires** something one of the seven defined — a shared local, a helper in
  `41_layout.lua` used by the status view — the runtime breaks at injection time with a Lua error naming a
  nil value. `45_views.lua` and `05_records.lua` are the likeliest dependents; read both.
- `plugin/nvim/doc/lain.txt` is a **vim helpfile** with tag syntax (`*:LainThread*`). Removing a tag that
  another line cross-references leaves a broken help link, which `spec/plugin/nvim_plugin_spec.rb` may
  check.
- `48_annotate.lua` places **extmarks**. If an extmark namespace is shared with a surviving module,
  deleting the placer without the namespace leaves orphaned marks in a live buffer.

### T2 — Delete the three Ruby views   [wave 1] [risk: medium]

**Depends on:** none
**Files:** delete `lib/lain/frontend/neovim/review_view.rb`,
`frontend/neovim/changeset_diff.rb`, `frontend/neovim/thread_view.rb`,
`spec/lain/frontend/neovim/{review_view,changeset_diff,thread_view}_spec.rb`
**Reuse:** nothing — removal
**Shared-file wiring:** three `require_relative` removals from `lib/lain/frontend/neovim.rb`
**Reachable from:** deliberately **removed**; these are constructed from `CLI::Wiring`'s view assembly, and
AC 3 asserts a chat assembles without them through `CLI::Wiring`

Three views, ~350 code lines, ~4,300 spec lines between them.

`review_view.rb` is one of the three generation-stamped row rings simplify-07's T1 consolidates — and **07
deliberately excluded it for this plan**. If 14 is declined, that exclusion must be reversed.

**Acceptance criteria**

```gherkin
Scenario: a chat assembles without the review views
  Given a chat wired the way the CLI wires one
  When its editor views are listed
  Then no review, changeset or thread view is present

Scenario: the surviving views still render
  Given a chat with an editor attached
  When the inbox and the approval queue render
  Then both appear

Scenario: the inbox's gestures still resolve
  Given a rendered inbox
  When a gesture arrives on a row
  Then it resolves to that row

Scenario: nothing references a deleted view
  When the library is searched for the deleted view constants
  Then none is found
```
→ spec files: `spec/lain/cli/wiring_spec.rb` (AC 1), `spec/lain/frontend/neovim/inbox_view_spec.rb`
(AC 2, AC 3); AC 4 is a search recorded in the commit message

**Escalation triggers**
- If `review_view.rb` shares a **constant** with a surviving view — a `WIDTH`, an `INDENT`, a staleness
  sentence — deleting it breaks the sibling. simplify-07's T7 extracts a shared fold value for exactly this
  reason; if 07 has landed, check the shared leaf survives.
- `thread_view.rb` is named in the deletability map's `thread` row as part of a **rewrite not a removal**,
  because `#annotate` and `#thread` are the **port's** messages. T4 handles the port; this card must not
  leave the port declaring messages nothing implements.
- If any of the three is constructed anywhere other than `CLI::Wiring`'s view assembly, that caller was not
  in the grounding — report it.

### T3 — Take the review rails out of the transport   [wave 2] [risk: medium]

**Depends on:** T1, T2
**Files:** modify `lib/lain/frontend/neovim/rpc_thread.rb`; modify
`spec/lain/frontend/neovim/rpc_thread_spec.rb`
**Reuse:** the surviving rails and `#deliver`/`#refusable` (`:450-460`) are unchanged
**Shared-file wiring:** none — `rpc_thread.rb` is task scope
**Reachable from:** `RenderInlet` is what every view calls; AC 2 asserts a chat still renders through the
surviving rails, driven against a live editor

Remove **seven of the thirteen** Lua constants — `OPEN_REVIEW` (`:70`), `REVIEW_REFUSED` (`:72`),
`SET_REVIEW` (`:85-86`), `REVIEW_FOCUS` (`:94`), `REVIEW_SETTLED` (`:104`), `OPEN_CHANGESET` (`:115-116`),
`SET_THREAD` (`:122`) — with their seven `post_*` methods, seven mirror inlet methods, and seven refusal
constants (`:340`, `:346`, `:347`, `:348`, `:349`, `:355`, `:363`).

Then **`ReviewWrite` entire** (`:499-732`, 234 raw lines) and its entries in `Router` (`:755-821`).

`rpc_thread.rb` goes from 419 code lines to roughly 250. Note simplify-07's T3 restructures the remaining
rails into a table — **sequence 14 first**, so 07 tables six rails rather than thirteen.

**Acceptance criteria**

```gherkin
Scenario: the transport offers no review rail
  When the render inlet's methods are listed
  Then none names a review, changeset or thread operation

Scenario: a chat still renders through the surviving rails
  Given a live editor
  When a chat turn renders and an approval is posted
  Then both appear in their buffers

Scenario: inbound editor messages still route
  Given a live editor
  When a reply is sent from the editor
  Then it reaches the conductor

Scenario: a detached editor still refuses rather than raising
  Given a render inlet whose queue is closed
  When a view is posted
  Then a refusal comes back
```
→ spec files: `spec/lain/frontend/neovim/rpc_thread_spec.rb` (AC 1, AC 4),
`spec/lain/frontend/neovim_runtime_spec.rb` (AC 2, AC 3 — `:nvim`-tagged)

**Escalation triggers**
- **`ReviewWrite` is inbound wire normalization** (`:499-732`) and `Router` (`:755-821`) is inbound
  dispatch. If `Router` has entries for **non-review** messages that happen to route through `ReviewWrite`,
  deleting it breaks them. Read `Router`'s table entry by entry.
- `rpc_thread.rb:24-33`'s `SocketOwned` and the liveness check at `:1082-1088` are **not** review-specific
  and must survive untouched — they are what stops two lains attaching to one editor.
- The seven refusal constants are user-visible sentences. If any is shared with a surviving rail, removing
  it changes a message a user reads.

### T4 — Reduce the review surface port to its text implementation   [wave 3] [risk: medium]

**Depends on:** T3
**Files:** delete `lib/lain/review/surface/neovim.rb`, `spec/lain/review/surface/neovim_spec.rb`;
modify `lib/lain/review/surface.rb`, `lib/lain/cli/review.rb`,
`lib/lain/cli/command/review.rb`
**Reuse:** **`Review::Surface::Text` is the surviving implementation** and is why `/review` keeps working
**Shared-file wiring:** one `require_relative` removal from `lib/lain/review/surface.rb`
**Reachable from:** `CLI::Command::Review` selects a surface on the live REPL path; AC 1 drives `/review`
through the command surface

With the editor implementation gone, the port has one implementation. **Decide and say whether the port
survives as a port**: a one-implementation seam is exactly what simplify-03 and simplify-12 delete
elsewhere, and consistency argues for collapsing it into `Review::Surface`. But a surface is a plausible
extension point — a remote one is sketched in
`planning/remote-surface-research-2026-08.md` — and collapsing it would have to be undone.

The deletability map's `thread` row (`:104-107`) calls this *"a rewrite not a removal"* because
`#annotate` and `#thread` are the **port's** messages. After T2 nothing implements them, so they leave the
port here.

**Acceptance criteria**

```gherkin
Scenario: a review opens on the text surface
  Given a changeset
  When a review is opened
  Then it is drawn as text

Scenario: a review settles and reports its verdict
  Given an open review
  When it is approved
  Then the verdict is reported

Scenario: the port declares no message nothing implements
  When the review surface's messages are listed
  Then each is implemented

Scenario: asking for an editor surface is refused clearly
  Given a request for an editor review surface
  When it is resolved
  Then it is refused, naming the surfaces available
```
→ spec files: `spec/lain/review/surface_spec.rb` (AC 3, AC 4),
`spec/lain/cli/command/review_spec.rb` (AC 1, AC 2)

**Escalation triggers**
- `spec/support/shared_examples/review_surface.rb` asserts the port's contract across implementations. With
  one implementation it becomes a **single-caller shared group** — which simplify-10's T9 deletes as
  indirection with no reuse. Either inline it or say why it stays.
- If `Review::Surface::Text` turns out to depend on something `neovim.rb` provided — a shared formatter, a
  width constant — the text surface breaks. Check before deleting.
- `cli/command/review.rb` and `cli/command/survey.rb` are simplify-04's T4 and simplify-05's `/survey`
  merge. If either is in flight, coordinate.

### T5 — Execute the deletability rows and correct the documents   [wave 4] [risk: medium]

**Depends on:** T4
**Files:** modify `spec/lain/review/deletability_spec.rb`; if the `docent` row is taken: delete
`lib/lain/review/docent.rb`, `lib/lain/prompt/templates/role/diff-docent.md`,
`spec/lain/review/docent_spec.rb`, and modify `lib/lain/review.rb`, `lib/lain/role/catalog.rb`,
`lib/lain/cli/command/review.rb`, `cli/command/survey.rb`,
`lib/lain/cli/wiring/toolset_build.rb`, `spec/lain/role_spec.rb`; modify `ARCHITECTURE.md`,
`planning/human-in-the-loop-review-research-2026-08.md`, `planning/README.md`
**Reuse:** `deletability_spec.rb`'s `thread` and `docent` rows already name every file, consumer and edit
site, and `BootWithout` (`:295-328`) is the existing proof harness
**Shared-file wiring:** require removals from `lib/lain/review.rb`; the `diff_docent` entry from
`lib/lain/role/catalog.rb`
**Reachable from:** AC 1 is the deletability harness booting the tree without these rows, which is the
production-path check available for a capability being removed

Two rows to settle. **`thread`** is executed by T1-T4; this card records that in the map. **`docent`** is
the Open decision — the `thread` row carries `forces: %w[docent]`, and if it goes, **simplify-12's T7
shrinks by one client**: `Docent` is 418 code lines reopened six times, with four records (`:905-1053`)
that are one record with a `state` field duplicating `Exchange#state`'s own `STATES` (`:160`).

Then correct the documents, which is the part most likely to be skipped:

- **`ARCHITECTURE.md`** describes the review surface's mechanism.
- **`planning/human-in-the-loop-review-research-2026-08.md`** records 7 spikes, a survey of
  tuicr/octo.nvim/codediff.nvim **with licences checked**, and an 11-entry decision log — and says the
  surface was *"built out as `specs/chunk-review-surface.md`"*. **Annotate it**: the licence check is why
  the octo.nvim port was permissible and should survive as a record even though the port does not.
- **`planning/README.md`**'s index row for that research doc.

**Acceptance criteria**

```gherkin
Scenario: the tree boots without the removed rows
  Given the deletion map with these rows removed
  When the tree is booted without them
  Then it loads

Scenario: the map records what was removed
  When the deletion map's keys are read
  Then the removed capabilities are named

Scenario: the negative control still holds
  Given a capability removed without one it forces
  When the tree is booted
  Then it fails, naming the missing constant

Scenario: no document describes a surface that does not exist
  When the architecture document and the review research document are read
  Then neither describes the editor review surface as present
  And the licence check for the removed port is still recorded
```
→ spec file: `spec/lain/review/deletability_spec.rb` (AC 1-3; AC 3 already exists at `:483-491` and must
stay green)

**Escalation triggers**
- `deletability_spec.rb`'s `edits` lists are checked **for staleness only, never for completeness**
  (`:157-173`). A green boot does not mean nothing else references a removed constant — grep as well.
- `deletability_spec.rb` is `:seam`-tagged and uses `cp -al` hardlinked copies (`:300`), so it needs
  `TMPDIR` on the same filesystem as the repo. **Seven examples fail with a bare `Command failed: cp`** when
  `TMPDIR` is unset, which reads exactly like a real defect — confirm the environment before believing red.
- If the `docent` row is **not** taken, `Docent` keeps a consumer in `cli/command/review.rb` and
  `toolset_build.rb` — so the `thread` row's `forces: %w[docent]` is then wrong, and the map needs
  correcting rather than ignoring.
- **Do not delete the licence record.** `51_thread.lua` was a port of GPL-or-other-licensed code and the
  check is why it was permissible. Deleting the code is fine; deleting the evidence of due diligence is
  not.

### T6 — Prove `/review` still works   [wave 4] [risk: low]

**Depends on:** T4
**Files:** modify `spec/lain/cli/command/review_spec.rb`,
`spec/lain/review/session_spec.rb`; update `planning/qa/scenarios/`
**Reuse:** the changeset model — `review/{source,changeset,marks,hunk,anchor,partition,bounds,submit}` — is
untouched and is what produces a review
**Shared-file wiring:** none
**Reachable from:** `/review` from the REPL and `lain review` from the CLI; every AC drives one of the two

This card exists because the plan's risk is **not** that something fails loudly — it is that `/review`
quietly becomes less useful and nobody notices until a human tries to use it.

Assert the full round trip on the text surface: open, scope, annotate, settle, report, submit.

**Acceptance criteria**

```gherkin
Scenario: a review of a local branch opens, settles and reports
  Given a branch with three changed files
  When a review is opened, approved and reported
  Then the report names all three files and the verdict

Scenario: a review scoped to a subset draws only that subset
  Given a branch with three changed files
  When a review is opened scoped to one
  Then only that file is drawn

Scenario: a settled review can be submitted
  Given a settled review with notes
  When it is submitted
  Then the submission carries the notes

Scenario: a review of a large changeset is bounded
  Given a branch with more changed files than the bound permits
  When a review is opened
  Then it is capped and says so
```
→ spec files: `spec/lain/cli/command/review_spec.rb` (AC 1, AC 2, AC 4),
`spec/lain/review/submit_spec.rb` (AC 3)

**Escalation triggers**
- AC 4 exists because `review/session.rb:36-43` records a real defect two copies of the scoping code
  caused — *"`/review` of an 800-file pull request drew all of it."* Confirm the bound still applies on the
  text surface.
- If the text surface cannot express something the editor surface could — inline annotation at a specific
  line, say — that is a **capability loss** and must be written down in the commit message and in
  `planning/qa/scenarios/`, not discovered by a user.
- `planning/qa/scenarios/` has scenarios naming the editor review surface. Updating them is part of this
  card, not an afterthought: per the project's own rule, closing a chunk includes updating that
  enumeration, and a stale scenario is worse than a missing one.

## Integration checks

After the last wave:

- `bundle exec rake pspec` green, **with the example count recorded and the arithmetic written out**. This
  plan deletes ~7,200 spec lines, so the count drops a long way legitimately — which is exactly the
  condition under which a dead worker hides.
- **`bundle exec rspec --tag nvim`** against a real editor. Seven Lua modules and seven transport rails are
  gone; a Lua module that is deleted from disk but still referenced by a surviving one fails only here.
- `bundle exec rubocop` clean, and confirm `.rubocop.yml`'s `Style/Documentation` `AllowedConstants` list
  drops any entry belonging to a deleted class.
- `bundle exec rspec spec/lain/review/deletability_spec.rb` after confirming `TMPDIR` is set — it is
  `:seam`-tagged and uses `cp -al`.
- `bundle exec rspec spec/plugin/` — the vim helpfile changed.
- **Measure the runtime Lua total before and after.** The claim is 66.6% of it goes; record both numbers.
- **Manual, human:** open a cockpit and run `/review` on a real branch end to end — scope it, annotate,
  settle, submit. This plan's whole risk is a quieter, less useful `/review` rather than a broken one, and
  no spec can tell you whether a human can still do the job.
- **Manual, human:** open the cockpit and confirm the surviving editor surfaces are intact — a chat turn
  renders, an approval can be answered in the buffer, a question can be answered. Seven of thirteen rails
  are gone and **a tmux pane inherits the spec runner's PATH** (CLAUDE.md:245-247), which has already
  hidden a status-127 failure for the life of a feature.
- Update `planning/qa/scenarios/` and `planning/qa/README.md` — `cockpit-surfaces.md` covers this screen
  and several of its questions no longer have the same answer.
