# Survey: reviewing a corpus of files as they stand

status: draft
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds · Jeremy Evans · Sandi Metz · Richard Schneeman · Aaron Patterson

**Depends on `planning/specs/chunk-partition-strategy.md` having LANDED.** Every card here
assumes `Partition::Strategy`, `ByDirectory` and the scope registry exist. Do not start this
chunk against a tree where `Changeset` still answers `#by_commit`.

## Intent

`/survey <path>` — review a body of files **as they stand**, with no diff, no base and no commit
walk, reusing the whole review model below `Source`: hunk keys, marks, anchors, annotations,
`Session`, every surface, the docent. Works on a git repository, a LaTeX directory, or a `docs/`
folder read for prose quality; the lens is supplied, not implied by the command.

The corpus is **lazy** (a file is chunked when it is read, not when the survey opens) and
**accretes** (files join as the human opens them), which is the shape a 95k-line project
actually gets reviewed in.

Adds the corpus arm of the review surface. `ROADMAP.md` has no line for this yet — the
orchestrator should add one when this lands rather than an agent hunting for a citation.

## Grounding

Verified 2026-08-07 against `main` at `2e26748` by parallel Explore passes, two executable
spikes (`spike/survey-seam/`, gitignored) and a review-panel counter-check that overturned two
of the plan's own first-draft claims. Line numbers were re-checked after that pass; where a
range is cited it was read, not remembered.

**What the spikes established as fact:**

- **Synthesizing diff bytes and consuming model values produce byte-identical results** — same
  hunk keys, same `Session.digest`, same 5,796 anchors, same headings, over 14 real markdown
  files. This chunk takes the model-values route because the byte route forces a permanent fake
  commit walk, not because the byte route is risky.
- **History rewriting does not move a mark.** Reorder, squash, split and reword all left base
  unchanged, digest unchanged, 2/2 marks kept — because `Changeset` reads a **two-tree** diff
  (`git diff <merge-base> <head>`) and `Session.digest` excludes head (`session.rb:88-94`). The
  commit walk feeds only the grouped view.
- **A rebase discards every mark**, by two independent mechanisms: `Marks::BaseMismatch` fires
  on any base move before keys are consulted; and separately, a neighbour's edit inside the
  `-U3` context window (`Source::LocalBranch::DIFF_HYGIENE`, `local_branch.rb:44-47`) rewrites a
  hunk's content key with no conflict and no change to the reviewer's own lines. `Review::Delta`
  (range-diff) was built for exactly this and **is not wired** — every `Delta` reference in
  `lib/` is `Epic::Intake::Delta`, a different class.
- **A rename discards marks in both worlds.** `Hunk#path_frame` (`hunk.rb:68`) puts the path in
  the key; a rename+edit measured 0/1 keys surviving on the *diff* side today. An existing shared
  property, pinned here rather than decided.

**The three forcing functions** — why laziness is a design problem, not an optimization:

- `Session.digest` → `MarkedChangeset.keys_by_path` (`marked_changeset.rb:77-79`) →
  `changeset.hunks`.
- `MarkedChangeset.of` (`marked_changeset.rb:87-88`) → `keys_by_path` **and**
  `marks.states(changeset)`, each walking every hunk.
- **`Bounds#check_cumulative!` (`bounds.rb:233-238`)** — and this is the one that defeats a naive
  fix. `guard!(Size.lines_in(files), ...)` evaluates its argument eagerly, and `Size.lines_in`
  (`bounds.rb:168`) is `files.sum { |file| file.hunks.sum { ... } }`. The file-count
  short-circuit fires only on the **refusal** path, so every *successful* presentation walks
  every hunk. B3 owns this; without it, laziness ships and nothing exercises it.

A file with no hunks already renders `unreviewed` via `HUNKLESS` (`marked_changeset.rb:52-58`),
so an unchunked file has an honest state — the coupling to break is *identity*, not state.

**Other facts cards depend on:**

- `Changeset#files` is the sole parse site: `@files ||= Parser.new(@source.diff).files.freeze`
  (`changeset.rb:134`). The only other `source.diff` consumer in `lib/` is
  `request_review.rb:604`, which needs raw bytes for `Epic::Intake::Prose#byte_digest`, and
  reaches a source only through `Source::Repository#source` (`source.rb:153`) — which constructs
  `LocalBranch` and nothing else. A corpus can never arrive there.
- `Session.digest`/`digest_parts` are at `session.rb:103` and `:109-114`; `regenerated?` at
  `:235`. `digest_parts` is a `private_class_method` reading `MarkedChangeset.keys_by_path`.
- **There is exactly one `Changeset` class**, parameterised by its source (`changeset.rb:126-128`).
  So `changeset.digest_parts` cannot dispatch differently for a corpus — B1's receiver must be
  the **source**, not the changeset (see Open decisions).
- `spec/support/shared_examples/review_source.rb`'s reversed-diff detector (`:336-370`) and its
  binary detector (`:376-389`) are **two-witness cross-checks** — `#diff` bytes against
  `#commits` numstat. A corpus answers neither, so no universal port group can contain them.
  They are diff-source laws (see Open decisions).
- `ChangedFile` is a frozen `Data` (`changeset.rb:48-56`); `Data` instances are frozen and
  `instance_variable_set` raises `FrozenError`. `Changeset#hunks` is `files.flat_map(&:hunks).freeze`
  (`changeset.rb:141`), and `Hunk.keys` (`hunk.rb:39-45`) `tally`s twice over a whole file's
  hunks — so it needs the batch materialised. An `Enumerator` does not solve this.
- `Structural::Queries.path_for` (`queries.rb:62`) hardcodes `symbols.scm` and `fetch(language)`
  (`:46`) is language-keyed only; `file_symbols.rb:109` calls it positionally. A second query
  name is a real change to `Queries`, not "one allowlist entry". Adding `:markdown` to
  `SUPPORTED_LANGUAGES` (`queries.rb:36`) changes **production** behaviour: `FileSymbols` with
  `language: "markdown"` raises `Unsupported` today (a named user error) and would raise
  `Missing` after (documented as "a packaging bug, not a user error").
- `tree-sitter-md 0.5.3` is compiled in via `ast-grep-language = "=0.44.1"`, and
  `Ext::TreeSitter.query(src, "markdown", "(section) @s")` was **run and returns matches**. No
  Rust changes needed.
- `Lain::Sensitivity#classify(path) -> Verdict` (`sensitivity.rb:419`) has landed. Hard-refusing
  a `:denied` path before approval is secret-boundary T12 and has **not** landed —
  `Policy#gates?` routes denied and gated alike to approval.
- `Lain::Project` requires `cwd` under `root` (`project.rb:103-108`), so it cannot represent a
  survey outside the session's project. `Sensitivity` takes `home:`/`cwd:` with no containment
  invariant and is the right layer.
