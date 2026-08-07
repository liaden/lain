# The partition axis: how a changeset is grouped becomes a swappable strategy

status: draft
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds · Jeremy Evans · Sandi Metz · Richard Schneeman · Aaron Patterson

## Intent

`Review::SCOPES` is `%w[commits cumulative]` — two literals, four dispatch tables derived from
them, and a `Bounds` refusal that names "commit" in prose. That axis is really *how a changeset
is grouped for reading*, and grouping-by-commit is one strategy among several. This chunk makes
it a port: `Partition::Strategy`, with `ByCommit`, `ByDirectory` and `Whole` shipped.

It is a **pure refactor of code that exists today** and is useful on its own — `lain review
--scope by_directory` works when it lands, whether or not anything is ever surveyed. It is also
the prerequisite for `planning/specs/chunk-survey-corpus.md`, which cannot remove its fabricated
commit walk until grouping stops meaning commits.

Delivers the partitioning arm of the bench's swappable-axis programme (ROADMAP.md's axis table,
"Orchestration" row's sibling concerns) — the axis is new, so this chunk adds the line rather
than satisfying one.

## Grounding

Verified 2026-08-07 against `main` at `2e26748` by parallel Explore passes, then re-verified
against a review panel's counter-check. Facts every card depends on:

- `SCOPES = %w[commits cumulative]` (`vocabulary.rb:93`). Four dispatch tables derive from it:
  `Bounds::SCOPE_NAMES`/`SCOPE_CHECKS`/`COMMIT_WALK` (`bounds.rb:106,111,116`),
  `Session::SCOPES` (`session.rb:87`), `Surface::Text::SCOPE_RENDERER` (`text.rb:58`),
  `ReviewView::SCOPE_ROWS` (`review_view.rb:122`). The last two are literals, spec-pinned equal
  to the vocabulary.
- **Five production readers of `by_commit`**: `bounds.rb:242` (`check_commits!`), `bounds.rb:262`
  (`cumulative_advice`), `bounds.rb:286` (`critique_chunks`), `marked_changeset.rb:101`,
  `surface/text.rb:134`, `review_view.rb:388`. **`cumulative_advice` is the one that decides the
  wave structure**: it is reached from the *cumulative* path (`bounds.rb:234,236`), so renaming
  `by_commit` without touching `bounds.rb` in the same commit leaves the suite red.
- `bounds.rb:286` calls `scope.with(files:)`, so a partition must be a `Data`, not a duck
  answering `#files`.
- `bounds.rb:247-248` interpolates `"commit #{scope.sha}"` into a refusal message. Replacing the
  *advice* alone (`COMMIT_WALK_ADVICE`) leaves an oversized directory partition refusing with
  `"commit lib/a: 240 files over the ceiling"`.
- `Changeset::CommitScope = Data.define(:sha, :subject, :body, :numstat, :files)`
  (`changeset.rb:118`); `MarkedChangeset::CommitRow` (`marked_changeset.rb:186-198`) forwards all
  five and derives `#added`/`#deleted`/`#binaries` by summing `numstat`. `review_view.rb:393,413`
  reads `#added`/`#deleted` as scalars and explicitly *not* `#numstat` (`review_view.rb:56-62`).
- Commit grouping lives in `Changeset#scopes`/`#owner_of`/`#ownership` (`changeset.rb:315-340`).
  Its rules are spec'd at `changeset_spec.rb:615-656`: one group per commit in walk order; an
  overlapping file goes to the **last** commit that touched it; a file no numstat accounts for
  raises `Unattributed`.
- `CommitScope` refuses `#hunks` and `#base_ref` deliberately, with a spec
  (`changeset_spec.rb:661-676`) — so `Marks#reconcile` can never be handed a filtered changeset.
  `Partition` inherits that protection only if it also withholds them.
- **Four sites hardcode a scope name**, not three: `CLI::Review#default_scope`
  (`review.rb:136`), `Command::Review::DEFAULT_SCOPE` (`command/review.rb:54`),
  `Tools::RequestReview::SCOPE = :cumulative` (`request_review.rb:100`, used at `:620`), and
  **`exe/lain:174`** — `method_option :scope, enum: %w[commits cumulative]`. Thor rejects an
  unlisted value *before* any registry is consulted, so the enum must move too or
  `--scope by_directory` fails at the CLI layer with the registry none the wiser.
