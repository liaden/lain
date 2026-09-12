# Survey: reviewing a corpus of files as they stand

status: done, except B12 part two — B20 owns it, and B12 part one is not reachable from
production until B20 lands
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds · Jeremy Evans · Sandi Metz · Richard Schneeman · Aaron Patterson

**Depends on `planning/specs/chunk-partition-strategy.md` per card, not wholesale.** Each
card's **Blocked on** line names the specific partition-chunk cards (A1/A3/A4) it waits on and
why; five cards here (B1, B4, B5, B6, B16) block on nothing in plan A and may run
**concurrently with it**. A card that edits files A1 rewrites (B2, B15) must not start until
A1 has merged — a worktree forked earlier is a doomed rebase.

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
range is cited it was read, not remembered. Re-verified 2026-08-09 at `d7e41b7` by a second
panel pass (`.critique-partition-survey.md`), which added cards B15/B16 and the projection/gesture/chunker consolidations, settled the decisions
recorded under Open decisions, and refreshed the stale cites (the secret boundary landed the
same day the first draft was verified).

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

Forcing functions one and two are owned: B2 moves digest identity to the source, and **B15**
makes tri-state derivation and reconcile per-path lazy. Without B15, `Session#present`
(`session.rb:270-273`) rebuilds `#marked` on every render and `Marks#states`
(`marks.rb:106-130`) walks `changeset.hunks.group_by(&:path)` — re-chunking the corpus on
every presentation, whatever B3 and B6 do. No other card touches `marks.rb` or
`marked_changeset.rb`.

**What "lazy" means here, priced honestly:** opening a survey is O(total bytes) — content-
addressed identity (`blake3` per file) requires one streamed read of every listed file, and
that is the unavoidable price of "re-chunking does not move the address" and "marks survive
across surveys". What laziness buys is that the PARSE tier — chunking, unit keys, tri-state
derivation — is strictly on demand, so presenting costs O(files ever marked), not O(corpus).
Two orderings keep the read honest: the file-count `Bounds` check runs **before** the
identity pass, so an oversized corpus is refused from the walk alone without reading a byte;
and the identity pass harvests `(digest, line count)` in one read, which is exactly the cheap
size B3's line ceiling needs. For a genuinely huge tree the accrete model is the escape
hatch: survey the subtree being read and widen (B12).

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
  So `changeset.digest_parts` cannot dispatch differently for a corpus — B2's receiver must be
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
  Rust changes needed. Measured caveat: sections nest for **ATX headings only** — a setext
  heading opens no section (a two-setext-heading document parses as one section), so setext
  documents take the paragraph floor (B4).
- `Lain::Sensitivity#classify(path) -> Verdict` (`sensitivity.rb:419`) has landed — and so has
  the full secret boundary this plan's first draft predated. A `:denied` path is refused
  outright, ahead of any approval, and is never approvable (`sensitivity/policy.rb:123-167`,
  landed `48eab7b`). `Sensitivity::Regions.detect` names the sensitive spans of any content
  (~0.27ms/KB, linear, no adversarial blowup). The run's ONE `Sensitivity::Ledger`
  (`cli/switchboard.rb:112`) records released region digests per absolute path — `ledger:` is
  always a REQUIRED keyword and there is deliberately no Null (`sensitivity/ledger.rb:105-124`).
  `Middleware::RedactSecretReads` renders an unreleased region as `<redacted:N>` and a released
  one as its real bytes, so a masked `.env` keeps its key names
  (`redact_secret_reads.rb:36-47`). The walk still consults `#classify` directly — a directory
  walk is not an Effect through the handler chain, so the upstream refusal never sees it — and
  **B5**'s projection is where the corpus meets the region model.
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
  before `changeset`(25), and `source.rb` requires its own children at the **bottom**
  (`source.rb:162-163`) — so definitions placed in `source.rb`'s module body precede
  `local_branch.rb` with zero index changes.
- `origin/main` **exists** and agent worktrees fork the remote-tracking ref (see the
  orchestrator contract). An earlier edition of this line claimed the ref was absent; it
  resolves.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only — never under a card's **Files**):
  `lib/lain.rb`, `lib/lain/review.rb`, `lib/lain/survey.rb`, `lib/lain/cli.rb`,
  `lib/lain/cli/command.rb`, `lib/lain/cli/command/surface.rb`, `exe/lain`, `.rubocop.yml`,
  `lain.gemspec`, `spec/spec_helper.rb`. `lib/lain/review/source.rb`'s **module body** is B2's
  scope; its `require_relative` lines are wiring.
- A new lib file, its index line and its spec land in **one** commit (CLAUDE.md).
- Check the example **count** against the previous merge, not just the failure count.
- **Re-ground after the partition chunk lands.** This plan's `bounds.rb`, `exe/lain` and
  scope-name cites are correct at `d7e41b7` and stale BY CONSTRUCTION once
  `chunk-partition-strategy.md` merges — A1 renames the readers, A3 rewrites the enum, A4
  replaces the advice constants. At each card's dispatch, re-verify its cites against the
  tree its worktree will actually fork, and cite by construct, not line.
- `git rev-parse origin/main main` before spawning each card's agent, the first included — agent
  worktrees fork the remote-tracking ref. Ask Joel to push if they differ.

## Open decisions

None. Three questions the first panel review identified as unbuildable-if-unanswered were
settled during planning, and the 2026-08-09 panel pass settled seven more; all are recorded
here so no agent reopens them mid-card:

- **A source supplies its own identity, as ONE message.** There is one `Changeset` class, so
  polymorphism on the changeset does not exist, and a type test in `Session` is the shape
  `source.rb`'s own doc condemns. The port gains `#identity` (B2), returning a small frozen
  value carrying `scheme` and `parts` — two messages carrying one value is a data clump
  `Keying.digest(scheme, parts)` would re-join at its only call site (`session.rb:103,109-114`).
  A diff source's identity composes exactly what `digest_parts` composes today, so `/review`'s
  digests stay bit-identical; a corpus answers `(path, content digest)` pairs.
- **The two-witness cross-checks are diff-source laws, not port laws.** The reversed-diff and
  binary-agreement examples hold `#diff` against `#commits`; a corpus has neither witness, so no
  universal group containing them can admit one. B2 moves them into a diff-source group and
  says so, rather than an agent discovering it and stopping. The files-shareability and
  instance-stability pins (`changeset_spec.rb:733-740`) are classified by the same split — see
  B6, whose chosen shape decides which group they can live in.
- **`Bounds` must stop forcing hunks on the success path** (B3) — and that alone is not
  laziness: `Session#present` re-derives tri-state through `Marks#states` over every hunk on
  every render, so **B15 exists** and presenting costs O(files ever marked). Without B15,
  T-for-laziness is decorative; with it, B10's pins are assertable.
- **Corpus units get their own key scheme: `unit-content-v1`.** A one-unit surveyed file and
  the same file newly added in a branch diff hash byte-identically under `hunk-content-v1`
  (all-`+` body, same path frame) — the collision is demonstrable in five minutes, not
  hypothetical. `Hunk#key` already hashes the scheme in (`hunk.rb:83-85`) and no keys are
  journaled yet, so minting is one constant now versus a session-separation argument nobody
  can re-check later.
- **Strategy applicability is the partition chunk's `#supports?(source)`** (its Open
  decisions). Here it means: the survey's default scope resolves through the registry to the
  whole strategy, and `--scope commits` over a corpus refuses naming the strategy and what the
  source lacks. B11 carries the ACs.
- **One open review per chat.** `Command::Surface` holds one `outbox:` across
  `review_commands` (`command/surface.rb:131`); the second `/review`-or-`/survey` in a chat
  refuses, naming the one already open (B14 AC). Two concurrent review surfaces is future
  work, not a mid-card improvisation.
- **A gated file enters the corpus redacted to its released regions** (Joel's ruling,
  2026-08-09). Withholding it wholesale would make `/survey` stricter than the read path over
  the same file; showing it in full would leak what the read path masks. So the corpus
  projects EVERY file through the region model at the source (B5): unreleased regions render
  as the read path's own `<redacted:N>` placeholder, denied paths stay absent (denial is not
  approvable), and unit keys and `#identity` digest the PROJECTION — a release legitimately
  changes what the survey can show, so the affected units honestly demand a re-read.
- **The accretion gesture's wire verb is its own card (B16).** Lua under
  `frontend/neovim/runtime/` is outside B12's files, and the acked dispatch table has no verb
  that can mean "add this buffer" (`human_replies.rb:609-611`). B16 lands the `survey_add`
  emission; B12's gesture half routes it.