- No gitignore-aware or binary-detecting walk exists in `lib/`.
  `Tools::Grep::RubySearch#files_under` (`grep.rb:114-121`) is the in-process template;
  `crates/lain-core/src/grep.rs:275` has the `ignore`-crate version but ships disabled.
- `Paths#sessions_dir` keys on `sha256(realpath(Dir.pwd))[0,12]` and does not care whether the
  directory is a repository — no new XDG convention needed.
- `Session.new` is `private_class_method` (`session.rb:216`) and memoizes `@digest` (`:219`),
  `@keys_by_path` (`:347`) and `@hunk_keys` (`:349`). `#marked` (`:251`) is deliberately **not**
  memoized, documented as "a stale view is exactly the defect a marker exists to prevent".
- `lain.rb` requires `lain/cli`(76) **before** `lain/review`(86), so every `Lain::Review::*` name
  inside `Lain::CLI` is read from a method body. `lib/lain/review.rb` requires `source`(23)
  before `changeset`(25).
- There is **no `origin/main`** ref in this clone; worktrees fork from local `main`.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only — never under a card's **Files**):
  `lib/lain.rb`, `lib/lain/review.rb`, `lib/lain/survey.rb`, `lib/lain/cli.rb`,
  `lib/lain/cli/command.rb`, `lib/lain/cli/command/surface.rb`, `exe/lain`, `.rubocop.yml`,
  `lain.gemspec`, `spec/spec_helper.rb`. `lib/lain/review/source.rb`'s **module body** is B2's
  scope; its `require_relative` lines are wiring.
- A new lib file, its index line and its spec land in **one** commit (CLAUDE.md).
- Check the example **count** against the previous wave, not just the failure count.

## Open decisions

None. Three questions a panel review identified as unbuildable-if-unanswered were settled during
planning; they are recorded here so no agent reopens them mid-card:

- **A source supplies its own identity parts.** There is one `Changeset` class, so polymorphism
  on the changeset does not exist, and a type test in `Session` is the shape `source.rb`'s own
  doc condemns. The port therefore gains `#identity_parts` and `#identity_scheme` (B2). A diff
  source answers exactly what `digest_parts` composes today, so `/review`'s digests stay
  bit-identical; a corpus answers `(path, content digest)` pairs.
- **The two-witness cross-checks are diff-source laws, not port laws.** The reversed-diff and
  binary-agreement examples hold `#diff` against `#commits`; a corpus has neither witness, so no
  universal group containing them can admit one. B2 moves them into a diff-source group and
  says so, rather than an agent discovering it and stopping.
- **`Bounds` must stop forcing hunks on the success path**, which is a change to `Bounds`, not
  to the corpus (B3). Without it, T-for-laziness is decorative.

## Waves

```
Wave 1: B1, B4, B5, B6        (no unmet deps)
Wave 2: B2 (←B1), B7 (←B4)
Wave 3: B3 (←B2), B8 (←B2,B5,B6), B9 (←B7)
Wave 4: B10 (←B8), B11 (←B3,B8)
Wave 5: B12 (←B10,B11)
Wave 6: B13 (←B12), B14 (←B12,B11)
```

Critical path: **B1 → B2 → B8 → B10 → B12 → B13** (six deep). B2 is the card every other
ultimately waits on, and it is the one whose contract question was the panel's blocker — it is
answered in Open decisions above, so the card is buildable rather than escalating.

## Tasks

### B1 — Pin that history rewriting preserves marks [wave 1] [risk: low]

**Depends on:** none
**Files:** create `spec/lain/review/seams/history_rewrite_spec.rb`
**Reuse:** `spec/lain/review/delta_spec.rb:8-30` (the build-once-copy-per-example rebase/amend
fixture and its `git` helper); `spec/support/seed_repo.rb`;
`Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB`
**Shared-file wiring:** none

A **characterization** card: it pins behaviour that already works and that nothing tests at the
seam level. `session_spec.rb:157` pins the digest *function* against a fabricated
`head_ref: "z" * 40` — a double. Nothing pins the property against real git, so changing
`LocalBranch#diff` to a walk-derived diff, or dropping `-U3` from `DIFF_HYGIENE`
(`local_branch.rb:44-47`), leaves every existing spec green while destroying it.

Commit dates **must** be pinned (`GIT_AUTHOR_DATE`/`GIT_COMMITTER_DATE`), or shas vary per run
and the base-unchanged assertion is noise. A first spike attempt made exactly that mistake and
reported four false positives.

Assertions must be made at the **`Changeset`** level (files, hunk keys, digest) and not only at
`LocalBranch`'s — otherwise B2, which changes what `Changeset` *reads* rather than what
`LocalBranch` *produces*, could break it entirely while this stays green.

```gherkin
Scenario Outline: rewriting history leaves every mark standing
  Given a feature branch of two commits reviewed against main, with every hunk marked reviewed
  When the history is rewritten by <operation>
  Then the merge base is unchanged
  And the changeset digest is unchanged
  And every mark survives reconciliation
  Examples: reordering the commits | squashing them into one |
            splitting one in two | rewording a commit message

Scenario: main advancing without a rebase changes nothing
  Given a feature branch reviewed against main with every hunk marked reviewed
  When main gains an unrelated commit and the feature branch is not rebased
  Then the merge base is unchanged and every mark survives

Scenario: a rebase discards every mark, whatever the hunk keys say
  Given a feature branch reviewed against main with every hunk marked reviewed
  When main gains a commit far from the reviewed hunk and the feature is rebased onto it
  Then the hunk content keys are unchanged
  But reconciliation raises BaseMismatch and no mark survives

Scenario: a neighbour editing inside the context window rewrites the key
  Given a feature branch whose hunk sits at line 10, reviewed against main
  When main edits line 8 and the feature is rebased onto it
  Then the hunk content key differs, though the reviewer's own lines never moved

Scenario: renaming a file discards its marks
  Given a reviewed file with a marked hunk
  When the file is renamed and edited
  Then no mark survives, because the path is in the key
```
→ spec file: `spec/lain/review/seams/history_rewrite_spec.rb`

**Escalation triggers:**
- The reorder or squash scenario is RED against today's `main`. That contradicts the measured
  spike result — stop; do not relax the assertion to make it pass.
- The rebase scenario raises something other than `Marks::BaseMismatch` (an `Unattributed`,
  say). Grounding says BaseMismatch fires first, and a different order invalidates B10's
  reasoning about why corpus marks survive.
- The context-window scenario comes out with keys the SAME. That would mean `-U3` context is not
  in `Hunk#body` after all, contradicting `hunk.rb:56-62` and removing a documented limitation.

---

### B2 — Hand the changeset model values, and say which laws are diff laws [wave 2] [risk: high]

