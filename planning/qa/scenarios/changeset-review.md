# Scenario: reviewing a real changeset, on a local branch

**What it exercises:** `lain review <branch>`, `Review::Source::LocalBranch`, `Review::Changeset`,
`Delta`/`Hunk`, all three `Review::Partition` strategies, `Review::Bounds`' three ceilings,
`Review::Verdict::Policy` (strict vs `--permissive`), the `/review` command at `you>`, and
`/review-submit`'s refusal when there is nowhere to post.

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
lain review feature                  # the default: base is the default base, head is `feature`
lain review open feature             # identical -- `open` is the escape, not a different command
lain review feature --base "$BASE"
lain review no-such-branch           # UnknownRef
lain review feature --base no-such   # UnknownRef, naming the BASE role
```

Expected, and **the role must be named** — `base` and `head` fail identically otherwise and an
operator cannot tell which of their two refs was the typo:

```
head ref "no-such-branch" does not resolve to a commit in <repo>: <git's own detail>
```

The `: <detail>` tail is load-bearing. `rev-parse --verify --quiet` silences "unknown revision" but
**not** "not a git repository" or "cannot change to …", and those two are exactly the ones a caller
needs. Run `lain review feature` from **outside any repository** and confirm the detail survives
rather than being swallowed into a bare "does not resolve".

**And in a repository with no `main`.** The default base is the literal `main`, so a `master`
repository cannot review a branch without `--base` (round 17's V2). The two entry points now answer
differently, and a round should drive both:

- **`/review <branch>` names the way out** since 2026-09-14 — `… -- this repository has no default
  base to review a branch against; name one with --base <ref>`. *(Prediction, not yet driven: a
  headless chat refuses `/review` for having no editor before it resolves any ref, so this needs the
  cockpit.)*
- **`lain review <branch>` still does not.** *Driven 2026-09-14* in a `git init -b master`
  repository: `base ref "main" does not resolve to a commit in <repo>`, exit 1, no mention of
  `--base`. That is the one-shot's wording today, not a regression; file it as V2's remainder if a
  round wants it changed.

### 1b — two roots, no merge base

The refusal that exists because the alternative is silent and catastrophic:

```bash
git checkout -q --orphan orphan; git commit -q --allow-empty -m 'unrelated'
lain review feature --base orphan
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
lain review help          # Thor's HELP SCREEN -- correct, and the reason `open` exists
lain review open help     # reviews the branch
lain review open tree     # reviews the branch
```

A `lain review help` that tries to review a branch is as much a defect as `lain review open help`
printing help.

## 2 — The three scopes, and where the enum comes from

```bash
for s in cumulative commits by_directory; do lain review feature --scope "$s"; done
lain review feature --scope by_files      # Thor rejects: not in the enum
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
`lain review --scope by_directory` was exactly that failure. **Check the failure direction:** a
scope the registry serves must be accepted, and a scope it does not must be refused by Thor with
the valid set named.

## 3 — `--base`, and what the changeset is actually cut against

`base` is not the ref the diff is taken from — **the MERGE BASE of base and head is**. Prove it:

```bash
git switch -q "$BASE"; git commit -q --allow-empty -m 'base moved on'
lain review feature --base "$BASE"
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
lain review wide --base feature
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
2. **`:LainNote` on the OLD side anchors to `(side, revision, path, line)` with `side` naming the
   old revision.** Place one on the OLD side and one on the NEW side of the same file at the same
   line number, and confirm the two notes are distinct and come back distinct. Round 7's §4b
   findings (F30–F39) are all on the note rail and **none of them were driven against two sides**.
3. **`x` marks a hunk, and a changeset has real hunks.** `cockpit-surfaces.md` §4's `x` refusal
   ("nothing on that row") is the sibling failure; here the positive case is reachable.

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

    error: --base takes a ref -- /review <pull-request|branch> [--base <ref>] [--scope cumulative|commits|by_directory] [--permissive] -- open a changeset review in the attached editor

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
lain review unicode --base feature
```

Both files must appear under their real names, under **all three** config routes. A `"caf\303\251.rb"`
in the listing is the finding, and it is one that only shows up if the round sets the config
deliberately — the default already being ON is not enough, because a global config could equally be
setting it OFF on this box.