- **B6 decides its shape from named candidates, with equality spec'd.** A memo-on-self is NOT
  impossible on a frozen `Data` — an ivar box set before `super` in a custom initialize works,
  verified under 4.0.6 — so the card weighs three shapes (boxed-memo `Data`, a memoizing
  `hunks` member answering `to_ary`, a distinct lazy type) on the axes that actually differ:
  duck duplication, `Ractor.shareable?` honesty, and EQUALITY (`MarkedChangeset.of` keys its
  row table by the file object under a no-default `fetch`, `marked_changeset.rb:89-93,100-103`).

## Dispatch graph

Cards dispatch **eagerly**: a card starts the moment every entry on its **Blocked on** line —
plan-A cards included — has MERGED to main. Merged, not merely "agent finished": worktrees
fork main, so an unmerged blocker is a doomed rebase. There are no wave barriers; the groups
below are a projection for reading, and the orchestrator should treat every card as
individually dispatchable.

```
start immediately (concurrent with plan A):  B1, B4, B5, B6, B16
after A1 merges:                             B2, B15     (A3, A4 also unblock, in plan A)
after B2 (B3 also needs A4):                 B3
after B2 + B4 + B5 + B6:                     B8
after B8:                                    B10 (also needs B15), B11 (also needs B3, A3)
after B10 + B16:                             B12
after B11:                                   B14
```

Critical path: **A1 → B2 → B8 → B10 → B12** — five deep, and the whole first rank runs while
plan A is still in flight. B8 is the merge point every later card waits on; B2 is the card
whose contract question was the first panel's blocker — both are answered in Open decisions,
so the cards are buildable rather than escalating. Consolidations from the 2026-08-09
revision: B4 absorbed B7 and B9 (one chunker family, one coverage contract, three commits),
B5 absorbed B17 (walking and projecting are one admission policy), B12 absorbed B13 (widening
and its gesture are one accretion feature), and the former ceremonial edges B12←B11 and
B14←B12 stay cut.

## Tasks

### B1 — Pin that history rewriting preserves marks [risk: low]

**Blocked on:** nothing — it asserts Changeset-level facts A1 preserves; may run concurrently
with plan A
**Files:** create `spec/lain/seams/history_rewrite_spec.rb`
**Reuse:** `spec/lain/review/delta_spec.rb:8-30` (the build-once-copy-per-example rebase/amend
fixture and its `git` helper); `spec/support/seed_repo.rb`;
`Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB`
**Shared-file wiring:** none

A **characterization** card: it pins behaviour that already works and that nothing tests at the
seam level. It drives real `git` per example, so it is tagged `:seam` and lives in
`spec/lain/seams/` — the existing subject-less seam home; this plan invents no
`spec/lain/review/seams/` subtree for four agents to relitigate.

`session_spec.rb:157` pins the digest *function* against a fabricated
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
Scenario: reordering the commits leaves every mark standing
  Given a feature branch of two commits reviewed against main, with every hunk marked reviewed
  When the commits are reordered
  Then the merge base is unchanged
  And the changeset digest is unchanged
  And every mark survives reconciliation

Scenario: squashing the commits into one leaves every mark standing
  Given a feature branch of two commits reviewed against main, with every hunk marked reviewed
  When the commits are squashed into one
  Then the merge base is unchanged
  And the changeset digest is unchanged
  And every mark survives reconciliation

Scenario: splitting one commit in two leaves every mark standing
  Given a feature branch of two commits reviewed against main, with every hunk marked reviewed
  When one commit is split in two
  Then the merge base is unchanged
  And the changeset digest is unchanged
  And every mark survives reconciliation

Scenario: rewording a commit message leaves every mark standing
  Given a feature branch of two commits reviewed against main, with every hunk marked reviewed
  When a commit message is reworded
  Then the merge base is unchanged
  And the changeset digest is unchanged
  And every mark survives reconciliation

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
→ spec file: `spec/lain/seams/history_rewrite_spec.rb`, tagged `:seam`

**Escalation triggers:**
- The reorder or squash scenario is RED against today's `main`. That contradicts the measured
  spike result — stop; do not relax the assertion to make it pass.
- The rebase scenario raises something other than `Marks::BaseMismatch` (an `Unattributed`,
  say). Grounding says BaseMismatch fires first, and a different order invalidates B10's
  reasoning about why corpus marks survive.
- The context-window scenario comes out with keys the SAME. That would mean `-U3` context is not
  in `Hunk#body` after all, contradicting `hunk.rb:56-62` and removing a documented limitation.

---

### B2 — Hand the changeset model values, and say which laws are diff laws [risk: high]

**Blocked on:** B1 — the characterization net this card must not turn red; **A1 (plan A)** —
this card edits `changeset.rb`, `session.rb` and the shared examples A1's reader move rewrites
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
2. `Source` gains `#identity` — one message returning a small frozen value carrying `scheme`
   and `parts` (Open decisions: two messages carrying one value is a data clump).
   `Session.digest` asks the changeset,
   which asks its source — **no type test anywhere**, because the object that has the parts
   supplies them. A diff source composes exactly what `digest_parts` composes today, so every
   `/review` digest is bit-identical and every journaled `changeset_digest` still joins.
   Restating the port's message list in `source.rb`'s module doc — which already miscounts the
   current set ("answers six… reads only these five", `source.rb:7-14`) — is an explicit
   deliverable of this card.
3. The port's law group splits. Assertions about **shape and self-consistency** stay universal;
   the **two-witness cross-checks** — reversed-diff (`review_source.rb:336-370`) and
   binary-agreement (`:376-389`) — and the sha-format and unified-diff-syntax assertions
   (`:151-157`, `:196-199`, `:258-324`) move into a group only diff sources include. This is
   settled (Open decisions): those laws hold `#diff` against `#commits`, and a source with
   neither witness cannot satisfy them. The files-shareability and instance-stability pins
   (`changeset_spec.rb:733-740`) are classified by the same split, in whichever direction B6's
   chosen shape dictates. **Do not weaken the universal half to keep them** — a
   port law that cannot fail is worse than a law in the right place.

**Load order** has a placement rule, not an either/or: the moved constants live in the owning
unit, positioned by its index. `source.rb` requires its children at the **bottom**
(`source.rb:162-163`), so `ChangedFile`/`Parser`/`Unparseable` defined in `source.rb`'s module
body — already this card's declared scope — precede `local_branch.rb` with zero index changes.
The sanctioned fallback is naming them from a method body (`LocalBranch` already does that for
`Isolation::Worktree`, `local_branch.rb:228-234`); reordering `review.rb`'s index is the worst
option and is not taken.

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
  bit-identical; a moved digest means the diff source's `#identity` does not compose what
  `digest_parts` composed.
- After the split, the **universal** group cannot fail *any* wrong implementation — it has
  become shape-checking with no discriminating power. Report what is left; a vacuous port
  contract is a worse outcome than an over-strict one.
- `request_review.rb:604` needs a change to keep working. `#diff` is untouched by this card; if
  it breaks, the port change is wider than planned.

---

### B3 — Bound a view without parsing it [risk: high]

**Blocked on:** B2 — the line guard's input comes from the source port; **A4 (plan A)** — same
`bounds.rb`, and A4 replaces the advice constants this card would otherwise collide with
**Files:** modify `lib/lain/review/bounds.rb`, `lib/lain/review/changeset.rb`,
`spec/lain/review/bounds_spec.rb`, `spec/lain/review/changeset_spec.rb`
**Reuse:** `Bounds::Size.lines_in` (`bounds.rb:168`); the existing short-circuit ordering and
its documented promise (`bounds.rb:250-266`)
**Shared-file wiring:** none

The card that makes B8's laziness real rather than decorative — together with B15, which owns
the tri-state half of the same problem.

Be precise about the mechanism, because the obvious fix is the wrong one: `check_cumulative!`
(`bounds.rb:233-239`) runs two **sequential** guards, so when the file-count guard raises,
`Size.lines_in` is never evaluated — the ordering is already correct, and wrapping the
argument in a lambda changes nothing. The defect is the line guard's **input**:
`Size.lines_in` sums `file.hunks` over every file, so every *successful* presentation walks
every hunk. The fix is that the line guard's input comes from **source-known sizes**, never
from `#hunks` — a corpus knows a file's line count from the identity pass (see Grounding); a
diff source knows it from the hunks it already parsed.

`Bounds`' stated promise is preserved and strengthened: the decision to refuse still reads a
file count, and now the decision to *present* reads no hunk either.