**Depends on:** B1
**Files:** modify `lib/lain/review/changeset.rb`, `lib/lain/review/source.rb`,
`lib/lain/review/source/local_branch.rb`, `lib/lain/review/source/github_pr.rb`,
`lib/lain/review/session.rb`, `spec/support/shared_examples/review_source.rb`,
`spec/lain/review/changeset_spec.rb`, `spec/lain/review/source/local_branch_spec.rb`,
`spec/lain/review/source/github_pr_spec.rb`, `spec/lain/review/session_spec.rb`
**Reuse:** `Changeset::Parser` (`changeset.rb:361+`) moves wholesale, not rewritten;
`LocalBranch#diff`'s memoization shape (`local_branch.rb:87`); `GithubPr`'s delegation pattern
(`github_pr.rb:285,290,306`); `Session.digest_parts` (`session.rb:109-114`) — its composition
moves to the diff sources unchanged; `Review::Keying.digest` and its golden-vector spec
**Shared-file wiring:** `lib/lain/review/source.rb`'s `require_relative` lines are unchanged by
this card; its module body is card scope

The seam everything rests on. Three changes, one responsibility: **the port hands down model
values instead of bytes.**

1. `Source` gains `#files -> Array<ChangedFile>`. `Changeset#files` becomes `@files ||=
   @source.files` and stops parsing. `Parser`, `ChangedFile` and `Unparseable` move so the diff
   sources own them.
2. `Source` gains `#identity_parts` and `#identity_scheme`. `Session.digest` asks the changeset,
   which asks its source — **no type test anywhere**, because the object that has the parts
   supplies them. A diff source composes exactly what `digest_parts` composes today, so every
   `/review` digest is bit-identical and every journaled `changeset_digest` still joins.
3. The port's law group splits. Assertions about **shape and self-consistency** stay universal;
   the **two-witness cross-checks** — reversed-diff (`review_source.rb:336-370`) and
   binary-agreement (`:376-389`) — and the sha-format and unified-diff-syntax assertions
   (`:151-157`, `:196-199`, `:258-324`) move into a group only diff sources include. This is
   settled (Open decisions): those laws hold `#diff` against `#commits`, and a source with
   neither witness cannot satisfy them. **Do not weaken the universal half to keep them** — a
   port law that cannot fail is worse than a law in the right place.

**Load order** is the concrete obstacle: `review.rb` requires `source`(23) before `changeset`(25),
so `ChangedFile`/`Parser` are undefined when `local_branch.rb` loads. Either move them ahead of
`source` in the index (orchestrator wiring) or name them from a method body — `LocalBranch`
already does that for `Isolation::Worktree` (`local_branch.rb:228-234`).

**`GithubPr` must not delegate `#files` to `local`.** Its `#diff` has two producers
(`github_pr.rb:294`) and the API-served bytes never reach `LocalBranch`; delegating would
silently parse the locally regenerated diff instead.

```gherkin
Scenario: a changeset never parses bytes it was not given
  Given a source answering #files with two changed files
  When the changeset is asked for its files
  Then it returns them without ever calling #diff

Scenario: a GitHub source parses the bytes it actually served
  Given a pull request whose diff came from the combined-diff API
  When its files are read
  Then they reflect the API-served bytes, not a locally regenerated diff

Scenario: a branch review's address does not move
  Given a changeset over a branch
  When its digest is taken
  Then it equals the digest recorded before this card, byte for byte

Scenario: identity comes from the source, without asking what kind it is
  Given a session over any source
  When its digest is taken
  Then the parts came from the source and nothing type-tested it

Scenario: the byte consumer is reachable only through a local branch
  When Source::Repository resolves a source
  Then it is a LocalBranch, asserted mechanically rather than documented

Scenario: the diff-source laws still fail a reversed diff
  Given a diff source answering a reversed changeset
  When it is held against the diff-source law group
  Then it fails

Scenario: the universal laws still fail a source that contradicts itself
  Given a source whose files name paths its own file_at cannot read on either side
  When it is held against the universal law group
  Then it fails
```
→ spec files: `spec/lain/review/changeset_spec.rb`,
`spec/lain/review/source/{local_branch,github_pr}_spec.rb`,
`spec/lain/review/session_spec.rb`, `spec/support/shared_examples/review_source.rb`

**Escalation triggers:**
- B1's characterization specs go red. The parser move must not change observable behaviour —
  stop rather than adjusting B1.
- Any existing digest fixture or golden vector changes value. `/review` addresses must be
  bit-identical; a moved digest means the diff source's `#identity_parts` does not compose what
  `digest_parts` composed.
- After the split, the **universal** group cannot fail *any* wrong implementation — it has
  become shape-checking with no discriminating power. Report what is left; a vacuous port
  contract is a worse outcome than an over-strict one.
- `request_review.rb:604` needs a change to keep working. `#diff` is untouched by this card; if
  it breaks, the port change is wider than planned.

---

### B3 — Bound a view without parsing it [wave 3] [risk: high]

**Depends on:** B2
**Files:** modify `lib/lain/review/bounds.rb`, `lib/lain/review/changeset.rb`,
`spec/lain/review/bounds_spec.rb`, `spec/lain/review/changeset_spec.rb`
**Reuse:** `Bounds::Size.lines_in` (`bounds.rb:168`); the existing short-circuit ordering and
its documented promise (`bounds.rb:250-266`); the `nil`-as-unbounded ceiling from
`chunk-partition-strategy.md`'s A4
**Shared-file wiring:** none

The card that makes B8's laziness real rather than decorative.

`check_cumulative!` (`bounds.rb:233-238`) passes `Size.lines_in(files)` as a `guard!`
**argument**, and Ruby evaluates arguments eagerly. `Size.lines_in` sums `file.hunks` over every
file. So today the file-count short-circuit fires only on the refusal path, and every
*successful* presentation walks every hunk — which is exactly the work a lazy corpus exists to
avoid, on exactly the path that matters.

The fix is that a view answers its **size** without being asked for its units. A file can report
its line count from what the source already knows (a corpus knows a file's length from the walk;
a diff source knows it from the hunks it already parsed) without materialising hunks. Whatever
shape that takes, the guard must consult it lazily — the line ceiling must not be measured until
the file-count guard has passed.

`Bounds`' stated promise is preserved and strengthened: the decision to refuse still reads a
file count, and now the decision to *present* reads no hunk either.

```gherkin
Scenario: presenting a view within the ceilings reads no hunks
  Given a changeset of fifty files well inside both ceilings
  When it is checked for presentation
  Then no file's hunks were materialised

Scenario: the line ceiling still refuses what it always refused
  Given a changeset of forty files of a thousand lines each
  When it is checked against the default line ceiling
  Then it refuses, naming the measurement and the ceiling

Scenario: deciding on file count alone does not measure lines
  Given a view whose file count alone exceeds the ceiling
  When it is checked
  Then no line count was computed to reach the decision

Scenario: a refusal message may measure what the decision did not
  Given a view refused on file count whose advice needs a per-partition measurement
  Then the message is still composed, and the promise is about the DECISION not the message
```
→ spec files: `spec/lain/review/bounds_spec.rb`, `spec/lain/review/changeset_spec.rb`

