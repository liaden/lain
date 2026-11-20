# Scenario: reviewing a real changeset, on a local branch

**Round 26 is the re-check** for the round 25 fixes stated in item 4 (h25-10: a verdict or a second `/review` with held notes is refused).

**What it exercises:** `qa-lain review <branch>`, `Review::Source::LocalBranch`, `Review::Changeset`,
`Delta`/`Hunk`, all three `Review::Partition` strategies, `Review::Bounds`' three ceilings,
`Review::Verdict::Policy` (strict vs `--permissive`), the `/review` command at `you>`, and
`/review-submit`'s refusal when there is nowhere to post, and `/review --since` and `--critique` (§10).

**The question it answers:** does a review of an actual diff tell the truth? `cockpit-surfaces.md`
§4 and §4b drive the review *rails* — the sidebar, the marks, the note anchors, the verdict — but
they drive them over **`/survey`**, a directory walk with no old side and no commits. Everything
that makes a changeset a changeset (a base ref, a merge base, per-commit grouping, an OLD revision
to anchor a note to) is untouched by them.

**Cost:** cheap. `LocalBranch` shells to `git` and nothing else — **no forge, no network, no API
key**. §6 needs a live model for one turn; everything else is deterministic.

**Needs:** `git`. nvim + tmux for §5 only, where it piggybacks on a cockpit that is already up.

**What it deliberately does not reach:** `Source::GithubPr` and the actual posting of a review.
Both need github.com. §7 drives the boundary between them — that a **local-branch** review refuses
to post rather than reaching for a network it has no business touching.

---

## 0 — The subject: a repository the driver builds

Outside the project, so nothing here is a fixture another scenario has moved. The shape matters:
**three commits, on three directories, with one file that exists only on the branch and one that is
deleted by it** — that is the minimum that tells `commits` from `by_directory` and gives the note
rail an OLD side to anchor against.

```bash
R="$(mktemp -d)/changeset"; mkdir -p "$R/lib" "$R/bin"; cd "$R"; git init -q .
git config user.email qa@example.invalid; git config user.name QA
cat > lib/tally.rb <<'RB'
class Tally
  def initialize = @counts = Hash.new(0)
  def add(word) = @counts[word.downcase] += 1
  def top(n) = @counts.sort_by { |w, c| [-c, w] }.first(n)
end
RB
printf '#!/usr/bin/env ruby\nputs "tally"\n' > bin/tally
printf '#!/usr/bin/env ruby\nputs "old"\n'   > bin/legacy
git add -A; git commit -qm 'seed'
BASE=$(git symbolic-ref --short HEAD)
git switch -qc feature

# commit 1 -- lib/ only
printf '  def total = @counts.values.sum\n' >> lib/tally.rb
git commit -qam 'lib: a total'
# commit 2 -- bin/ only, and a deletion
printf 'puts Tally.new.total\n' >> bin/tally; git rm -q bin/legacy
git add -A; git commit -qm 'bin: use it'
# commit 3 -- a new file, in a third directory
mkdir -p doc; printf '# Tally\n\nCounts words.\n' > doc/README.md
git add -A; git commit -qm 'doc: say what it is'
```

**Corrected by round 17: the recipe's deletion deleted nothing.** Commit 2 used to run
`git rm -q bin/../bin/tally 2>/dev/null || true` over a file it had just modified; `git rm` refuses a
file with local modifications, the `|| true` swallowed it, and the subject had no deleted file at
all. The seed now carries `bin/legacy` for commit 2 to delete. *Driven 2026-09-14*:
`git diff --name-status $BASE feature` reads `D bin/legacy`, `M bin/tally`, `A doc/README.md`,
`M lib/tally.rb` — the four changed paths §2 counts.

**Do not hard-code `main` in your own commands** — `git init`'s default branch is a per-box setting
(`init.defaultBranch`); this box now gives `main`, and it gave `master` when this was written. The
recipe captures `BASE` before `git switch -c feature`; use `$BASE` everywhere below. **Lain's own
default base, though, IS hard-coded `main`** — §1 drives what that costs in a `master` repository.

