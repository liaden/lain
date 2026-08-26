# Review

Longer arguments behind `lib/lain/review/**`, moved out of the source headers so a
file's own doc can stay at the density `CLAUDE.md` sets. Each source file that gave
something up here keeps a one-line pointer at the spot it left.

## The surface port

`Lain::Review::Surface` is the seam between the review model and whatever renders a
changeset for a human. Its eight messages, and the duck probe that checks them, are
documented at `lib/lain/review/surface.rb`.

### Why `focus` is not part of `present`

They differ in how often they are allowed to happen, which is the whole of it.
`present` runs on EVERY redraw -- a mark redraws a row, a scope toggle redraws the
sidebar, `Handover::Redraw` calls it after a gesture -- and a redraw that moved the
human would yank them out of the chat pane mid-sentence every time they marked a
hunk. `focus` happens ONCE, when a round is opened, because that is the moment lain
handed them something and asked them to work on it.

The editor half already draws exactly this line and names it in those terms:
`41_layout.lua` has `review_place` ("MOVES NOBODY, ever") and `review_layout` ("The
ONLY entry point that takes focus"), with the second one reachable from Lua and
called by nothing in Ruby -- so a `/survey` built the review tabpage, drew into it,
and left the human in the session tab to go and find it. The port was where the
distinction had nowhere to live.

### Why `verdict` and `settle` are two messages and not one

They travel in opposite directions and neither can be inferred from the other.
`verdict` ASKS -- it goes out when there is no judgement yet, and it is a QUERY,
which is the whole reason the port has nowhere to put its refusal. `settle` SAYS ONE
LANDED -- it goes out after `Session#submit` has journaled a judgement the policy
admitted, and it carries the word inward, so a String coming back is unambiguously a
refusal and it joins the command law rather than `verdict`'s exemption
(`spec/support/shared_examples/review_surface.rb`, law #5).

It exists because the review's ONE TERMINAL gesture was the only one that
acknowledged nothing: `:LainReviewVerdict approve` journaled correctly and printed
nowhere, while `mark` and `refuse` both said so in words. A human who makes the
gesture that ends the review and is answered with silence reads it as broken --
which is exactly how the previous, genuinely broken version of that command read.

It is a PUSH and not a return value, and that is forced rather than chosen:
`Review::Handover#wrote_verdict` answers `nil` for "taken", because its return value
is what the editor's `:w` succeeds or fails with. There is no room in that answer for
a sentence, so the sentence has to leave by the surface.

### What `present`'s `changeset` argument answers

`Changeset` and `Marks` had not landed when `Surface::Text` was written, so the duck
`present` actually needs is stated once at the port rather than in each adapter's own
doc -- the drift `MESSAGES` exists to prevent for a message's SHAPE applies just as
much to what one argument of one message means.

- `changeset.files` answers an Enumerable of file entries (`#path`, `#state` -- one
  of `Review::FILE_STATES`) for the FLAT scope, `:cumulative`.
- `changeset.partitions` answers an Enumerable of group entries (`#label`, `#files`
  -- same file-entry shape) for every GROUPED scope, whichever
  `Review::Partition::Strategy` produced them.
- `changeset.sides` answers which of `Review::SIDES` the ROUND presents at all, as a
  subset of that vocabulary in its own order -- both for anything spanning a base
  revision and a head one, the new side alone for a corpus surveyed as it stands. It
  is the round's fact and never a file's: a file with no old path is an addition
  INSIDE a two-sided round, and only a surface that can build panes needs to tell
  those apart before it draws. See `Review::Source` for why the question belongs to
  the source.

A surface that draws more than a path and a glyph needs more than that, and
`Frontend::Neovim::ReviewView` is where the additional members and their reasons are
stated -- including the two a LAZY source makes necessary (`#chunked?` on a file,
`#counted?` on a group), which are how a surface tells "there is nothing here" from
"nobody has looked yet" WITHOUT reading the corpus it is drawing.

It reads `#partitions` and not `#by_commit`, and the rename is the contract rather
than a spelling: grouping-by-commit is one strategy on that axis, so a surface that
named it would be a surface that could only ever render one. A group answers `#label`
-- what heads it -- because a directory has no subject and a commit's sha is not what
a heading shows. `#partitions` takes no argument at the port: whoever built the view
chose the strategy, and a renderer re-partitioning what it was handed could draw rows
the session never marked.

Neither `Changeset` nor `Marks` alone answers this: a changeset is
files/hunks/anchorable lines with no notion of review state, and marks derives that
state from hunks with no notion of files-as-such. The object that answers
`#files`/`#partitions` has to be built by JOINING the two -- the session is the one
place both are held together, so it is the session's job to produce it, not either of
them alone, and not a surface reaching for both on its own.

## Where the review ceilings come from

`Lain::Review::Bounds` refuses a view past a ceiling and never truncates, samples or
elides. The constants are at `lib/lain/review/bounds.rb`; the derivations are here.

### Where the bound is NOT

Not on diff size. Research measured the parser at 80,800 rendered lines in 0.26s and
39MB, so nothing there is defending the parse. The constraints are downstream of it: a
human reading a cumulative view, and a `/critique` prompt against a context window.

### Deciding cheaply, and why nothing in `Bounds` reads a hunk

The file count is the cheapest fact and, at the work scale that motivates this, the one
that fires first -- 800 files against a ceiling of 300. `#check_presentation!` therefore
asks it FIRST, so the DECISION to refuse is reached on a file count alone and never
costs a walk over the thing it is refusing to walk over.

Ordering alone was never the whole of it, and reading it as such is the trap: a
short-circuit fires on the REFUSAL path, so every SUCCESSFUL presentation went on to sum
`file.hunks` over every file it had just agreed to present. Wrapping the argument in a
lambda fixes nothing -- the ordering was already right and the input was wrong. So the
line ceiling asks a FILE what it costs (`Source::ChangedFile#rendered_lines`), and each
file answers from what its own source already knows: a parsed diff from the hunks it
parsed, a corpus from the line counts its identity pass harvested in one streamed read.
Nothing sends `#hunks`, so a file nobody has chunked survives a whole bounded
presentation unchunked.

That covers the MESSAGE as well as the DECISION, which it did not use to: naming a
narrower scope only when that scope actually fits still means measuring the candidate's
groups, but the measurement is the same per-file arithmetic and it still gives up at the
first candidate's first group whose FILE count is over. The promise is nevertheless
stated as being about the DECISION, because that is the one a future strategy cannot
quietly break: composing a sentence is allowed to measure, and a candidate that had to
read content to know whether it fits would be within its rights.

There is a spec on each half, and both drive files that RAISE when their hunks are read
-- the only proof that a message was not sent, since a recording double leaves a green
run resting on the recorder.

### `DEFAULT_MAX_CRITIQUE_LINES = 7_000`

The size a `/critique` chunk is packed to, and the only ceiling set against a context
window rather than a reader.

Set from the WINDOW. A rendered diff line measures **49.6 bytes** here (`git diff
HEAD~8`, 6,849 lines, 339,711 bytes / measured), so ~14 tokens/line at ~3.5 bytes/token
(an ESTIMATE for code, not a measurement); 7,000 lines is then ~99k tokens. That is
**half** of the smallest window a bench arm might run (200K, Haiku 4.5) and ~10% of the
1M default, leaving the prompt, the surrounding code and the reply the other half of the
worst case. The estimate is bounded and the conclusion survives its range: at 3.0
bytes/token 7,000 lines is 58% of a 200K window, at 4.0 it is 43%.

The half is a POLICY -- a judgement about how much of a window the diff should occupy --
while the window and the bytes/line are measured. That distinction is the correction: the
first cut set 4,000 from the measured 2,727 rendered lines per commit, which is the mean
of a SYNTHETIC UNIFORM generator (`bigdiff_stacked` emits 30 identical commits) and
therefore a distribution with no tail. A ceiling at mean + 47% refuses the tail of every
real changeset -- concretely, it refused a 5,001-line single-file commit that is ~71k
tokens, 7% of a 1M window, while the doc justified itself by that same window. The two
could not both be true.

The measured per-commit view now sits at 39% of the ceiling rather than 68% of it. The
same arithmetic is what makes the premise true rather than assumed: 74,400 changed lines
is ~80,800 rendered, ~1.1M tokens, past even a 1M window.

## The changeset-source port

`Lain::Review::Source` is where a reviewable changeset comes from. The seven messages
a source answers, and what is deliberately absent from that list, are at
`lib/lain/review/source.rb`; these are the arguments behind the shape.

### `#sides`, and why the question is the SOURCE's

A corpus has no old side -- not "not this time", but structurally, for every
file it will ever hold, because its base holds nothing. A changeset has two
even when a particular file is an addition. Those are different facts, and
only the first means an editor should not build the window.

Nothing downstream can tell them apart: `Changeset#old_side` answers `[]`
for a file with no old path whichever kind it came from, and an editor has
already built its panes at first paint, before any row is opened. So the
fact belongs to the object that knows it without reading anything, and it
travels on the render that PRECEDES the layout (`Surface::Neovim#present`).

The one downstream reader that needs the walk is `Partition::ByCommit`,
through `Changeset#commits` -- which is why a strategy answers
`#supports?(source)` rather than being assumed to apply: the refusal names
the strategy and what the source lacks, instead of a `NoMethodError` from
inside a grouping.

### The port hands down MODEL VALUES, not bytes

`Changeset` used to hold a source's diff and parse it, which made "a source"
mean "a thing with unified-diff bytes in it" -- so a corpus of files
reviewed as they stand could not exist without synthesizing bytes for the
changeset to take apart again. `Parser`, `ChangedFile` and `Unparseable`
therefore live HERE, with the sources that have bytes to parse, and
`Diffed` is the two lines of shape that turns bytes into the values the
port owes. `Identity` is the same move for the ADDRESS: the object that HAS
the parts supplies them, so there is no type test anywhere above.

### Not every source has two witnesses

The port's laws split in two, and the split is forced. Assertions about
shape, and about a source agreeing with its OWN other answers, hold for
anything. But the reversed-diff and binary-agreement cross-checks hold
`LocalBranch#diff` against `LocalBranch#commits` -- two witnesses -- and a
source with only one cannot satisfy them however correct it is. Those live
in `"a diff-bearing review changeset source"`.

The two messages went with them, and that correction is worth recording: a
law calling `#diff` on a source that has none does not fail as a shape
violation, it raises `NoMethodError` -- so leaving it universal would have
been the port still demanding bytes while its own doc promised otherwise. A
corpus-shaped source was built and failed exactly those two examples.

### `#file_at`, and why a diff is not enough

It is the one message about a single PATH rather than the whole changeset,
and it is here because a unified diff cannot be DRAWN from: an editor
showing the old side beside the new needs the whole old file, and a diff
carries the hunks and three lines around them. Every consumer of that is a
renderer, so the read belongs to the source that already knows where the
bytes live.

### `DiffOrigin`, and why it is on the PORT

It began as `GithubPr`'s alone, and its first consumer therefore asked
`respond_to?(:diff_origin)` -- a type test in duck costume, and the one
place a consumer branched on WHICH source it was handed. The answer is not
a defter conditional: a source that never asks an API still has an answer
to "where did these bytes come from". The conditional is gone, and with it
a live defect -- the guard was tested on one leg only, and an ordinary pull
request rendered a fallback note with an empty reason.

### Refusals here are RAISED, unlike `Forge::Gh`'s

Gh's doctrine is that a refusal is a VALUE, because a landing folds over
answers and journals them. This port is not that: a ref that does not
resolve is the caller naming something that does not exist, which is Gh's
OWN distinction on the other side of the line -- "gh answering no is data,
gh not existing is a broken machine". There is no review to be had and no
fold to carry a not-ok answer, so `UnknownRef` raises.

## The editor's review surface

`Lain::Review::Surface::Neovim` adapts the seven port messages onto the four review
rails `Frontend::Neovim::RenderInlet` owns. It holds no review state; the arguments
behind that shape are here, and the class is at `lib/lain/review/surface/neovim.rb`.

### Which rail each message rides, and why two of them share one

`present` -> `set_review`, through `Frontend::Neovim::ReviewView`, which
is the object that turns a changeset into sidebar rows and holds the
line -> file index a `<CR>` resolves through. The view's `Rendered`
carries the lines AND the stamp they belong to, and both go out
together -- there is no `#generation` reader to read them apart, which
is deliberate on the view's side and is what keeps a gesture from
resolving rendering N's row against rendering N+1's stamp.

`annotate` and `thread` -> `set_thread`, both of them, THROUGH
`Frontend::Neovim::ThreadView`, because the thread pane is keyed by
ANCHOR ID and a note at an anchor is a message in that anchor's
conversation. `thread` sends no message at all (this object keeps no
history to replay -- `Surface::Text#thread` makes the same honest
reading of "open"), so the view renders its own invitation to ask;
`annotate` sends the note as one message. The extmark rail a note would
ALSO ride does not exist yet, so a note is visible in the pane and
nowhere else until it does.

THE VIEW IS THE ONE OWNER OF THAT PAYLOAD, and this object may not
build one itself. It used to: both messages posted `@rpc.set_thread(
anchor.id, lines)` -- a bare String where the editor half refuses
anything but a table `{id, path, side, line}`, because the pane is
cursor-driven and an id names no position. The refusal travelled over a
NOTIFY, so it reached nobody, and `Review::Session#annotate` -- the
whole production route to this rail -- produced no pane at all while
this object answered "it landed". Two owners of one wire shape is what
allowed the two to drift; there is now one, and this object's share is
deciding what ENTRIES a note becomes.

`mark` and `refuse` and `verdict` and `settle` -> `review_refused`, the
review's ONE notice rail (`runtime/65_review.lua` echoes it into the
message area).
`refuse` is what that rail was built for. `mark` is there because
redrawing the sidebar so the file's tri-state marker moves needs the
CHANGESET, which is exactly the state this object must not hold. The
redraw does now happen -- `Review::Handover::Redraw` makes it, from the
gesture rail, which holds both the session and the scope -- so this
notice is no longer the only thing that says a mark landed; it stays
because it is the one that says so in WORDS, at the moment of the
gesture, and it is what a mark reaching this surface from anywhere but
that rail still has. `verdict` posts the ASK, because on an
interactive surface asking a human for a decision is a thing you do
rather than a thing you wait for; `settle` posts the ANSWER to that
ask, and it is here for `mark`'s reason plus one more -- a sidebar row
says what is REVIEWED and nothing in a row can say the round is CLOSED,
so words are the only place that fact fits.

### What a message answers

A refusal SENTENCE when the editor did not take it, and nothing that is
a String when it did -- `RenderInlet`'s own convention, passed straight
up rather than translated, because a detached editor is a fact the
caller has to be able to say out loud and an exception is the one shape
a port whose adapters DECLINE IN WORDS must not use. The four rails
already answer exactly this, so every command below is a tail call.

`#verdict` is the exception and the reason is not tidiness:
`Review::VERDICTS` are Strings, so a refusal returned from the one
message that answers a verdict could not be told apart from a verdict.
It answers `nil`, the same as `Surface::Null#verdict` and
`Surface::Text#verdict`.

A NULL VERDICT VALUE DOES NOT CLOSE THIS, and saying so is the point of
the paragraph -- an earlier draft here pointed at `Verdict::None`
as the fix and a review panel was right that it is not one. A null
verdict says "no verdict"; it still cannot tell the caller that the
HUMAN DECLINED from that the EDITOR WAS DETACHED, which are different
facts with different things to do about them. What closes it is the
object this port does not have: an answer value carrying
verdict-or-refusal, returned by every message. That same object would
make the port's refusal law uniform and delete its `#verdict`
exemption (`spec/support/shared_examples/review_surface.rb`, law #5),
which is the one place the panel found nvim's convention shaping the
port. Left open deliberately rather than closed badly.

`#settle` DOES NOT CLOSE IT EITHER, and the two must not be read as one
gesture. `settle` carries a verdict INWARD, so its answer has no
ambiguity to resolve and it obeys the refusal law like every other
command; `verdict` asks a human OUTWARD and still has nowhere to put a
refusal. Adding the one did not un-exempt the other.

### The gesture leg, and where `drifted:` is measured

`#marked_at` and `#marked` are the way BACK: the editor marked a row,
and the session is what records it. Nothing is recomputed on the way --
`Frontend::Neovim::ReviewView#marks` says which hunks the row named
against the rendering the human is actually looking at, and every key it
answers is forwarded verbatim.

The ANNOTATE write joins the same leg, and `drifted:` is neither this
object's to compute nor the session's. Drift is the anchor text against
the line the number NOW names, and that line lives in the EDITOR
BUFFER -- which is neither the diff the session holds nor anything this
object may hold. So the comparison is made where the buffer is, in the
note rail's lua half at settle time, content against content, and
arrives INBOUND as a field on the `review_annotate` payload. This surface
FORWARDS it, the session receives it, and nobody computes it from state
they do not have. That is also exactly what the extmark contract
requires: a mark inside a rewritten span MOVES rather than
invalidating, so whether it survived can never answer the question and
only content can. The leg itself waits on `ReviewWrite::KEYS`, which
carries neither `drifted` nor the buffer's revision in this tree.

THAT LEG REFUSES UNIFORMLY OR NOT AT ALL, and that is a rule rather
than a description of what it happens to do. Notes arrive ONE AT A
TIME, and the editor forgets the batch only after the last one lands
-- so a `wrote_annotation` that takes note 1 and refuses note 2 leaves
note 1 recorded while the editor still holds every note, and the
human's retry records note 1 a SECOND time. A note-by-note rail is safe
only while no consumer refuses per-note; that is a property of the
CONSUMERS, and this is one of them.

So the refusal is computed from exactly one predicate -- is a session
bound to record against (`Unbound`) -- which cannot vary within a
batch. Everything a note CARRIES is either already judged at the
boundary by `Neovim::ReviewWrite` (shape, every key present, side and
kind closed, path and text non-blank, and `line` against
`Review::Anchor.line!`'s own domain, asked there precisely so nothing
downstream has to say it by raising), or is JOURNALED rather than
refused. `revision` and `drifted` are the second kind, deliberately:
`AnnotationPlaced` carries a revision so that "authored against one
diff, submitted against another" stays DETECTABLE IN THE RECORD, and
refusing it at the wire would defeat that AND make the refusal
per-note. A `validates`-shaped check added here -- one that can pass
one note and fail the next -- reintroduces the duplicate the moment it
exists.

THIS OBJECT CAN NEVER ITSELF BE `@changeset_review`, and that is worth
knowing before somebody tries. `CLI::HumanReplies::Gestures` sends
`mark(line, state, generation:)`, which is exactly `#marked_at`'s shape
under another name -- but the PORT owns `mark` on this object for the
opposite direction (`mark(hunk_key, state)`, model to surface), so the
name is taken and cannot be shared. A separate gesture adapter,
answering `open`/`mark`/`ask` and delegating to this surface and its
view, is what `bind_changeset_review` has to be handed. That is a
wiring card's object, not this one's; the collision is stated here so
it is discovered by reading rather than by a rail that silently does
nothing.

### The one leg this object cannot grow, and why

`Frontend::Neovim::ReviewView`'s `changesets:` collaborator -- what a
`<CR>` on a sidebar row opens -- is NOT this object. Taking a changeset
in `#present` and rendering it immediately is not caching, and nothing
here does otherwise; but `changesets.open(path, line)` is driven by a
gesture arriving ARBITRARILY LATER than the `present` that drew the row,
and it needs that file's old side and both revisions. That is a
changeset held to answer a later message, which is the one state this
class is defined by not keeping.
`Frontend::Neovim::ReviewView::Unwired` keeps the gesture honest until
the object that holds the diff answers it.

## The review handover

`Lain::Review::Handover` is the open changeset review as the rails a human answers
on see it, at `lib/lain/review/handover.rb`. These are the two arguments behind it.

### Two rails, and the difference is what may go wrong on each

`#wrote_annotation` and `#wrote_verdict` are ANSWERED. They run on the RPC
THREAD, inside the human's `:w`, and their return value IS what that write
succeeds or fails with. So neither may park, and neither may RAISE: a raise
reaches `Frontend::Neovim::RpcThread#answer`, which answers the editor and
then re-raises, ending the editor session over one note. That is why the
rescues below are wide (this project's `Lain::Error` taxonomy plus the
`ArgumentError` a record's guard refuses with) rather than a list a new
refusal class one layer down could silently escape.

`#open`, `#mark` and `#ask` are ACKED. They arrive on the command inbox and
are served by `CLI::HumanReplies::Gestures` on the reactor thread, which
asks each answer `#opened?`/`#marked?`/`#asked?` and renders `#report` when
it says no. Nothing here may raise on that rail either -- `Gestures`
rescues only NoMethodError -- so `#mark` folds the session's refusals into
the answer instead of letting them out.

### A gesture that changed a row draws that row again

Both ACKED gestures change what a row SAYS, and the human's NEXT gesture is
resolved against the rendering they are still looking at -- so a gesture
that changed a row and drew nothing left `<CR>` followed by a mark refusing
the very row the `<CR>` had just made markable. `Redraw` closes that, and
it is injected because the SCOPE it needs is the one fact this rail cannot
ask anybody for.

KNOWN LIMITATION, and it is a RACE rather than a hole. The redraw is
posted, not applied: inlet -> wake pipe -> RPC thread -> nvim, measured at
roughly 7-20ms at `Bounds::DEFAULT_MAX_FILES`. A mark carrying the PRE-OPEN
stamp is still refused, with the same
`Frontend::Neovim::ReviewView::UNREAD` sentence, over a file that has
demonstrably been read. Keyboard autorepeat (~30ms) clears the window; a
deliberate two-key roll may not; pressing `x` again always works.

Left OPEN deliberately. Closing it means letting the view answer a gesture
from the live changeset rather than from the rendering it drew, which is
exactly what the stamp bought its way out of -- and it cannot be done half
way, because a held rendering's `Row` carries `read:` frozen at render
time, so the view cannot tell "still unread" from "read since" without
consulting the model. A better sentence for that case would need the same
consultation.

## The corpus source

`Lain::Review::Source::Corpus` reviews a directory of files as they stand -- no
diff, no base, no commit walk. The class is at `lib/lain/review/source/corpus.rb`;
these are the arguments behind its cost model and its naming.

### Opening reads every file ONCE and parses none of them

Priced honestly, because it is the trade the whole arm rests on. The
address is content-addressed, so `#identity` streams every listed file
and hashes it -- O(total bytes), and unavoidable if "re-chunking does not
move the address" and "marks survive across surveys" are both to hold.
What laziness buys is the PARSE tier: chunking is per file, on demand,
through `LazyFile`, so presenting costs O(files ever marked) rather than
O(corpus). Round identity therefore does NOT depend on the chunking
strategy, so improving a chunker later does not open a new round over a
tree nobody touched.

The total is stated rather than left to be inferred: a fully worked
corpus reads each file TWICE -- once for the identity pass, once when it
is finally chunked -- and a third time per `#file_at` an editor asks for.
`Reading#content` is deliberately not memoized: a memo would hold the
whole corpus resident for the life of the session, which is the cost the
accrete model exists to avoid.

The file ceiling is checked in `#initialize`, from the walk alone: an
oversized corpus is refused without reading a byte it would then throw
away, and putting the guard in the constructor is what makes that
structural rather than remembered.

### Every path is named from ONE root, and it is the READER's

A walk names what it found beneath the tree it was pointed at, which is
the only root it has. Everything downstream reads those names somewhere
ELSE: the sidebar row a `<CR>` resolves, the buffer `47_diff.lua` opens
against `getcwd(-1, -1)`, and the path a verdict's refusal sends a human
to. So `/survey ./lib` labelled a row `greeter.rb` and opened an empty
buffer for a file that does not exist, and every object on that path had
a passing spec, because each was tested against a double standing where
the next one's root would have been.

`named_from:` is that reader's root, and it is a CWD rather than a
project root. `Lain::Project` splits the two on purpose -- root is the
authority boundary, cwd is where a relative path RESOLVES -- and a
monorepo chat runs with cwd deep in a subtree while root sits at the
repository top, so naming from the root breaks `/survey .`. nil names
from the surveyed tree itself.

LEXICAL, and never resolved. The prefix is joined the way the EDITOR
joins it: `Dir.pwd` and nvim's `getcwd` are both physical, and a survey
root is `File.expand_path` of what a human typed -- so a symlinked
subdirectory names `lib/x`, the editor opens `<cwd>/lib/x`, and both
follow the same link to the same file. `realpath` here would mint a
prefix that no longer sits under the editor's cwd at all.

It moves the ADDRESS, since `#identity` is composed from the paths: one
tree surveyed from two roots is two corpora, and a mark made under one
does not carry to the other. That is the price, and it is the right way
round -- a name a reader cannot resolve is worse than a mark set that
belongs to the directory it was made in.

### Collaborators are injected, all four

The walk decides which paths enter, the projection which bytes of them
do, `Bounds` how many is too many, and the chunker how a file divides.
None is constructed here. The chunker in particular is not a convenience:
it is the seam a counting chunker rides so that "this survey chunked
nothing" is a measurement through the real stack rather than a flag the
subject sets about itself.
