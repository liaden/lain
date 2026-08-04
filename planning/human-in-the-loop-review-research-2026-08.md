# Human in the loop diff review: research

> ⚠️ **LLM-generated synthesis** (Claude, 2026-08-04). Provenance is mixed, so it is marked
> per section:
> - **Measured here.** The 7 spikes in §3 were written and run in this repo. Their output is
>   pasted verbatim. Branch `spike/review-ui`, commits `eebb24d`, `36fdc99`, `55677b0`,
>   `9e0f471`, `3484b56`.
> - **Verified upstream.** Licenses came from the GitHub API on 2026-08-04. Issue text is
>   quoted with issue numbers. Source claims about tuicr, octo.nvim and codediff.nvim came
>   from sub-agent reads of fresh clones at the versions named in each section.
> - **Inferred.** Every reading of what a finding means for lain, the rankings in §6, and all
>   effort estimates. These are Claude's, and Joel has not signed off on them except where
>   §6 records a ruling in his words.
>
> Nothing here has been built. §5 is where the thinking currently sits, not a plan.

---

## 1. The questions, as asked

Joel, 2026-08-04, opening:

> for the epic orchestration or even the idea of adding a feature in general, I would like for
> us to have this idea of the "Human-in-the-loop" where when the plan is done and implemented,
> we have done a `/critique` of the code change, the human is then shown the current diff
> against origin/main and able to locally annotate it with comments to review the code via
> `nvim`. We can have a key press that allows asking a question of the LLM about specific parts
> of the changes that allow for an inline conversation about that portion of the code? Or
> perhaps the code review UI is structured to allow for it to have a conversation chat that
> references the cursor marker's position or similar?
>
> I want us to consider how this fits into what we have and what would be good UI/UX.

Then, in order:

> None of this is "live in production" so we can reset protocol back down to 1 if we want or
> even consider it to be 0.9 instead?

> Lets do some preliminary spiking on this in a branch on a worktree maybe, and lets see what
> open source tooling we could use for this to facilitate things as well.

> Can we take inspiration from `tuicr`, `review.nvim`, `diff-review`, or `octo.nvim`? Could we
> copy out implementation details, license permitting, to help bootstrap our code more easily?

> There is "code lifting" and there is "UI/UX lifting." Beyond that, we could look at issues
> reported on the repos to find out common UI/UX concerns so we are more proactive in
> addressing how things should work?

> Some thoughts I have: if the "human in the loop" review is done with fixup commits and on top
> of logical commits and/or stacked PRs, then the "reviewed" flagging for the changes is a lot
> easier for us to manage in the long run right? Are there edge cases I am missing here though?

> Alternatively, if comments and reviewing is even just based off of the SHA, we could have the
> secondary review do a `git diff` of new state versus previous state to show what has changed
> since the last review? We can still see the overall changes still but just bring attention to
> how it has evolved since the last time the human reviewed.

> There is the way we expose things to the human versus how we implement things and they don't
> have to exactly match as long as it doesn't result in surprises in behavior so it may look
> like they comment on a line for a given commit but we may have journaled it differently.
>
> Beyond that, the fixups can wait until the human has fully approved, I think?

> Well, if we have logical commits, it can be nice to walk the commits for the review process,
> right? So sometimes it should be cummulative and sometimes it should be a narrower field of
> view, right?
>
> Also, one thing I perosnally dislike about Github is not being able to see associated code
> that is impacted by the changes. Can we make sure the "human in the loop" is able to reach and
> discover the impacted code too to facilitate their review process?

> I wonder if there is room for a sidebar for navigating the diff partially such as seeing the
> commit messages and what files were changed per commit and some information about the commit
> then and otherwise being able to benefit from the full files? Maybe we can benefit from
> `lain://review` as a diff buffer and still allow for a `gf` that allows us to go to file that
> is changed? Then again, if we use vims default diff viewing and build on that, we fold away
> code that isn't changed already so.

> Different use case that I think would be powerful for me at work: being able to do the diff
> review of a PR on github by just using this portion of the orchestration in isolation in lain
> by supplying the branch itself and/or the PR link. Possibly then having it opt to do the
> `/critique` command to review the change, and prefill some of the commentary to facilitate the
> human reviewers review as well?

And on posting model-written comments to other people's PRs:

> I am fine with a code review comment on another PR being under my responsibility if I have
> chosen to post it. It is my obligation to review and edit that proposed comment proactively
> as a first line of triage and not putting that burden on the initial author of the PR.

The issue-tracker suggestion produced more usable design input than reading any of the source
did. See §4.2.

---

## 2. What lain already has

Roughly 70% of this exists. Read of the repo on 2026-08-04.

`Lain::Epic::Review` (`lib/lain/epic/review.rb`, 561 lines) owns the handoff. `#open` journals
the written digest and a generation; `#settle` diffs disk against written, journals
`review_closed`, and resolves that generation's promise. Regeneration refuses while a review is
open. `Review.from_journal` rebuilds the state, so a chat restarted mid-review still refuses to
overwrite. Identity is the pair `(epic_slug, generation)` on purpose: a bare integer off the
wire cannot say which review it means.

`Epic::Review::Annotations` (57 lines) turns extmarks into
`{line, text, anchor_text, issue_id, drifted}`, journaled in placement order. Drift compares
`anchor_text` against whatever the line number now points at. Drifted notes are kept, with the
reason stated in the source: "their words are the part nobody can reconstruct."

`runtime.lua` already has the editor side: `open_review`, `:LainAnnotate` (extmark plus
`virt_text`), `:LainReviewDone`, a `lain_review_annotations` namespace, and `BufUnload` cleanup.
`Tools::RequestReview` parks the fiber on the promise with no timeout, so two reviews can be
open at once.

The gap is stated in the code. `RequestReview::Refusals::NO_DOCUMENT`:

> `implementation` gates a changeset digest rather than a document, so reviewing it would mean
> reviewing a diff, a surface lain does not have.

Machinery that would plug in: `Approval::Queue::Pending#decide` is first-answer-wins across
surfaces, and its class comment says a Neovim surface is meant to coexist. `Approval::SignoffQueue`
plus `lain epic queue` already implement the deferred-gate morning queue. `planning/epic-orchestration.md`
§3.3 defines the gate policies (`interactive`, `hands-off`, `deferred`, `Adjudicated`).

`Forge::Gh` (`lib/lain/forge/gh.rb`) wraps `gh` behind a `shell_out_factory` seam with retry and
timeout handling, and `Reconcile::World#pr_for` resolves a PR from a head branch. That covers
reading a PR. Nothing posts review comments.

Not built: any changeset surface, any inline conversation, and `lain://status` (ruled in
epic-orchestration §3.8, never written). `lain://diff` exists and is the request payload diff, so
that name is taken.

---

## 3. Spikes run here

All 7 ran in `/home/joel/dev/lain-spike-review` on branch `spike/review-ui`. Output below is
pasted, not summarized. §3.1 through §3.4 came first; §3.5 through §3.7 were added after the
design broadened and are what closed open question 7.6 and sized the performance problem.

### 3.1 Anchor model (`spike/review-probe/diff_map.rb`)

Question: can plain Ruby map every rendered diff line back to `(path, side, file_line)`, and does
any gem or crate earn a place?

Against `HEAD~5...HEAD`, 2159 rendered lines across 88 files:

```
VERIFY new-side (worktree):   1501/1501 anchors resolve
VERIFY old-side (merge-base):  179/179 anchors resolve
```

A unified diff is a line-oriented state machine with 2 counters. That is the whole parser. No
diff gem or crate is needed, because `imara-diff`, `diffy` and `similar` all compute diffs and
git already did that.

Two things the spike caught that memory would not have:

1. The first version incremented the old-side counter on additions. Only checking the old side
   found it. Check the inconvenient side.
2. `git diff A...B` compares B against `merge-base(A, B)`, not against A. Old-side anchors have
   to be verified against the merge base or every deletion anchor shifts silently.

### 3.2 Annotation substrate (`spike/review-probe/diagnostics_probe.lua`)

Question: can `vim.diagnostic` carry review annotations? BLOCKER, SHOULD-FIX and NIT map onto
ERROR, WARN and HINT, and in exchange nvim gives signs, virtual text, `]d` and `[d`, `setqflist`,
severity filtering, and every picker's diagnostics source.

nvim 0.12.4, headless:

```
1. SET/GET      -> 3 diagnostics readable
2. FILTER       -> 1 BLOCKER via severity filter
3. NAVIGATION   -> ]d lands on line 3
4. QUICKFIX     -> 3 entries
5. RENDERING    -> 3 extmarks with virt_text/sign placed by the diagnostic layer
6. EDIT DRIFT   -> lnum before insert: 3  after inserting 2 lines above: 3  => STATIC
7. COEXISTENCE  -> lain extmark placed alongside diagnostics on same buffer: ok
```

Line 6 decides it. Diagnostics do not move when the buffer is edited; extmarks do. So extmarks
own position and diagnostics mirror them for display. `Annotations`' drift detection keeps
working untouched, and the projection into diagnostics is roughly 40 lines of lua for a large
return in navigation.

### 3.3 Re-review delta (`spike/review-probe/redelta.sh`)

Question: when the human reviews a second time, what shows them what changed? The scenario built
is the normal one for an agent: the base moved under the branch, and a commit was amended.

```
=============== A. git diff HEAD_V1 HEAD_V2 (tree compare) ===============
   README.md | 3 +++
   util.rb   | 2 +-
  ^ files touched: README.md util.rb

=============== B. git range-diff (patch-series compare) ===============
  1:  c96560e = 1:  967ef87 feat: audit before write
  2:  60997b6 < -:  ------- feat: bump helper
  -:  ------- > 2:  b3d6a59 feat: bump helper (typo fixed)

=============== C. what each says the human must re-read ===============
  git diff      -> 2 file(s), including base movement the human never reviewed
  range-diff    -> 1 entr(y/ies) identical, 2 needing attention
```

`git diff` between the two heads reports `README.md`, which is somebody else's landed work. The
human never reviewed it and does not need to. `range-diff` omits it.

The incidental result matters more than the intended one. Range-diff marked commit 1 identical
(`=`) across 2 completely different SHAs, because it matches by patch content. That is the stable
identity property spr and jujutsu get from change-ID trailers, available for free, with no
discipline required of the agent.

The spike also pins the reviewed head under `refs/lain/reviewed/<generation>`. Once the branch is
rewritten, nothing else keeps the baseline reachable and `git gc` can take it.

### 3.4 Native diff mode (`spike/review-probe/native_diff_probe.lua`)

Question: what does vim's own diff mode give us, against rendering a diff into a scratch buffer
ourselves?

```
1. REAL BUFFERS -> new buftype="" old buftype=""  filetype="ruby"
2. FOLDING      -> foldmethod="diff"  line 5 foldclosed=1  line 20 foldclosed=-1
3. ]c MOTION    -> from line 1 jumped to line 20
4. INTRA-LINE   -> groups: DiffAdd=yes DiffChange=yes DiffDelete=yes DiffText=yes | DiffText active at the changed span: false
5. TWO PANES    -> 2 diff windows; nvim owns filler+scroll sync (diff_set_topline)
6. SIGNAL/NOISE -> 26/40 lines folded away; zR expands the whole file in place
```

`buftype=""` with filetype detected means these are real buffers, so the language server,
treesitter and every picker attach normally. That is what §5.5 needs.

`foldmethod=diff` hid 26 of 40 lines, and `zo` or `zR` expands surrounding code in place. That is
the affordance GitHub handles with a click-to-expand button.

A separate check confirmed the default `diffopt` already carries `linematch:40` and
`indent-heuristic`, and accepts `inline:char`:

```
inline:char accepted -> true
diffopt -> internal,filler,closeoff,indent-heuristic,inline:char,linematch:40
```

So character-level intra-line diffing is free. An earlier claim in this thread that it was not
free was about `vim.diff()` the function, which is a different thing from diff mode.

Two honest gaps in this probe. Check 4 returned false, and that is inconclusive rather than
negative: `inspect_pos` reads syntax, extmarks and semantic tokens, and diff highlighting is
applied by the screen renderer, so it cannot see it. Check 5 counted windows and did not measure
scroll sync; that claim still rests on codediff's source comment quoted in §4.3.

### 3.5 The old side of a diff (`spike/review-probe/oldside_probe.lua`)

Question: native diff mode gives real buffers on the new side. The old side has to come from
`git show <base>:<path>`, so it has no file behind it. What does that cost?

```
1. DIFF ACCEPTS -> old buftype="nofile" diff=true | new diff=true
2. FILETYPE     -> before=""
   after set    -> "ruby"  treesitter attaches=false
3. FOLDING      -> 17/30 folded on the OLD side too
4. EXTMARK      -> row before=14 after inserting 2 above=16  SLIDES (drift detection works)
5. IDENTITY     -> name="lain://review/OLD/app.rb"
6. LSP          -> old-side buftype="nofile" means no client attaches
```

Line 4 answers the open question: an extmark anchored in a scratch buffer slides on edit exactly
as it does in a real file, so drift detection works identically on both sides.

Two costs, both statable rather than fatal. Filetype has to be set by hand because there is no
path to sniff. And no LSP client attaches to a `nofile` buffer, so go-to-definition and find-
references work on the new side only.

Probe 2's treesitter result says nothing: nvim ships no Ruby parser under `--clean`. Inconclusive.

### 3.6 Code intelligence, actually available

§5.5 recommended SCIP on the strength of `spike/scip-probe` existing. Running it changes the
recommendation for half the codebase.

**Rust works.** `rust-analyzer scip ext/lain` produced a 933KB index in 6.7s wall. Feeding it to
the existing probe:

```
project-symbol references: 2194/2260 resolved to an in-index definition (97%)

QUERY 'blake3_hex' -> blake3_hex().
  definition -> src/lib.rs:95
  10 reference(s): src/lib.rs:496, 2230, 2236, 2250, 2257, 2257, 2262, 2262, 2267, canonical.rs:144

HOT project symbols (most referenced, defined in-index):
    96  digest/Digest#      def@ src/digest.rs:25
    92  canonical/Canon#    def@ src/canonical.rs:39
```

That "hot symbols" ranking is the blast-radius column from §5.5, already computed. The 3% gap is
real: rust-analyzer logged `Bug: definition at src/canonical.rs:37:16-37:21 should have been in an
SCIP document but was not`. So the omission set will have holes and cannot be presented as
complete.

**Ruby has no working code intelligence in lain's prescribed toolchain.** `scip-ruby` is not
installed and is a Sorbet fork, which this project abstains from. There are 3 separate ruby 4.0.6
installs on this box:

```
  /home/joel/.rubies/ruby-4.0.6/bin/ruby         4.0.6   <- what CLAUDE.md prescribes
  /home/joel/.asdf/installs/ruby/4.0.6/bin/ruby  4.0.6   <- where ruby-lsp 0.26.10 is installed
  /home/linuxbrew/.linuxbrew/bin/ruby            4.0.6
```

`ruby-lsp --version` fails under the first and succeeds under the second. The LSP client used to
test this crashed 3 times for the same reason. This is a setup problem rather than a design one, and the fix
is `gem install ruby-lsp` under `~/.rubies/ruby-4.0.6` or pointing the client at the asdf install.
It does mean the Ruby half of §5.5 is unverified until that is done.