**Escalation triggers:**
- A cheap size cannot be obtained without the source reading every file anyway — for a corpus
  that means a `stat` per file, which may be acceptable, or a full read, which is not. Report
  the cost; if it is a full read, laziness is not achievable and B8's premise needs revisiting
  before B8 is reviewed.
- Making the line guard lazy requires restructuring `guard!` in a way that changes what a
  refusal message says. The messages are covered by `bounds_spec.rb` and each was written
  against a specific reported failure — a changed sentence needs saying, not silently shipping.
- The diff sources cannot answer a size without parsing, making this a corpus-only optimisation
  behind a conditional. That is the special-casing this codebase refuses; stop and report.

---

### B4 — Chunk any file into gap-free paragraph runs [wave 1] [risk: low]

**Depends on:** none
**Files:** create `lib/lain/survey/chunker.rb`, `lib/lain/survey/chunker/paragraphs.rb`,
`lib/lain/survey/unit.rb`, `spec/lain/survey/chunker/paragraphs_spec.rb`,
`spec/lain/survey/unit_spec.rb`, `spec/support/shared_examples/survey_chunker.rb`
**Reuse:** `Changeset#lines`'s `delete_suffix`-not-`chomp` rule (`changeset.rb:257`) and its
reason — a CRLF file's trailing `\r` is content
**Shared-file wiring:** `require_relative "lain/survey"` in `lib/lain.rb`, immediately **before**
`lain/review`(86); new `lib/lain/survey.rb` index requiring `survey/unit` then `survey/chunker`

The universal floor every other chunker falls back to. A `Unit` is `(path, label, start_line,
lines)`.

**This card authors the coverage contract** that B7 and B9 are then held to: units are ordered,
and *every line of the file belongs to exactly one unit*. Not a line count — reconstruct the
file by concatenating units in order and compare to the input, which catches reordering and
duplication as well as gaps. A line in no unit is never shown, so marking the file reviewed
would be a lie, which is `Bounds`' own never-truncate discipline one tier down.

```gherkin
Scenario: units reconstruct the file exactly
  Given any text file
  When it is chunked
  Then concatenating the units in order yields the original file byte for byte

Scenario: runs are packed toward the ceiling rather than emitted one per paragraph
  Given a file of ten short blank-line-separated paragraphs
  When it is chunked with a ceiling above their total
  Then they are packed into fewer units than there are paragraphs

Scenario: an unsplittable run exceeds the ceiling rather than being cut
  Given a file whose single paragraph is twice the ceiling
  When it is chunked
  Then one over-ceiling unit is emitted rather than a unit cut mid-paragraph

Scenario: a CRLF file round-trips
  Given a file whose lines end in carriage-return line-feed
  When it is chunked
  Then reconstruction is byte-identical, carriage returns included

Scenario: an empty file yields no units
  Given an empty file
  When it is chunked
  Then no units are produced and the coverage contract still holds
```
→ spec files: `spec/lain/survey/chunker/paragraphs_spec.rb`, `spec/lain/survey/unit_spec.rb`
→ shared contract: `spec/support/shared_examples/survey_chunker.rb`

**Escalation triggers:**
- The coverage contract cannot be stated without knowing the file's type. It must be
  type-agnostic — every later chunker is held to it — so a type-dependent contract means the
  seam is wrong.
- A `Unit` needs to be mutable to be useful to B8's laziness. It must not be: CLAUDE.md's
  deep-freeze rule and `Ractor.shareable?` both apply, and B8 owns its own memoisation.

---

### B5 — Walk a directory into reviewable files [wave 1] [risk: medium]

**Depends on:** none
**Files:** create `lib/lain/survey/walk.rb`, `lib/lain/survey/withheld.rb`,
`spec/lain/survey/walk_spec.rb`, `spec/lain/survey/withheld_spec.rb`
**Reuse:** `Tools::Grep::RubySearch#files_under` and `#skip?` (`grep.rb:114-121`) as the
in-process walk template; `Lain::Sensitivity#classify` (`sensitivity.rb:419`) and
`Verdict#denied?`/`#gated?`; `crates/lain-core/src/grep.rs:275` for the binary-detection shape
(reference only — this card stays in process)
**Shared-file wiring:** `require_relative "survey/walk"` and `"survey/withheld"` in
`lib/lain/survey.rb`

Answers an ordered list of readable paths under a root, plus **a named value for what was
withheld and why** — `Withheld` is its own object because four later cards consume it (B8
decides what withheld paths do to `#files`, B12/B14 render them, B13 refuses an added denied
path with a report). Left as "the walk names it somehow", four agents in four worktrees invent
four answers.

A survey reads **every file it lists**, categorically unlike a diff review reading only what
changed, so every candidate routes through `Sensitivity`. Note that `Sensitivity::Policy#gates?`
today routes denied and gated alike to approval (secret-boundary T12 is unlanded), so this card
consults `#classify` directly rather than assuming a hard refusal exists upstream.

The walk must also report a cheap **size** per path, because B3 needs one and re-reading every
file to get it defeats the purpose.

```gherkin
Scenario: a denied path never enters the corpus
  Given a directory containing an SSH private key
  When the directory is walked
  Then that path is absent from the files, and present in the withheld with its reason

Scenario: a gated path is withheld rather than silently dropped
  Given a directory containing a .env file
  When the directory is walked
  Then it is withheld, naming that it is credential-shaped

Scenario: binary files are excluded and reported
  Given a directory containing a PNG and a Ruby file
  When the directory is walked
  Then only the Ruby file is in the files, and the PNG is withheld as binary

Scenario: the walk reports a size without reading file bodies
  Given a directory of fifty files
  When it is walked
  Then every path carries a line-or-byte size and no body was read into memory

Scenario: the walk is deterministic
  Given any directory
  When it is walked twice
  Then both walks return the same paths in the same order, and the same withheld
```
→ spec files: `spec/lain/survey/walk_spec.rb`, `spec/lain/survey/withheld_spec.rb`

**Escalation triggers:**
- `Sensitivity.new` cannot be built for a path outside the session's cwd without the
  classification becoming ambiguous. That is a policy question, not an implementation detail —
  stop.
- A cheap size cannot be had without reading the file (e.g. line count needs a read). Report
  what is cheap — B3 is built on this answer and a byte size may have to do.
- A path classifies `:denied` that a human would obviously want surveyed. Report it; the rule
  table belongs to `Sensitivity`, not to an exception list here.

---

