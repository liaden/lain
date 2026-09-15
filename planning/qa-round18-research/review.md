# Round-18 research: the review, survey and critique surfaces

Tree: `/home/tara/dev/lain` at `90f081b9`. Read-only. Nothing was run except `git log` / `git show` /
`grep`. Evidence: `planning/qa-findings-round18-2026-09-15.md` and
`~/tmp/lain-qa-round18/records/fork-{survey,review}-report.md`.

**A note on SHAs.** The archived round-11 chunk (`planning/archive/chunk-qa-round11-survey-surfaces.md`)
lists Landed SHAs from a history that was later rewritten. Its SHAs are **not ancestors of HEAD**. The
twins on `main` are:

| round-11 card | archived SHA (off main) | twin on main |
|---|---|---|
| T6 | `60be33f2` | `bad7d081` |
| T7 | `d18b579c` | `34d54994` |
| T10 | `0669d378` | `dd5cfdec` |
| T13 | `338862d3` | `45334f57` |

Checked with `git merge-base --is-ancestor`. `02885580` is on main.

Classification key: (a) regression by the latest fix · (b) gap outside a card's scope · (c) pre-existing,
never touched · (d) by design, ruling owed/taken · (e) finding/scenario wrong.

---

## F133 — a note's `anchor_text` journals a masked secret raw (HIGH)

### 1. Mechanism, re-verified

The mechanism is correct but cited one hop late. `48_annotate.lua:182` only copies `note.anchor_text`
onto the wire. The raw read happens earlier, **at placement**, in two places:
- `:LainNote`: `48_annotate.lua:544`, `anchor_text = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]`;
- `:LainNoteCompose`: `52_note_compose.lua:231`, the same read, taken at pane open.

On a survey that buffer is the NEW slot. It is a real file buffer loaded from disk:
`47_diff.lua:184-191` (`bufadd` + `bufload`).

The Ruby path applies no projection at any step:
1. `rpc_thread.rb:717`: `ReviewWrite.normalized` does `Wire.text(note["anchor_text"])`, which only
   interns;
2. `handover.rb:271-278` (`wrote_annotation`) → `anchor` (`:338-341`);
3. `session.rb:372-380` (`annotate`) → `AnnotationPlaced.new(... anchor_text: anchor.anchor_text ...)`
   → `@journal << placed`.

`Handover` holds no ledger or projection. `Command::Survey` does hold one (`command/survey.rb:110`,
`@projection`), and it builds the `Handover` in the same object (`:294-300`) without passing it in.

The finding's "likely wider" is broader than stated. `/review` has **no projection anywhere**:
- `grep Projection|Regions|ledger|Masking` over `lib/lain/review` and `cli/command/review.rb` hits only
  `source/corpus.rb`.
- So on a changeset review, the note's `anchor_text` (either side), the docent brief's hunk and the
  `/critique` brief (`critique.rb:289`, `Patch.of`) all carry raw diff bytes.

That is the secret-boundary researcher's territory. The point here is that on `/review` there is no
guarantee for `anchor_text` to break; on a survey there is.

### 2. Most recent relevant changes
- **`dd5cfdec` (round-11 T10, "Say what Projection actually guarantees").** It rewrote
  `survey/projection.rb:43-50` to separate the raw NEW buffer ("correct") from "the artifact itself:
  the journal, the docent brief, a `/critique` prefill". The note rail was named as the reason the
  buffer is raw. Nobody traced a note's words from that buffer into the journal.
- **The code path is older.** Placement read: `ba379be5`, then `82ffa984` (the compose pane). Handover
  path: `485246e9`. Session record: `3d460deb`, then `53515bbf`.
- Round 17 did not touch any of it.

### 3. Why it is this way
- **Human ruling, round 11:** *"`/survey` opening the raw file is CORRECT and is not a defect … neither
  is fixed by masking the file"* (archived chunk, Intent).
- **T10's own escalation trigger:** *"If narrowing the claim reveals that a surface other than the
  annotation pane shows unprojected bytes — the journal, the docent brief, a `/critique` prefill —
  stop immediately and escalate. That would be a real leak."* Nothing escalated. The note→journal hop
  was not examined.
- **The raw bytes are deliberate evidence for drift.** `rpc_thread.rb:549-560`: *"text interned and
  NEVER stripped, because an anchored line's indentation is precisely the evidence a drift check
  compares"*. `changeset.rb:269-272`: *"EVIDENCE, so decoded but never scrubbed"*.
  `48_annotate.lua:31-38`: drift is measured in the editor, both halves off one buffer.
- **The scenario promises exactly this artifact.** `planning/qa/scenarios/survey.md` §4 says the
  guarantee covers *"the corpus digest, the journal, and anything a docent question sends to the
  model"*.

### 4. Classification
**(b)**, a gap outside round-11 T10's scope that T10's own escalation trigger described. It is not a
regression and round 17 never touched it.

### 5. Constraints and open questions

**Constraints**
- **Keep the raw buffer (human ruling, round 11).** Do not mask the NEW buffer.
- **Drift must still be measured in lua** on raw buffer text (`48_annotate.lua:22-43`,
  `handover.rb:233-238`). A Ruby-side projection must apply AFTER the measurement. `drifted` is
  forwarded, never recomputed. `spec/lain/review/handover_spec.rb:472-487` pins the forwarding.