- **Five** spec files build `Struct.new(:files, :by_commit)` doubles — verified by grep, not by
  report: `surface/neovim_spec.rb:136`, `review_view_spec.rb:52`, `frontend/neovim_spec.rb:615`,
  `surface/text_spec.rb:22`, `frontend/neovim/changeset_diff_spec.rb:360`. A sixth commonly-cited
  site, `shared_examples/review_surface.rb:338`, is **not a double** — it is the error-message
  String `"changeset: must answer #files and #by_commit for the rendering laws"`, and it also
  needs updating.
- Specs pinning the vocabulary: `bounds_spec.rb:143-149,159-162`, `session_spec.rb:342-346`,
  `text_spec.rb:184-186`, `review_view_spec.rb:113-115,159`,
  `shared_examples/review_surface.rb:390,400,433`.
- There is **no `origin/main`** ref in this clone; worktrees fork from local `main`.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only — never under a card's **Files**):
  `lib/lain.rb`, `lib/lain/review.rb`, `.rubocop.yml`, `lain.gemspec`, `spec/spec_helper.rb`.
  `exe/lain` is shared **except** for A3, which owns its `--scope` enum as card scope (see A3).
- A new lib file, its index line and its spec land in **one** commit (CLAUDE.md), so the
  orchestrator applies each wiring line with the card that needs it.
- Check the example **count** against the pre-chunk baseline after each wave, not just the
  failure count — a dead worker reports as "fewer examples, 0 failures".

## Open decisions

None. Two decisions were taken during planning and are recorded so they are not reopened as
oversights:

- **`Partition` carries a small core plus a per-strategy detail, not `CommitScope`'s five
  members.** Making a directory partition answer `sha`, `body` and `numstat` means three lies on
  every non-commit strategy, and `bounds.rb:247` and `review_view.rb:393,413` both render from
  them. A1 settles the shape.
- **`by_commit` is removed, not aliased.** A migration alias would be a special case with no
  card scheduled to remove it. A2 moves every reader in one commit — the rename is mechanical
  and the readers are five.

## Waves

```
Wave 1: A1                    (no unmet deps)
Wave 2: A2 (←A1)
Wave 3: A3 (←A2), A4 (←A2)
```

Critical path: **A1 → A2 → A3** (three deep). A2 is the only card that touches production
readers, and it is deliberately one card: `cumulative_advice` (`bounds.rb:262`) makes any split
of it red at the intermediate commit.

## Tasks

### A1 — Give a partition a value and a strategy a port [wave 1] [risk: medium]

**Depends on:** none
**Files:** create `lib/lain/review/partition.rb`, `lib/lain/review/partition/strategy.rb`,
`lib/lain/review/partition/whole.rb`, `lib/lain/review/partition/by_directory.rb`,
`spec/lain/review/partition_spec.rb`, `spec/lain/review/partition/whole_spec.rb`,
`spec/lain/review/partition/by_directory_spec.rb`
**Reuse:** `Changeset::CommitScope` (`changeset.rb:118`) for the members that must survive;
`Review::Surface.check!` and `Surface::MESSAGES` (`surface.rb`) as the precedent for a
duck-probed port with declared arities — reuse its shape, do not invent a third convention
(`CLI::CompactionStrategy#live_tier` is the other);
`MarkedChangeset::CommitRow` (`marked_changeset.rb:186-198`) for what a renderer asks a group
**Shared-file wiring:** `require_relative "review/partition"` in `lib/lain/review.rb`, **before**
`review/changeset`(25)

Introduces the objects without moving any caller onto them — that is A2's job, and keeping them
apart is what lets each be reviewed on its own terms.