### B6 — Let a changed file supply its hunks on demand [wave 1] [risk: high]

**Depends on:** none
**Files:** create `lib/lain/review/lazy_file.rb`, `spec/lain/review/lazy_file_spec.rb`
**Reuse:** `Changeset::ChangedFile` (`changeset.rb:48-56`) — the messages that must be answered
identically (`old_path`, `new_path`, `path`, `binary?`, `status`, `hunks`);
`Changeset::ChangedFile::STATUSES` and its `fetch` discipline
**Shared-file wiring:** `require_relative "review/lazy_file"` in `lib/lain/review.rb`, after
`review/changeset`(25)

`ChangedFile` is a frozen `Data`, `Data` instances are frozen, and `instance_variable_set` raises
`FrozenError` — so a memo-on-self is impossible. An `Enumerator` does not rescue it either:
`Changeset#hunks` is `files.flat_map(&:hunks).freeze` (`changeset.rb:141`), which drains it, and
`Hunk.keys` (`hunk.rb:39-45`) `tally`s twice over a whole file's hunks, so the batch must be
materialised anyway. A drained-once-re-yielded-twice Enumerator is either re-chunking or
memoising.

So laziness needs its **own type**: a file answering `ChangedFile`'s messages, holding a
chunk-supplying callable, memoising its hunks on first demand. It is not a `Data` and does not
pretend to be deeply frozen — and that is the card's whole risk, so it is isolated here rather
than smuggled into B8.

`Ractor.shareable?` is where this must be honest: a `ChangedFile` is shareable and this is not.
Establish and **spec** what is true of it rather than leaving a reader to assume the value-object
guarantees carry over.

```gherkin
Scenario: a lazy file answers the changed-file messages
  Given a lazy file over a path
  When it is asked its path, status and binary-ness
  Then it answers as a changed file would, without chunking

Scenario: hunks are produced once, on first demand
  Given a lazy file whose chunker counts its calls
  When its hunks are read twice
  Then the chunker ran once

Scenario: constructing a lazy file chunks nothing
  Given a chunker that raises if called
  When a lazy file is constructed over it
  Then no error is raised

Scenario: it declares honestly whether it is shareable
  Given a lazy file
  When it is asked whether it is Ractor-shareable
  Then the answer is spec'd rather than assumed
```
→ spec file: `spec/lain/review/lazy_file_spec.rb`

**Escalation triggers:**
- A lazy file cannot answer `#status` without chunking. Status comes from the path pair, not the
  hunks (`changeset.rb:92-98`) — if it does, the seam is wrong.
- Anything downstream `Marshal`s, `freeze`s or `Ractor`-shares a `ChangedFile` and would now get
  a non-shareable object. `spec/lain/event_spec.rb`'s shareability discipline is the precedent
  for how seriously this is taken — stop and report the call site.
- Making this type means `Changeset#files` returns a mixed array (lazy for a corpus, `Data` for
  a diff). If any consumer branches on which, that is the special-casing to report.

---

### B7 — Chunk markdown by its own section tree [wave 2] [risk: medium]

**Depends on:** B4
**Files:** create `lib/lain/survey/chunker/markdown.rb`,
`lib/lain/structural/queries/markdown/sections.scm`,
`spec/lain/survey/chunker/markdown_spec.rb`; modify `lib/lain/structural/queries.rb`,
`spec/lain/structural/queries_spec.rb`, `spec/lain/tools/file_symbols_spec.rb`
**Reuse:** `Tools::FileSymbols` + `Structural::Queries.fetch` + `Ext::TreeSitter.query` as the
precedent; `lib/lain/structural/queries/ruby/symbols.scm` for authoring style;
`spec/support/shared_examples/survey_chunker.rb` from B4
**Shared-file wiring:** `require_relative "survey/chunker/markdown"` in
`lib/lain/survey/chunker.rb`

`tree-sitter-md` is compiled in and `Ext::TreeSitter.query(src, "markdown", "(section) @s")` was
**run and returns matches** — no Rust, no new dependency.

But the `Queries` change is larger than "one allowlist entry", and this card owns the whole of
it. `path_for` (`queries.rb:62`) hardcodes `symbols.scm` and `fetch(language)` (`:46`) is
language-keyed; a second query name means generalising both, and `file_symbols.rb:109` calls
`fetch` positionally. **And the allowlist entry changes production behaviour**: `FileSymbols`
with `language: "markdown"` raises `Unsupported` today — a named user error — and would raise
`Missing`, documented as "a packaging bug, not a user error". Either author
`markdown/symbols.scm` too, or keep the chunker's query name out of the tool's allowlist.

Why the grammar over a regex: `section` nodes **nest by heading level**, so the tree gives the
hierarchy; a `#`-looking line inside a `fenced_code_block` is `code_fence_content`, never a
heading; setext headings are a distinct node kind rather than a second regex plus a precedence
rule.

Depth is adaptive: a section that fits is one unit whole; one that does not becomes its own
prose plus a unit per child; a leaf still over the ceiling falls back to B4's paragraph runs.
Fixed depth is useless — this repo's `CLAUDE.md` has H2 sections in the hundreds of lines.

**The heading goes INSIDE the unit's hashed body**, inverting `Hunk`'s rule deliberately: `Hunk`
excludes the `@@` line because it is *derived position*; a markdown heading is *authored
content*, so rewording it should force a re-read.