- **`Projection#project` is whole-file and reconciles the ledger** (`projection.rb:55-63, 97-107`,
  `complete: true`). Projecting a lone line through it would **forget releases** ("a partial scan
  reconciles away releases"). A single base64 line also may not be detected without its PEM context.
  The safe source of projected text is the corpus `Reading#content` (`corpus.rb:201`) at that line, or
  a mask derived from the whole-file regions.
- **"Journal a digest instead" changes a record contract.** `Session::Replay` rebuilds `Anchor`s from
  `record["anchor_text"]` (`session/replay.rb:172`). `Anchor#drifted?` compares text
  (`anchor.rb:152-164`). `records_spec.rb:280-295` pins blank and indentation-preserving `anchor_text`.
- **The `Wire.text` normalization is pinned** by `spec/lain/frontend/neovim/rpc_thread_spec.rb:799-801`.
- **The projection has to reach the rail.** `Command::Survey` owns the projection and `Handover` does
  not. Injection must follow CLAUDE.md, and the ledger must be the run's ONE ledger
  (`projection.rb:52-57`, "no default and no Null Object").
- **Note text.** `annotation_placed.text` (the human's own words) is also unprojected. Out of the
  finding's scope, but the same record.

**Open questions for the human**
- Should `/review` (changeset) notes and briefs be projected at all? No guarantee exists there today.
- Is masking `anchor_text` acceptable given that a later drift or replay would then compare against
  masked text?

---

## F143 — a ceiling-refused `/review` still binds the verdict rails (MED-HIGH)

### 1. Mechanism, re-verified
The citation is correct: `cli/command/review.rb:184-193` runs `round` (`Session.open` journals
`changeset_opened`, `session.rb:122-128`), then `wired`, then `drawn`.
- `wired` (`:234-237`) does **both** `env.replies.bind_changeset_review(handover)` and
  `@outbox.hold(...)`.
- `drawn` (`:284-288`) calls `session.present`, which raises `Bounds::TooLarge` at `session.rb:300`
  before the surface is told.

The finding is **incomplete in three ways**:
1. **The outbox also holds the refused round** (`review.rb:236`, before the draw). So:
   - `/critique` would critique it (`middleware/skill_dispatch.rb:66,71` reads `@outbox.open?` and
     `held_changeset`);
   - `/review-submit` on a PR target would try to post a review of it.

   This is inferred from the code and was not driven.
2. **`/survey` has the same rails half.** `command/survey.rb:227` binds before `shown` (`:228`). The
   line-ceiling and `UnsupportedScope` refusals raise from `present`, AFTER the bind. `/survey`
   deliberately holds only after the draw (`:233-237`), so its outbox is clean but its rails are not.
3. **Nothing withdraws the previous sidebar.** Nothing in the refusal path calls the surface (a
   property `5607b2db` asserts), so the old `lain://review` stays up.

### 2. Most recent relevant changes
- **The latest touch to `review.rb` is `c3ccaa39` (r17 T26).** It changed `refuse_unreadable!` and
  added `resolved_target` (`:195-209`). The `round → wired → drawn` order is untouched.
- **The order dates from `7b6fa060`**: *"The bind comes before the draw because a human fast enough to
  answer between the two would send a verdict nothing could route."* `d2bc32df` added the hold beside
  it (`wired`).
- **`5607b2db` ("bound every presentation, not just the text one") made refuse-after-open the design.**
  From its commit message: *"CLI::Review loses 'a refusal leaves no record of a round', because the
  guard runs one call after Session.open journals; buying it back needs the second caller this card
  deleted, so the property asserted instead is that no surface is told."* It also added the comment now
  at `review.rb:278-283`: *"the round it refused stays open with its rails bound. That is the honest
  state, and the next `/review` rebinds them."*
- **Round-11 T6 (`bad7d081`) reconsidered the ordering for `/survey` only.** The hold moved after the
  draw so a refusal cannot lock out `/review` (`survey.rb:201-206`; the "stranding pair" at
  `spec/lain/cli/command/survey_spec.rb:840-870`). `/review` kept hold-before-draw, because a second
  `/review` over a `/review` rebinds.

### 3. Why it is this way
The design accepts "bound but undrawn" as the honest state, with recovery by re-issuing `/review`
(`review.rb:211-215` and `:278-283`; `survey_spec.rb:763-768` calls it "the documented recovery from a
bounded refusal").

What it never considered:
- a VERDICT or MARK landing on the undrawn round;
- `--permissive` making that verdict succeed;
- the stale sidebar.

`session.rb:280-285` states the stake: *"a refusal that has already drawn is not one … the human
believes they are looking at the whole changeset."* The scenario records only the journal half as known
(`changeset-review.md` §4: "documented, deliberate").

There is also an inconsistency in the spec tree. `spec/lain/cli/command/review_spec.rb:596-597` says
*"a bounded refusal must leave it holding NOTHING"*, but no example asserts `outbox` is not open after
`TooLarge`, and the code holds before the draw. The comment is false and unenforced.

### 4. Classification
**(b)**, a consequence of the refuse-after-bind design (`5607b2db`, `7b6fa060`) that nobody examined.
It is not a regression from round 17. The "rails bound" half is **(d)**, by design with an explicit
comment; the verdict-lands and stale-sidebar halves were never ruled on.

### 5. Constraints and open questions

**Constraints**
- **One enforcer.** `Bounds#check_presentation!` must have exactly one caller, `Session#present`
  (`spec/lain/review/bounds_spec.rb:880-930`, a Ripper count). Do not add a pre-check in the command.
- **Bind before draw** stays for the "human fast enough" race (`review.rb:171-177`,
  `survey.rb:201-202`). A fix is more likely "refuse gestures on an undrawn round" (a state on
  `Handover`/`Session`) or "unbind/rebind to the prior Handover on raise" than reordering.
- **Specs to keep green:**
  - `review_spec.rb:614-635`: nothing drawn on refusal (`sink.string` empty);
  - `survey_spec.rb:840-870`: outbox not open after a line or scope refusal;
  - `review_spec.rb:763-778`: rebind over a prior review.
- **The journal half stays.** `Session.open` journals before present (`session.rb:104-128`, "nothing is
  ever held without a record behind it").
- **Gesture rails must never raise** (`handover.rb:13-17`, the Redraw doc `:102-106`). An
  "undrawn" refusal has to be a String answer.

**Open questions for the human**
- On a ceiling refusal, should the previous review's rails and sidebar be **restored** (the prior round
  stays live), or cleared to a placeholder with nothing bound?
- Should `/review` adopt `/survey`'s hold-after-draw too, so the outbox is not left holding a refused
  round?

---

## F144 — a changeset review's NEW side is the working tree, not the reviewed head (MED-HIGH)

### 1. Mechanism, re-verified
The citation is correct:
- `ChangesetDiff#drawn` (`frontend/neovim/changeset_diff.rb:127-134`) posts `old_lines` (from
  `changeset.old_side`, i.e. `git show base:path`) plus `revisions` (`:159`, `new => head_ref`).
- `47_diff.lua:723-728` then does `new_buf = review_diff.new_side(path)` (`bufadd` + `bufload` of the
  disk file, `:184-191`) and stamps it with `new_revision`.
- Notes read `anchor_text` from that buffer (see F133) and journal `revision = head_ref`.

No source performs or checks a checkout. `grep checkout|switch|worktree` over `lib/lain/review/source/`
and `lib/lain/cli/review.rb` returns nothing. This covers **PR reviews too**: `Source::GithubPr` fetches
objects (`github_pr.rb:310-323`), so the human's checkout is typically not the PR head at all.

The finding is complete. One addition: the drift comparison is also against the working tree
(`48_annotate.lua:31-38`), so `drifted: false` is internally consistent and still false about the named
revision.

### 2. Most recent relevant changes
- **`a27b84fe` ("neovim: a changed file as a real pair…")** built `47_diff.lua`. `e536eb63` later
  touched `new_side` resolution for surveys.
- **Round-11 ruling:** raw file on a survey's NEW side (see F133).
- **Round-17 T21 (`3ec1dc79`)** fixed the same class for `/critique` only: children read a detached
  checkout of the head (`critique.rb:9-20`, `Checkouts` `:397-435`). F108 was *"critique reads the
  working tree"*.

### 3. Why it is this way
The original design, `planning/specs/chunk-review-surface.md`:
- **T15:** *"New side is the real file (`buftype=""`, so the language server and treesitter
  attach)."*
- **T5's AC:** *"every new-side anchor resolves against the working tree … each new-side anchor's
  anchor_text equals that line in the file on disk"*.
- **T16's AC:** *"the recorded anchor names side new, that file line, and the head revision"*.

The design equated the working tree with the head and never stated the precondition. The in-code
rationale for a real file is `47_diff.lua:8-11`: *"THE NEW SIDE IS THE FILE, not a copy of it … A
`nofile` copy would … silently lose all of it"* (LSP and treesitter). The `nowrite` fallback and the
reason `nofile` was rejected are at `:154-183`. The seam spec fixture always has the checkout at head
(`spec/lain/review/changeset_spec.rb:92-93, 977-1005`, "resolves every new-side anchor against the
file on disk").

T21 recognised the working-tree hazard for model reads (`critique.rb:11-13`: *"the human goes on
editing while a round is open, so an inline critique reads bytes nobody reviewed"*) and deliberately
left the human surface alone.

### 4. Classification
**(c)**, pre-existing since the review-surface chunk. The design's hidden precondition was never
stated, and round 17 did not touch it.

### 5. Constraints and open questions

**Constraints**
- **LSP and treesitter.** `buftype=""` on the NEW side is a stated requirement
  (`spec/lain/frontend/neovim/diff_mode_spec.rb:227-236`, "is the real file on disk, not a copy of
  it"). A `git show` buffer loses that.
- **Extmark rules** (`47_diff.lua:20-26`): refill in place, unstamp on leave.
- **No shelling out from lua** (`47_diff.lua:28-40`, diffview#466). Ruby must read `git show head:path`
  and post it, as it already does for `old_lines`.
- **Drift stays measured in the editor buffer** (`48_annotate.lua:22-38`).
- **Survey behaviour stays.** A survey's NEW side must stay the raw disk file (round-11 ruling). Any
  change is changeset-only, keyed on `Source#sides`.
- **`changeset_spec.rb:977-1005` assumes disk == head.** A fix that detects dirt or not-at-head must
  not break the at-head case.
- **The `revision` on a note is load-bearing** for `Submit::Placer#revision_moved?`
  (`review/submit.rb:230`).

**Open questions for the human**
- Show NEW from objects when the checkout is not at head or is dirty (losing LSP there), or refuse the
  open, or flag it in the banner?
- For PR reviews, where the local checkout is almost never the PR head, what is the intended NEW side?

---

## F157 — review session, notes and docent threads are not restored on `--resume` (MEDIUM)

### 1. Mechanism, re-verified
Correct. Neither `Review::Session.from_journal` (`review/session.rb:147-156`) nor `Docent#replay`
(`review/docent.rb:379-382`) has a caller in `lib/`:
- `grep` finds only doc references (`session.rb:45,221`, `submit/outbox.rb:15`);
- `cli/resume.rb` contains no `review` or `docent` (`grep -l`: nothing).

Both commands always call `Session.open` (`command/survey.rb:269-274`, `command/review.rb:239-243`),
which starts a **new round** and never consults the journal. `Docent.for` builds fresh `Threads`
(`docent.rb:272-276, 297`).

### 2. Most recent relevant changes
- `3d460deb` ("review: the session, rebuildable from its journal…"), review-surface chunk T13.
- `b3fbada1` (the docent, with `replay`).
- Neither was ever wired into `--resume`. Round 17 did not touch either.

### 3. Why it is this way

**The capability's stated intent.**
- `session.rb:5-8`: *"rebuildable from the journal, so a chat restarted mid-review resumes rather than
  losing everything a human did (octo#118 and octo#980…)"*.
- Chunk-review-surface T13: *"so a chat restarted mid-review resumes rather than losing state"*.
- `docent.rb:367-369`: *"so the next #open renders what the recorded run rendered, with no provider
  call"*.

**Three decisions that argue against the naive wiring.**
- **Rounds are round-scoped.** `session.rb:32-34`: *"ANNOTATIONS ARE ROUND-SCOPED: produced, consumed,
  then historical. Nothing re-anchors a note onto a later round."* T13's AC: *"annotations do not
  carry forward into a new round"* (`session_spec.rb:177`). A `/survey` retyped in a resumed chat is,
  by today's code, a new round, and approving it over the prior round's blocker is consistent with
  that rule.
- **The Outbox rejected the journal as the holder.** `submit/outbox.rb:15-21`: *"It could have been the
  journal instead ({Session.from_journal} rebuilds a round from the record). Rejected because a rebuild
  has to regenerate the CHANGESET too, and the author goes on pushing — every annotation authored
  against the old head would then fail {Placer}'s `revision_moved`…"* That was about posting, but it
  is the same hazard for a resume.
- **`from_journal` reconciles marks** against the changeset as it stands now and raises on a base move
  (`session.rb:130-146`). A resumed survey's corpus digest can move whenever a file changed.

**The scenario overclaims.** `planning/qa/scenarios/survey.md` §7 check 4 says *"the exchange lands in
the chat's own journal and replays with it"*. The first half holds, the second has no production path.

### 4. Classification
**(b)**, a built capability never wired, left outside every card. Two qualifiers:
- **(d)** in part: whether reopening "the same" corpus in a resumed chat is the same round is an
  unruled question against the round-scoped decision;
- **(e)** for survey §7 check 4's "replays with it".

### 5. Constraints and open questions

**Constraints**
- **Round-scoped annotations** (`session.rb:32-34`; `session_spec.rb` "annotations do not carry forward
  into a new round").
- **`Marks::BaseMismatch` / `reconcile`** semantics (`session.rb:130-146`).
- **The Outbox's rejection** of journal rebuild for submission (`outbox.rb:15-21`).
- **Deletability.** `spec/lain/review/deletability_spec.rb:135-142` pins that only the docent's own
  files name `Docent` in code. A resume wire-up must reach `replay` without naming the class outside
  its row.
- **Docent replay needs the anchor.** Replay holds exchanges without anchors until `open`
  (`docent.rb:689-694`), so replayed threads need a note's anchor re-posted to be reachable
  (`handover.rb:244-250`: "a note is the only thing that ever does").
- **Replay skips unreadable records** by rule (`docent.rb:372-374`, `Session::Replay#fold`).

**Open questions for the human**
- On `--resume`, should reopening the same target or digest seed from `resumed_from`'s journal (the
  "resume mid-review" intent), or is every `/survey` a new round and the banner should say notes do not
  carry over?
- If seeded, what happens to marks and notes when the digest moved?

---

## F158 — corpus line-ceiling refusal says "nothing to fall back to" though `--unbounded` works (MEDIUM, UX)

### 1. Mechanism, re-verified
Correct. `Source::Corpus#initialize` refuses on the **file count** only (`corpus.rb:246-247, 333` →
`bounds.rb:230-231` with `CORPUS_NARROWING`, `:106`). The **line** ceiling is asked later, in
`Session#present` → `check_presentation!`:
- **cumulative:** `check_cumulative!` (`bounds.rb:284-289`) with subject `"the cumulative view"` and
  advice `cumulative_advice` (`:335-338`), which falls back to `NO_PRESENTABLE_SCOPE` (`:140-141`,
  "…presents this changeset whole");
- **`by_directory`:** `check_group!` (`:310-315`) with subject `group.detail.named(group.label)`
  (unstripped `../big/ab`) and `NO_NARROWER` (`:133`).

Neither sentence knows about `--unbounded`, which only `/survey` and `lain survey` accept
(`command/survey.rb:45`, `cli/survey.rb:78-85`). Both refusals raise after the bind in `/survey`
(`survey.rb:227`), which is F143's rails half.

### 2. Most recent relevant changes
- **Round-11 T13 (`45334f57`; archived as `338862d3`)** routed the corpus *file* refusal through
  `Bounds#guard!` with `CORPUS_NARROWING`. The line ceiling was not in its scope.
- **The generic sentences are older:** `NO_NARROWER` and `NO_PRESENTABLE_SCOPE` from the
  partition/strategy work (`d8dbd267` era; `5607b2db` moved enforcement to `Session#present`).
- Round 17 did not touch `bounds.rb`.

### 3. Why it is this way

**T13 was deliberately limited to a file count** (archived chunk T13):
- *"The early refusal itself is correct and must stay — QA measured it deciding on a file count
  alone"*;
- the escalation trigger: *"`bounds_spec.rb:385-445` pins that advice is composed by measuring without
  reading hunks … if the implementation starts measuring anything in `Corpus#initialize` … Stop."*

`bounds.rb:224-226` explains why a corpus has no line count at construction: *"A line count is not a
fact a walk has — it is the read this refusal is avoiding."*

The T13 execution correction is also relevant: *"`--scope by_directory` cannot lift the corpus
ceiling"*. That applies to the file ceiling. For the line ceiling a scope can help, and QA saw
`big/split` correctly advised `by_directory`.

**Both sentences were written for `/review`,** where no `--unbounded` exists, so "nothing to fall back
to" was true there. `NO_PRESENTABLE_SCOPE`'s doc (`bounds.rb:135-139`): *"Advice that sends a human
down a path which also refuses is worse than no advice"*. The inverse, advice that omits a path that
works, was not considered for corpora.

### 4. Classification
**(b)**, a gap left outside round-11 T13's file-count scope.

### 5. Constraints and open questions

**Constraints**
- **`Bounds` stays source-agnostic in advice.** `NARROWING_CANDIDATES` is strategy-neutral and must
  not spell a strategy (`bounds.rb:112-126`). Source filtering belongs to `Session#present`
  ("`#supports?` is consulted where the source is in hand", `:124-126`). A corpus-aware sentence must
  come from something that knows the source (the command, or a source-supplied advice), not from a type
  test in `Bounds`.
- **The file-count refusal must not start measuring or walking** (T13; `survey.md` §2 check 4;
  `bounds_spec.rb` measuring-without-reading pins).
- **Specs pinning the current words:**
  - `spec/lain/review/bounds_spec.rb:441,454`: `/no scope that presents this changeset whole/`;
  - `spec/lain/cli/review_spec.rb:382,394`: `narrowest scope`;
  - `spec/lain/cli/survey_spec.rb:253-256`: only `/lines/`.

  Keep the `/review` wording intact.
- **`--unbounded` LAST** (`bounds.rb:99-105`; `survey_spec.rb:248-251`, `/--unbounded\z/`) for the file
  refusal. Mirror it if the line refusal names the flag.
- **Scopes a corpus cannot answer.** A remedy naming `commits` for a corpus is itself a finding
  (`survey.md` §2 check 3).

**Open question for the human.** Is the subject word "this corpus" (`bounds.rb:110`, `CORPUS`) wanted
for the line refusal too? That is one place a source-specific word already lives in `Bounds`.

---

## F159 — an unsettled survey blocks `/review`; approve is the only verdict (MEDIUM, gap)

### 1. Mechanism, re-verified
Correct:
- `Command::Review#refuse_over_survey!` (`review.rb:221-225`) refuses while
  `held_source == corpus && held_verdict.empty?`.
- `Review::VERDICTS = %w[approve]` (`review/vocabulary.rb:64-71`), enforced at
  `rpc_thread.rb` `ReviewWrite.verdict`.
- `Outbox` has no release (`outbox.rb:79-94`, `hold` replaces; nothing clears).

The block is **symmetric**: an unsettled changeset review blocks `/survey` (`survey.rb:257-261`). A
survey over a survey rebinds, but the rebound round is unsettled too, so the only in-chat release is an
`approve`.

### 2. Most recent relevant changes
- **Round-11 T6 (`bad7d081`; archived `60be33f2`)**, "Stop a settled round from holding the gesture
  rails": a *settled* round no longer blocks.
- Round 17 did not touch this.

### 3. Why it is this way
- **Round 11's F67 named the gap:** *"There is no `/review-close` or equivalent, so the only exit is
  restarting the chat."* (Deleted findings file, `git show 17e2e7c3^:planning/qa-findings-round11-2026-08-25.md`.)
- **T6 fixed only the settled half.** Its escalation trigger says *"`session.rb` … reopening a settled
  round is 'a larger decision' … This card does not reopen anything."*
- **The outbox may not interpret.** Its doc (`outbox.rb:120-131` in the chunk's citation, now
  `:99-110`) forbids the outbox deciding what a source word means.
- **The one-member vocabulary is deliberate.** `vocabulary.rb:64-70`: *"ONE member on purpose: the
  verdict vocabulary is research open question 3 ('reuse the panel's APPROVE / APPROVE-WITH-FIXES /
  REQUEST-CHANGES?') and is unsettled … adding the second value is a deliberate edit HERE, with the
  question settled"* (`planning/human-in-the-loop-review-research-2026-08.md:1067`).
- **A second verdict is refused** as unreadable (`session.rb:67-70`, `AlreadySettled`).
- **One surface per chat.** `SURVEY_OPEN` (`review.rb:68-76`): a second surface would rebind the rails
  away from a sidebar whose marks cannot reach.

### 4. Classification
**(d)**. The verdict vocabulary is an explicitly unsettled ruling (research open question 3), and a
close or withdraw gesture is a gap round 11 recorded and T6 deliberately did not build.

### 5. Constraints and open questions

**Constraints**
- **Adding a verdict** is a deliberate edit to `VERDICTS` with the question settled (`vocabulary.rb:64-70`).
  `ReviewWrite.verdict` cites it.
- **Policies read `blocker` against `approve`** (`verdict/policy.rb`; `session.rb:402-407`). A
  "withdraw" must not be admissible through a policy meant for judgement, or it becomes the escape
  `BlockersOnly` exists to prevent (`survey.md` §6).
- **Still-live guards.** `bad7d081` and `survey_spec.rb:763-838` pin the live-round refusal wording
  (asserted on the guard's own words, `:807-816`). "A settled round is not in the way" must keep
  holding.
- **The outbox forwards and never interprets** (round-11 T6's falsifiable criterion).
- **`@held` must survive for `/review-submit`** after settle (round-11 T6 note;
  `review_submit.rb:107-109`).

**Open questions for the human**
- Settle research open question 3: is there a non-approving terminal verdict (withdraw, abandon,
  request_changes)?
- Or is "close" a separate gesture that journals no verdict and simply releases the rails?

---

## F160 — critique chunk room vs the child's unbounded reads (MEDIUM)

### 1. Mechanism, re-verified
Correct, with the raw-JSON path made precise:
- `Critique::Budget#room` (`critique.rb:239`) gives chunk content `1/READ_SHARE` (`:56-59`, half) of
  what remains. Nothing bounds the child's reads: the `diff_critic` role holds `read_file` etc.
  (`role/catalog.rb:69`), and `Tool::Invocation` carries no window (round-17 Open decision 2).
- `Middleware::RequestBudget` is composed only in `Wiring#model_phase` (`cli/wiring.rb:557-560`), so a
  child's over-window 400 raises `Provider::Ollama::WindowExceededError`.
- That error's **message is the raw JSON body**: `ollama.rb:373-377` wraps `wrapped.message`, which
  `window_exceeded` (`:380-389`) itself parses as JSON.
- It raises out of the child's `Agent` (`agent.rb:336-341` withdraws and re-raises) and out of
  `Subagent#run` / `RoleSpawn#call` into `Critique#answer`'s `rescue StandardError => e;
  outcome("refused", e.message)` (`critique.rb:183-184`). The JSON becomes `critique_chunk.text` and
  the merged heading body (`:207`).
- No `window_pressure` is written for children: RequestBudget is absent, and `request_sent` is
  main-agent only (T24 escalation text).

The same exposure applies structurally to `diff_docent` children (`catalog.rb:61`, same tools, same
spawn path). That is inferred, not driven.

### 2. Most recent relevant changes
- **`3ec1dc79` (r17 T21)** built `Critique` with `READ_SHARE` and `SCHEMA_RESERVE_TOKENS`.
- **`4cf30b98` (r17 T24)**, landed after T21, made every ollama request send `truncate: false`
  (`provider/ollama/encoding.rb:55-65`).

Before T24, a child over the window was silently truncated (F90's shape). After T24 it is a 400 that
only the main agent translates. So the *raw-JSON* symptom is an interaction created by T24 landing on a
path T21 had built.

### 3. Why it is this way
- **T21's design:** *"Chunks are sized to the child's window. Without this, every chunk child
  re-creates F90 … T24 does not cover child requests."* In code, `critique.rb:22-37`: *"a chunk's
  content may take only half of what that leaves, because a child told it may read has every read's
  result ride its NEXT request."*
- **T21's rescue is deliberate:** *"A child that fails costs its own chunk and never the others, for
  {Docent::Delivery}'s reason: the failure's words are the finding"* (`critique.rb:174-177`).
- **T24's escalation trigger:** *"Child agents. A child's requests are not journaled … If the budget
  must cover children (T21's chunk children), stop and name the construction site."* The Execution log
  records T24's redesign but no child escalation.
- **Open decision 2:** *"A window-relative `read_file`/tool result bound (F90's third leg) is deferred.
  `Tool::Invocation` carries no window."* T24 repeats *"Open decision 2 stands"* and the Execution log
  repeats *"Open decision 2 (window-relative per-tool bounds) still stands."*
- **The subagent answer bound** is fixed at 16 KiB for the same missing-window reason
  (`tools/subagent.rb:425-432`, `ANSWER_BOUND`).

### 4. Classification
**(b)**, a known deferred gap (Open decision 2 plus T24's child trigger).

The raw provider JSON reaching the merged findings is a secondary **(a)-by-interaction**: T24's
`truncate: false` turned a silent truncation into a raise whose message is JSON, on a path T21's rescue
renders verbatim. No card owned the combination.

### 5. Constraints and open questions

**Constraints**
- **A failed chunk must not stop the others** (`critique_spec.rb:171-181`, "keeps critiquing the other
  chunks when one child fails, and says which one did").
- **Refuse before spend** (T21 AC "no child is spawned", `critique_spec.rb` "response reserve" and
  "line-packed chunk" groups). **Never split a file** (T21 escalation trigger).
- **The room pin.** `critique_spec.rb:230-245` pins the first request under 60% of the window (the
  `READ_SHARE` effect).
- **RequestBudget contract.** It is outermost and holds under `--no-journal` (`request_budget.rb:16-19`,
  `wiring.rb:549-556`). A child-side budget needs a construction site in the spawn seam (T24's
  trigger). Its record goes to the record journal (`window_pressure`). A child's `turn_usage` must not
  reach the file as a parent reading (r17 Grounding §3: salvage pairing, `cache_waste`,
  `scribe_spec.rb:395`).
- **The truncation stays refused.** Keep ollama's `truncate: false` (T24 ruling).
- **Pair with F137.** A child that raises journals no completion; a fix here should not assume a
  `message` record exists.

**Open questions for the human**
- Build window-relative read bounds (Open decision 2) now, or give children a `RequestBudget` (a
  worded refusal as the chunk text) as the smaller step?
- Should a refused chunk's text be the translated refusal rather than the provider's words?

---

## F183 — four path bases around one survey (LOW)

### 1. Mechanism, re-verified
- **(a) Text group header.** `review/surface/text.rb:156` renders `legible(partition.label)` without
  the `\A(?:\.\./)+` strip that `row` applies at `:158`. The nvim sidebar strips both
  (`frontend/neovim/review_view.rb:430, 444`, `displayed_path`). **Correct.**
- **(b) Disclosure.** `Withheld.*(relative, …)` with `relative` from the walk root
  (`survey/walk.rb:241-266`). Rows come from `Corpus::Prefix.between(named_from || walk.root, walk.root)`
  (`corpus.rb:136-143, 246`). **Correct.**
- **(c) Thread header and `annotation_placed.path`** carry the climbed, cwd-relative `file.path`
  (`thread_view.rb:137`; the note's `path` is the stamp from `47_diff.lua:728`). **Correct.**
- **(d) The `by_directory` refusal subject** is `group.detail.named(group.label)` unstripped
  (`bounds.rb:312`). **Correct.**

### 2. Most recent relevant changes
- **`c3ccaa39` (r17 T26 item V1)** made `lain survey` pass `named_from: @cwd` (`cli/survey.rb:148-154`).
  Before it, `lain survey` named rows from the walk root (no climb), so its text headers had nothing to
  strip. T26 therefore **exposed** (a) on the one-shot and made (b) and (d) disagree there too. They
  already disagreed on `/survey`, which named from cwd since `e536eb63`.
- **`02885580`** added the row-only strip to `text.rb` (*"The text surface says the same sentence, so
  it strips the same way"*) and never stripped the header.
- **Round-11 T7 (`34d54994`; archived `d18b579c`)** unified header and row in `review_view.rb` only (its
  Files list was that file).

### 3. Why it is this way

**Display is not resolution** (`02885580`): *"`Row#path` keeps the name the corpus gave it, because
that is the key a gesture resolves through."*

**The partial-ancestor limitation is a documented known.** From `02885580`: *"when cwd and the surveyed
root share a partial ancestor, the row reads relative to the shared parent rather than the root … An
example pins that, because the honest fix threads the surveyed root into the render and is a larger
change than this."* Round-18's withdrawn near-finding cites this.

**Round-11 T7 kept the climb in the thread header on purpose:** *"the two other surfaces that render
this path correctly today and must keep doing so: the OLD buffer's name
(`lain://review/OLD/../../../…`) and the thread pane header (`-- thread at ../../../…:12 --`).
`file.path` itself must stay untouched."*

**`named_from` is the cwd by ruling** (`command/survey.rb:263-268`): *"the editor opens a row against
the directory it was started in … Not the project root either"*.

### 4. Classification
- **(a) text header: (a)**, a regression exposed by r17 T26 V1 (`c3ccaa39`) on `lain survey`, through a
  pre-existing asymmetry from `02885580`.
- **(b) disclosure base:** (c) for `/survey`; T26 extended it to `lain survey`.
- **(c) thread header and note path: (d)**, kept deliberately by round-11 T7.
- **(d) refusal subject:** (c), pre-existing (and part of F158).

### 5. Constraints and open questions

**Constraints**
- **`file.path` and `anchor.path` stay the resolution key** (`02885580`; round-11 T7;
  `changeset_diff.rb:108-115`, where the ROOT is the contract).
- **Pinned behaviour to preserve:**
  - `spec/lain/frontend/neovim/review_view_spec.rb:184-228` pins the strip and the partial-climb known
    limitation;
  - `review_view_spec.rb:489-531` pins 40-column widths;
  - `spec/lain/review/surface/text_spec.rb` "drops a survey's leading climb from a row's displayed
    path";
  - `spec/lain/cli/survey_spec.rb` "row names, when the surveyed directory is not the invoking cwd"
    (T26).
- **The header label is the partition's output**, not the view's (round-11 T7 escalation). Strip at
  render, never in `Partition::ByDirectory`.

**Open question for the human.** Does the thread header / note `path` keep the climb (round-11 T7's
"correct"), or should every human-facing string use one displayed base?

---

## F184 — `/survey` splits on whitespace (LOW)

### 1. Mechanism, re-verified
Correct. `Command::Survey#call` does `parse(args.to_s.split)` (`command/survey.rb:142`) and
`Parsed.new(path: rest.first, …)` (`:162`). `refuse_unreadable!` refuses only `--`-prefixed extras
(`:185-189`). `/review` has the identical shape (`review.rb:118, 138`), which is F186/C5.

### 2. Most recent relevant changes
- `50a0e512` ("chat: open a survey from the prompt") introduced it, copying `7b6fa060`'s `/review`
  parse.
- T26 listed `cli/command/survey.rb` in its Files, but `c3ccaa39` did not modify it
  (`git show --stat`).

### 3. Why it is this way
No recorded decision on quoting or extra positionals was found. The one-shot `lain survey` refuses
extra args through Thor (round-11 T8, "Refuse unknown switches in exe/lain, on every subcommand"). The
parse comments speak only to flags (`survey.rb:34-36`: *"a directory named `--squash` is nobody's"*).

### 4. Classification
**(c)**, pre-existing and untouched.

### 5. Constraints and open questions

**Constraints**
- **Flag and value pairing is by index** (`survey.rb:172-178`). Quoting must happen before that parse.
- **Needs-value refusals are pinned** (`survey.rb:180-189`; `survey_spec` needs-value examples).
- **Fix both commands.** Keep `/review`'s parse in step (F186), since the two are deliberate mirrors.

**Open question for the human.** Adopt Shellwords semantics for slash-command args generally, or refuse
a second positional by name?

---

## F185 — the thread pane drops its note at the first question; the brief never carries it (LOW, UX)

### 1. Mechanism, re-verified
Correct:
- The note renders once through `Surface::Neovim#annotate` → `@thread_view.show(anchor,
  [Entry(speaker: kind, text:)])` (`review/surface/neovim.rb:167-168`).
- `Handover#wrote_annotation` then calls `@docent.hold`, which does not draw (`handover.rb:251-258,
  274`).
- The first question re-renders the pane through `Docent#render` → `@view.show(anchor,
  conversation.entries)` (`docent.rb:464, 592`), and `Exchanges#entries` holds only Q/A pairs
  (`:789-794`).
- `Docent::Brief#sections` (`docent.rb:867-871`) carries the question, where, the hunk, both contexts
  and the dossier. `Docent.for` passes no dossier (`:272-276`), so the brief says `NO_DOSSIER`.

### 2. Most recent relevant changes
- `485246e9` ("give the review a docent that can actually answer") introduced `hold` and the
  note-renders-first rule.
- `a1765997` introduced the surface's `annotate` render.
- Round 17 did not touch either.

### 3. Why it is this way
- **One payload per anchor.** `handover.rb:251-258`: *"hold does not draw, so the note's own render is
  the only payload this rail posts: the thread carries one payload per anchor."* `docent.rb:321-325`:
  *"makes the note win BY CONSTRUCTION rather than by write order"*. That solved the note-vs-empty
  race at open, not the replacement at the first answer.
- **A known, pinned loss in the other direction.** `handover.rb:259-267` records that a second note at
  an answered line mints a new anchor and hides the answered thread.
- **The brief is deliberately minimal.** `docent.rb:29-37`: *"unbiased by authorship because it is told
  nothing about who wrote the change: {Brief} is the whole of what the child sees"*. `docent.rb:820-825`:
  one hunk, never the changeset. A reviewer's note is not authorship, but it is a claim the docent
  would then be conditioned on. No ruling covers it.

### 4. Classification
**(c)**, pre-existing. The note-into-brief half touches an unstated design choice about what conditions
the docent, so it carries a small **(d)** component.

### 5. Constraints and open questions

**Constraints**
- **Thread pane rules.** One payload per anchor. `hold` must not draw, and must swallow ENOENT
  (`docent.rb:327-336`).
- **Replay equals live by construction** (`docent.rb:370-372`). If the note becomes an entry, replay
  must fold `annotation_placed` too, or replayed panes differ from live ones.
- **`brief_key` comparability** (`docent.rb:806-819, 863`; `DocentAsked`). Adding the note changes every
  key: expected, but bench joins across versions break.
- **Deletability of the docent** (`spec/lain/review/deletability_spec.rb:135-142`).
- **Specs to keep green:** `spec/lain/frontend/neovim/thread_view_spec.rb` (entry rendering) and
  `spec/lain/review/docent_spec.rb:376-415` (replay with a forbidden answerer).

**Open question for the human.** Should the docent be told the reviewer's note (risking an answer that
argues with the note rather than reads the hunk), or should only the pane keep showing it?

---

## Cross-finding

### Shared root causes
1. **The review rail treats "bound" and "drawn" as one state** (F143, and F158's `/survey` refusal path):
   - bind-before-draw (`review.rb:171-177`, `survey.rb:201-202, 227`);
   - enforcement moved into `Session#present` (`5607b2db`);
   - nothing marks a round as "opened but never presented".

   A single "undrawn round refuses gestures / restore prior handover" change covers F143 for both
   `/review` and `/survey` (line ceiling, `UnsupportedScope`).
2. **Editor buffers are raw working-tree bytes, and the record copies from them** (F133, F144):
   - the NEW side is the disk file (`47_diff.lua:184-191`);
   - `anchor_text` is read from it at placement and journaled verbatim;
   - `revision` is stamped with `head_ref` regardless of the checkout.

   One design question covers both: what the note record claims to have seen. A projected-from-objects
   evidence line (the head blob for a changeset; the projected corpus `Reading` for a survey) would
   answer F133's journal leak and F144's false revision together. Showing NEW from objects remains
   F144's separate UX half.
3. **Refusal sentences written for `/review` are reused by the corpus source** (F158, F183(d)). Advice
   and subject are source-agnostic in `Bounds` by rule, so a corpus needs its own advice supplier. One
   change covers F158 and F183(d).
4. **Capabilities built with no production caller** (F157). `Session.from_journal` and `Docent#replay`
   join the pattern `planning/specs/staleness-*` tracks.
5. **No lifecycle end for a round short of a verdict** (F159, and F157's "is it the same round").
   Settling research open question 3, or adding a close gesture, and ruling whether a resumed reopen is
   the same round are adjacent decisions and should be taken together.
6. **Children run outside the main agent's model phase** (F160, and F137 from the fork report): no
   `RequestBudget`, no `window_pressure`, no completion on raise.

   One child-side model-stack construction site, T24's named trigger, would cover F160's wording and
   pressure record. It would not cover read bounds (Open decision 2).

### Which findings one fix would cover
- **F143 (`/review`) + F143-shaped `/survey` refusals**: one "undrawn round" state on `Handover`/`Session`.
- **F133 + F144 (the record half)**: one "evidence from objects or projection, not from the buffer" rule
  at `Handover#wrote_annotation`, with the projection or blob reader injected.
- **F158 + F183(d)**: one corpus-aware refusal (advice and subject) supplied by the source or command.
- **F183(a)**: a one-line strip on `text.rb:156`, mirroring `review_view.rb:430/444`. Independent of
  the rest.
- **F184 + F186(C5)**: one shared slash-command argument parse.
- **F157, F159, F185**: each needs a human ruling first (round identity across resume, verdict
  vocabulary or close gesture, docent conditioning on notes). No mechanical fix should precede them.