**`Bounds::UNBOUNDED = Float::INFINITY` lands here** (moved from the partition chunk's A4; its
only consumer is B11's `--unbounded`). `INFINITY` answers the whole comparison duck — `x <=
INFINITY` is true, `x > INFINITY` is false — so the ceiling comparisons stay untouched; only
the `Integer(...)` coercion (`bounds.rb:175-178`) special-cases it, and unlike `nil` it cannot
arrive by accident from a missed config lookup. An absent ceiling argument still defaults to a
number: silently-unbounded is precisely the failure `Bounds` exists to prevent.

```gherkin
Scenario: presenting a view within the ceilings reads no hunks
  Given a changeset whose fifty files raise if their hunks are read
  When it is checked for presentation
  Then it presents and nothing raised

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

Scenario: an unbounded ceiling presents what a number would refuse
  Given a view of 600 files and an UNBOUNDED file ceiling
  When it is checked
  Then it presents

Scenario: an absent ceiling is not silently unbounded
  Given a Bounds built with no file ceiling argument at all
  When it is checked against an oversized view
  Then it refuses, because the default is a number and not UNBOUNDED
```
→ spec files: `spec/lain/review/bounds_spec.rb`, `spec/lain/review/changeset_spec.rb`; the
no-hunk assertions use a source double whose files raise on `#hunks` — the
`bounds_spec.rb:342,362` precedent — not implementation spying

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

### B4 — The coverage contract and its three chunkers [risk: high]

**Blocked on:** nothing — no plan-A file is touched; may run concurrently with plan A
**Files:** create `lib/lain/survey/chunker.rb`, `lib/lain/survey/chunker/paragraphs.rb`,
`lib/lain/survey/chunker/markdown.rb`, `lib/lain/survey/chunker/code.rb`,
`lib/lain/survey/unit.rb`, `lib/lain/structural/queries/markdown/sections.scm`,
`spec/lain/survey/chunker/paragraphs_spec.rb`, `spec/lain/survey/chunker/markdown_spec.rb`,
`spec/lain/survey/chunker/code_spec.rb`,
`spec/lain/survey/unit_spec.rb`, `spec/support/shared_examples/survey_chunker.rb`; modify
`lib/lain/structural/queries.rb`, `spec/lain/structural/queries_spec.rb`,
`spec/lain/tools/file_symbols_spec.rb`
**Reuse:** `Changeset#lines`'s `delete_suffix`-not-`chomp` rule (`changeset.rb:265`) and its
reason — a CRLF file's trailing `\r` is content; `Tools::FileSymbols` +
`Structural::Queries.fetch` + `Ext::TreeSitter.query` as the precedent;
`lib/lain/structural/queries/ruby/symbols.scm` for authoring style, and the
`{ruby,rust,typescript}/symbols.scm` files **unchanged**
**Shared-file wiring:** `require_relative "lain/survey"` in `lib/lain.rb`, immediately **before**
`lain/review`(86); new `lib/lain/survey.rb` index requiring `survey/unit` then `survey/chunker`;
`lib/lain/survey/chunker.rb` requires `chunker/paragraphs`, `chunker/markdown`, `chunker/code`

One card, three commits — formerly B4, B7 and B9, merged because the coverage contract is one
review subject and the three implementations are its witnesses; split, the contract's authors
and its consumers reviewed each other across card boundaries. **Commit one** is the contract
and the paragraph floor; **commit two** markdown sections plus the `Queries` generalisation;
**commit three** code definitions. Each commit is green alone.

**Part one — the paragraph floor.** The universal floor every other chunker falls back to. A
`Unit` is `(path, label, start_line, lines)`.

**This part authors the coverage contract** that parts two and three are then held to: units are ordered,
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

**Part two — markdown by its own section tree** (formerly B7).

`tree-sitter-md` is compiled in and `Ext::TreeSitter.query(src, "markdown", "(section) @s")` was
**run and returns matches** — no Rust, no new dependency.

But the `Queries` change is larger than "one allowlist entry", and this part owns the whole of
it. `path_for` (`queries.rb:60-61`) hardcodes `symbols.scm` and `fetch(language)` (`:46`) is
language-keyed; a second query name means generalising both, and `file_symbols.rb:109` calls
`fetch` positionally. The gate becomes a declared **`{language => [query names]}` table**, not
a wider language list — after this card, markdown ships `sections.scm` only and ruby/rust/ts
ship `symbols.scm` only, so `fetch(:markdown, :symbols)` must stay `Unsupported`. A flat
allowlist cannot say that, **and it changes production behaviour**: `FileSymbols`
with `language: "markdown"` raises `Unsupported` today — a named user error — and would raise
`Missing`, documented as "a packaging bug, not a user error".

Why the grammar over a regex: `section` nodes **nest by heading level for ATX headings**, so
the tree gives the hierarchy; a `#`-looking line inside a `fenced_code_block` is
`code_fence_content`, never a heading. **Setext headings are the measured exception** (panel,
ran against the compiled ext): a `setext_heading` node exists, but it *opens no section* — a
document of two setext headings parses as ONE section containing both, so a
`(section)`-walking chunker sees no hierarchy there. Ruled: **setext-authored documents take
B4's paragraph floor**, stated rather than silently fallen into; handling setext structurally
would need exactly the second rule this paragraph says the grammar avoids.

Three ext mechanics the implementing agent should not rediscover mid-card:
`Ext::TreeSitter` returns **flat** captures with **byte** offsets — nested sections arrive as
overlapping ranges in one frozen array, so the chunker rebuilds the tree by range containment
and converts bytes to lines itself (`treesitter.rs:23,29-41`; `FileSymbols#line_for` is the
in-repo precedent) — and `"markdown"` is the **block** grammar only: heading and paragraph
content is an opaque `(inline)` node, harmless for section chunking.

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

Scenario: a setext-headed document is chunked honestly
  Given a markdown file whose headings are setext underlines
  When it is chunked
  Then it falls to the paragraph floor and the coverage contract holds

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

**Part three — code by its top-level definitions** (formerly B9), on part two's generalised
`Queries.fetch`.

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
  Then the unit count is at most one per five lines — the same threshold the escalation
  trigger binds, so the AC and the trigger cannot disagree
```
→ spec file: `spec/lain/survey/chunker/code_spec.rb` (includes B4's contract)

**Escalation triggers:**
- A `symbols.scm` returns overlapping or nested spans (a method inside a class both reported).
  Gap-free coverage assumes a flat top-level partition; nesting is a granularity policy decision
  — stop rather than picking one.
- Coverage requires editing an existing `symbols.scm`. Those files serve `Tools::FileSymbols`
  in production (`file_symbols.rb:109` is the sole `Queries.fetch` caller — `CodeOutline` uses
  ast-grep patterns, not these queries).
- The gap-unit rule produces more units than lines/5 on a real file. That makes marking useless
  — report the measurement rather than shipping it.

---

### B5 — Walk a directory, and project what the survey may see [risk: high]

**Blocked on:** nothing — no plan-A file is touched; may run concurrently with plan A
**Files:** create `lib/lain/survey/walk.rb`, `lib/lain/survey/withheld.rb`,
`lib/lain/survey/projection.rb`,
`spec/lain/survey/walk_spec.rb`, `spec/lain/survey/withheld_spec.rb`,
`spec/lain/survey/projection_spec.rb`; modify `lib/lain/sensitivity/regions.rb`,
`lib/lain/middleware/redact_secret_reads.rb`,
`spec/lain/middleware/redact_secret_reads_spec.rb`
**Reuse:** `Tools::Grep::RubySearch#files_under` and `#skip?` (`grep.rb:114-121`) as the
in-process walk template; `Lain::Sensitivity#classify` (`sensitivity.rb:419`) and
`Verdict#denied?`/`#gated?`; `crates/lain-core/src/grep.rs:275` for the binary-detection shape
(reference only — this card stays in process); `Sensitivity::Regions.detect` and
`Sensitivity::Ledger#outstanding` (`ledger.rb:149-159`) with `complete: true`;
`RedactSecretReads::PLACEHOLDER` (`redact_secret_reads.rb:86`) — the format **moves** to
`Sensitivity::Regions::PLACEHOLDER` and the middleware references it
**Shared-file wiring:** `require_relative "survey/walk"`, `"survey/withheld"` and
`"survey/projection"` in `lib/lain/survey.rb`

One card, two commits — formerly B5 and B17, merged because walking and projecting are one
admission policy: "which paths enter, and which bytes of them" is a single review subject, and
split, the withheld/gated/denied routing was decided in one card and enforced in another.
**Commit one** is the walk and `Withheld`; **commit two** the projection through the region
ledger.

**Part one — the walk.** Answers an ordered list of readable paths under a root, plus **a named value for what was
withheld and why** — `Withheld` is its own object because four later cards consume it (B8
decides what withheld paths do to `#files`, B12/B14 render them, B12's gesture refuses an added denied
path with a report). Left as "the walk names it somehow", four agents in four worktrees invent
four answers.

A survey reads **every file it lists**, categorically unlike a diff review reading only what
changed, so every candidate routes through `Sensitivity#classify` — consulted directly,
because a directory walk is not an Effect through the handler chain and the upstream denial
handler never sees it. The routing is two-way, not three: a `:denied` path is withheld
(denial is not approvable — `48eab7b`'s posture); everything else, gated and ordinary alike,
enters the corpus and is projected through the region model by part two, with the gated verdict
kept on the listing so disclosure can say *why* a file arrived masked. Wholesale-withholding
gated files was this card's first draft and is overruled: it would make `/survey` stricter
than the read path over the same file.

**Two walk rules, stated so four agents cannot invent four answers:**

- **Binary:** a NUL byte in the first 8KiB means binary — a bounded sniff is permitted, a full
  read is not. This deliberately diverges from grep's semantics; `grep.rs:275`'s
  `BinaryDetection::quit(0)` comment already documents that the Ruby and Rust arms are not
  subsets of each other.
- **Ignores:** when the root is a git repository, the walk asks git —
  `git ls-files -z --cached --others --exclude-standard`, one spawn per open — so `tmp/`,
  `lib/lain/lain.so` and vendored trees never enter. An ignored path is simply not listed; it
  is not "withheld" (withheld means would-be-reviewed-but-protected). A non-repository root
  walks everything, which is what a LaTeX directory wants.

The walk reports a cheap **byte size** per path from `stat`; line counts arrive later, from
the identity pass (Grounding), not from a second read.

```gherkin
Scenario: a denied path never enters the corpus
  Given a directory containing an SSH private key
  When the directory is walked
  Then that path is absent from the files, and present in the withheld with its reason

Scenario: a gated path enters, carrying its verdict
  Given a directory containing a .env file
  When the directory is walked
  Then the path is listed rather than withheld, and its listing names it credential-shaped

Scenario: binary files are excluded and reported
  Given a directory containing a PNG and a Ruby file
  When the directory is walked
  Then only the Ruby file is in the files, and the PNG is withheld as binary

Scenario: an ignored path is not listed and not withheld
  Given a repository root whose gitignore covers tmp/
  When it is walked
  Then no tmp/ path is listed, and none appears in the withheld either

Scenario: the walk reports a size without reading file bodies
  Given a directory of fifty files
  When it is walked
  Then every path carries a byte size, and no read beyond the bounded binary sniff occurred

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
- A path classifies `:denied` that a human would obviously want surveyed. Report it; the rule
  table belongs to `Sensitivity`, not to an exception list here.
- `git ls-files` misses a case the survey needs (submodules, a worktree quirk) and the fix
  looks like re-implementing gitignore semantics in Ruby. Stop — that is the disabled
  `ignore`-crate arm's territory, and hand-rolling it is the thing the crate survey rule
  exists to prevent.

**Part two — the projection through the region ledger** (formerly B17). The
`Ledger#outstanding` call uses `complete: true`, which is sound precisely because the corpus
reads whole files; the shared `PLACEHOLDER` constant is what keeps the survey and the read
path from drifting on what a masked region looks like.

Joel's ruling (2026-08-09): a gated file enters the corpus **redacted to its released
regions** — wholesale withholding makes `/survey` stricter than the read path over the same
file; full entry makes it looser. The projection is applied at the SOURCE, for the
middleware's own reason ("the only place a leak can be stopped is before the thing that
remembers it"): above the source, the session, surfaces, journal and docent see only released
bytes, so no survey artifact can carry an unreleased secret.

**Every file is projected, not just gated ones** — the content boundary exists because a path
rule cannot see a key pasted into `notes.txt` (`redact_secret_reads.rb:17-23`). The scan
shares the identity pass's read and costs ~0.27ms/KB, linear.

The ledger is the run's one ledger, honouring its no-default, no-Null rules: `/survey` (B14)
reaches the switchboard's (`switchboard.rb:112`); `lain survey` (B11) constructs one for its
own process. With no approval surface wired into a survey, the masked projection simply stands
— the human can always open their own file in their own editor; releasing regions from inside
a survey is a filed follow-up, not this chunk.

Unit keys and `#identity` digest the **projection**: a release changes what the survey can
show, so the affected units' keys change and honestly demand a re-read, and `regenerated?`
reporting a release as a content change is telling the truth.

```gherkin
Scenario: a gated file enters masked, structure intact
  Given a directory containing a .env of three assignments
  When the corpus is built and the file's units read
  Then the key names are legible, each value reads as a placeholder, and no value's bytes
  appear anywhere in the projection

Scenario: the placeholder is the read path's own
  Given a projected file with two unreleased regions
  When its projection is rendered
  Then the placeholders match the redacted-read format — by shared constant, pinned by spec

Scenario: a released region is real bytes
  Given a file with two regions, one released to the run's ledger
  When it is projected
  Then the released region is its own bytes and the other is a placeholder

Scenario: a release is a content change, not a mystery
  Given a surveyed file with a masked region in one unit, all units marked
  When the region is released and the file re-projected
  Then that unit's key changes and the other units keep their marks

Scenario: an ordinary file with a pasted secret is masked too
  Given a notes file containing an API key assignment
  When it is projected
  Then the value is masked, though the path classified ordinary

Scenario: a denied path is still absent
  Given a directory containing an SSH private key
  When the corpus is built
  Then that path is withheld entirely — denial is not approvable, and projection does not
  resurrect it
```
→ spec files: `spec/lain/survey/projection_spec.rb`,
`spec/lain/middleware/redact_secret_reads_spec.rb` (the extraction must leave it green)

**Escalation triggers:**
- Moving `PLACEHOLDER` breaks a middleware spec pinning the literal string. The extraction
  must be behaviour-preserving; a changed rendering needs saying, not shipping.
- Projection cost dominates the open on a real tree — the scan is linear, but linear over
  megabytes of vendored blobs is real seconds. Report the measurement; B5's ignore rule is
  the intended relief valve, not a scan cap — a cap must come back through
  `complete: false` or releases are forgotten (`redact_secret_reads.rb:67-78`).
- The survey needs `complete: false` semantics anywhere. That means a partial read slipped
  in; the corpus reads whole files by design — stop.

---

### B6 — Let a changed file supply its hunks on demand [risk: high]

**Blocked on:** nothing — creates new files only; may run concurrently with plan A, but
re-ground the `MarkedChangeset` row-fetch cites at dispatch if A1 has merged by then
**Files:** create `lib/lain/review/lazy_file.rb`, `spec/lain/review/lazy_file_spec.rb`
**Reuse:** `Changeset::ChangedFile` (`changeset.rb:48-56`) — the messages that must be answered
identically (`old_path`, `new_path`, `path`, `binary?`, `status`, `hunks`);
`Changeset::ChangedFile::STATUSES` and its `fetch` discipline
**Shared-file wiring:** `require_relative "review/lazy_file"` in `lib/lain/review.rb`, after
`review/changeset`(25)

A bare `Enumerator` does not give laziness here: `Changeset#hunks` is
`files.flat_map(&:hunks).freeze` (`changeset.rb:141`), which drains it, and
`Hunk.keys` (`hunk.rb:39-45`) `tally`s twice over a whole file's hunks, so the batch must be
materialised anyway. A drained-once-re-yielded-twice Enumerator is either re-chunking or
memoising.

But a memo-on-self is **not** impossible on a frozen `Data` — an ivar holding a mutable box,
set before `super` in a custom initialize, memoises fine on the frozen instance (verified
under 4.0.6; assignment *after* `super` and `instance_variable_set` do raise). So this card is
a **design decision, not a forced move**, and it decides between three named shapes (Open
decisions): a boxed-memo `Data`; keeping `ChangedFile` untouched with a memoising `hunks`
member answering `to_ary` (which `flat_map` flattens, and which needs no parallel duck at
all); or a distinct lazy type answering `ChangedFile`'s messages and holding a chunk-supplying
callable. The axes that actually differ: duck duplication, `Ractor.shareable?` honesty, and
**equality**.

Equality is where the tree actually bites, so it is spec'd, not assumed: `MarkedChangeset.of`
keys its row table by the file object itself and `walk` resolves through a no-default
`rows.fetch(file)` (`marked_changeset.rb:89-93,100-103`). Value semantics guarantee a
re-derived equal file still fetches; identity semantics require the exact instances to flow
from `changeset.files` through every partition to every row, or a `KeyError` fires far from
its cause. Whichever shape is chosen, spec the equality answer alongside the
`Ractor.shareable?` answer — a `ChangedFile` is shareable today, and whatever this card ships
is honest about being less than that.

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

Scenario: equality is spec'd against the row table's fetch
  Given two lazy files derived over the same path and chunker
  When one keys a marked-changeset row table and the other fetches from it
  Then the spec pins whether the fetch resolves — the chosen semantics, exercised where they
  bite
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

### B8 — Read a folder as a review source [risk: high]

**Blocked on:** B2 — the `#identity` port message and the split law groups; B4 — the chunkers
and their dispatch; B5 — the walk, `Withheld` and the projection; B6 — the lazy file
**Files:** create `lib/lain/review/source/corpus.rb`, `spec/lain/review/source/corpus_spec.rb`,
`spec/lain/survey/chunker_spec.rb`; modify `lib/lain/survey/chunker.rb` (module body — the
dispatch below; its `require_relative` lines stay orchestrator wiring)
**Reuse:** B5's walk, `Withheld` and projection; B6's lazy file; B4's chunkers and dispatch;
`Source::DiffOrigin.already_local` (`source.rb:101`); the **universal** law group as split by B2;
`Review::Hunk.keys` batching (`hunk.rb:39`)
**Shared-file wiring:** `require_relative "source/corpus"` in `lib/lain/review/source.rb`

The third `Source`. Answers `#files` (lazy, via B6), `#base_ref` with a **fixed constant**,
`#head_ref` and `#identity` from content digests (B2's port message), `#file_at` from
disk, `#diff_origin` as `already_local`. It does **not** answer `#diff` — and does not need to,
because `Source::Repository` (`source.rb:153`) is the only path to the one byte consumer.

The fixed base is the incremental property: `Marks` refuses to cross a base change, so a base
moving per run would discard every mark on every re-survey.

**Chunker dispatch is this card's named object, and the chunker is an injected collaborator.**
`Survey::Chunker.for(path)` decides which chunker a path gets — `.md` to Markdown, a language
with a symbols query to Code, everything else to the paragraph floor (all B4) — and the
corpus takes `chunker:` in its constructor, defaulting to that dispatch. The injection is not a
convenience: it is the observation seam B10 pushes a counting chunker through to make the
laziness pins assertable against a real stack.

A unit becomes a `Hunk` under **its own scheme, `unit-content-v1`** (Open decisions — the
`hunk-content-v1` collision with a newly added diff file is demonstrable), with
`new_start`/`new_count` from the unit, `old_start`/`old_count` fixed at `0,0` (there is no old
side), and its label as `heading`.
**Every line, including empty ones, carries its `+` origin marker** — `Changeset#walk`,
`#anchor_at` and `#evidence` all read one (`evidence` is `line.byteslice(1..)`), and
`Changeset#context?` treats `""` as *context* (`changeset.rb:299`), so a blank line emitted
bare would silently grow an old side and materialise anchors against the fake base. A
deliberate carry, not an oversight. Two byte-identical units in one file fall through
`span_key` to `full_span_key`, which embeds `new_start` — so an insertion above a pair of
duplicate units discards both their marks; noted as accepted behaviour, spec'd so it is a
recorded property rather than a surprise.

`#identity` is `(path, content digest)` pairs over the **projection** (B5): one streamed read
and one blake3 per file, **no parse**, with the file-count `Bounds` check ahead of it and line
counts harvested in the same pass (Grounding). Round identity therefore does not
depend on chunking strategy — improving a chunker later does not open a new round over an
unchanged tree — and a region release changes exactly the files it touched.

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
  Given a directory containing an SSH private key
  When the corpus is built
  Then that path is absent from the files and readable from the withheld report

Scenario: a blank line is new-side content, not context
  Given a corpus file containing blank lines
  When its units become hunks and the changeset walks them
  Then every line carries the + marker, evidence round-trips byte for byte, and no old-side
  anchor materialises

Scenario: each file type meets its chunker
  Given a directory holding a markdown file, a ruby file and a log file
  When the corpus chunks them
  Then the dispatch hands each to sections, definitions and paragraph runs respectively

Scenario: a corpus key can never satisfy a diff mark
  Given a file surveyed as one unit and the same bytes newly added in a branch diff
  When both keys are taken
  Then they differ, because the schemes differ
```
→ spec file: `spec/lain/review/source/corpus_spec.rb` (includes the universal law group),
`spec/lain/survey/chunker_spec.rb`

**Escalation triggers:**
- The universal law group still cannot admit this source after B2's split. That means the split
  was drawn in the wrong place, and papering over it here hides the defect in the contract.
- `Anchor::InvalidLine` is raised anywhere. Old-side anchors should be unreachable (no context,
  no deletions), so a line-0 anchor means the walk reads a side that should not exist.
- The identity pass cannot run after the file-count guard without restructuring `Session.open`.
  The ordering is a grounding promise (refuse an oversized corpus without reading a byte) —
  report rather than quietly reading first.

---

### B10 — Address and present a corpus end to end [risk: medium]

**Blocked on:** B8 — the source under test; B15 — the lazy tri-state its laziness pins assert
**Files:** create `spec/lain/seams/survey_session_spec.rb`
**Reuse:** `Review::Session.open`/`.from_journal`; `Surface::Text`; `Marks#reconcile`;
B8's injected `chunker:` seam — the counting chunker rides a REAL stack;
`spec/lain/review/session_spec.rb` for the session-driving idiom
**Shared-file wiring:** none

A `:seam` card with **no lib changes** (placed in `spec/lain/seams/`, the existing seam home):
it drives the real `Session`, `Marks`, `MarkedChangeset`
and `Surface::Text` over a real `Source::Corpus` and pins that the assembled stack behaves. Every
prior card proves its own object; nothing yet proves they compose, and the spike showed the
composition is where the interesting properties live.

It also pins the laziness end to end — the claim B3, B6 and B15 exist to support and which no
single-object spec can make. The observations are made through B8's injected counting
chunker, never by spying on internals: "no file was chunked" means the injected chunker
counted zero calls through the real stack.

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
→ spec file: `spec/lain/seams/survey_session_spec.rb`, tagged `:seam`

**Escalation triggers:**
- Presenting forces chunking despite B3 and B15. That means their fixes did not reach the path
  a real session takes — this is the card that would find it, and it is a real finding, not a
  spec bug. Name which of the two the counting chunker implicates.
- A surface (not `Marks`) turns out to force hunks for the flat view — a rendering read no
  card scoped. Report the reader rather than widening B15 mid-card.

---

### B11 — Survey a path from the command line [risk: medium]

**Blocked on:** B3 — `Bounds::UNBOUNDED`; B8 — the source it opens; **A3 (plan A)** — the
registry, `#supports?` resolution, and the `exe/lain` enum shape this card mirrors
**Files:** create `lib/lain/cli/survey.rb`, `spec/lain/cli/survey_spec.rb`
**Reuse:** `CLI::Review` (`review.rb:106-175`) for the whole shape — `checked_surface`,
`Journal.open(paths:)`, the `ensure journal.close`, `drawn`, returning Strings so only the
frontend prints; the nested `class Review < Thor` in `exe/lain` (`:333-349` today) for the
subcommand shape; `Boundary#render` (`exe/lain:46-53`), which requires every refusal to be a
`Lain::Error` — cite these by construct when re-grounding, the file drifts
**Shared-file wiring:** in `exe/lain`, a nested `class Survey < Thor` mirroring `Review`
plus `desc` and `subcommand "survey", Survey` beside the existing `subcommand "review"`
(`:521` today); `require_relative "cli/survey"` in `lib/lain/cli.rb`

`lain survey PATH [--scope <strategy>] [--unbounded]`. Every `Lain::Review::*` name is read from
a **method body** — `lain.rb` loads `cli`(76) before `review`(86), so a class-body constant is a
load-time `NameError`.

The scope flag's whole surface is decided here, not discovered: the **default resolves through
the registry to the whole strategy**, exactly as an explicit scope does; an inapplicable
strategy — `--scope commits` over a corpus — refuses through `#supports?(source)` (the
partition chunk's port message), naming the strategy and what the source lacks.
`--unbounded` maps to `Bounds.new(max_files: Bounds::UNBOUNDED, max_lines: Bounds::UNBOUNDED)`
(B3's constant); `max_critique_lines` is untouched — `/critique` chunking keeps its ceiling
regardless of what a human is willing to scroll.

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
  Then it presents, with both the file and line ceilings lifted

Scenario: an inapplicable strategy refuses by name
  Given a directory surveyed with --scope commits
  When the scope is resolved against the corpus
  Then it refuses, naming the commit strategy and that the corpus has no commit history

Scenario: the absent scope resolves like an explicit one
  Given a directory surveyed with no scope flag
  When the default is resolved
  Then it went through the registry to the whole strategy, not a restated literal
```
→ spec file: `spec/lain/cli/survey_spec.rb`

**Escalation triggers:**
- A refusal escapes that is not a `Lain::Error` — `Boundary#render` turns only those into a
  clean `Thor::Error`; anything else reaches the user as a backtrace.
- Thor swallows a path colliding with a reserved command name (`help`, `tree`). `Review` needed
  `default_command :open` for exactly this.

---

### B12 — Grow a survey without losing what was read [risk: high]

**Blocked on:** B10 — the composed stack a widening rebuilds and replays over; B16 — the
`survey_add` verb part two routes
**Files:** create `spec/lain/review/session/extension_spec.rb`; modify
`lib/lain/review/session.rb`, `lib/lain/review/records.rb`,
`lib/lain/review/session/replay.rb`, `spec/lain/review/session_spec.rb`,
`spec/lain/review/records_spec.rb`, `lib/lain/cli/human_replies.rb`,
`lib/lain/review/handover.rb`, `spec/lain/cli/human_replies_spec.rb`,
`spec/lain/review/handover_spec.rb`
**Reuse:** `ChangesetOpened` (`records.rb:17-50`) as the record shape including its `Guardable`
block and `JOURNAL_TYPE` reopen; `Replay::TYPES` and the positional-round rule
(`replay.rb:33-45`); `Marks#reconcile`'s pruning semantics; B8's content-based address, which is
what lets an extension record a digest without chunking
**Shared-file wiring:** none

One card, two commits — formerly B12 and B13, merged because widening and its gesture are one
accretion feature: the API between them was one method, and the cross-card seam invited
exactly the "gesture resolves to a stale unit" ambiguity the trigger below guards. **Commit
one** is the widening and its records; **commit two** the gesture that drives it.

**Part one — the widening.** A survey accretes. A widening message rebuilds the changeset over
more paths, re-reconciles, and
journals a `CorpusExtended` record carrying the new digest.

**Name it `#widen` or `#add_paths`, not `#extend`** — `Object#extend` exists and shadowing it on
an aggregate is a debugging trap.

**Five ivars move, not three**: the memos `@digest` (`session.rb:219`), `@keys_by_path`
(`:347`) and `@hunk_keys` (`:349`) are invalidated, and `@changeset` is swapped for the wider
one with `@marks` re-derived through `reconcile`. `#marked` (`:251`) is deliberately *not*
memoized, documented as "a stale view is exactly the defect a marker exists to prevent" —
sibling memos silently staleified by a widening is that same defect. **Mutation is chosen
over rebuild deliberately**: `Session.from_journal` over the wider corpus would replay through
the only sanctioned constructor and cannot miss an ivar, but part two's live holders (`Gestures`,
`Handover`) hold *this* session object, and a widening that swaps the instance strands them.
Identity for the holders is the requirement; the five-ivar inventory is the price, and the
"widening invalidates every derived answer" scenario is what keeps the inventory honest.

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

**Part two — the gesture** (formerly B13). Reuse here: `Gestures` (`human_replies.rb:578-693`)
and its `review_open`/`review_mark`/`review_ask` routes (`:609-611`); B16's `survey_add` wire
verb — this part gives it meaning; `#gestured` (`:687-692`) as the refusal-reporting wrapper;
`NoReview` (`:103-120`) as the null; `Handover`'s acked-rail discipline (`handover.rb:29-34`);
B5's `Withheld` for the refusal reason and its projection for a gated addition.

The gesture that makes accretion usable: the human opens a file in the cockpit and adds it to
the survey in progress. The wire half already exists (B16); this part routes `survey_add`
through `Gestures` to part one's widening.

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

Scenario: adding a gated file masks rather than refuses
  Given an open survey
  When the add gesture names a credential-shaped file
  Then it joins with its unreleased regions masked, and the report says how many

Scenario: the gesture never raises out of the rail
  Given an open survey
  When the add gesture names a path that cannot be read
  Then a report comes back and no exception escapes
```
→ spec files: `spec/lain/cli/human_replies_spec.rb`, `spec/lain/review/handover_spec.rb`

**Escalation triggers:**
- B16's verb arrives with a payload this card cannot resolve to a survey path (a relative
  path, a buffer with no file). Report the payload shape rather than guessing a resolution.
- `Handover` cannot fold a refusal into an answer without raising, because the widening path
  raises something `Gestures`' `NoMethodError` rescue will not catch — the failure
  `handover.rb:20-27` warns ends the editor session.
- Adding a file mid-survey invalidates `ReviewView`'s line-to-row index and a stale gesture
  resolves to the wrong unit. A generation counter may be needed; that is a design decision.

---

### B14 — Open a survey from the chat prompt [risk: medium]

**Blocked on:** B11 — the CLI resolution and flag surface this command reuses wholesale
**Files:** create `lib/lain/cli/command/survey.rb`, `spec/lain/cli/command/survey_spec.rb`
**Reuse:** `CLI::Command::Review` (`command/review.rb`) wholesale — flag parsing, the `NO_EDITOR`
refusal (`:66-70`), the bind-before-draw ordering (`:164-171,181-182`), the `Handover`
construction (`:225`); `CLI::Survey`'s resolution from B11; `Registry#register`
(`command/registry.rb:27-32`)
**Shared-file wiring:** `require_relative "command/survey"` in `lib/lain/cli/command.rb`; one
entry in `Command::Surface#builtins`/`#review_commands` (`command/surface.rb:120-131`)

`/survey <path> [--scope <strategy>] [--unbounded]` in an attached cockpit — **the surface
Joel actually uses**, so it is not a thinner variant of B11; the editor is where a survey is
read and marked, and it carries the same flags B11 does (a cockpit that cannot open what the
CLI can is a parity bug waiting to be reported).

It refuses without an editor rather than drawing into `Surface::Null`, for `Command::Review`'s
stated reason: an opened review nothing drew and no gesture could reach is the failure the whole
review surface was written against.

**One open review per chat** (Open decisions): `Command::Surface` holds one `outbox:` across
`review_commands` (`command/surface.rb:131`), and this card does not renegotiate that — the
second `/review`-or-`/survey` refuses, naming the one already open. The refusal is an AC, not
a mid-card discovery.

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

Scenario: a second review surface in one chat is refused by name
  Given a chat with a branch review open
  When /survey is given a directory
  Then it refuses, naming the review already open — and the mirror holds for /review over an
  open survey
```
→ spec file: `spec/lain/cli/command/survey_spec.rb`

**Escalation triggers:**
- Binding a survey through `bind_changeset_review` needs a message `Handover` does not answer.
  The rail is generic in shape; if it is not, stop rather than adding a second parallel rail.
- The one-open-review refusal cannot see the other command's open state through
  `Command::Surface#outbox` alone. Report the state gap; do not add a second registry.

---

### B15 — Derive a file's review state without walking the corpus [risk: high]

**Blocked on:** **A1 (plan A)** — `marked_changeset.rb` is rewritten by A1's reader move, so a
worktree forked earlier is a doomed rebase. Nothing in plan B blocks it
**Files:** modify `lib/lain/review/marks.rb`, `lib/lain/review/session/marked_changeset.rb`,
`spec/lain/review/marks_spec.rb`, `spec/lain/review/session/marked_changeset_spec.rb`
**Reuse:** `HUNKLESS` (`marked_changeset.rb:52-58`) — an unchunked file already has an honest
state, which is this card's whole premise; `Marks#states`/`#state_for`/`#reconcile`
(`marks.rb:106-130`); `#marked`'s no-memo rule and its documented reason (`session.rb:251`)
**Shared-file wiring:** none

The card that makes the survey's laziness true where it would otherwise die. `Session#present`
(`session.rb:270-273`) builds `#marked` on every render, and `MarkedChangeset.of` walks
`keys_by_path` AND `Marks#states` over every hunk of every file — so whatever B3 and B6 do,
presentation re-chunks the corpus. No other card touches `marks.rb` or `marked_changeset.rb`.

The mechanism: a path that carries **no marks** is `unreviewed`, answerable from the marks
alone — O(marks), zero chunking, the `HUNKLESS` precedent extended from "no hunks" to "not yet
asked". Only a path that carries marks needs its current keys to decide
reviewed/partial/stale. So `Marks` answers which paths it holds marks for, tri-state is
derived per file on demand, and `#reconcile` prunes against the current keys of **marked paths
only** — pruning tautologically never needs the keys of a path with nothing to prune. Rows
keep the same-object pin (`session_spec.rb:518-523`): laziness lives in the derivation, not in
row identity.

Diff-source behaviour must be observably unchanged: every existing marks, marked_changeset and
session spec stays green untouched, and for an eager changeset the lazy derivation returns
exactly what `#states` returns today.

```gherkin
Scenario: an unmarked file's state costs no chunking
  Given a changeset whose files raise if their hunks are read
  And marks that name none of its paths
  When every file's state is derived
  Then every state is unreviewed and nothing raised

Scenario: a marked file is the only one that pays
  Given a changeset of ten files and a mark on one file's unit
  When states are derived
  Then only that file's hunks were read

Scenario: reconcile prunes without a corpus walk
  Given marks naming two of fifty files
  When the marks are reconciled against the changeset
  Then only those two files' hunks were read, and stale marks are pruned exactly as before

Scenario: a diff review sees nothing change
  Given a marked changeset over an ordinary branch diff
  When states are derived lazily and via the eager path
  Then the two answers are identical
```
→ spec files: `spec/lain/review/marks_spec.rb`,
`spec/lain/review/session/marked_changeset_spec.rb`

**Escalation triggers:**
- A marked file's tri-state cannot be derived without OTHER files' keys — a cross-file read
  inside `states`. That contradicts the per-path shape and B10 inherits it; stop.
- Keeping the same-object row pin requires memoizing rows in a way `#marked`'s no-memo doc
  forbids. The pin and the doc are both deliberate; report the conflict rather than picking a
  side.

---

### B16 — Emit the add-to-survey gesture from the editor [risk: medium]

**Blocked on:** nothing — lua and frontend spec only; may run concurrently with plan A
**Files:** modify `lib/lain/frontend/neovim/runtime/46_sidebar.lua` (or the sibling runtime
file the keymap honestly belongs to — content buffers may argue for another),
`spec/lain/frontend/neovim_spec.rb`
**Reuse:** the emission shape its three siblings already use —
`vim.rpcrequest(chan, "lain_command", <verb>, {...})` (`46_sidebar.lua:122,156`,
`51_thread.lua:613`) — and the view generation those emissions carry
**Shared-file wiring:** none

The wire half of accretion, split from B12's gesture because lua under `runtime/` is a different surface
with different specs, and the acked dispatch table has no verb that can mean "add this buffer"
(`human_replies.rb:609-611`). A keymap emits `survey_add` carrying the current buffer's
**absolute path** and the view generation, on the acked rail like its siblings. This card
proves emission only — the verb arrives and is acked; B12's gesture gives it meaning.

```gherkin
Scenario: the gesture emits the buffer's path
  Given an attached cockpit with a file buffer focused
  When the add-to-survey keymap is pressed
  Then survey_add arrives carrying that buffer's absolute path and the view generation

Scenario: an unrouted verb does not wedge the editor
  Given a cockpit whose Ruby side does not yet route survey_add
  When the keymap is pressed
  Then the editor session survives — the verb is acked or reported, never raised through
```
→ spec file: `spec/lain/frontend/neovim_spec.rb`

**Escalation triggers:**
- The acked Router refuses verbs it has no route for in a way that ends the session — then
  emission cannot land ahead of its route, and B16 must merge into B12. Report rather
  than wiring a stub route.
- The keymap needs a buffer or window API the runtime files do not already use. Note which,
  so the review panel sees the new surface area.

---

### B18 — Let presentation cost only what has been read [risk: high]

**Added 2026-08-09, during execution.** B15 discovered that its own card's premise is false:
a mark is `(hunk_key, state)` and `hunk_key` is a **one-way blake3 digest**
(`records.rb`'s `HunkMarked`, `hunk.rb:83-85`), so `Marks` cannot name the paths it holds
marks for — at any cost. Two of B15's four scenarios therefore had no implementation, and
B15 shipped the honest subset (laziness while the mark set is empty) with the limit pinned
by a spec. **B10's "presenting chunks nothing" premise depends on this card, so it lands
before B10 dispatches.**

**Blocked on:** A3 and B2 — both rewrite `session.rb`, which this card edits; B15, whose
guard this makes fire
**Files:** modify `lib/lain/review/lazy_file.rb`, `lib/lain/review/session.rb`,
`lib/lain/review/marks.rb`, `lib/lain/review/session/marked_changeset.rb`,
`spec/lain/review/lazy_file_spec.rb`, `spec/lain/review/session_spec.rb`,
`spec/lain/review/marks_spec.rb`, `spec/lain/review/session/marked_changeset_spec.rb`
**Reuse:** `HUNKLESS` (`marked_changeset.rb`) — an unchunked file already has an honest
state; B15's empty-mark-set short circuit in `Marks#reconcile`, which this extends from
"no marks at all" to "no marks on this path"
**Shared-file wiring:** none

**The route taken, and the two rejected — corrected after B15's review.** B15 named three,
and the panel **measured route 3 and found it insufficient on its own**:

1. **Journal the path with the mark** (`records.rb` + `replay.rb` + `session.rb`). Makes
   B15's mechanism literally true. **Not taken**: `hunk_marked` records are already
   journaled, so this is a persisted-record-shape change with a migration, and old journals
   would replay pathless and degrade silently to the eager walk. That is Joel's call, not an
   execution-time patch. It remains available if the seam below proves harder than it looks.
2. **Accept that only opening is lazy.** What B15 shipped, and honestly pinned. The panel
   measured its true reach as narrower than the card claimed: **a resume of a round that
   marked nothing, and only until the first question is asked** — because `Session.open`
   composes its digest through `keys_by_path` before `initialize` ever reconciles.
3. **`LazyFile#chunked?` alone.** ~~Taken~~ **Insufficient, measured.** `MarkedChangeset.of`
   guards on `keys_by_path.empty?` — *all or nothing*. A **partial** table falls through to
   `marks.states(changeset)` and walks every hunk of every file. On a 50-file corpus: 0 keys
   → 0/50 chunked, **1 key → 50/50**, 5 keys → 50/50. A corpus session hands `.of` exactly
   the partial table that gets zero benefit.

**So this card is route 3 AND the per-path seam** — which is route 1's work minus the
journal change. It must land:

- **`Marks#state_of(keys)`**, the honest object. B15 identified it and correctly declined to
  build it unwired; it is what turns the `NO_STATES` ternary into real polymorphism, and
  without it `.of` cannot consult marks per path at all.
- **`LazyFile#chunked?`**, so `keys_by_path` can name only what the corpus has read.
- **`Session#keys_by_path` and `#hunk_keys`**, eager and on no card's Files line in either
  plan.
- **`Session.digest_parts`' `keys_by_path` call** (`session.rb:110`), which makes `.open`
  eager regardless of everything else. **Check B2 first**: B2 replaces `digest_parts`'
  composition with a source-supplied `#identity`, which may already remove this walk. If it
  has, say so and drop it from scope rather than re-fixing it.
- **The two `Marks` doubles** B15 named (`session_spec.rb`, `lazy_file_spec.rb`, both
  `instance_double(Marks, states: {...})`), which pin `.of` to the whole-changeset walk.

**One hazard this card must not reintroduce.** `.of(cs, fully_marked_marks, keys_by_path: {})`
already renders a fully-reviewed file as `unreviewed`, silently — unreachable from `lib/`
today because only `Session#marked` passes the argument and always passes it full. Making the
table legitimately partial makes that path reachable. The class doc's own warning applies:
putting both meanings on one message name is how a table renders the wrong glyph with nothing
failing.

```gherkin
Scenario: presenting a corpus nobody has read chunks nothing
  Given a corpus whose files raise if their hunks are read
  When the session is presented
  Then it presents and nothing raised

Scenario: one mark does not cost the corpus
  Given a corpus of fifty files with a mark on one file's unit
  When the session is presented
  Then only that file's hunks were read

Scenario: an unread file still has an honest state
  Given a corpus file nothing has chunked
  When its row is read
  Then it is unreviewed, by the same rule a hunkless file already answers

Scenario: a diff review sees nothing change
  Given a marked changeset over an ordinary branch diff
  When it is presented before and after this card
  Then the rendered states are identical

Scenario: the row identity pin still holds
  Given a partitioned marked changeset
  When one file's row is read at whole scope and under its partition
  Then they are the same object
```
→ spec files: `spec/lain/review/lazy_file_spec.rb`, `spec/lain/review/session_spec.rb`,
`spec/lain/review/session/marked_changeset_spec.rb`

**Escalation triggers:**
- `#chunked?` cannot be answered without forcing the chunk. Then the message is a lie and
  the route is dead — stop, and route 1 becomes Joel's call.
- Making `keys_by_path` lazy requires memoizing `#marked`, which `session.rb` documents as
  forbidden ("a stale view is exactly the defect a marker exists to prevent"). Report the
  conflict rather than picking a side — B15 hit the same tension and correctly stopped.
- The two `Marks` doubles B15 named (`session_spec.rb` and `lazy_file_spec.rb`, both
  `instance_double(Marks, states: {...})`) need more than the one-word edit B15 predicted.
  That would mean the per-path seam is wider than `#states` was.

---

### B19 — Draw a survey without reading it [risk: high]

**Added 2026-08-09, during execution.** B3's panel found that `review_view.rb` forces every
file's hunks **at render, in both flat and grouped scopes**, so B3's and B8's laziness dies
the moment a corpus is drawn in the cockpit. B8 measured the ordering and proposed this split
rather than widening its own card, which was the right call: the surface is not even the first
offender.

**Blocked on:** B18 — measured, and this is why the split exists: `Session.open` chunks 0/50
but `Session#present` chunks **50/50** through `Session#keys_by_path`, **before any surface is
involved**. Fixing the renderer first fixes nothing.
**Files:** modify `lib/lain/frontend/neovim/review_view.rb`, `lib/lain/review/partition.rb`,
`lib/lain/review/session/marked_changeset.rb`, and their specs
**Reuse:** B3's `#rendered_lines` seam — a file already answers a size without chunking, which
is the shape a header needs; B8's `Corpus`, whose bound is computed from the identity pass
**Shared-file wiring:** none

**The three sites, all in `review_view.rb`, all in flat *and* grouped scope:**

- `:428` `partition_header` → `PartitionRow#added`/`#deleted` → `Undetailed.counted` →
  `file.hunks`
- `:421` `keys_by_path` → `Hunk.keys(file.hunks)` for **every** file
- `:439` `first_line` → `file.hunks.first`

All three want real hunks, so this is a **rendering decision**, not a mechanical fix: what may
a heading claim about a group nobody has read, and how does a gesture resolve a key for a file
nobody has chunked? A `+N -M` that silently means "unknown" is the rendered-zero the partition
chunk's Open decisions already refused once.

**`Partition::Undetailed`'s docstring is wrong and must be corrected regardless of what else
this card does**: its "nothing renders this yet" disclaimer is attached to `binaries`, while
`added`/`deleted` **are** drawn today. That sentence is how the problem stayed invisible.

```gherkin
Scenario: drawing a corpus reads only what it shows
  Given a corpus of fifty files whose hunks raise if read
  When the review view is drawn at whole scope
  Then it draws, and nothing raised

Scenario: a group heading is honest about what it has not read
  Given a partitioned corpus nobody has chunked
  When a partition heading is drawn
  Then it does not render a count it cannot know, and does not render a zero that means unknown

Scenario: a gesture still resolves on a file that has been read
  Given a corpus file the human has opened
  When a mark gesture resolves its key
  Then it resolves, and only that file was chunked

Scenario: a diff review draws exactly as before
  Given an ordinary branch changeset
  When the view is drawn at both scopes
  Then the rendering is byte-identical to before this card
```
→ spec files: `spec/lain/frontend/neovim/review_view_spec.rb`,
`spec/lain/review/partition_spec.rb`

**Escalation triggers:**
- A heading cannot be honest without either chunking or rendering something a reader could
  mistake for a real count. That is a design question about what a survey heading means —
  stop and report the shape you reached.
- Making `keys_by_path` per-file conflicts with B18's shape. B18 owns that seam; inherit it
  rather than building a second one.

---

### B20 — Add one path to a live survey [risk: high]

**Added 2026-08-09, during execution**, when B12 escalated its own part two with three reasons
a panel then verified. B12 part one landed the widening — `Session#widen`, `Widening`,
`CorpusExtended`, the replay fold — and **all of it is unreachable from production**: zero
`lib/` callers. That is the unwired-features shape, and it is deliberate rather than an
oversight: the widener the gesture needs does not exist, and building it was outside B12's
files. **This card is what makes B12's work reachable. Part one is not done until this lands.**

**Blocked on:** B12 part one; B14 (the `/survey` command, landed) — but note **B14 alone does
not unblock this**: B14 supplies a *holder*, and the missing piece is a *widener*.
**Files:** modify `lib/lain/survey/walk.rb`, `lib/lain/review/source/corpus.rb`,
`lib/lain/review/handover.rb`, `lib/lain/cli/human_replies.rb`,
`lib/lain/frontend/neovim/gestures.rb` and their specs
**Reuse:** `Survey::Walk`'s private `#decide`/`#admit`/`#linked`/`#verdict_for` — **the whole
point is to reuse the classifier, not to re-derive it**; `Session#widen` and `Widening` (B12);
B16's landed `survey_add` emission; `Handover`'s existing rail shape
**Shared-file wiring:** none

**Why it is a card and not a fix.** `Survey::Walk`'s entire admission policy is private; its
only public surface is `root:`, `#files`, `#withheld`, `#each`. There is **no seam that yields
one `Listing` for an arbitrary path under the same verdict**, and a panel checked the three
candidates: a wider root admits the whole subtree and blows the file ceiling; `Corpus` only
ever consumes what the walk produced and never mints a `Listing`; B8's `chunker:` seam is
about how a file divides, not which files are in. Constructing a second `Walk` rooted at the
added file's directory is duplication with extra steps — and gets the relative path wrong.

**The hole to decide FIRST, before implementing.** `Walk#widened(absolute_path)` returning a
walk-duck built from the same `#decide` is the right instinct. What it does not answer is
**what the relative `path` of a file outside `root` is** — and that string is the corpus's
identity key and the `Reading#path` the chunker dispatches on. `Walk.contains?` refuses such a
path today. Decide the naming rule explicitly and write it down, or it will be discovered
mid-implementation. Widening the root instead is not a free answer: it changes every existing
path's key and would discard every mark, which is the property the fixed base exists to
protect.

**Do not ship a stopgap route that can only refuse.** B12 declined one and was right to: a
route that always refuses satisfies two ACs by construction, which is the same vacuity that
made two of part two's ACs unbuildable in the first place. B16's silent drop of an unrouted
verb is real (`rpc_thread.rb`'s `@routes[verb]&.call` acks and drops) but closing it deserves
a **generic** unrouted-verb report in a B16 follow-up, not a `survey_add`-shaped stub.

```gherkin
Scenario: adding a file widens the survey and keeps every mark
  Given a survey with every unit marked reviewed
  When a file beside it is added through the gesture
  Then no mark is lost, the new file's units are unreviewed, and only that file was chunked

Scenario: adding a denied path is refused with the classifier's own reason
  Given a survey and an SSH private key beside it
  When that path is added
  Then it is refused, naming the same reason the walk would have withheld it for

Scenario: adding a gated file masks rather than refuses
  Given a survey and a .env beside it
  When that path is added
  Then it enters redacted to its released regions, as the walk would have admitted it

Scenario: adding a path already in the survey refuses without journaling
  Given a survey containing one file
  When that same file is added again
  Then it refuses and no extension record is written

Scenario: a refusal never raises out of the rail
  Given an attached cockpit
  When any of the above refusals fires
  Then the editor session survives and the human is told
```
→ spec files: `spec/lain/survey/walk_spec.rb`, `spec/lain/review/source/corpus_spec.rb`,
`spec/lain/review/handover_spec.rb`, `spec/lain/cli/human_replies_spec.rb`

**Escalation triggers:**
- The relative-path rule cannot be settled without either moving the root (which discards
  every mark) or admitting a second naming scheme. Stop — that is a plan decision.
- Reusing `#decide` requires making more of `Walk` public than one message. The classifier
  staying single is the reason this card exists; widening its surface to five methods trades
  the reason away.
- A widening needs to re-run the identity pass over files already in the corpus. It must not —
  B8's identity is per-file and content-addressed precisely so a widening pays only for what
  it adds.

## Integration checks

- `bundle exec rake pspec` green, example **count** compared against the pre-chunk baseline — a
  dead worker reports as "fewer examples, 0 failures, non-zero exit".
- `bundle exec rubocop` clean. **Never** name a `.toml` or `.scm` on a rubocop command line; a
  bare invocation is safe because the default `Include` patterns do not match them.
- `bundle exec rake compile` — no Rust changed; this is a regression check that nothing disturbed
  `ext/lain`.
- `pre-commit run --all-files`, including `yard-lint`.
- `spec/output_discipline_spec.rb` green — `CLI::Survey` returns Strings and must not print.
- A **laziness check** the suite cannot express as a unit: survey this repository's `lib/`
  with a counting chunker injected through B8's `chunker:` seam and confirm the number of
  files chunked is far below the number listed. B10 pins the property; this confirms it at
  real scale, through the seam the plan owns rather than ad-hoc instrumentation.
- **Manual pass owed to Joel:**
  1. `/survey` a real directory in the cockpit; mark units, annotate one, confirm the tri-state
     renders and gestures land.
  2. Add a file mid-survey via B12's gesture and confirm no mark is lost.
  3. `/survey ~/dev/resume` — the non-Ruby, non-markdown case that motivated the paragraph floor.
  4. `/survey` a directory holding a `.env`: confirm it arrives masked with key names legible,
     the disclosure says why, and — after releasing a region through a read approval in the
     same chat — the affected unit honestly demands a re-read.
  5. Open `/survey` with a branch review already open and confirm the refusal names it.
- **Follow-ups to file, not to build here:** wire `Review::Delta` (it exists, is spec'd, and
  nothing calls it — it is the answer to "what must I re-read after a rebase"); revisit whether
  `Marks` can survive a base move now that the context-window mechanism is pinned by B1; an
  approval surface for releasing regions from *inside* a survey (B5's projection stands masked without
  one); region-redacted entry currently digests the projection — revisit if release-driven
  re-reads prove noisy at scale.