```gherkin
Scenario: a hash inside a fenced code block is not a heading
  Given a markdown file whose rust fence contains a line reading "# not a heading"
  When it is chunked
  Then no unit boundary falls at that line

Scenario: a unit carries the path to itself
  Given a markdown file with an H3 nested under an H2 under an H1
  When it is chunked
  Then that unit's label names all three headings in order

Scenario: an oversized section descends into its children
  Given an H2 far above the ceiling containing three H3 subsections
  When it is chunked
  Then the H2's own prose and each H3 become separate units

Scenario: frontmatter and preamble are covered
  Given a markdown file opening with YAML frontmatter and prose before its first heading
  When it is chunked
  Then those lines belong to units and the coverage contract holds

Scenario: rewording a heading changes that unit's key and no other
  Given a chunked markdown file of five sections
  When one heading is reworded and nothing else changes
  Then that unit's content key differs and the other four are unchanged

Scenario: the symbols tool's refusal does not degrade
  Given FileSymbols asked for a language it does not support
  When it refuses
  Then it still refuses as a user error, not as a packaging bug
```
→ spec files: `spec/lain/survey/chunker/markdown_spec.rb` (includes B4's contract),
`spec/lain/structural/queries_spec.rb`, `spec/lain/tools/file_symbols_spec.rb`

**Escalation triggers:**
- Generalising `Queries.fetch` to `(language, query_name)` breaks a caller the grounding did not
  find. `file_symbols.rb:109` is the known one — a second means the API is wider than mapped.
- A `.scm` needs to be vendored rather than hand-authored. `queries.rb:16-18` records that the
  existing ones are hand-authored specifically to avoid a `NOTICE` obligation.
- The grammar parses a real file in this repo into a shape where sections do **not** nest.
  Adaptive depth assumes a tree.

---

### B8 — Read a folder as a review source [wave 3] [risk: high]

**Depends on:** B2, B5, B6
**Files:** create `lib/lain/review/source/corpus.rb`, `spec/lain/review/source/corpus_spec.rb`
**Reuse:** B5's walk and `Withheld`; B6's lazy file; B4/B7's chunkers;
`Source::DiffOrigin.already_local` (`source.rb:101`); the **universal** law group as split by B2;
`Review::Hunk.keys` batching (`hunk.rb:39`)
**Shared-file wiring:** `require_relative "source/corpus"` in `lib/lain/review/source.rb`

The third `Source`. Answers `#files` (lazy, via B6), `#base_ref` with a **fixed constant**,
`#head_ref` and `#identity_parts` from content digests (B2's port message), `#file_at` from
disk, `#diff_origin` as `already_local`. It does **not** answer `#diff` — and does not need to,
because `Source::Repository` (`source.rb:153`) is the only path to the one byte consumer.

The fixed base is the incremental property: `Marks` refuses to cross a base change, so a base
moving per run would discard every mark on every re-survey.

A unit becomes a `Hunk` with `new_start`/`new_count` from the unit and its label as `heading`.
**Lines keep their `+` origin marker** — `Changeset#walk`, `#anchor_at` and `#evidence` all read
one (`evidence` is `line.byteslice(1..)`), so bare content would anchor every line one character
short and count none as new-side. A deliberate carry, not an oversight.

`#identity_parts` is `(path, content digest)` per file: one read and one blake3, **no parse**.
That is what lets a round be opened without chunking, and it means round identity does not
depend on chunking strategy — improving a chunker later does not open a new round over an
unchanged tree.

```gherkin
Scenario: opening a survey chunks nothing
  Given a directory of fifty files
  When a corpus source is built and its session digest taken
  Then no file has been chunked

Scenario: a file chunks once, on first demand
  Given a corpus source
  When one file's hunks are read twice
  Then that file was chunked once and the others not at all

Scenario: a folder with no repository is reviewable
  Given a directory of markdown files that is not a git repository
  When a corpus source is built over it
  Then it answers files, and every file's status is added

Scenario: the base never moves, so marks persist across surveys
  Given a corpus surveyed once with every unit marked reviewed
  When an unrelated file is edited and the corpus is read again
  Then reconciliation does not raise and untouched units keep their marks

Scenario: editing one unit re-reads only that unit
  Given a corpus of a five-section document, all marked reviewed
  When one section's body is edited and a paragraph is inserted above the first
  Then only those two units lose their marks

Scenario: re-chunking does not move the corpus address
  Given a corpus addressed with every file chunked
  When the same corpus is addressed with no file chunked
  Then the digest is the same

Scenario: withheld paths are reported rather than vanishing
  Given a directory containing a credential-shaped file
  When the corpus is built
  Then that path is absent from the files and readable from the withheld report
```
→ spec file: `spec/lain/review/source/corpus_spec.rb` (includes the universal law group)

**Escalation triggers:**
- The universal law group still cannot admit this source after B2's split. That means the split
  was drawn in the wrong place, and papering over it here hides the defect in the contract.
- A corpus unit's content key collides with a real diff hunk's key for the same bytes — they
  share the `hunk-content-v1` scheme. If reachable, a corpus mark could satisfy a changeset
  hunk; stop, this needs its own scheme.
- `Anchor::InvalidLine` is raised anywhere. Old-side anchors should be unreachable (no context,
  no deletions), so a line-0 anchor means the walk reads a side that should not exist.

---

### B9 — Chunk source files by their top-level definitions [wave 3] [risk: high]

**Depends on:** B7
**Files:** create `lib/lain/survey/chunker/code.rb`, `spec/lain/survey/chunker/code_spec.rb`
**Reuse:** `lib/lain/structural/queries/{ruby,rust,typescript}/symbols.scm` **unchanged**;
B7's generalised `Structural::Queries.fetch`; `Tools::FileSymbols` for the call shape;
`spec/support/shared_examples/survey_chunker.rb`
**Shared-file wiring:** `require_relative "survey/chunker/code"` in `lib/lain/survey/chunker.rb`

The difficulty is **entirely** the coverage contract. A file is not only its definitions:
requires, constants, module bodies, trailing code and the prose between methods all belong to
some unit. Symbol queries name the definitions; the gaps between them are this card's work.

The rule that keeps it honest: walk top to bottom, emit each definition's span as a unit, and
emit every inter-definition gap as its own unit rather than attaching it to a neighbour.
Attaching a gap downward is tempting and makes an edit to a file-level require invalidate an
unrelated method.

```gherkin
Scenario: the coverage contract holds over a real source file
  Given this repository's own lib/lain/review/hunk.rb
  When it is chunked
  Then concatenating the units in order yields the file byte for byte

Scenario: a file-level require is its own unit
  Given a Ruby file with requires above its first class
  When it is chunked
  Then those lines form a unit that is not part of the first definition

Scenario: editing one method leaves its siblings' keys alone
  Given a chunked Ruby file of four methods
  When one method's body is edited
  Then only that unit's content key changes

Scenario: an unsupported language falls back rather than refusing
  Given a file in a language with no symbols query
  When it is chunked
  Then paragraph runs are produced and the coverage contract holds

Scenario: granularity stays legible
  Given this repository's own lib/lain/review/session.rb
  When it is chunked
  Then the unit count is far below one per five lines
```
→ spec file: `spec/lain/survey/chunker/code_spec.rb` (includes B4's contract)

**Escalation triggers:**
- A `symbols.scm` returns overlapping or nested spans (a method inside a class both reported).
  Gap-free coverage assumes a flat top-level partition; nesting is a granularity policy decision
  — stop rather than picking one.
- Coverage requires editing an existing `symbols.scm`. Those files serve `Tools::FileSymbols`
  and `Tools::CodeOutline` in production.
- The gap-unit rule produces more units than lines/5 on a real file. That makes marking useless
  — report the measurement rather than shipping it.

---

### B10 — Address and present a corpus end to end [wave 4] [risk: medium]

**Depends on:** B8
**Files:** create `spec/lain/review/seams/survey_session_spec.rb`
**Reuse:** `Review::Session.open`/`.from_journal`; `Surface::Text`; `Marks#reconcile`;
`spec/lain/review/session_spec.rb` for the session-driving idiom
**Shared-file wiring:** none

A `:seam` card with **no lib changes**: it drives the real `Session`, `Marks`, `MarkedChangeset`
and `Surface::Text` over a real `Source::Corpus` and pins that the assembled stack behaves. Every
prior card proves its own object; nothing yet proves they compose, and the spike showed the
composition is where the interesting properties live.

It also pins the laziness end to end, which is the claim B3 and B6 exist to support and which no
single-object spec can make.

```gherkin
Scenario: a survey opens, marks, renders and replays
  Given a corpus over a directory of markdown
  When a session is opened, three units marked, one annotated, and the round replayed from its journal
  Then the marks and the annotation survive and the round is not reported regenerated

Scenario: presenting a survey chunks only what it must
  Given a corpus of fifty files inside the ceilings
  When the session is presented at whole scope
  Then the tri-state renders for every file and no file was chunked

Scenario: marking a unit chunks its file and no other
  Given a presented survey
  When one file's unit is marked reviewed
  Then that file was chunked and the others were not

Scenario: a survey groups by directory
  Given a corpus spanning three directories
  When it is presented at directory scope
  Then each directory heads its files
```
→ spec file: `spec/lain/review/seams/survey_session_spec.rb`

**Escalation triggers:**
- Presenting forces chunking despite B3. That means B3's fix did not reach the path a real
  session takes — this is the card that would find it, and it is a real finding, not a spec bug.
- `Marks#states` forces every file's hunks to derive a tri-state, which no card scoped. If so,
  laziness is unreachable for the flat view and the plan needs a decision — stop.

---

### B11 — Survey a path from the command line [wave 4] [risk: medium]

**Depends on:** B3, B8
**Files:** create `lib/lain/cli/survey.rb`, `spec/lain/cli/survey_spec.rb`
**Reuse:** `CLI::Review` (`review.rb:106-175`) for the whole shape — `checked_surface`,
`Journal.open(paths:)`, the `ensure journal.close`, `drawn`, returning Strings so only the
frontend prints; `exe/lain:167-183` for the nested-Thor subcommand shape;
`Boundary#render` (`exe/lain:49-53`), which requires every refusal to be a `Lain::Error`
**Shared-file wiring:** in `exe/lain`, a nested `class Survey < Thor` mirroring `Review`
(`:167-183`) plus `desc` and `subcommand "survey", Survey` beside `:352-355`;
`require_relative "cli/survey"` in `lib/lain/cli.rb`

`lain survey PATH [--scope <strategy>] [--unbounded]`. Every `Lain::Review::*` name is read from
a **method body** — `lain.rb` loads `cli`(76) before `review`(86), so a class-body constant is a
load-time `NameError`.

`Paths#sessions_dir` works unchanged for a non-repository path.

```gherkin
Scenario: a directory of markdown is surveyed
  Given a directory of markdown files
  When it is surveyed
  Then the rendering names every file with its review state

Scenario: withheld paths are disclosed
  Given a directory containing a credential-shaped file
  When it is surveyed
  Then the output names what was withheld and why

Scenario: a path that does not exist refuses cleanly
  Given a path naming nothing
  When it is surveyed
  Then a Lain::Error is raised, naming the path, with no backtrace reaching the user

Scenario: an oversized survey refuses and names the narrowing
  Given a directory over the file ceiling
  When it is surveyed with no unbounded flag
  Then it refuses, naming what to narrow to

Scenario: the unbounded flag presents what the ceiling would refuse
  Given that same directory
  When it is surveyed unbounded
  Then it presents
```
→ spec file: `spec/lain/cli/survey_spec.rb`

**Escalation triggers:**
- A refusal escapes that is not a `Lain::Error` — `Boundary#render` turns only those into a
  clean `Thor::Error`; anything else reaches the user as a backtrace.
- Thor swallows a path colliding with a reserved command name (`help`, `tree`). `Review` needed
  `default_command :open` for exactly this.

---

### B12 — Grow a survey without losing what was read [wave 5] [risk: high]

**Depends on:** B10, B11
**Files:** create `spec/lain/review/session/extension_spec.rb`; modify
`lib/lain/review/session.rb`, `lib/lain/review/records.rb`,
`lib/lain/review/session/replay.rb`, `spec/lain/review/session_spec.rb`,
`spec/lain/review/records_spec.rb`
**Reuse:** `ChangesetOpened` (`records.rb:17-50`) as the record shape including its `Guardable`
block and `JOURNAL_TYPE` reopen; `Replay::TYPES` and the positional-round rule
(`replay.rb:33-45`); `Marks#reconcile`'s pruning semantics; B8's content-based address, which is
what lets an extension record a digest without chunking
**Shared-file wiring:** none

A survey accretes. A widening message rebuilds the changeset over more paths, re-reconciles, and
journals a `CorpusExtended` record carrying the new digest.

**Name it `#widen` or `#add_paths`, not `#extend`** — `Object#extend` exists and shadowing it on
an aggregate is a debugging trap.

**Three memos go stale and the card must invalidate all three**: `@digest` (`session.rb:219`),
`@keys_by_path` (`:347`) and `@hunk_keys` (`:349`). `#marked` (`:251`) is deliberately *not*
memoized, documented as "a stale view is exactly the defect a marker exists to prevent" — three
sibling memos silently staleified by a widening is that same defect.

`regenerated?` (`session.rb:235`) changes meaning: *last recorded* digest versus current, so a
deliberate widening does not read as the ground shifting underneath the human. For a changeset
there are no extension records, so last-recorded is the opened digest and `/review` behaviour is
unchanged — `session_spec.rb:1101` must stay green untouched.

```gherkin
Scenario: widening a survey keeps every mark
  Given a survey with every unit marked reviewed
  When it is widened by one file
  Then no mark is lost and the new file's units are unreviewed

Scenario: widening is not a regeneration
  Given a survey
  When it is widened and nothing else changes
  Then it does not report itself regenerated

Scenario: a change underneath the human still reports regenerated
  Given a widened survey
  When a file already in it is edited outside the session
  Then it reports itself regenerated

Scenario: a changeset review is unaffected
  Given a branch review with no extension records
  When it is asked whether it regenerated after an amend that changed nothing
  Then it answers false, exactly as before

Scenario: widening invalidates every derived answer
  Given a survey whose digest and keys have been read
  When it is widened
  Then the digest and the keys reflect the wider corpus

Scenario: a widening replays
  Given a journal of an opened survey, two marks and a widening
  When the round is rebuilt from the journal
  Then it spans the wider path set and both marks stand
```
→ spec files: `spec/lain/review/session/extension_spec.rb`,
`spec/lain/review/session_spec.rb`, `spec/lain/review/records_spec.rb`

**Escalation triggers:**
- Redefining `regenerated?` makes any existing session spec red. `/review` behaviour must be
  unchanged; red means last-recorded and opened are not equivalent in the no-extension case.
- `Replay`'s positional round rule (`replay.rb:33-45`) cannot express a widening without a fourth
  field on a record. That doc argues specifically against adding one.
- Widening makes a **filtered** changeset reachable by `Marks#reconcile`, whose contract says it
  may only ever be handed the whole unfiltered one. That is the tuicr#247 bug this codebase
  already refused once.

---

### B13 — Add an opened buffer to the live survey [wave 6] [risk: high]

**Depends on:** B12
**Files:** modify `lib/lain/cli/human_replies.rb`, `lib/lain/review/handover.rb`,
`spec/lain/cli/human_replies_spec.rb`, `spec/lain/review/handover_spec.rb`
**Reuse:** `Gestures` (`human_replies.rb:578-693`) and its `review_open`/`review_mark`/
`review_ask` routes (`:609-611`); `#gestured` (`:687-692`) as the refusal-reporting wrapper;
`NoReview` (`:103-120`) as the null; `Handover`'s acked-rail discipline (`handover.rb:29-34`);
B5's `Withheld` for the refusal reason
**Shared-file wiring:** none

The gesture that makes accretion usable: the human opens a file in the cockpit and adds it to the
survey in progress.

It rides the **acked** rail, not the answered one. `Handover`'s doc is explicit that acked
gestures are served by `Gestures` on the reactor thread and that nothing there may raise —
`Gestures` rescues only `NoMethodError`, so a refusal must be folded into the answer and
reported, never let out.

```gherkin
Scenario: adding a file widens the survey
  Given an open survey and a file outside it
  When the add gesture names that file
  Then the survey spans it and its units are unreviewed

Scenario: adding a file already surveyed is refused, not duplicated
  Given an open survey containing a file
  When the add gesture names that same file
  Then it is refused with a report and the survey is unchanged

Scenario: adding a denied path is refused with its reason
  Given an open survey
  When the add gesture names a path Sensitivity classifies denied
  Then it is refused with a report naming the protection, and nothing is journaled

Scenario: the gesture never raises out of the rail
  Given an open survey
  When the add gesture names a path that cannot be read
  Then a report comes back and no exception escapes
```
→ spec files: `spec/lain/cli/human_replies_spec.rb`, `spec/lain/review/handover_spec.rb`

**Escalation triggers:**
- The gesture needs a *new* editor verb rather than reusing the existing routes. That means lua
  changes under `lib/lain/frontend/neovim/runtime/`, outside this card — stop and report the
  surface needed.
- `Handover` cannot fold a refusal into an answer without raising, because the widening path
  raises something `Gestures`' `NoMethodError` rescue will not catch — the failure
  `handover.rb:20-27` warns ends the editor session.
- Adding a file mid-survey invalidates `ReviewView`'s line-to-row index and a stale gesture
  resolves to the wrong unit. A generation counter may be needed; that is a design decision.

---

### B14 — Open a survey from the chat prompt [wave 6] [risk: medium]

**Depends on:** B11, B12
**Files:** create `lib/lain/cli/command/survey.rb`, `spec/lain/cli/command/survey_spec.rb`
**Reuse:** `CLI::Command::Review` (`command/review.rb`) wholesale — flag parsing, the `NO_EDITOR`
refusal (`:66-70`), the bind-before-draw ordering (`:164-171,181-182`), the `Handover`
construction (`:225`); `CLI::Survey`'s resolution from B11; `Registry#register`
(`command/registry.rb:27-32`)
**Shared-file wiring:** `require_relative "command/survey"` in `lib/lain/cli/command.rb`; one
entry in `Command::Surface#builtins`/`#review_commands` (`command/surface.rb:120-131`)

`/survey <path> [--scope <strategy>]` in an attached cockpit — **the surface Joel actually
uses**, so it is not a thinner variant of B11; the editor is where a survey is read and marked.

It refuses without an editor rather than drawing into `Surface::Null`, for `Command::Review`'s
stated reason: an opened review nothing drew and no gesture could reach is the failure the whole
review surface was written against.

No `/survey-submit` sibling: there is no pull request under a corpus, and `Submit::Nowhere`
(`submit/outbox.rb:33-37`) already models "a perfectly good review with nowhere to post".

```gherkin
Scenario: a survey opens in the attached editor
  Given a chat with an editor attached
  When /survey is given a directory
  Then the survey is drawn and its gesture rails are bound

Scenario: a headless chat refuses and says how to attach one
  Given a chat with no editor attached
  When /survey is given a directory
  Then it refuses, naming the flag that attaches an editor

Scenario: rails are bound before anything is drawn
  Given a chat with an editor attached
  When /survey opens a survey
  Then the rails were bound before the surface was told

Scenario: an unknown flag is refused rather than read as a path
  When /survey is given a flag it does not declare
  Then it refuses, naming the flag
```
→ spec file: `spec/lain/cli/command/survey_spec.rb`

**Escalation triggers:**
- Binding a survey through `bind_changeset_review` needs a message `Handover` does not answer.
  The rail is generic in shape; if it is not, stop rather than adding a second parallel rail.
- `Command::Surface#outbox` holds one review per run and both `/review` and `/survey` would claim
  it. Two open reviews in one chat is a state question nobody has decided — stop.
- A gesture becomes ambiguous about which of two open reviews it addresses. Report; do not pick
  a precedence rule.

## Integration checks

- `bundle exec rake pspec` green, example **count** compared against the pre-chunk baseline — a
  dead worker reports as "fewer examples, 0 failures, non-zero exit".
- `bundle exec rubocop` clean. **Never** name a `.toml` or `.scm` on a rubocop command line; a
  bare invocation is safe because the default `Include` patterns do not match them.
- `bundle exec rake compile` — no Rust changed; this is a regression check that nothing disturbed
  `ext/lain`.
- `pre-commit run --all-files`, including `yard-lint`.
- `spec/output_discipline_spec.rb` green — `CLI::Survey` returns Strings and must not print.
- A **laziness check** the suite cannot express as a unit: survey this repository's `lib/` and
  confirm from the walk's own instrumentation that the number of files chunked is far below the
  number listed. B10 pins the property; this confirms it at real scale.
- **Manual pass owed to Joel:**
  1. `/survey` a real directory in the cockpit; mark units, annotate one, confirm the tri-state
     renders and gestures land.
  2. Add a file mid-survey via B13's gesture and confirm no mark is lost.
  3. `/survey ~/dev/resume` — the non-Ruby, non-markdown case that motivated the paragraph floor.
  4. Confirm a survey and a branch review can coexist in one chat, or that the refusal when they
     cannot is legible (B14's trigger).
- **Follow-ups to file, not to build here:** wire `Review::Delta` (it exists, is spec'd, and
  nothing calls it — it is the answer to "what must I re-read after a rebase"); revisit whether
  `Marks` can survive a base move now that the context-window mechanism is pinned by B1.