**The member set is this card's real decision.** `CommitScope`'s five members are honest for
commits and lies for anything else: a directory has no sha, no body, no numstat. But
`CommitRow` forwards all five, `review_view.rb:393,413` renders `#added`/`#deleted` as scalars,
and `bounds.rb:247` interpolates `scope.sha` into a refusal. So a `Partition` needs a **core**
every strategy can answer honestly — at minimum a `label` (what a heading renders and what a
refusal names) and `files` — plus whatever a commit strategy additionally carries. Decide the
shape here; A2 is where it meets its renderers.

`Partition` must be a `Data` and answer `#with(files:)` — `Bounds#critique_chunks`
(`bounds.rb:286`) calls exactly that, and `/critique` chunking breaks without it. It must
**withhold** `#hunks` and `#base_ref`, for `CommitScope`'s reason (`changeset_spec.rb:661-676`):
a filtered group must be impossible to hand to `Marks#reconcile`.

A strategy answers `#name`, `#partition(changeset) -> [Partition]` and `#advice` — the last
being what a `Bounds` refusal recommends at this strategy, which is what lets A4 delete
`COMMIT_WALK_ADVICE`.

`ByDirectory` ships here, not later: a port whose only implementation is `Whole` (degenerate by
construction) proves nothing, and `ByDirectory` is what makes the member-set decision above
concrete rather than hypothetical. It partitions **any** changeset by `File.dirname` — it needs
no corpus and is testable against an ordinary branch changeset today.

```gherkin
Scenario: a partition survives non-destructive update
  Given a partition carrying three files
  When it is asked for a copy with a different file list
  Then a new partition is returned with the same label and the new files

Scenario: a partition cannot be mistaken for a whole changeset
  Given a partition
  When it is asked for its hunks or its base revision
  Then it answers neither

Scenario: the port refuses an incomplete strategy before it is used
  Given an object answering #name and #partition but not #advice
  When it is checked against the strategy port
  Then it is refused, naming the missing message

Scenario: the port refuses a strategy whose #partition takes the wrong arity
  Given an object answering all three messages but whose #partition takes no arguments
  When it is checked against the strategy port
  Then it is refused, naming the arity

Scenario: the whole strategy yields one partition over every file
  Given a changeset of five files
  When it is partitioned by the whole strategy
  Then one partition is returned carrying all five

Scenario: files group under their directory
  Given a changeset spanning lib/a, lib/b and the repository root
  When it is partitioned by directory
  Then three partitions are returned, each labelled by its directory

Scenario: every file lands in exactly one partition
  Given a changeset of twenty files across six directories
  When it is partitioned by directory
  Then the partitions' files together are the changeset's, with no file in two

Scenario: partitioning is deterministic
  Given any changeset
  When it is partitioned twice by the same strategy
  Then the partitions come back in the same order both times
```
→ spec files: `spec/lain/review/partition_spec.rb`,
`spec/lain/review/partition/whole_spec.rb`, `spec/lain/review/partition/by_directory_spec.rb`

**Escalation triggers:**
- The core member set cannot satisfy both `review_view.rb:393,413` (scalar `#added`/`#deleted`)
  and an honest directory partition, and the only way through is a nil or a zero. A rendered
  zero is a lie a reader cannot tell from a real one — stop and report the shape you reached,
  because A2 and A4 both build on it.
- A strategy needs the `Source` rather than the changeset to partition. A strategy takes a
  changeset; if `ByCommit` looks like it will need a source in A2, say so here — the seam is
  wrong and A2 will inherit it.
- A third "does this collaborator answer the port" convention appears necessary beyond
  `Surface.check!` and `CompactionStrategy#live_tier`. `surface.rb`'s own doc argues against
  exactly that.

---

### A2 — Move every reader from the commit axis to the partition axis [wave 2] [risk: high]