### 3.7 A work-sized changeset (`bigdiff.sh`, `bigdiff_stacked.sh`)

Joel supplied the real number: "+62,000 LOC, -12,000 LOC", decomposed into "30+ logical commits or
end up being decomposed into stacked PRs". Every earlier spike here ran 2159 lines, so this builds
something the right shape.

Flat, 800 files:

```
 800 files changed, 62400 insertions(+), 12000 deletions(-)
  rendered diff lines: 80800

  parsed 80800 rendered lines, 76800 anchorable, in 0.26s   RSS 39MB
  per-line cost: 3.2 us

  git diff --numstat : 0.05s
  git diff (full)    : 0.06s
```

Decomposed, 30 commits of 27 files:

```
  cumulative: 810 files changed, 63180 insertions(+), 12150 deletions(-)
  cumulative rendered lines: 81810
  per-commit rendered lines: 2727 2727 2727

  git log --numstat over all commits: 0.07s

  range-diff --no-patch : 0.22s
  identical (=) : 29
  changed  (!<>): 1
```

**The decomposition is what makes this reviewable.** 2,727 lines per commit against 81,810
cumulative is a 30x reduction, and 2,727 is the size every earlier spike ran clean. §5.4's commit
walk is required at this scale rather than a convenience.

The range-diff result is the other one worth keeping. After rebasing onto a moved base and
amending the tip, all 30 SHAs changed, and range-diff still reported 29 identical and 1 changed, in
0.22s. A re-review reads 2,727 lines instead of 81,810.

Nothing in our layer is the bottleneck at this size. The real limits sit elsewhere, and §7 records
them: `/critique` over 74k lines exceeds any context window and has to chunk (per commit is the
natural unit), SCIP indexing at monorepo scale is unmeasured, GitHub stops serving a combined diff
past 300 files so 810 files needs tuicr's local-object-database fallback, and no human reads 74k
lines, which is what makes blast-radius sorting and generated-file collapsing matter.

---

## 4. The external survey

### 4.1 Licensing

Lain is MIT (`lain.gemspec:21`). Checked via the GitHub API on 2026-08-04.

| Project | License | Copy code? |
|---|---|---|
| tuicr | MIT | yes, with attribution |
| octo.nvim | MIT | yes, with attribution |
| codediff.nvim (esmuellert) | MIT | yes, with attribution |
| review.nvim | Apache-2.0 | legal, adds obligations |
| diff-review (colonyops) | none detected | no grant to copy |
| diffview.nvim | GPL-3.0-or-later | would infect lain |

Two traps. `diff-review` has no LICENSE file at all; its root contents were listed to confirm.
Default copyright applies, so it is read-only for us. GitHub reports `NOASSERTION` for diffview
because its LICENSE opens with a prose preamble, and the text underneath is GPL-3-or-later.
octo's review panel is described upstream as heavily inspired by diffview, which means we should
not read diffview for implementation and then write ours from memory of it.

review.nvim at Apache-2.0 is legal to include in an MIT project, and the copied portion stays
Apache-2.0: retain notices, ship the license, state modifications, handle any NOTICE file. The
gemspec's flat `license = "MIT"` would stop being the whole truth. What we would take from it is
a comment-type taxonomy, a handful of strings, so the bookkeeping costs more than the code.

The distinction doing most of the work: techniques, UX patterns and data models are not
copyrightable. Only specific expression is. All 6 projects are available as design sources,
including the 2 we cannot copy from.

### 4.2 Issue trackers

Joel's suggestion, and the highest-yield source in the survey.

