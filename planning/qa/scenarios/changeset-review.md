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
**three commits, on two directories, with one file that exists only on the branch and one that is
deleted by it** — that is the minimum that tells `by_commit` from `by_directory` and gives the
note rail an OLD side to anchor against.

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
git add -A; git commit -qm 'seed'
git switch -qc feature

# commit 1 -- lib/ only
printf '  def total = @counts.values.sum\n' >> lib/tally.rb
git commit -qam 'lib: a total'
# commit 2 -- bin/ only, and a deletion
printf 'puts Tally.new.total\n' >> bin/tally; git rm -q bin/../bin/tally 2>/dev/null || true
git add -A; git commit -qm 'bin: use it'
# commit 3 -- a new file, in a third directory
mkdir -p doc; printf '# Tally\n\nCounts words.\n' > doc/README.md
git add -A; git commit -qm 'doc: say what it is'
```

**Do not hard-code `main`.** `git init` gives `master` on some boxes (it does on this one), and every
`git rev-parse main` in this section then fails. Capture it: `BASE=$(git symbolic-ref --short HEAD)`
before the `git switch -c feature`.

**Record `git rev-parse $BASE feature` in the findings.** Every line number and every hunk count
below is against these three commits; a round that regenerates the subject differently cannot
compare against the last one.

## 1 — Resolution, and the two refusals

```bash
lain review feature                  # the default: base is the default base, head is `feature`
lain review open feature             # identical -- `open` is the escape, not a different command
lain review feature --base main
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
for s in whole by_commit by_directory; do lain review feature --scope "$s"; done
lain review feature --scope by_files      # Thor rejects: not in the enum
```

`whole` is the default. Against §0's subject:

| scope | expected grouping |
|---|---|
| `whole` | one group, four changed paths |
| `by_commit` | **three** groups, in topo order, each naming its subject line |
| `by_directory` | **three** groups — `lib/`, `bin/`, `doc/` |

**The enum is read off `Review::Partition::STRATEGIES`, not written by hand in the exe**, and that
is a real past defect rather than tidiness: Thor validates `enum:` *before* it dispatches, so a
hand-written list rejects a scope the registry serves without the registry ever being asked.
`lain review --scope by_directory` was exactly that failure. **Check the failure direction:** a
scope the registry serves must be accepted, and a scope it does not must be refused by Thor with
the valid set named.

## 3 — `--base`, and what the changeset is actually cut against

`base` is not the ref the diff is taken from — **the MERGE BASE of base and head is**. Prove it:

```bash
git switch -q main; git commit -q --allow-empty -m 'main moved on'
lain review feature --base main
```

The changeset must be unchanged by that empty commit on `main`. A review that grows a "main moved
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
you> /review feature --base main --scope by_commit
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
the switch.

## 6 — The one model turn

Ask the model to critique the open changeset. What is being checked is not the critique's quality:

- the `/critique` ceiling is **7,000 lines** and is the only bound set against the window, so
  confirm the chunking actually chunks — a critique that silently sends one oversized block is the
  regression;
- the model is shown the **changeset**, not the working tree. Dirty the working tree after opening
  the review (`echo junk >> lib/tally.rb`, uncommitted) and confirm the critique does not mention
  it.

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