**Depends on:** A1
**Files:** create `lib/lain/review/partition/by_commit.rb`,
`spec/lain/review/partition/by_commit_spec.rb`; modify `lib/lain/review/changeset.rb`,
`lib/lain/review/session/marked_changeset.rb`, `lib/lain/review/bounds.rb`,
`lib/lain/review/surface/text.rb`, `lib/lain/frontend/neovim/review_view.rb`,
`spec/lain/review/changeset_spec.rb`, `spec/lain/review/session_spec.rb`,
`spec/lain/review/bounds_spec.rb`, `spec/lain/review/surface/text_spec.rb`,
`spec/lain/review/surface/neovim_spec.rb`,
`spec/lain/frontend/neovim/review_view_spec.rb`, `spec/lain/frontend/neovim_spec.rb`,
`spec/lain/frontend/neovim/changeset_diff_spec.rb`,
`spec/support/shared_examples/review_surface.rb`
**Reuse:** `Changeset#scopes`/`#owner_of`/`#ownership` (`changeset.rb:315-340`) move **wholesale**
into `ByCommit` — the last-writer-wins rule and the `Unattributed` refusal are behaviour to
preserve, not to redesign; `Surface::Text::SCOPE_RENDERER` (`text.rb:58`) and
`ReviewView::SCOPE_ROWS` (`review_view.rb:122`) as the dispatch shape
**Shared-file wiring:** `require_relative "review/partition/by_commit"` in
`lib/lain/review/partition.rb`

**Deliberately one card**, and the reason is mechanical rather than stylistic: `by_commit` is
read from `cumulative_advice` (`bounds.rb:262`), which is on the *cumulative* path, so any
commit that renames it without moving `bounds.rb` in the same breath is red. The five
production readers and the five spec doubles move together or not at all.

`Changeset#by_commit` becomes `#partitions(strategy)`; the commit-grouping logic leaves
`Changeset` for `ByCommit`; `CommitScope` becomes A1's `Partition`; `CommitRow` follows.

The conservation rules must survive verbatim (`changeset_spec.rb:615-656`), and
`session_spec.rb:519` pins that a `FileRow` is the **same object** under a partition as at whole
scope — a re-render must not be able to show two states for one file.

Five doubles to update, verified by grep: `surface/neovim_spec.rb:136`,
`review_view_spec.rb:52`, `frontend/neovim_spec.rb:615`, `surface/text_spec.rb:22`,
`frontend/neovim/changeset_diff_spec.rb:360`. Also `shared_examples/review_surface.rb:338`,
which is an **error-message String** naming `#by_commit`, not a double.

```gherkin
Scenario: commit grouping behaves exactly as before
  Given a changeset of three commits where one file is touched by two of them
  When it is partitioned by the commit strategy
  Then there is one partition per commit in walk order
  And the overlapping file appears only under the last commit that touched it

Scenario: an unattributable file still refuses loudly
  Given a changeset naming a file no commit's numstat accounts for
  When it is partitioned by the commit strategy
  Then Unattributed is raised, naming the file

Scenario: a file row is shared between the flat and grouped views
  Given a partitioned marked changeset
  When one file's row is read at whole scope and under its partition
  Then they are the same object

Scenario: a changeset partitions by a strategy it was not built with
  Given a changeset
  When it is partitioned by the whole strategy and then by the commit strategy
  Then both answer, and neither returns the other's grouping

Scenario: a grouped rendering names its partitions
  Given a marked changeset partitioned by directory
  When it is presented at grouped scope
  Then each directory label heads its files

Scenario: the two scopes still differ
  Given one marked changeset
  When it is presented whole and then grouped
  Then the whole rendering carries no partition heading

Scenario: a strategy with no renderer fails loudly at load
  Given a strategy registered with no rendering declared for it
  When the surface is loaded
  Then it raises, naming the strategy

Scenario: nothing answers the old message
  When a changeset is asked for by_commit
  Then it does not respond to it
```
→ spec files: `spec/lain/review/partition/by_commit_spec.rb`,
`spec/lain/review/changeset_spec.rb`, `spec/lain/review/session_spec.rb`,
`spec/lain/review/bounds_spec.rb`, `spec/lain/review/surface/text_spec.rb`,
`spec/lain/frontend/neovim/review_view_spec.rb`,
`spec/support/shared_examples/review_surface.rb`

**Escalation triggers:**
- `Changeset#partitions` needs to memoize per strategy, turning `@by_commit ||=`
  (`changeset.rb:229`) into a cache keyed by strategy. That is a new failure mode — a stale
  partition under a re-render — and `#marked` (`session.rb:251`) is deliberately *not* memoized
  for exactly that reason. Stop and confirm rather than inventing a cache.