**Record `git rev-parse $BASE feature` in the findings.** Every line number and every hunk count
below is against these three commits; a round that regenerates the subject differently cannot
compare against the last one.

## 1 — Resolution, and the two refusals

```bash
qa-lain review feature                  # the default: base is the default base, head is `feature`
qa-lain review open feature             # identical -- `open` is the escape, not a different command
qa-lain review feature --base "$BASE"
qa-lain review no-such-branch           # UnknownRef
qa-lain review feature --base no-such   # UnknownRef, naming the BASE role
```

Expected, and **the role must be named** — `base` and `head` fail identically otherwise and an
operator cannot tell which of their two refs was the typo:

```
head ref "no-such-branch" does not resolve to a commit in <repo>: <git's own detail>
```

The `: <detail>` tail is load-bearing. `rev-parse --verify --quiet` silences "unknown revision" but
**not** "not a git repository" or "cannot change to …", and those two are exactly the ones a caller
needs. Run `qa-lain review feature` from **outside any repository** and confirm the detail survives
rather than being swallowed into a bare "does not resolve".

**And in a repository with no `main`.** The default base is the literal `main`, so a `master`
repository cannot review a branch without `--base` (round 17's V2). The two entry points now answer
differently, and a round should drive both:

- **`/review <branch>` names the way out** since 2026-09-14 — `… -- this repository has no default
  base to review a branch against; name one with --base <ref>`. *(Driven round 26: the
  cockpit wording names `--base <ref>`. A headless chat refuses `/review` for having no editor before it resolves any ref, so this needs the
  cockpit.)*
- **`qa-lain review <branch>` names it too, since round 26's fix (T48).** *Driven 2026-09-14, and again round 26,
  when `qa-lain review feature` in a `master` repo said `base ref "main" does not resolve` with no `--base` hint.* In
  a `git init -b master` repository both entry points now say `… -- this repository has no default base to review a
  branch against; name one with --base <ref>`, exit 1, from the one `Target#branch`. A `--base` the human typed
  that does not resolve still reports the plain `base ref … does not resolve`.

### 1b — two roots, no merge base

The refusal that exists because the alternative is silent and catastrophic:

```bash
git checkout -q --orphan orphan; git commit -q --allow-empty -m 'unrelated'
qa-lain review feature --base orphan
```

```
"orphan" and "feature" share no merge base in <repo>, so there is no revision to anchor the old side to
```

**Diffing against the empty tree instead would present the entire branch as additions**, which
reads as a successful review of a changeset nobody wrote. That is the shape to watch for: a review
that *works* and shows every file as new.

### 1c — the reserved first word

Thor owns the first word, so a branch actually named `help` or `tree` needs the escape. Nothing
below the exe treats a target as anything but a ref.

```bash
git branch help feature; git branch tree feature
qa-lain review help          # Thor's HELP SCREEN -- correct, and the reason `open` exists
qa-lain review open help     # reviews the branch
qa-lain review open tree     # reviews the branch
```

A `qa-lain review help` that tries to review a branch is as much a defect as `qa-lain review open help`
printing help.

## 2 — The three scopes, and where the enum comes from

```bash
for s in cumulative commits by_directory; do qa-lain review feature --scope "$s"; done
qa-lain review feature --scope by_files      # Thor rejects: not in the enum
```

**Corrected by round 17: the scopes are `cumulative`, `commits` and `by_directory`**, not `whole` and
`by_commit` (those are the partition CLASS names, `Whole` and `ByCommit`; the scope a human types is
each strategy's `name`). `cumulative` is the default. *Driven 2026-09-14* against §0's subject:

| scope | grouping |
|---|---|
| `cumulative` | one group, four changed paths: `bin/legacy`, `bin/tally`, `doc/README.md`, `lib/tally.rb` |
| `commits` | **three** groups, in topo order, each headed by its subject line — `lib: a total` / `lib/tally.rb`, `bin: use it` / `bin/legacy`, `bin/tally`, `doc: say what it is` / `doc/README.md` |
| `by_directory` | **three** groups — `lib/`, `bin/`, `doc/` *(not re-driven)* |

and `--scope by_files` exits 1 with `Expected '--scope' to be one of cumulative, commits,
by_directory; got by_files`.

**The enum is read off `Review::Partition::STRATEGIES`, not written by hand in the exe**, and that
is a real past defect rather than tidiness: Thor validates `enum:` *before* it dispatches, so a
hand-written list rejects a scope the registry serves without the registry ever being asked.
`qa-lain review --scope by_directory` was exactly that failure. **Check the failure direction:** a
scope the registry serves must be accepted, and a scope it does not must be refused by Thor with
the valid set named.

## 3 — `--base`, and what the changeset is actually cut against

`base` is not the ref the diff is taken from — **the MERGE BASE of base and head is**. Prove it:

```bash
git switch -q "$BASE"; git commit -q --allow-empty -m 'base moved on'
qa-lain review feature --base "$BASE"
```

The changeset must be unchanged by that empty commit on the base. A review that grows a "base moved
on" entry is anchoring to the base **tip** rather than the merge base, which is the classic way a
review starts showing other people's work as yours.

## 4 — The ceilings, and the one property that moved

Three bounds, and a refusal must name **which one fired** with its measurement and its ceiling
beside it — a bare "too large" leaves the reader guessing between three:

| ceiling | default | what it catches that the others cannot |
|---|---|---|
| files | 300 | a wide changeset |
| rendered lines | 30,000 | the other shape — 40 files of 1,000 lines each |
| `/critique` lines | 7,000 | the only one set against a **context window** rather than a reader |

Manufacture the file ceiling; it is the cheapest:

```bash
git switch -qc wide feature
ruby -e '301.times { |i| File.write("f#{i}.txt", "x\n") }'
git add -A; git commit -qm 'wide'
qa-lain review wide --base feature
```

**Then read the journal, because T31c changed something the screen cannot show.** The ceiling is
now enforced by `Review::Session#present` rather than by the command, so a refused review **leaves a
`changeset_opened` record on file where it used to leave nothing**:

```bash
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next;
  puts r["type"] if %w[changeset_opened review_verdict].include?(r["type"])}' "$JOURNAL"
```

That is documented, deliberate, and exactly the kind of thing a round records as *known* rather than
files as a defect. What must still hold: the surface is never told, **nothing is drawn**, and the
refusal reaches stderr. A refused review that renders a partial diff is the finding.

## 4b: Hunks are projected before any reader sees them *(after round 22's D-4)*

Round 22 found a changeset's hunks reaching the docent brief, `/critique`'s patch, submit and marks
with an unreleased secret in them. Hunks are now projected first. Plant `API_KEY=sk-live-0000000000000000000000000000`
and a PEM block (a realistic body, per `secret-boundary.md` section 4) in a changed file, open the review,
ask the docent about it, run `/critique`, and drive a note. Checks:

- a detected, unreleased secret reads as `<redacted:N>` in all four readers, and the session journal holds **no
  byte** of it (the `secret-boundary.md` section 7 grep over `$QA`, minus the exclusions listed there);
- **each side of a file is projected whole**, so a key block cut off at a hunk's edge is still caught, and the
  hunk's line counts still match its header;
- **a rename projects the `-` lines from the old path at `base_ref`**: rename a file holding a secret and check
  the removed side is masked too;
- **a release the human made on the working tree survives opening a review**; the base side never forgets
  one, so a base-side secret stays masked even after the working copy was released;
- placeholders number once per hunk across both sides; a note's quoted evidence numbers them across the
  **whole file**, so the same region can show a different number there. Known, not a defect;
- **hunk keys and the changeset identity do not move** when a region is released, or when a secret appears in
  another hunk. Open twice around a release and compare the keys and the `changeset_opened` digest.

**Known limits, expected verdicts and not fixed:** a file gated only by its **name** (`password.txt`) is
region-masked in a hunk, not masked whole as it is in a survey (`survey.md` section 4); and an implementation
review opened through `request_review` does not see a release made in chat. Opening a review costs about
15 to 20 ms per file (`HEAD~150` is about 6 seconds), so a slow open on a wide changeset is not a regression.

## 5 — In the cockpit, over a changeset instead of a survey

Piggyback on the subject session's cockpit, and drive the **same rails `cockpit-surfaces.md` §4
drives over a survey** — the point is that they behave differently when there is an OLD side.

```
you> /review feature --base <the $BASE branch> --scope commits
```

Then, over RPC (`method.md`'s socket recipe — never a screen scrape):

```bash
nvim --server "$S" --remote-expr 'bufname()'      # MUST print lain://review
nvim --server "$S" --remote-send '2G<CR>'         # opens sidebar | OLD | NEW
```

The three checks a survey structurally cannot make:

1. **The OLD window holds the base revision's bytes**, not an empty buffer. A survey has no old side,
   so `<C-w>l` reaching a blank pane passes unnoticed there and is a defect here.
2. **`:LainNote` takes a kind first: `:LainNote note <text>`, `blocker`, or `question`.** **`:LainNote` on the OLD side anchors to `(side, revision, path, line)` with `side` naming the
   old revision.** Place one on the OLD side and one on the NEW side of the same file at the same
   line number, and confirm the two notes are distinct and come back distinct. Round 7's §4b
   findings (F30–F39) are all on the note rail and **none of them were driven against two sides**. Notes come
   back only through `:LainNoteDone` (round 25). When the head is the checked-out branch, NEW is the working file
   itself, so a note on NEW anchors in the file you can edit.
3. **`x` marks a hunk, and a changeset has real hunks.** `cockpit-surfaces.md` §4's `x` refusal
   ("nothing on that row") is the sibling failure; here the positive case is reachable. b28-2, open ruling: `x` on a never-opened changeset row (`spec/spec_helper.rb`) answered `marked reviewed: 1 hunk(s)` in round 28, because `read` is `file.chunked?` and a parsed changeset file is always chunked (`review_view.rb:453`), so the UNREAD refusal fires only on a row with no hunk keys. Whether marking without opening should refuse is the ruling. Ruled, and landed in 3c5aa85f (card T25): a row counts as read only once a human opened its diff in the round, so the prediction (a refusal on a row nobody opened, even one lain already chunked) holds today.
4. **A verdict with held notes is refused, and nothing is dropped** (round 25, h25-10, fixed). Place a note, do not run
   `:LainNoteDone`, then `:LainReviewVerdict approve`. It refuses `1 note not handed back -- :LainNoteDone first` (`N notes` for
   more; a blocking note's `path:line` is appended after a colon) and the review stays open. After `:LainNoteDone`, the same verdict
   goes through and the journal holds the annotations and the verdict. A second `/review` over an open round with held notes refuses
   with the same sentence, and journals nothing. The `/review-submit` text says only that the verdict and the *handed-back* annotations are
   on the journal. A verdict that settles with the note gone, or a submit text that claims a held note is journaled, is the finding back.
   Round 26 re-checks both: a verdict with 3 notes held refuses `3 notes not handed back -- :LainNoteDone first: config/app.env:2` (h25-10 fixed); a second `/review` with notes held refuses the same way (h25-9 fixed).

h28-6, open: under `--scope commits` a commit whose file a LATER commit also touched shows as `(no hunks reachable here)`: the red commit (`test: failing tests at ...`) lists no file, and the spec appears only under the implementation commit that rewrote it, so the view hides the red-to-green change. `/critique` does chunk the red commit separately.

Then the verdict, both policies:

```
you> /review feature --permissive
```

`--permissive` resolves to `BlockersOnly`; the default is strict. So over a **partially** reviewed
changeset, strict must refuse `:LainReviewVerdict approve` naming the unreviewed remainder, and
permissive must accept it while unresolved non-blocking marks stand. **Drive both on the same
changeset in the same round** — one alone cannot tell a working policy switch from a switch that is
read and ignored.

Check the flag parser too, since it grew a switch and switches are where `--base` breaks:

```
you> /review feature --base --permissive
```

must refuse rather than resolving against a ref literally named `--permissive` and quietly dropping
the switch. Round 17 found it refused for the wrong reason — `--base is not a flag /review can read`,
of a flag it reads (F121). *Driven 2026-09-14* (a headless chat parses the line before it looks for
an editor), for both `/review feature --base --permissive` and a bare trailing `/review feature
--base`:

    error: --base takes a ref -- /review <pull-request|branch> [--base <ref>] [--since <sha>] [--scope cumulative|commits|by_directory] [--permissive] [--critique[=FOCUS]] -- open a changeset review in the attached editor; /review close lets the open round go without a verdict (a branch named close is refs/heads/close); --critique runs /critique over the opened round, and takes the rest of the line as its options and focus

## 6 — `/critique` over the held review

**Round 17 found this section's premise had no path that made it true** (F108): the 7,000-line
critique chunker had no caller outside `spec/`, and `/critique the changeset currently open for
review` ran `git status --porcelain` and `git diff lib/tally.rb` — the model read an uncommitted
`JUNKMARKER_UNCOMMITTED` straight out of the working tree. **Since 2026-09-14, with a `/review` held,
`/critique [focus]` no longer runs the skill inline.** It critiques the held changeset from git
objects: one fresh-root `diff_critic` child per chunk, each child's prompt carrying that chunk's
hunks as the reviewed revisions show them, the child's working directory a detached checkout of the
reviewed head, and the findings merged in chunk order. With no review held, `/critique` is the skill
exactly as before.

What is being checked is not the critique's quality *(predictions, not yet driven — this is the
discharging chunk's integration check 8)*:

- **the working tree never reaches a child.** Open the review, then dirty the tree with a marker
  (`echo JUNKMARKER >> lib/tally.rb`, uncommitted), then `/critique`. No child request may contain
  the marker, and each must contain hunks from the reviewed revisions. The children's read tools do
  not confine paths — an absolute path still reaches the project's tree, and each child's brief says
  so — so the check is on what the model was *handed*, and a child that chose to read the tree by
  absolute path is a model finding to record, not this defect;
- **chunks are sized to the CHILD's served window, not to 7,000 lines.** 7,000 lines is ~99k tokens
  against a 32k local window, which would recreate round 17's silent truncation in every child. The
  line ceiling is derived from the window `WindowBook` reports for the child's model, less the
  instructions and a response reserve; read `ollama ps` and each child's `prompt_eval_count`, which
  must not be truncated;
- **it refuses before spending when it cannot fit or cannot know.** Each refusal starts `/critique
  refused before spawning anything:` — a single file whose hunks estimate over the room a chunk may
  take names the file, its estimate, the room and the window; a window nothing the server has
  reported vouches for (a fresh session before any turn, or `--num-ctx` alone) says to send one turn
  first; a review changing no file says so. A review opened over a tree rather than commits (a
  `/survey`) refuses as having no reviewed revision to critique from;
- **the merged findings name every chunk**, headed `critique of <base>..<head> in <n> chunk(s), each
  read by the diff_critic role`, and each chunk's result is journaled;
- **Ctrl-C stops a running `/critique`.** Its children run in the middleware phase, which is now
  supervised; the discharging chunk's own review found it ignoring Ctrl-C and SIGTERM. Record wall-clock
  and token counts per child — the "cost and latency" gap `README.md` names.

## 7 — `/review-submit` must refuse, not reach for the network

The boundary this scenario exists to hold. With a **local branch** review open:

```
you> /review-submit
```

It must refuse by name — there is no pull request to post to — and it must do so **without a network
call**. Verify the negative rather than trusting the message: run the session with no route to
github.com (`--api-base` is irrelevant here; drop the route, or watch with `ss`/`strace`) and
confirm the refusal is instant rather than a timeout. A refusal that takes 30 seconds is a network
attempt with a polite message on the end of it.

Also drive:

```
you> /review-submit          # with nothing open at all
```

Two different refusals — "nothing is open" and "nowhere to post" — and they must not be the same
sentence. The remedies are nothing alike.

## 8 — Paths git will lie about

`core.quotePath` defaults to ON and renders `café.rb` as the literal `"caf\303\251.rb"` — **not a
filename any caller can open**. It is quiet rather than loud because the diff header quotes it too,
so the numstat and the diff agree with each other on the wrong answer. `LocalBranch` pins
`-c core.quotePath=false`, and pinning is the only fix that survives the setting arriving from a
global config, a repo-local config, or `GIT_CONFIG_*`.

```bash
git switch -qc unicode feature
printf 'x\n' > "café.rb"; mkdir -p 'a b'; printf 'y\n' > 'a b/spaced.rb'
git add -A; git commit -qm 'unicode and spaces'
git config core.quotePath true              # and repeat with GIT_CONFIG_COUNT=1 ...
qa-lain review unicode --base feature
```

Both files must appear under their real names, under **all three** config routes. Also plant a name with a control character (`ruby -e 'File.write("evil\e[2K\rinnocent.rb","x\n")'`) and a newline in a name. h28-1, open: `qa-lain review` prints the raw escape (`Review::Surface::Text#displayed_path` calls `Utf8.legible`, which scrubs only invalid UTF-8), so a terminal shows `innocent.rb` and a newline splits the row in 2; commit subjects have the same gap. `lain trust` escapes control characters in a file it prints, which is the precedent. A `"caf\303\251.rb"`
in the listing is the finding, and it is one that only shows up if the round sets the config
deliberately — the default already being ON is not enough, because a global config could equally be
setting it OFF on this box.

## 9: A 30-file branch, between the 4-path subject and the 300-file ceiling *(headless half driven 2026-11-10; the cockpit half is a prediction)*

§0's subject has 4 changed paths and §4 refuses at 301, so no section reviews the size a real branch has. The
hot-path round's spawn profile put 1,285 `git show` calls at `Review::Source::LocalBranch#file_at` over one suite run,
one per file per side, and `§4b` already prices an open at about 15 to 20 ms per file. A branch of 30 files is where
that cost is large enough to notice and small enough that nothing may refuse it. Zero model turns.

```bash
R="$(mktemp -d)/wide30"; mkdir -p "$R/lib/n" "$R/bin"; cd "$R"; git init -q -b main .
git config user.email qa@example.invalid; git config user.name QA
for i in $(seq 1 10); do printf 'a = %s\n' "$i" > "lib/m$i.rb"; done
git add -A; git commit -qm seed; git switch -qc feature
for i in $(seq 1 10); do printf 'b = %s\n' "$i" >> "lib/m$i.rb"; done; git commit -qam 'edit ten'
for i in $(seq 1 10); do printf 'n = %s\n' "$i" > "lib/n/n$i.rb"; done; git add -A; git commit -qm 'add ten'
for i in $(seq 1 10); do printf '#!/bin/sh\necho %s\n' "$i" > "bin/t$i"; done; git add -A; git commit -qm 'add ten bins'
git diff --name-status main feature | wc -l      # 30: 10 M under lib/, 10 A under lib/n/, 10 A under bin/
```

The recipe names `main` on purpose (`git init -b main`), so the default base resolves and §1's `master` refusal is not
in play. Record `git rev-parse main feature` beside the findings.

**1. Open it in each scope.** From `$R`, with `method.md`'s redirected `XDG_*`:

```bash
for s in cumulative commits by_directory; do /usr/bin/time -f "$s %es" qa-lain review feature --base main --scope "$s" | grep -c '^ *\[ \]'; done
```

Driven 2026-11-10 against this fixture (the checkout's `exe/lain` through `bundle exec`, about 2 s wall per run, boot
included, so the 30 `git show` calls do not dominate it):

| scope | what the output holds |
|---|---|
| `cumulative` | the header `reviewing branch feature at cumulative scope: <40 hex>..<40 hex>`, then 30 `[ ] <path>` rows in path order (`bin/t1`, `bin/t10`, `bin/t2` ... then `lib/m1.rb` ... then `lib/n/n1.rb` ...), exit 0 |
| `commits` | 3 groups headed `edit ten`, `add ten`, `add ten bins`, 10 rows each |
| `by_directory` | 3 groups headed `bin`, `lib` and `lib/n`, 10 rows each (a nested directory is its own group) |

The count is 30 in all three, and no scope prints a ceiling refusal: 30 is far under 300 files and the line ceilings.
**Wrong looks like:** a row count other than 30 (a deleted or renamed file dropped, or a file listed twice under two
commits in `cumulative`); a refusal naming a bound; a scope that exits non-zero; a wall that is seconds beyond the
others, since the open reads every file from git objects and a regression to a per-file shell-out per scope would show
as 3 scopes taking different times.

**2. The record.** Each open writes one `changeset_opened` record, and a refused one would too (§4):

```bash
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next
  puts "#{r["source"]} #{r["base_ref"][0,8]}..#{r["head_ref"][0,8]} #{r["digest"][-12..]}" if r["type"]=="changeset_opened"}' \
  "$XDG_STATE_HOME"/lain/sessions/*/*.ndjson
```

3 opens leave 3 records, each `local_branch`, and **one digest** across them: the identity is the same commits, whatever
the scope, so a digest that moves between the scopes of one branch is a defect (hand-driven 2026-11-10: it did not move).
Each `qa-lain review` run is its own session file, so read the glob rather than one journal.

**3. In the cockpit** *(prediction)*. Piggyback on the subject session, as §5 does:

```
you> /review feature --base main --scope commits
```

Open the sidebar with `2G<CR>` (§5) over RPC and check, on this size rather than on 4 paths: the sidebar lists 30 rows
under 3 headers and scrolls without drawing a partial row; `<CR>` on a `lib/m3.rb` row puts base bytes (`a = 3`) in the
OLD window and the branch's (`a = 3`, `b = 3`) in NEW; `<CR>` on a `lib/n/n3.rb` row, a file the base does not carry,
leaves OLD empty by the nil rule (`file_at` answers nil for a path the revision lacks), not an error buffer. Then `x`
on 3 rows, `:LainNote note ok` on one, `:LainNoteDone`, and `:LainReviewVerdict approve`: the default strict policy
must refuse, naming the unreviewed remainder (§5), and `/review feature --base main --permissive` must accept. The open itself, from `/review` to the sidebar drawn,
should read as instant; record its wall beside the headless one. A 30-file open that takes several seconds in the
cockpit while the headless one took 2 is the finding.

## 10: `/review --since` and `--critique`

Both are flags of `/review` (`Command::Review`), so both need the cockpit for the open itself; their refusals before the open
do not. Use §0's subject. Written from the code at `f6504763`; nothing here has been driven.

**`--since` is for pull requests.** On a branch it is refused before any ref is resolved:

```
you> /review feature --since 0123abc
```

Expect `--since is for pull requests, and "feature" is a branch: name the commit to review from with --base <ref> instead.` and no
round. `/review feature --since` (nothing after it) refuses `--since takes a commit -- <usage>`. `/review close --since 0123abc`
refuses `/review close takes nothing after it`. A value that is not 4 to 40 hex characters
(`--since zzzz`) is refused `--since "zzzz" is not a commit sha` once the target is known to be a pull request.

**The pull request half is live only** (it calls the forge; use a throwaway pull request in a personal repository, never a
work one). With a pull request that has 3 commits `c1 c2 c3`:

- `/review <url> --since <c1>`: the sidebar holds only the files `c2` and `c3` changed, and the headline's range starts at `c1`.
- `--since` as an abbreviation that a branch name also matches is refused `since commit <x> is unknown or ambiguous in this
  repository: name a commit sha that no branch or other commit shares a prefix with`.
- Force-push the branch so `c1` is gone from its history, then repeat: the whole pull request is shown and the banner says
  `since commit <12 hex> is not an ancestor of the pull request head <12 hex> (force-pushed?), so the whole pull request is shown`.
- Post the round with `/review-submit`: comments are placed against the whole pull request, so a comment on a line the whole
  pull request does not change goes into the review's body, not inline.

**`--critique` is written bare or as `--critique=FOCUS`, and takes the end of the line.**

```
you> /review feature --base <the $BASE branch> --critique=critics=1 check the totals for off-by-one
```

Expect the headline (`reviewing branch feature at cumulative scope: ...`) and, under it, the findings of `/critique` over the
round just opened: `critique of <base>..<head> in <n> chunk(s), each read by the diff_critic role`. This spends local model calls.
The round stays open and holds no critique notes: `:LainNoteDone` has nothing to hand back that the critique wrote, and a
`/review-submit` posts no model text. (The plan ruled that critique stays a report and never becomes a note.)

Then the refusals, each with its own ordering:

| line | expect |
|---|---|
| `/review feature --critique focus` | `--critique is not a flag /review can read -- <usage>`: the space form is refused, no round |
| `/review feature --base $BASE --critique=critics=1 critics=2` | `/critique refused before spawning anything: critics= was given twice`, **before the round opens**: no `changeset_opened`, the editor bound to nothing |
| `/review feature --base $BASE --critique=critics=0` | the headline, then `the critique did not run: /critique refused before spawning anything: critics must be a whole number from 1 to 5, got 0`; **the review stays open** |
| `/review feature --base $BASE --critique=model=nonesuch` | the headline, then `the critique did not run: <the unserved-model refusal>`; the review stays open |
| `/review close --critique` | `/review close takes nothing after it` |
| `/review feature --critique` in a headless chat | the no-editor refusal, nothing spent |

| `/review feature --critique` typed at a reply prompt (a parked `ask_human`, answered by typing the command instead of an answer) | `/review ... is a session command and cannot run at a reply prompt -- answer the question first`, **before the round opens**: no `changeset_opened`. A `/review feature` with no `--critique` at the same prompt is not refused for this reason |

**`/stop` reaches the critics.** The critique runs as the next supervised turn, the way a typed `/critique` does, so the stop key
works on it. With `--critique=critics=3` on a held round and the first critic running, type `/stop`: the running critic ends,
the other 2 never start (their children are absent from the journal), and `/stop` does not answer `no ask is running`. Then the
control: the same line with no `/stop` finishes all 3 critics and the merged findings name 3 chunks' worth of notes. A `/stop`
that says nothing is running while a critic works is the finding. The round opens before the critique starts either way.

The ordering is the property: a refusal that can be known up front leaves **no** round behind; one only the run can find leaves
the round open with the reason under the headline. A critique that ran **before** the review opened, or an open review lost to a
refusal that came late, is the finding. Also check what a focus does to the line: the focus runs to the end, so
`--critique=critics=1 --base main` takes `--base main` as focus text, not as a flag.

**From the queue.** An offer built by `lain queue open ... --critique FOCUS` shows the line `/review <url> --critique=FOCUS`
and runs this same path on Enter (`review-queue.md` §4 and §11).