**The reviewed-mark has to key on content.** [tuicr#228], describing our exact workflow:

> When I do a review, I mark files I've reviewed as I go, then I get the review and paste it
> back into Claude. Happy days. Then Claude changes everything, but my review is now outdated.
> So I run `:clear`, but the reviewed files are still shown as "reviewed", so I have to uncheck
> them all one-by-one.

Human PR review rarely hits this, because humans do not rewrite the branch between rounds. In an
agent loop it is the normal case.

**A boolean per file is wrong for a second reason.** [tuicr#247], from someone reviewing a stack
of jj changes with an agent squashing feedback between rounds:

> There are sometimes multiple changes in my stack that touch a single file. When I filter to
> one of the changes and mark the file as reviewed, I have actually only seen part of the
> overall diff.

Their fix made review state a list of commits in which the file was reviewed, with a tri-state
indicator: green when reviewed at the current filter, yellow when parts remain unreviewed at full
scope.

**Large changesets break all of them.** [octo#302]: review start fails outright on large PRs.
[tuicr#475]: a hard 300-file ceiling, and "patches large enough to hit the limit also made file
and commit navigation slow." [tuicr#288] and [tuicr#394]: an ongoing streaming-highlight and
perceived-latency effort. codediff has no size guard of any kind (§4.3). Agent changesets are the
large-diff case; the spike diff was 88 files from 5 commits.

Three findings confirm choices lain already made:

- Drifted comments should stay visible. [octo#877] is an open complaint that octo hides outdated
  comments in review mode, from a user who wants to keep the conversation going on a line that
  moved. `Annotations` already keeps them.
- Review state should not live in editor memory. [octo#118] asks for persistence outside the
  editor so a crash does not lose comments; octo#980 is "review resume errors out"; tuicr#358 is
  threads not fetched on resume. `Review.from_journal` covers this.
- Buffer-local keymaps get lost on tab switches ([octo#854]). Lain binds from `BufEnter` in
  cleared augroups, which avoids it, and it is the exact trap to fall back into.

[tuicr#229] separately floats storing reviews in-repo so "that information can be used for
future reviews, either for agents or humans."

**diffview's tracker, added 2026-08-04.** Mined after native diff mode became the chosen surface
(§6.2), because diffview is the one project that uses it. Two findings apply directly:

- [diffview#509], open: opening the diff view flashes the currently focused buffer in both diff
  windows. Our sidebar `<CR>` is the same operation, so set the buffer before showing the window.
- [diffview#466], open: `E5560 nvim_buf_is_valid must not be called in a lua loop callback`. That
  is the whole class of calling an nvim API from a libuv callback without `vim.schedule`. Lain's
  RPC thread posts lua by notification, so it applies to anything we add.

[diffview#457] and #582 are cursor and fold state lost on tab switch, the same family as
[octo#854]. Three projects lose editor state on tab switching.

One correction worth recording. A first query for diffview performance issues returned nothing,
which looked like evidence that native diff mode avoids the large-diff problem. A broader sweep
says otherwise: 18 performance-ish issues for diffview, 19 for octo, 8 for tuicr. Native diff mode
being lazy per file is still true and does not exempt anyone from performance work.

### 4.3 codediff.nvim

Alignment is cheap. Filler is one `virt_lines` extmark carrying N virtual rows
(`lua/codediff/ui/filler.lua:45-68`), and the 3-deleted-versus-7-added case is 12 lines
(`ui/core.lua:168-190`). Every hunk contributes `max(orig_len, mod_len)` rows to both sides.

Scroll sync is expensive, and their header comment (`lua/codediff/scrollsync.lua:1-24`) explains
why:

> Native `scrollbind` tracks position with a display-line count (`get_vtopline`) that becomes
> discontinuous when a single virt_lines/diff filler block is taller than the window (`w_topfill`
> is clamped). That discontinuity makes the bound window oscillate between the correct position
> and a wrong one, redrawing the whole pane each step -> visible flicker. Built-in `:diffthis`
> avoids this because it syncs with `diff_set_topline` (a structural, diff-block mapping) instead.

Their 415-line replacement exists because they render fillers themselves rather than using diff
mode. §3.4 takes the other branch and the problem does not arise.

Their diff engine is a vendored C port of VSCode's algorithm, roughly 30k lines, loaded by LuaJIT
FFI from a prebuilt shared object downloaded from GitHub releases on first use. Not something we
want, and not something we need.

They have no performance guards: no line-count limit, no lazy or chunked render, everything
synchronous and eager. A 5-second diff budget is passed to the engine and the returned
`hit_timeout` flag is never read, so a timeout renders a degraded diff quietly. The largest input
under test is 50 filler lines.

Their inline and side-by-side renderers are parallel implementations, roughly 1500 lines with
verbatim duplication between them. Inline is conceptually the projection: deleted lines become
`virt_lines` on the modified buffer.

### 4.4 tuicr (MIT, v0.20.0, ~60k lines of Rust)

They punted on anchor drift, deliberately, after trying the alternative.

There is no re-anchoring in the codebase. The HEAD short SHA goes into the session slug
(`src/slug.rs:17-22`) so a new commit produces a fresh session rather than "resurrecting stale
comments tied to the previous HEAD." Lookup is exact-slug match with no fallback, so committing
mid-review gives you a blank session next time.

The history is the part worth keeping. They shipped destructive deletion (`fbc3990`, a literal
`remove_file` on your comments when HEAD moved), then slug-addressed sessions (`01b0eeb`) which
accidentally shared state across a commit, then reverted (`2c9ab88`):

> Two `tuicr -w` runs on the same branch resolved to the same persisted session even after the
> user had committed, dragging the previous run's comments back into the new clipboard output.

The tell is a dead struct. `LineContext { new_line, old_line, content: String }`, exactly the
shape you need to relocate an anchor, is never populated in production; the only 2 construction
sites are inside `#[cfg(test)]`. It is serialized into every session file as dead weight.

Where they do carry state forward it is all-or-nothing at file granularity. PR force-push runs
`file_review_carried_forward` (`src/app/session.rs:610-654`): reviewed-hunk markers survive
because they are content-addressed, and comments survive only if the file is byte-identical
across heads. Any change anywhere in the file drops every comment on it. Not marked stale, not
greyed, dropped. The old head's session file stays on disk and the manifest holds one entry per
PR slug, so it is unreachable.

**The content-addressed hunk key is the good part** (`src/model/diff_types.rs:78-121`):

> Unique hunk content ignores hunk header line numbers so unrelated edits above a hunk do not
> clear its reviewed state. Repeated identical hunks fall back to a line-aware key because a pure
> occurrence count can move reviewed state onto a different hunk when one duplicate changes.

The key hashes the hunk's own text including origin markers, so it is position-independent. Add
500 lines above and the mark follows. The `-v1:` prefix lets the scheme change without corrupting
old sets. Keys absent from the current diff are pruned on every load, and there is an explicit
`preserve_hunks` flag for when a filtered subset is displayed and pruning would delete marks for
hunks merely hidden by the filter. Roughly 40 lines.

**The three-way merge is the other transferable idea** (`merge_external_session_changes`,
`src/app/session.rs:214-278`). The TUI keeps a snapshot as the merge base, polls the file's
`(mtime, len)`, and on change merges by comment UUID with the conflict rules written out as
comments: "Local deletion wins over an external edit", "Local edit wins over an external edit of
the same comment." Polling is suppressed while the user is mid-compose. Roughly 60 lines, no
daemon, no socket, no database.

Two smaller ideas: ephemeral session files written the instant a target is active, so an agent
can resolve the slug before the human has typed anything (deleted on exit if empty); and
`active_sessions.json` carrying pid, slug and `last_seen_at` so an agent picks the live session
instead of guessing by timestamp. Also `UnmappableReason` (`src/forge/submit.rs:105-138`): every
way a comment can fail to map onto a forge is a named variant with a human label, shown in an
"Unplaced comments" section rather than dropped.

Do not copy their `Comment` type. Detached from its container it does not know its own path or
line, because `line_comments` is a `HashMap<u32, Vec<Comment>>` where the map key holds the line.
That forces 3 near-identical enums for one concept (`CommentTarget`, `CommentAnchor`,
`StoredCommentLocation`), and the `CommentAnchor` doc comment says inferring the level from a bare
`Comment` "is wrong."

Other warts: `line_comments` is keyed by line without side, so old-line-11 and new-line-11 share a
bucket and correctness depends on 2 renderer predicates staying mirror images. Range comments are
stored under `range.end`. `maybe_migrate` (`storage.rs:709-747`) renames `reviews/` to
`reviews.bak1` and starts empty on any layout change, and no migration was ever written; they have
done it twice. No retention or GC at all.

Not usable as a library. `src/lib.rs` exists and `ReviewStore` is a clean 12-method facade, and
then `src/model/diff_types.rs:1` is `use ratatui::style::Style;` with `DiffLine` carrying
`highlighted_spans`. The merge, carry-forward and hunk reconciliation logic is `pub(crate)`. There
are no feature flags to trim the TUI dependency graph. Their own agent integration is a skill that
shells out to a documented JSON CLI (`docs/REVIEW_CLI.md`).

Credit where due: 2 TODOs in 60k lines, dense colocated tests, doc comments that explain why
including past bugs, and a "legacy JSON still parses" test for every serde field addition. This is
a well-run project that made an explicit, documented decision not to solve anchor drift.

### 4.5 octo.nvim (MIT, HEAD ~Jan 2026)

**The thread view is a buffer swap into the opposite pane**, not a float and not a new split
(`lua/octo/reviews/thread-panel.lua:62-88`). octo runs a 2-window vertical diff; when the cursor
lands on a commented line it replaces the other window's buffer with a rendered thread buffer. The
pane you are reading stays where it is. No window is created or destroyed on cursor movement,
which is what would otherwise cause flicker and layout churn.

The general form, which survives whatever layout we pick: keep a persistent second pane and swap
its buffer. Never open or close windows on cursor movement.

Mechanism worth taking:

- Trigger is `CursorMoved` on pattern `*` (`lua/octo/autocmds.lua:66-74`), with a cheap bail-out:
  `pcall(nvim_buf_get_var, bufnr, "octo_diff_props")`. Absent, return.
- `octo_diff_props = {path, split}` is a buffer variable (`file-entry.lua:554-557`). Side is a
  discriminator carried on the buffer, never encoded in the line number. That matches the
  `(path, side, line)` anchor from §3.1 directly.
- One range extmark per thread, with its id keying the metadata table
  (`lua/octo/ui/writers.lua:3527-3540`).
- Comment-count virtual text uses `virt_text_pos = "right_align"` (`file-entry.lua:479-491`), so
  the count sits at the right edge and never collides with code.
- `validate_layout`, `recover_layout` and `ensure_layout` (`layout.lua:246-295`) detect a
  user-clobbered window arrangement and rebuild it. Called before every thread show. Users will
  `:q` one of our windows.

octo does not solve anchor drift; it outsources it. No local re-anchoring, no content hashing, no
extmark-following of threads. It reads `thread.line` or `thread.originalLine` off the API object
and picks one by review level, with an honest comment about the result (`reviews/init.lua:568-571`):

> This may result in a jump to the wrong line when the review is neither in the last commit or
> the original one

Issue #302's root cause was JSON parsing, not rendering. `gh api --paginate` emits each page as a
separate JSON document concatenated together, so `vim.json.decode` on the joined stdout dies. The
maintainer chose to wait for upstream `gh` to ship `--slurp`, roughly a 2-year stall. Their
eventual Lua reimplementation silently drops any page that fails to decode
(`lua/octo/gh/init.lua:170-182`), so a large PR now produces a quietly truncated file list instead
of a crash. That is a worse failure mode than the one it replaced.

The remaining scalability wall is unbounded fan-out. Review start fetches every file, each fetch
fires 2 requests (one per side), and some go through a synchronous `git show`:

```lua
for _, file in ipairs(files) do
  file:fetch(false)   -- async, ALL of them, unthrottled
end
```

A 290-file PR spawns roughly 580 concurrent `gh` and `git` subprocesses. No queue, no concurrency
cap, no viewport windowing.

Port cost, measured by grepping GitHub coupling per file: `thread-panel.lua` is 165 lines with 1
coupled line; `layout.lua` is 350 lines with zero. The minimum viable port (thread-panel
show/hide/create, `get_alternative_win`, layout validate and recover, the `octo_diff_props` idiom,
the autocmd) is roughly 300 lines with 5 to 10 shallow GitHub assumptions.

Do not port `writers.lua` (3500+ lines; `write_thread_snippet` alone is roughly 200 lines of
virtual-text diff painting keyed on a GitHub-shaped `diffHunk` string), `octo-buffer.lua` (1197
lines of save and mutation engine we would own in Ruby anyway), or the position-mapping code (it
solves GitHub REST `position` integers, which we do not have). Dropping octo's PR-versus-COMMIT
review-level branching removes roughly 80 lines of conditionals.

Three defects to fix while porting:

1. The show path has no idempotency guard. The hide path checks `if current_alt_bufnr ~= alt_buf`;
   the show path does not. Every `CursorMoved` while sitting on a commented line re-runs
   `nvim_win_set_buf`, `configure()`, the keymap registration, `diffoff!` and `normal ]c`.
2. `associated_bufs` and the global `octo_buffers` registry are append-only, never cleaned on
   `BufWipeout`.
3. Sign-name state is built by string concatenation inside the per-comment loop, so a thread with
   3 pending comments builds `octo_thread_pending_pending_pending`, an undefined sign whose
   placement failure is swallowed by `pcall`.

### 4.6 Posting comments back to GitHub

Read of both submit paths, because §5.6 puts standalone PR review first and nothing here had
touched the write side.

**The `(path, side, line)` anchor is exactly GitHub's modern model.** Both projects converged on
it. tuicr's payload (`src/forge/github/submit.rs:17-52`) is `path`, `line`, `side`, `body`, plus
optional `start_line` and `start_side`, with one top-level `commit_id` for the whole review. octo's
GraphQL input (`lua/octo/model/octo-buffer.lua:597-610`) is the same fields. Neither uses
`position` for PR-level comments.

**Do not model `position`.** octo's commit-level path still uses the legacy API and hand-computes
the hunk offset (`octo-buffer.lua:705-729`), ending in a `position = position + offset - 1` fudge.
That arithmetic has zero test coverage: nothing under `lua/tests/` touches `process_patch` or
`generate_line2position_map`. `position` is an offset into the diff as served, so it breaks when
the diff is paginated or re-hunked. Not modelling it also removes octo's hard refusal, "Can't
create a multiline comment at the commit level" (`octo-buffer.lua:663-666`), which exists only
because the legacy API has no range concept.

**The failure modes are about anchor validity against the diff GitHub thinks it is serving.** Three
checks have to happen before submit, and tuicr skips two of them:

| check | GitHub requires | tuicr | octo |
|---|---|---|---|
| `start_line <= line` | yes | normalized in `LineRange::new` | not enforced |
| same side for both ends | yes | forced | forced |
| **same hunk for a range** | **yes** | **not checked, so a 422** | checked (`reviews/init.lua:440-449`) |
| **path is in the diff** | **yes** | **not checked** | implicit |

tuicr's own per-commit mode injects a synthetic file named `Commit Message (abc1234)`
(`src/app/diff_load.rs:82-95`) with no guard in the mapper, so a comment on a commit message maps
to that path and GitHub rejects it.

**One thing to take wholesale: the `## Unplaced comments` fallback.** When tuicr cannot map a
comment it does not drop it. A resolver modal offers "Move to summary" or "Omit", defaulting to the
former, and the comment renders as a bullet under a heading in the review body:
`- [ISSUE] src/lib.rs: kaboom`. Nothing is lost silently, and the degraded form is still actionable.

**Use the real file-level comment API.** GitHub has `subject_type: "file"` (REST) and
`subjectType: FILE` (GraphQL). Neither project uses it; both fake a file-level comment by anchoring
to the first valid line. That creates a whole failure class: for a file deleted in the PR there are
no new-side lines, so tuicr's `FileLevelNoAnchor` fires even though a LEFT-side anchor exists and
GitHub would accept it (`src/forge/submit.rs:216, 234-238`, test at `:834-846`).

**Do not copy tuicr's `UnmappableReason` shape**, even though the idea is right.
`MixedSideRange` fires from 3 structurally different causes and shows the same string for all of
them, one of which is an internal inconsistency reported to the user as "range spans both diff
sides". Worse, its single-line and range paths disagree about what a valid old-side line is: the
range check accepts only Deletion lines (`submit.rs:376-404`) while the single-line check has no
origin filter at all (`:289-310`), so a LEFT-side range touching a context line is rejected even
though GitHub accepts it. One unambiguous reason per rejection.

**Sequencing worth copying.** tuicr saves the session to disk before the network call
(`src/app/submit.rs:320-322`) and leaves comments at `local_draft` on failure, so a lost round trip
costs nothing. It also snapshots repo, PR and head SHA and discards the result if the user reloaded
mid-submit. Neither project retries, which is defensible because a batched review POST is not
idempotent.

**Two drafting models, and the batch one fits us.** tuicr drafts entirely locally and sends one
atomic POST, with draft mode expressed by omitting `event`. octo creates a server-side pending
review up front and posts each comment as its own call, so it gets per-comment errors immediately
and cannot draft offline. For an agent authoring comments programmatically, batch and atomic is the
better fit, but only with the validation tuicr skips moved to the front.

**The warning that applies directly to §5.4.** tuicr's follow-up fixes after the feature landed
were #332, #334, #442, #462 and #464, and 3 of those 5 are about the commit-range and commit-id
axis rather than the anchor triple. There is a live instance in the code: `src/app/submit.rs:56-62`
validates comments against `range_diff_files`, whose own declaration
(`src/app/mod.rs:1287-1288`) says it holds the full-range diff, while `commit_id` is narrowed to
the subset head. So in a narrowed multi-commit review the anchors are checked against one diff and
submitted against another. Our dual-scope design (§5.4) has exactly this hazard, and "which diff
did the human actually annotate" has to be a first-class part of the anchor rather than implied by
the current view.

### 4.7 What none of them solve

All 3 comparable projects punt on anchor drift, by 3 routes. octo outsources it to GitHub's
server-side line recomputation. tuicr defines it away with HEAD-pinned session identity, after
trying and reverting the alternative. codediff has no comment model.

Every one of those punts works because the review is short-lived relative to the code: a human
reviews a PR that is not moving, or starts over when it moves. In an agent loop the code changes
because of the review, in rounds, which is [tuicr#228]'s complaint.

An earlier draft of this document concluded that lain therefore has to solve cross-round
re-anchoring. **That conclusion was wrong**, and §5.3 records what replaced it: with round-scoped
annotations and a range-diff delta view, lain never re-anchors across rounds either. The
difference from the other 3 is that the human is shown exactly what moved instead of being asked
to start over.

The 2 ideas that do transfer are about state, not anchoring: tuicr's content-addressed hunk keys
and its three-way merge.

---

## 5. Where the thinking currently sits

Nothing here is built. This is the shape the conversation converged on.

### 5.1 Three surfaces

**Sidebar (`lain://review`).** The navigator, and where the scope switch lives: toggle between a
commit walk (message, files touched, stats per commit) and a flat cumulative file list. Carries
review progress marks, finding counts, and blast-radius numbers per file. `<CR>` opens a file.

**Native vim diff mode on the real file pair.** Where reading and annotating happen. Folded to the
changes, `zo` to expand context in place, `]c` and `[c` between hunks, and real buffers so the
language server and treesitter attach (§3.4).

**Thread pane.** Persistent, buffer swapped on cursor movement, octo's technique from §4.5 with
the idempotency guard added on both paths.

`gf` from a unified-diff buffer was considered and is not needed, because in diff mode you are
already in the real file. If a continuous-scroll stream is wanted later, §3.1's map gives the
exact `(path, side, line)` to make `gf` land correctly.

### 5.2 The anchor

Annotations anchor to `(path, side, line)` in the real file, with `anchor_text` for drift, which
is what `Annotations` already does. Extmarks own position; diagnostics mirror them for signs,
virtual text, `]d` navigation and quickfix (§3.2).

Every annotation gets a UUID at creation. Cheap now, expensive to retrofit, and it is the
precondition for tuicr's merge if we ever need it (§6.8).

Old-side annotations need thought: the old side is a buffer materialized from
`git show <base>:<path>`, so it is not a file on disk. `(path, side: old, line)` is still
recordable, and the storage path should not assume both sides are real files.

### 5.3 Review state across rounds

Annotations are round-scoped. They are produced, consumed by the agent, and become historical.
Nothing re-anchors them onto the next round's code.

The delta between rounds is shown with `git range-diff`, not `git diff` (§3.3). The reviewed head
is pinned under `refs/lain/reviewed/<generation>` so the baseline stays reachable after a rewrite.

Reviewed marks use content-addressed hunk keys, tuicr's scheme (§4.4). The reason changed during
the conversation: range-diff removed the drift-survival argument, and dual-scope review (§5.4)
brought the same mechanism back for scope derivation instead.

Joel's framing, which is what makes this work: what the human sees and what we journal do not have
to match, as long as behavior is not surprising. The human can comment on a line of a commit while
we store something else entirely. The one constraint worth holding is that an annotation must
never vanish silently or reappear on a line the human did not choose, which is the failure both
octo and tuicr have.

Fixups collapse only after approval, so for the whole life of a review the history is append-only
and review state is monotonic. The squash trap does not fire, because by the time a squash
happens the ledger has already done its job.

### 5.4 Scope

Cumulative and per-commit are both needed, and the sidebar switches between them.

Per-commit is not only narrower. §2.2 of epic-orchestration orders commits pedagogically rather
than chronologically (preparation, then behavior change, then wiring), so walking commits replays
the authored teaching order. Cumulative catches what per-commit cannot: commit C adds a call,
commit D removes the callee, each clean alone.

Supporting both makes the tri-state indicator required rather than optional, which is [tuicr#247]
exactly. Record marks at hunk granularity and derive every coarser indicator: a file is green at
full scope only when all its hunks across all commits are marked, and yellow when some are.

§3.7 raises the commit walk from a convenience to a requirement. At Joel's real work size, the
cumulative view is 81,810 rendered lines and a single commit is 2,727. The decomposition is the
only thing that makes a changeset that size readable at all, and it is also what makes re-review
cheap: after a rebase changed all 30 SHAs, range-diff still identified 29 commits as unchanged.

### 5.5 Impacted code

Because the reading surface is real files with a language server attached, `gr`, `gi` and incoming
call hierarchy already work at no cost to us. A synthetic diff buffer would give up all of it,
which is the strongest argument for §5.1's choice.

Three things worth adding on top:

**The omission set.** Take the symbols the changeset changes, resolve their references, subtract
the files in the diff. What remains is code that references changed symbols and was not touched.
`spike/scip-probe` already builds both halves (`def_sites` and `refs`) in one pass over a SCIP
index. It renders as a HINT diagnostic on the changed symbol with the untouched sites in the
quickfix list.

**Blast radius per file**, as a column in the sidebar: N references across M files, K touched.

**Which tests exercise the change.** The design plan already calls coverage "a review lens, never
a gate", and this is that lens pointed at a specific changeset.

Mechanism, revised after §3.6 measured it: LSP for interactive lookups, SCIP for the precomputed
omission set. The ast-grep and treesitter probes in `spike/` are for structural pattern search and
do not apply here.

That split holds for Rust today and does not yet hold for Ruby. `rust-analyzer scip` gives a usable
index in 6.7s with 97% of project references resolving, and its hot-symbol ranking is the
blast-radius column already computed. Ruby has no SCIP indexer we will use, because `scip-ruby` is
a Sorbet fork and this project abstains from Sorbet. The Ruby path is therefore LSP-only, which
makes the omission set N `findReferences` round trips rather than one index query. Whether that is
fast enough across 800 files is unmeasured.

Three costs. SCIP needs an indexer run per language and goes stale, so index once when the review
opens against the reviewed state. The index has holes (3% here), so the omission set cannot be
presented as complete. And it will have false positives, because plenty of callers legitimately
need no change, so it ships as a lens rather than a gate.

### 5.6 Two modes

**Epic-gated.** Lain's agent wrote the code, a fiber is parked on the promise, and the human's
verdict resolves it and feeds the implementation-stage `Approval::Gate`.

**Standalone PR review.** Point lain at a branch or PR link, review it locally, optionally run
`/critique` to prefill suggestions, and post accepted comments back to GitHub. A third party wrote
the code, and nothing inside lain is gated on the outcome, so the promise, the handoff and the
gate are all unnecessary in this mode.

The second mode is useful architecturally, because it forces the review surface to work with no
epic, no parked fiber and no verdict consumer. The epic path then becomes one caller rather than
the owner. That is a better answer to "how do non-epic sessions get this" than widening the
`(epic_slug, generation)` key.

Standalone mode needs 3 things that epic mode does not: a submit path (`Forge::Gh` reads today and
does not post), both sides of a PR materialized (`git fetch origin pull/N/head` plus `git show`),
and a machine-readable sidecar from `/critique` beside its prose. Per [tuicr#475], GitHub stops
serving a combined diff past 300 changed files, and tuicr's fallback is the local object database
when the checkout matches, else a blobless bare clone. At the size §3.7 measures, 810 files, that
fallback is the normal path rather than an edge case.

§4.6 read both submit implementations and the anchor survives: `(path, side, line)` is GitHub's
current REST and GraphQL model verbatim, so no re-mapping layer is needed. What it added is a list
of validations to run before submitting (same hunk for a range, path present in the diff, one
unambiguous reason per rejection), the `## Unplaced comments` degradation so nothing is dropped
silently, `subject_type: "file"` for real file-level comments, and the ordering rule that local
state is saved before the network call.

On prefilled comments, Joel's ruling:

> I am fine with a code review comment on another PR being under my responsibility if I have
> chosen to post it. It is my obligation to review and edit that proposed comment proactively as
> a first line of triage and not putting that burden on the initial author of the PR.

So the mechanism is per-comment promotion (suggestions render in their own namespace, editing one
promotes it, ignoring drops it, no bulk accept), justified by triage obligation rather than by
caution.

One thing to decide deliberately: reviewing work code sends an employer's source to an API. The
critique step should be model-agnostic from the start so it can run against a local model through
the existing ollama path when the code cannot leave.

### 5.7 The bench arm

Standalone mode produces data as a side effect of being used. Does a prefilled review make a human
reviewer faster or better? The promote-or-ignore decision on each suggestion is labeled
supervision on critique quality, accumulated by doing the work: which personas get promoted,
whether BLOCKERs promote more than NITs, whether more context changes the accept rate.

That is an argument for building standalone mode first. It has fewer dependencies, it produces
measurements, and it gets used daily.

### 5.8 Scope of a first slice

Sidebar, native diff mode, `(path, side, line)` anchors, diagnostics projection, content-addressed
hunk marks with the tri-state, and a size guard that fails loudly. The size guard belongs in the
first slice on the §4.2 evidence rather than deferred.

The docent conversation comes second. It depends on the anchor model the first slice fixes, and
building it first means building it twice.

---

## 6. Decision log

Ranked options with the losers kept. Superseded entries record what replaced them and why, so a
future reader can reopen them.

### 6.1 Protocol version: keep the counter, bump to 9

Joel asked whether to reset to 1 or 0.9 since nothing is in production.

- **Bump to 9.** One line plus a history entry. `runtime.lua:16` does `protocol ~= RUNTIME_PROTOCOL`,
  an equality test, so a monotonic counter is already the right shape.
- **Reset to 1.** Buys nothing, because there is no external consumer to spare. Destroys the
  8-entry history at `frontend/neovim.rb:29-62`, which exists "to tell whether a running runtime
  has some feature." Version 5's entry is itself a backfill repairing a skipped bump. Churns
  `neovim.rb:63`, `runtime.lua:15`, 4 headings in `plugin/nvim/doc/lain.txt`, and 2 specs.
- **Semver, 0.9.** Rejected: implies ordering and range compatibility the equality test does not
  implement. `Lain::Core::Client::PROTOCOL_VERSION = "0.1.0"` is semver because that daemon
  protocol negotiates, and 2 shapes for 2 different things is correct.

### 6.2 Layout: native diff mode on real files

- **Native diff mode, per file, with a sidebar navigator.** Chosen. §3.4 measured what it gives:
  real buffers for LSP, folding, `]c`, `inline:char`, and nvim owning filler and scroll sync. Also
  inherently lazy, since 2 buffers are open regardless of changeset size, which answers the
  large-diff theme.
- **Single-stream unified diff buffer.** *Superseded 2026-08-04.* Recommended earlier in this
  conversation to avoid codediff's 535 lines of alignment and scrollsync. Native diff mode makes
  those lines unnecessary, and a synthetic buffer gives up LSP, which §5.5 needs. The cost of
  giving it up is cross-file continuous scroll, mitigated by rebinding `]c` at a file's last hunk
  to advance to the next file.
- **Custom side-by-side rendering.** Rejected. Costs the alignment math plus 415 lines of
  scrollsync, forces `nowrap`, and leaves folds unsolved even in codediff's own implementation.

### 6.3 Annotation substrate: extmarks anchor, diagnostics display

- **Both, layered.** Chosen, on the §3.2 measurement.
- **Extmarks only.** What exists today. Means hand-rolling navigation, gutter signs and a finding
  list that nvim gives away.
- **Diagnostics only.** Rejected on measurement: annotations would not survive an edit, which
  breaks the drift detection `Annotations` exists to compute.

### 6.4 Reviewed marks: content-addressed hunk keys

- **Hunk-content keys, tuicr's scheme.** Chosen. Position-independent, `-v1:` prefix, span-qualified
  fallback for duplicate hunks, pruned against the current diff with a preserve flag for filtered
  views. Roughly 40 lines. Justified now by scope derivation (§5.4) rather than drift survival.
- **File-level content digest.** *Superseded.* Fixes [tuicr#228] but clears a whole file's mark on
  any change anywhere in it, which is the carry-forward behavior tuicr ships and which drops state
  too eagerly on a large file.
- **Boolean per path.** Rejected. What everyone builds first, and what both tuicr issues complain
  about.

### 6.5 Re-review delta: range-diff

- **`git range-diff` between the pinned reviewed range and the current range.** Chosen, and it
  supplies stable commit identity for free (§3.3).
- **`git diff` between the two heads.** Rejected on measurement: it reports base movement the human
  never reviewed. This was Joel's original phrasing of the idea, and the idea is right with the
  primitive corrected.
- **Change-ID trailers (spr and jujutsu style).** *Superseded.* Proposed earlier in this
  conversation to survive the SHA churn that epic-orchestration §2.2 documents as unconditional.
  Range-diff gives the same identity property by patch content, with no discipline required of the
  agent, so the trailer machinery comes out.

### 6.6 Commit structure: logical commits, fixups deferred until approval

Joel's proposal, and it holds. During a review the history is append-only, so review state is
monotonic and invalidation moves from every round to every landing.

Edge cases raised against it, and where each landed:

- *SHA is the wrong key.* Real. epic-orchestration §2.2, corrected 2026-07-30, says the cascade is
  unconditional: GitHub's rebase-and-merge always writes new SHAs. Resolved by range-diff (§6.5).
- *Resolution is non-local.* A comment on commit C fixed by fixup F leaves C carrying an open
  finding forever. Resolved by round-scoped annotations (§5.3): the annotation is consumed by the
  agent and does not persist onto the next round.
- *Per-commit approval is not approval of the result.* Real and unresolved by commit structure.
  Handled by keeping the cumulative view (§5.4).
- *Autosquash collapses the ledger.* Resolved by deferring the squash until after approval.
- *Agents amend by default.* Handled structurally: the orchestrator owns commits, which
  `/execute-plan` already does.
- *One card is not one reviewable idea.* Unresolved. Logical commits bound the number of review
  units, not their size.

### 6.7 Thread window: persistent pane, buffer swapped

- **Swap the buffer of an existing pane.** Chosen, octo's technique, with the missing idempotency
  guard added on the show path.
- **Open a split on demand.** *Superseded.* Proposed earlier. Window creation on cursor movement is
  where the flicker and layout churn come from.
- **Floating window.** Rejected. Lain has never called `nvim_open_win` with `relative=`, and a
  float suits a conversation that needs scrollback poorly.

### 6.8 Concurrent writers: the journal is the only writer

- **Editor sends gestures, Ruby journals.** Chosen, and it is what lain already does. No merge is
  needed because there is one writer.
- **Shared-file three-way merge, tuicr's design.** Held in reserve. Roughly 60 lines and proven,
  and worth adopting only if the editor ever writes review state directly. The UUID precondition
  is adopted now regardless (§5.2).

### 6.9 Who answers an inline question: a role, defaulting to a fresh docent

- **Fresh `role/diff-docent` per thread.** Chosen. Gets the hunk, both revisions of the enclosing
  function, the task card and its ACs, `.handback-T<id>.md`, and the panel's findings. Unbiased by
  authorship, and it makes the handback earn its keep: if the docent cannot answer "why this way"
  from it, that is a finding about the handback. In standalone mode the handback does not exist,
  and the context becomes the PR description, commits and linked issue, which is thinner.
- **The parked implementer.** Knows why directly, and is the author being asked to judge itself.
  Its context is full of implementation detail.
- **`SendMessage` to the live implementer.** Works in `/execute-plan`, which already does this for
  mechanical fixes, and does not exist in the `Epic::Review` path. Rejected as the default because
  the design should not depend on which orchestrator is driving.
- **The chat pane.** The escape hatch, free, already there. Gives up cursor anchoring.

### 6.10 Vendoring: none initially

- **Design reference only.** Chosen for all 6 projects. Port octo's thread-window technique with an
  attributing comment even though MIT permits omitting one, because attribution costs a line and
  keeps provenance auditable.
- **Vendor `scrollsync.lua`.** Moot under §6.2, since native diff mode makes it unnecessary. It
  would have been the right call under custom side-by-side: standalone, MIT, and it encodes a
  Neovim bug we would otherwise rediscover.
- **Vendor from review.nvim.** Rejected. Apache-2.0 bookkeeping exceeds the value of a comment-type
  taxonomy.

If anything is ever vendored: `runtime.lua` is injected as a single file read and `exec_lua`'d, and
it is already 1359 lines. Third-party lua must not go into that string, because it would mix
licenses inside one injected blob. Vendored code goes under `plugin/nvim/lua/lain/vendor/<project>/`
with original headers intact, plus a `THIRD_PARTY.md`, excluded from the repo's doc linting.

### 6.11 Build order: standalone PR review first

- **Standalone first.** Chosen on §5.7's reasoning: fewer dependencies, produces measurements, gets
  daily use.
- **Epic-gated first.** The original framing of the request. Still the eventual target, and it
  needs the gate, promise and verdict plumbing that standalone does not.

---

## 7. Open questions

1. **Anchor drift within a round** still needs its own spike before the first slice fixes a shape.
   Specifically whether `anchor_text` alone is enough, or whether before and after context lines
   are wanted, which is what tuicr's dead `LineContext` was reaching for.
2. **The size guard's failure mode.** octo's fix for #302 turned a crash into a quietly truncated
   file list. Whatever bound we set has to fail loudly. §3.7 narrows where the bound belongs: our
   parse layer handles 80,800 lines in 0.26s, so the guard is not about diff size. It is about
   `/critique` context limits, SCIP index time, and GitHub's 300-file API ceiling.
2b. **Chunking `/critique` at work scale.** 74k changed lines exceeds any context window. The
   commit is the natural chunk (2,727 lines each per §3.7), which also gives per-commit findings
   that the sidebar can attribute. Unspecified.
2c. **Collapsing generated and vendored files.** At 810 files a large share is lockfiles, generated
   code and vendored trees. `.gitattributes` `linguist-generated` is the standard marker and is
   what GitHub collapses on. Probably the highest-value filter at this size, and unexplored.
2d. **Ruby code intelligence is not installed** under the toolchain CLAUDE.md prescribes (§3.6).
   Setup task, not a design question, but §5.5 stays unverified for Ruby until it is done.
3. **Verdict vocabulary.** Reuse the panel's APPROVE, APPROVE-WITH-FIXES, REQUEST-CHANGES and feed
   it to the implementation-stage gate?
4. **Structured `/critique` output.** Required for standalone mode, optional for epic mode. One
   sidecar format for both?
4b. **Which diff an anchor was authored against** has to be part of the anchor, not implied by the
   current view. §4.6 found a live instance of getting this wrong in tuicr: comments validated
   against the full-range diff, submitted against a narrowed head SHA. Our dual-scope design
   (§5.4) has the same hazard, and 3 of tuicr's 5 follow-up fixes were on this axis.
5. **Worktree retention under `deferred`.** A morning queue only works if the changeset is still
   reviewable. Record base and head refs, and do not retire the worktree until the gate drains.
6. ~~**Old-side annotation storage** (§5.2).~~ **Closed by §3.5**: an extmark in a `nofile` buffer
   slides on edit exactly as it does in a real file, so drift detection works on both sides. The
   residual costs are that filetype must be set by hand and no LSP client attaches, making
   go-to-definition new-side only.
7. **Partial approval.** Mechanical fixes merge without re-review under current `/execute-plan`
   routing, so they could squash immediately while substantive ones wait. Worth stating rather than
   discovering.
8. **Approval granularity under stacking.** Deferred squash collides with §2.2's "land the bottom
   aggressively" unless approval is scoped per stack layer.

---

## 8. References

Repos surveyed, with license as of 2026-08-04:

- [tuicr](https://github.com/agavra/tuicr), MIT. Rust review TUI: continuous diff, comments at
  line, range, file and review level, per-hunk progress.
- [octo.nvim](https://github.com/pwntester/octo.nvim), MIT. GitHub PR review in nvim; the mature
  threaded-comment model.
- [codediff.nvim](https://github.com/esmuellert/codediff.nvim), MIT. Side-by-side and inline diff
  rendering.
- [review.nvim](https://github.com/georgeguimaraes/review.nvim), Apache-2.0. Diff annotations
  exported as markdown for an LLM.
- [diff-review](https://github.com/colonyops/diff-review), no license. Read-only for us.
- [diffview.nvim](https://github.com/sindrets/diffview.nvim), GPL-3.0-or-later. Do not read for
  implementation.

Issues cited:

- [tuicr#228] reviewed-mark invalidation after an agent rewrite. The most useful single issue found.
- [tuicr#247] partially-reviewed files; per-commit review state.
- [tuicr#229] in-repo review storage as future agent context.
- [tuicr#475] 300-file ceiling and slow navigation.
- [tuicr#288] streaming highlight and perceived latency.
- [octo#98] review PRs at commit level (45 comments, their most-discussed).
- [octo#302] review start fails on large PRs.
- [octo#877] outdated comments hidden in review mode.
- [octo#118] persist review comments outside editor state.
- [octo#854] keymaps lost on tab switch.

Upstream source locations cited:

- tuicr: `src/slug.rs:17-22`, `src/model/diff_types.rs:78-121`, `src/app/session.rs:214-278`,
  `:610-654`, `src/forge/submit.rs:105-138`, `docs/REVIEW_CLI.md`. Commits `fbc3990`, `01b0eeb`,
  `2c9ab88`.
- octo.nvim: `lua/octo/reviews/thread-panel.lua:62-88`, `lua/octo/autocmds.lua:66-74`,
  `lua/octo/reviews/file-entry.lua:479-491`, `:554-557`, `lua/octo/reviews/layout.lua:246-295`,
  `lua/octo/gh/init.lua:170-182`.
- codediff.nvim: `lua/codediff/scrollsync.lua:1-24`, `lua/codediff/ui/filler.lua:45-68`,
  `lua/codediff/ui/core.lua:168-190`.

In-repo:

- `lib/lain/epic/review.rb`, `lib/lain/epic/review/annotations.rb`, `lib/lain/tools/request_review.rb`
- `lib/lain/frontend/neovim.rb` (the PROTOCOL history), `lib/lain/frontend/neovim/runtime.lua`
- `lib/lain/approval/` (`queue.rb`, `signoff_queue.rb`, `gate/policy.rb`), `lib/lain/cli/epic_queue.rb`
- `lib/lain/forge/gh.rb`, `lib/lain/forge/reconcile/world.rb`
- `planning/epic-orchestration.md` §2.2, §3.2, §3.3, §3.8, §3.11
- `~/.claude/plans/jiggly-greeting-avalanche.md`, "Interface" and "Review before merge"
- `spike/scip-probe`, `spike/astgrep-probe`, `spike/ts_query.lua`
- Spike branch `spike/review-ui`: `eebb24d`, `36fdc99`, `55677b0`
- `references/oss-inspiration.md`, the "Code-review UIs" section

<!-- link reference definitions for the bare [tuicr#N] / [octo#N] citations above -->
[tuicr#228]: https://github.com/agavra/tuicr/issues/228
[tuicr#229]: https://github.com/agavra/tuicr/issues/229
[tuicr#247]: https://github.com/agavra/tuicr/issues/247
[tuicr#288]: https://github.com/agavra/tuicr/issues/288
[tuicr#394]: https://github.com/agavra/tuicr/issues/394
[tuicr#475]: https://github.com/agavra/tuicr/issues/475
[octo#98]: https://github.com/pwntester/octo.nvim/issues/98
[octo#118]: https://github.com/pwntester/octo.nvim/issues/118
[octo#302]: https://github.com/pwntester/octo.nvim/issues/302
[octo#854]: https://github.com/pwntester/octo.nvim/issues/854
[octo#877]: https://github.com/pwntester/octo.nvim/issues/877
[diffview#457]: https://github.com/sindrets/diffview.nvim/issues/457
[diffview#466]: https://github.com/sindrets/diffview.nvim/issues/466
[diffview#509]: https://github.com/sindrets/diffview.nvim/issues/509