- `ByCommit` cannot be built without a `Source`, because `ownership` reads `@source.commits`. A
  strategy takes a changeset; if it ends up holding a source, A1's seam was wrong.
- Any of the five doubles needs to be taught a message the surface port does not document
  (`surface.rb:45-46`). That means a surface reads more of the duck than the port declares —
  report the gap rather than widening the double.
- `bounds.rb:247-248`'s `"commit #{scope.sha}"` cannot be made honest for a directory partition
  with the member set A1 chose. A4 owns the *advice*; this card owns the *subject*, and if they
  cannot both be honest the member set needs revisiting.

---

### A3 — Resolve a scope against a strategy registry [wave 3] [risk: high]

**Depends on:** A2
**Files:** modify `lib/lain/review/vocabulary.rb`, `lib/lain/review/session.rb`,
`lib/lain/tools/request_review.rb`, `lib/lain/cli/review.rb`,
`lib/lain/cli/command/review.rb`, `exe/lain`, `spec/lain/review/vocabulary_spec.rb`,
`spec/lain/review/session_spec.rb`, `spec/lain/tools/request_review_spec.rb`,
`spec/lain/cli/review_spec.rb`, `spec/lain/cli/command/review_spec.rb`
**Reuse:** `Session.scope!` (`session.rb:119-124`) as the single validation point both CLI paths
already converge on; `Review::SCOPES`' declare-once discipline and its stated reason
(`vocabulary.rb:86-92`)
**Shared-file wiring:** none — **this card owns `exe/lain:174`'s `--scope` enum as scope**, by
exception to the orchestrator contract, because no other card can make that line correct and
leaving it stale silently breaks the feature at the CLI layer

`SCOPES` becomes the registry of available strategies. `Session.scope!` resolves a name to a
strategy and refuses an unknown one as loudly as today — a typo must not fall through to
whichever branch a bare `==` left as default, which is the whole reason the vocabulary exists.

**Four sites hardcode a scope name and all four must resolve through the registry**:
`review.rb:136`, `command/review.rb:54`, `request_review.rb:100`, and `exe/lain:174`. The last
is the one most easily missed: Thor validates its `enum:` *before* dispatch, so a registry that
knows about `by_directory` while Thor does not means `lain review --scope by_directory` fails
with a Thor error and no registry involvement.

```gherkin
Scenario: an unknown scope is refused by name
  Given a session
  When it is presented at a scope no strategy declares
  Then it raises, naming what was given

Scenario: a newly registered strategy is reachable from the command line
  Given the directory strategy is registered
  When lain review is run with that scope
  Then it is accepted rather than rejected as an unknown flag value

Scenario: the absent flag still resolves through the registry
  Given a review presented with no scope named
  When the default is resolved
  Then it goes through the same resolution an explicit scope does

Scenario: the tool's hardcoded scope resolves through the registry
  Given the implementation review tool
  When it presents its session
  Then the scope it used was resolved, not restated as a literal

Scenario: a typo still fails loudly rather than defaulting
  Given a session presented at "cumulatve"
  When the scope is resolved
  Then it raises rather than rendering the grouped or the flat view
```
→ spec files: `spec/lain/review/vocabulary_spec.rb`, `spec/lain/review/session_spec.rb`,
`spec/lain/tools/request_review_spec.rb`, `spec/lain/cli/review_spec.rb`,
`spec/lain/cli/command/review_spec.rb`

**Escalation triggers:**
- Making `SCOPES` a registry leaves the derive-don't-restate specs
  (`bounds_spec.rb:143-149`, `text_spec.rb:184-186`, `review_view_spec.rb:113-115`) tautological
  rather than falsifiable. Those specs exist so a strategy without a renderer fails loudly;
  report what still fails when one is removed, and if nothing does, the registry has eaten the
  property it was supposed to generalize.
- Resolution needs to consult a *source* to know which strategies apply. `Session.scope!` is a
  class-level validator with no collaborators; if applicability is source-dependent the check
  belongs at `#present` instead. Confirm before moving it — `chunk-survey-corpus.md` depends on
  where this lands.
- Changing `request_review.rb` ripples into epic-tier specs. This card's scope is scope
  resolution only; an epic behaviour change means the seam is wider than planned.

---

### A4 — Let a refusal name the strategy, and a ceiling be absent [wave 3] [risk: medium]

**Depends on:** A2
**Files:** modify `lib/lain/review/bounds.rb`, `spec/lain/review/bounds_spec.rb`
**Reuse:** `Bounds::Size.lines_in` (`bounds.rb:168`); the short-circuit ordering that decides on
a file count and measures only on the refusal path (`bounds.rb:236-266`);
`Agent::Budget` as the precedent for a ceiling that raises rather than returning a readable value
**Shared-file wiring:** none

Two changes, both small, held apart from A2 so the mechanical rename and the policy change are
reviewed separately.

First: advice comes from the strategy's `#advice`, replacing `COMMIT_WALK_ADVICE`,
`NO_NARROWER` and `NO_PRESENTABLE_SCOPE` (`bounds.rb:120-128`) — three constants that name
"commit" in prose and would tell a directory reviewer to present per commit.

Second: a ceiling of `nil` means **unbounded**, an explicit opt-out. `nil` must be
distinguishable from "not configured": a ceiling that silently became unbounded is precisely the
failure `Bounds` exists to prevent, and the class doc is emphatic that it never truncates,
samples or elides.

The short-circuit's promise must survive: the *decision* to refuse still reads a file count
only, and hunks are summed only when composing the message.

```gherkin
Scenario: a refusal recommends what the strategy offers
  Given a view over the file ceiling, partitioned by directory
  When it is checked
  Then the refusal names the directory partitioning and never the word commit

Scenario: a nil ceiling presents what a number would refuse
  Given a view of 600 files and a nil file ceiling
  When it is checked
  Then it presents

Scenario: an absent ceiling is not silently unbounded
  Given a Bounds built with no file ceiling argument at all
  When it is checked against an oversized view
  Then it refuses, because the default is a number and not nil

Scenario: deciding to refuse still costs no hunk walk
  Given a view whose file count alone exceeds the ceiling
  When it is checked
  Then no hunk is read to reach the decision
```
→ spec file: `spec/lain/review/bounds_spec.rb`

**Escalation triggers:**
- Making a ceiling nillable needs a `nil` guard at more than one call site. That is the Null
  Object smell CLAUDE.md names by example — stop and report rather than repeating the guard.
- `each_critique_chunk` (`bounds.rb:285`) cannot pack a partition because `#with(files:)` is
  unavailable. A1 requires a `Data`; if that did not hold, `/critique` chunking is broken and
  this is where it surfaces.
- The last hunk-walk on the *success* path cannot be removed without changing what `Bounds`
  measures. Note it and move on — **`chunk-survey-corpus.md` owns that problem**
  (`Size.lines_in` is evaluated eagerly as a `guard!` argument at `bounds.rb:235`, so every
  successful presentation walks every hunk). Do not fix it here; a corpus is what makes it
  expensive, and the fix needs a cheap size a source can answer.

## Integration checks

- `bundle exec rake pspec` green, with the example **count** compared against the pre-chunk
  baseline.
- `bundle exec rubocop` clean — bare invocation only; never name a `.toml` on the command line.
- `pre-commit run --all-files`, including `yard-lint`: A1 and A2 both reopen `Data.define`
  classes, and `Documentation/DuplicateNamespaceComment` is what catches a second docstring.
- `bundle exec rspec --tag core` and `bundle exec rake compile` as regression checks — no Rust
  or daemon code changes here.
- Grep for surviving `by_commit` references across `lib/`, `exe/` and `spec/` — A2 removes the
  message rather than aliasing it, so any survivor is a miss.
- **Manual pass owed to Joel:** `lain review --scope by_directory` against a real branch, and
  the same in the cockpit via `/review`, confirming the sidebar groups by directory and that an
  oversized directory partition refuses with a sentence naming the directory rather than a
  commit sha.
