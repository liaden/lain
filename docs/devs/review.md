# Review

Longer arguments behind `lib/lain/review/**`, moved out of the source headers so a
file's own doc can stay at the density `CLAUDE.md` sets. Each source file that gave
something up here keeps a one-line pointer at the spot it left.

## The surface port

`Lain::Review::Surface` is the seam between the review model and whatever renders a
changeset for a human. Its 8 messages, and the duck probe that checks them, are
documented at `lib/lain/review/surface.rb`.

### Why `focus` is separate from `present`

They differ in how often they are allowed to happen. `present` runs on every redraw: a
mark redraws a row, a scope toggle redraws the sidebar, `Handover::Redraw` calls it
after a gesture. A redraw that moved the human would yank them out of the chat pane
mid-sentence every time they marked a hunk. `focus` happens once, when a round is
opened, because that is the moment lain handed them something and asked them to work on
it.

The editor half already draws this line and names it in those terms. `41_layout.lua`
has `review_place` ("MOVES NOBODY, ever") and `review_layout` ("The ONLY entry point
that takes focus"). The second was reachable from Lua and called by nothing in Ruby, so
a `/survey` built the review tabpage, drew into it, and left the human in the session
tab to go and find it. The port was where the distinction had nowhere to live.

### Why `verdict` and `settle` are 2 messages

They travel in opposite directions and neither can be inferred from the other.

- `verdict` asks. It goes out when there is no judgement yet, and it is a query, which
  is why the port has nowhere to put its refusal.
- `settle` says one landed. It goes out after `Session#submit` has journaled a
  judgement the policy admitted, and it carries the word inward. A String coming back
  is therefore unambiguously a refusal, and `settle` joins the command law while
  `verdict` keeps its exemption (`spec/support/shared_examples/review_surface.rb`,
  law #5).

`settle` exists because the review's one terminal gesture was the only one that
acknowledged nothing: `:LainReviewVerdict approve` journaled correctly and printed
nowhere, while `mark` and `refuse` both said so in words. A human who makes the gesture
that ends the review and is answered with silence reads it as broken, which is how the
previous, genuinely broken version of that command read.

It is a push because the return path is taken. `Review::Handover#wrote_verdict` answers
`nil` for "taken", since its return value is what the editor's `:w` succeeds or fails
with. There is no room in that answer for a sentence, so the sentence has to leave by
the surface.

### What `present`'s `changeset` argument answers

`Changeset` and `Marks` had not landed when `Surface::Text` was written, so the duck
`present` needs is stated once at the port instead of in each adapter's own doc. The
drift `MESSAGES` exists to prevent for a message's shape applies equally to what one
argument of one message means.

- `changeset.files` answers an Enumerable of file entries (`#path`, `#state`, one of
  `Review::FILE_STATES`) for the flat scope, `:cumulative`.
- `changeset.partitions` answers an Enumerable of group entries (`#label`, `#files`,
  the same file-entry shape) for every grouped scope, whichever
  `Review::Partition::Strategy` produced them.
- `changeset.sides` answers which of `Review::SIDES` the round presents at all, as a
  subset of that vocabulary in its own order. Both sides go with anything spanning a
  base revision and a head one; the new side alone goes with a corpus surveyed as it
  stands. It is the round's fact and never a file's: a file with no old path is an
  addition inside a 2-sided round, and only a surface that can build panes needs to
  tell those apart before it draws. See `Review::Source` for why the question belongs
  to the source.

A surface that draws more than a path and a glyph needs more than that.
`Frontend::Neovim::ReviewView` states the additional members and their reasons,
including the 2 a lazy source makes necessary: `#chunked?` on a file and `#counted?`
on a group. They tell a surface "there is nothing here" from "nobody has looked yet"
without reading the corpus it is drawing.

The port reads `#partitions` and not `#by_commit`, and the name is part of the
contract. Grouping by commit is one strategy on that axis, so a surface that named it
could only ever render one. A group answers `#label` (what heads it) because a
directory has no subject and a commit's sha is not what a heading shows.
`#partitions` takes no argument at the port: whoever built the view chose the
strategy, and a renderer re-partitioning what it was handed could draw rows the
session never marked.

Neither `Changeset` nor `Marks` alone answers this. A changeset is files, hunks and
anchorable lines with no notion of review state, and marks derives that state from
hunks with no notion of files as such. The object that answers `#files` and
`#partitions` is built by joining the 2. The session is the one place both are held
together, so producing it is the session's job: neither of them alone, and no surface
reaching for both on its own.

## Where the review ceilings come from

`Lain::Review::Bounds` refuses a view past a ceiling and never truncates, samples or
elides. The constants are at `lib/lain/review/bounds.rb`; the derivations are here.

### Where the bound sits

The bound is not on diff size. Research measured the parser at 80,800 rendered lines in
0.26s and 39MB, so nothing there defends the parse. The constraints are downstream of
it: a human reading a cumulative view, and a `/critique` prompt against a context
window.

### Deciding cheaply, and why nothing in `Bounds` reads a hunk

The file count is the cheapest fact and, at the work scale that motivates this, the one
that fires first: 800 files against a ceiling of 300. `#check_presentation!` therefore
asks it first, so the decision to refuse is reached on a file count alone and never
costs a walk over the thing it is refusing to walk over.

Ordering was not the whole of it. A short-circuit fires on the refusal path, so every
successful presentation went on to sum `file.hunks` over every file it had just agreed
to present. Wrapping the argument in a lambda fixes nothing, because the ordering was
already right and the input was wrong. So the line ceiling asks a file what it costs
(`Source::ChangedFile#rendered_lines`), and each file answers from what its own source
already knows: a parsed diff from the hunks it parsed, a corpus from the line counts
its identity pass harvested in one streamed read. Nothing sends `#hunks`, so a file
nobody has chunked survives a whole bounded presentation unchunked.

That covers the message as well as the decision. Naming a narrower scope only when that
scope fits still means measuring the candidate's groups, but the measurement is the
same per-file arithmetic and it gives up at the first candidate's first group whose
file count is over. The promise is stated as being about the decision, because that is
the one a future strategy cannot quietly break. Composing a sentence is allowed to
measure, and a candidate that had to read content to know whether it fits would be
within its rights.

There is a spec on each half, and both drive files that raise when their hunks are
read. That is the only proof a message was not sent, since a recording double leaves a
green run resting on the recorder.

### `DEFAULT_MAX_CRITIQUE_LINES = 7_000`

The size a `/critique` chunk is packed to, and the only ceiling set against a context
window and not a reader.

It is set from the window. A rendered diff line measures **49.6 bytes** here (`git diff
HEAD~8`, 6,849 lines, 339,711 bytes, measured), so about 14 tokens per line at about
3.5 bytes per token (an estimate for code, not a measurement). At that rate 7,000 lines is
about 99k tokens. That is half of the smallest window a bench arm might run (200K,
Haiku 4.5) and about 10% of the 1M default, leaving the prompt, the surrounding code and
the reply the other half of the worst case. The estimate is bounded and the conclusion
survives its range: at 3.0 bytes per token 7,000 lines is 58% of a 200K window, at 4.0
it is 43%.

The half is a policy, a judgement about how much of a window the diff should occupy.
The window and the bytes per line are measured. The first cut set 4,000 from the
measured 2,727 rendered lines per commit, which is the mean of a synthetic uniform
generator (`bigdiff_stacked` emits 30 identical commits) and therefore a distribution
with no tail. A ceiling at mean + 47% refuses the tail of every real changeset. It
refused a 5,001-line single-file commit that is about 71k tokens, 7% of a 1M window,
while the doc justified itself by that same window. The 2 could not both be true.

The measured per-commit view now sits at 39% of the ceiling instead of 68%. The same
arithmetic makes the premise true: 74,400 changed lines is about 80,800 rendered, about
1.1M tokens, past even a 1M window.

## The changeset-source port

`Lain::Review::Source` is where a reviewable changeset comes from. The 7 messages a
source answers, and what is deliberately absent from that list, are at
`lib/lain/review/source.rb`, beside `#line_at`, which every source also answers and the
shared group does not yet hold. These are the arguments behind the shape.

### `#sides`, and why the question is the source's

A corpus has no old side. That holds structurally for every file it will ever hold,
because its base holds nothing. A changeset has 2 even when a particular file is an
addition. Those are different facts, and only the first means an editor should not
build the window.

Nothing downstream can tell them apart. `Changeset#old_side` answers `[]` for a file
with no old path whichever kind it came from, and an editor has already built its panes
at first paint, before any row is opened. So the fact belongs to the object that knows
it without reading anything, and it travels on the render that precedes the layout
(`Surface::Neovim#present`).

The one downstream reader that needs the walk is `Partition::ByCommit`, through
`Changeset#commits`. That is why a strategy answers `#supports?(source)` and is not
assumed to apply: the refusal names the strategy and what the source lacks, instead of
a `NoMethodError` from inside a grouping.

### The port hands down model values, not bytes

`Changeset` used to hold a source's diff and parse it, which made "a source" mean "a
thing with unified-diff bytes in it". A corpus of files reviewed as they stand could
not exist without synthesizing bytes for the changeset to take apart again. `Parser`,
`ChangedFile` and `Unparseable` therefore live here, with the sources that have bytes
to parse, and `Diffed` is the 2 lines of shape that turns bytes into the values the
port owes. `Identity` is the same move for the address: the object that has the parts
supplies them, so there is no type test anywhere above.

### Not every source has 2 witnesses

The port's laws split in 2. Assertions about shape, and about a source agreeing with
its own other answers, hold for anything. The reversed-diff and binary-agreement
cross-checks hold `LocalBranch#diff` against `LocalBranch#commits`, which are 2
witnesses, and a source with only one cannot satisfy them however correct it is. Those
live in `"a diff-bearing review changeset source"`.

The 2 messages went with them. A law calling `#diff` on a source that has none does
not fail as a shape violation; it raises `NoMethodError`. Leaving it universal would
have been the port still demanding bytes while its own doc promised otherwise. A
corpus-shaped source was built and failed exactly those 2 examples.

### `#file_at`, and why a diff is not enough

It is the one message about a single path and not the whole changeset. It exists
because a unified diff cannot be drawn from: an editor showing the old side beside the
new needs the whole old file, and a diff carries the hunks and 3 lines around them.
Every consumer of that is a renderer, so the read belongs to the source that already
knows where the bytes live.

### `#line_at`, and why it is separate from `#file_at`

A note's evidence is one line of the reviewed revision, numbered as the file the human
placed it in numbers it. For a diff source that is `#file_at` cut by `Anchor.lines`,
and `Source::Diffed` answers it so.

A corpus cannot do that. Its `#file_at` is the projection, and masking a region that
spans lines (a private key block) collapses those lines into one placeholder, so the
projection's line N is not the file's. `Corpus#line_at` asks `Survey::Projection#line`,
which reconciles over the whole file and masks only where a region crosses that raw
line. A file the walk gated for its name (`password.txt`, `secrets/prod`) is masked
whole instead: every line of it answers the one placeholder, and `#projected_line` maps
every line to 1.

It answers nil when asked past the end, at a revision that does not hold the path, or
for a surveyed file deleted since. `Changeset#anchor` records that as a note with no
evidence line. The note rail takes a batch of notes whole or refuses it whole, so a
refusal of one note would journal its neighbours twice on the retry.

### `DiffOrigin`, and why it is on the port

It began as `GithubPr`'s alone, and its first consumer therefore asked
`respond_to?(:diff_origin)`: a type test in duck costume, and the one place a consumer
branched on which source it was handed. A source that never asks an API still has an
answer to "where did these bytes come from", so the conditional is gone. A live defect
went with it: the guard was tested on one leg only, and an ordinary pull request
rendered a fallback note with an empty reason.

### Refusals here are raised, unlike `Forge::Gh`'s

Gh's doctrine is that a refusal is a value, because a landing folds over answers and
journals them. This port has no fold to carry a not-ok answer. A ref that does not
resolve is the caller naming something that does not exist, which is Gh's own
distinction on the other side of the line: "gh answering no is data, gh not existing is
a broken machine". There is no review to be had, so `UnknownRef` raises.

## The editor's review surface

`Lain::Review::Surface::Neovim` adapts the 7 port messages onto the 4 review
rails `Frontend::Neovim::RenderInlet` owns. It holds no review state; the arguments
behind that shape are here, and the class is at `lib/lain/review/surface/neovim.rb`.

### Which rail each message rides, and why 2 of them share one

`present` goes to `set_review`, through `Frontend::Neovim::ReviewView`. The view turns
a changeset into sidebar rows and holds the line to file index a `<CR>` resolves
through. The view's `Rendered` carries the lines and the stamp they belong to, and both
go out together. There is no `#generation` reader to read them apart, on purpose: that
is what keeps a gesture from resolving rendering N's row against rendering N+1's stamp.

`annotate` and `thread` both go to `set_thread`, through `Frontend::Neovim::ThreadView`,
because the thread pane is keyed by anchor id and a note at an anchor is a message in
that anchor's conversation. `thread` sends no message at all (this object keeps no
history to replay, and `Surface::Text#thread` reads "open" the same way), so the view
renders its own invitation to ask. `annotate` sends the note as one message. The
extmark rail a note would also ride does not exist yet, so a note is visible in the
pane and nowhere else until it does.

The view is the one owner of that payload, and this object may not build one itself. It
used to. Both messages posted `@rpc.set_thread(anchor.id, lines)`, a bare String where
the editor half refuses anything but a table `{id, path, side, line}`, because the pane
is cursor-driven and an id names no position. The refusal travelled over a notify, so
it reached nobody, and `Review::Session#annotate` (the whole production route to this
rail) produced no pane at all while this object answered "it landed". Two owners of one
wire shape allowed the 2 to drift. There is now one owner, and this object's share is
deciding what entries a note becomes.

`mark`, `refuse`, `verdict` and `settle` go to `review_refused`, the review's one
notice rail (`runtime/65_review.lua` echoes it into the message area).

- `refuse` is what that rail was built for.
- `mark` is there because redrawing the sidebar so the file's tri-state marker moves
  needs the changeset, which is exactly the state this object must not hold. The redraw
  now happens: `Review::Handover::Redraw` makes it, from the gesture rail, which holds
  both the session and the scope. The notice is no longer the only thing that says a
  mark landed. It stays because it says so in words, at the moment of the gesture, and
  it is what a mark reaching this surface from anywhere but that rail still has.
- `verdict` posts the ask, because on an interactive surface asking a human for a
  decision is something you do and not something you wait for.
- `settle` posts the answer to that ask. It is here for `mark`'s reason plus one more:
  a sidebar row says what is reviewed and nothing in a row can say the round is closed,
  so words are the only place that fact fits.

### What a message answers

A refusal sentence when the editor did not take it, and nothing that is a String when
it did. This is `RenderInlet`'s own convention, passed straight up and not translated,
because a detached editor is a fact the caller has to be able to say out loud, and an
exception is the one shape a port whose adapters decline in words must not use. The
4 rails already answer exactly this, so every command below is a tail call.

`#verdict` is the exception, for a structural reason. `Review::VERDICTS` are Strings,
so a refusal returned from the one message that answers a verdict could not be told
apart from a verdict. It answers `nil`, the same as `Surface::Null#verdict` and
`Surface::Text#verdict`.

A null verdict value does not close this. An earlier draft here pointed at
`Verdict::None` as the fix, and a review panel was right that it is not one. A null
verdict says "no verdict". It still cannot tell the caller that the human declined from
that the editor was detached, which are different facts with different things to do
about them.

What closes it is an object this port does not have: an answer value carrying verdict
or refusal, returned by every message. That object would make the port's refusal law
uniform and delete the `#verdict` exemption (`spec/support/shared_examples/review_surface.rb`,
law #5), the one place the panel found nvim's convention shaping the port. It is left
open on purpose, since closing it badly is worse.

`#settle` does not close it either, and the 2 are separate gestures. `settle` carries
a verdict inward, so its answer has no ambiguity to resolve and it obeys the refusal
law like every other command. `verdict` asks a human outward and still has nowhere to
put a refusal. Adding the one did not remove the exemption of the other.

### The gesture leg, and where `drifted:` is measured

`#marked_at` and `#marked` are the way back: the editor marked a row, and the session
records it. Nothing is recomputed on the way. `Frontend::Neovim::ReviewView#marks` says
which hunks the row named against the rendering the human is actually looking at, and
every key it answers is forwarded verbatim.

The annotate write joins the same leg. Computing `drifted:` belongs to neither this
object nor the session. Drift is the anchor text against the line the number now names,
and that line lives in the editor buffer, which is neither the diff the session holds
nor anything this object may hold. So the comparison is made where the buffer is, in
the note rail's Lua half at settle time, content against content, and arrives inbound
as a field on the `review_annotate` payload. This surface forwards it, the session
receives it, and nobody computes it from state they do not have.

That matches the extmark contract: a mark inside a rewritten span moves and does not
invalidate, so whether it survived can never answer the question and only content can.
The leg itself waits on `ReviewWrite::KEYS`, which carries neither `drifted` nor the
buffer's revision in this tree.

That leg refuses uniformly or not at all. Notes arrive one at a time, and the editor
forgets the batch only after the last one lands. A `wrote_annotation` that takes note 1
and refuses note 2 leaves note 1 recorded while the editor still holds every note, and
the human's retry records note 1 a second time. A note-by-note rail is safe only while
no consumer refuses per note. That is a property of the consumers, and this is one of
them.

So the refusal is computed from exactly one predicate, whether a session is bound to
record against (`Unbound`), which cannot vary within a batch. Everything a note carries
is either already judged at the boundary by `Neovim::ReviewWrite` or journaled and not
refused.

- At the boundary: shape, every key present, side and kind closed, path and text
  non-blank, and `line` against `Review::Anchor.line!`'s own domain, asked there so
  nothing downstream has to say it by raising.
- Journaled: `revision` and `drifted`, deliberately. `AnnotationPlaced` carries a
  revision so that "authored against one diff, submitted against another" stays
  detectable in the record. Refusing it at the wire would defeat that and make the
  refusal per note.

A `validates`-shaped check added here, one that can pass one note and fail the next,
reintroduces the duplicate the moment it exists.

This object can never itself be `@changeset_review`. `CLI::HumanReplies::Gestures`
sends `mark(line, state, generation:)`, which is `#marked_at`'s shape under another
name. The port owns `mark` on this object for the opposite direction (`mark(hunk_key,
state)`, model to surface), so the name is taken and cannot be shared. A separate
gesture adapter, answering `open`/`mark`/`ask` and delegating to this surface and its
view, is what `bind_changeset_review` has to be handed. That is a wiring card's object.
The collision is stated here so it is found by reading and not by a rail that silently
does nothing.

### The leg this object cannot grow

`Frontend::Neovim::ReviewView`'s `changesets:` collaborator, what a `<CR>` on a sidebar
row opens, is not this object. Taking a changeset in `#present` and rendering it
immediately is not caching, and nothing here does otherwise. But `changesets.open(path,
line)` is driven by a gesture arriving arbitrarily later than the `present` that drew
the row, and it needs that file's old side and both revisions. That is a changeset held
to answer a later message, the one state this class is defined by not keeping.
`Frontend::Neovim::ReviewView::Unwired` refuses the gesture until the object that holds
the diff answers it.

## The review handover

`Lain::Review::Handover` is the open changeset review as the rails a human answers on
see it, at `lib/lain/review/handover.rb`. These are the 2 arguments behind it.

### Two rails, and what may go wrong on each

`#wrote_annotation` and `#wrote_verdict` are answered. They run on the RPC thread,
inside the human's `:w`, and their return value is what that write succeeds or fails
with. Neither may park, and neither may raise: a raise reaches
`Frontend::Neovim::RpcThread#answer`, which answers the editor and then re-raises,
ending the editor session over one note. That is why the rescues are wide (this
project's `Lain::Error` taxonomy plus the `ArgumentError` a record's guard refuses
with) and not a list a new refusal class one layer down could silently escape.

`#open`, `#mark` and `#ask` are acked. They arrive on the command inbox and are served
by `CLI::HumanReplies::Gestures` on the reactor thread, which asks each answer
`#opened?`, `#marked?` or `#asked?` and renders `#report` when it says no. Nothing here
may raise on that rail either, since `Gestures` rescues only NoMethodError. `#mark`
therefore folds the session's refusals into the answer.

### A gesture that changed a row draws that row again

Both acked gestures change what a row says, and the human's next gesture is resolved
against the rendering they are still looking at. A gesture that changed a row and drew
nothing left `<CR>` followed by a mark refusing the very row the `<CR>` had just made
markable. `Redraw` closes that. It is injected because the scope it needs is the one
fact this rail cannot ask anybody for.

Known limitation: a race, not a hole. The redraw is posted and not applied: inlet, wake
pipe, RPC thread, nvim, measured at roughly 7-20ms at `Bounds::DEFAULT_MAX_FILES`. A
mark carrying the pre-open stamp is still refused, with the same
`Frontend::Neovim::ReviewView::UNREAD` sentence, over a file that has demonstrably been
read. Keyboard autorepeat (about 30ms) clears the window. A deliberate 2-key roll may
not, and pressing `x` again always works.

It is left open on purpose. Closing it means letting the view answer a gesture from the
live changeset and not from the rendering it drew, which is what the stamp bought its
way out of. It cannot be done half way, because a held rendering's `Row` carries `read:`
frozen at render time, so the view cannot tell "still unread" from "read since" without
consulting the model. A better sentence for that case would need the same consultation.

## The corpus source

`Lain::Review::Source::Corpus` reviews a directory of files as they stand: no diff, no
base, no commit walk. The class is at `lib/lain/review/source/corpus.rb`; these are the
arguments behind its cost model and its naming.

### Opening reads every file once and parses none of them

This is the trade the whole arm rests on, so it is priced here. The address is
content-addressed, so `#identity` streams every listed file and hashes it. That is
O(total bytes), and unavoidable if "re-chunking does not move the address" and "marks
survive across surveys" are both to hold.

Laziness buys the parse tier. Chunking is per file, on demand, through `LazyFile`, so
presenting costs O(files ever marked) and not O(corpus). Round identity therefore does
not depend on the chunking strategy, and improving a chunker later does not open a new
round over a tree nobody touched.

The total is stated and not left to be inferred. A fully worked corpus reads each file
twice (once for the identity pass, once when it is finally chunked) and a third time per
`#file_at` an editor asks for. `Reading#content` is not memoized: a memo would hold the
whole corpus resident for the life of the session, which is the cost the accrete model
exists to avoid.

The file ceiling is checked in `#initialize`, from the walk alone. An oversized corpus
is refused without reading a byte it would then throw away, and putting the guard in the
constructor makes that structural.

### Every path is named from one root, the reader's

A walk names what it found beneath the tree it was pointed at, which is the only root it
has. Everything downstream reads those names somewhere else: the sidebar row a `<CR>`
resolves, the buffer `47_diff.lua` opens against `getcwd(-1, -1)`, and the path a
verdict's refusal sends a human to. So `/survey ./lib` labelled a row `greeter.rb` and
opened an empty buffer for a file that does not exist, and every object on that path had
a passing spec, because each was tested against a double standing where the next one's
root would have been.

`named_from:` is that reader's root, and it is a cwd and not a project root.
`Lain::Project` splits the 2 on purpose: root is the authority boundary, cwd is where
a relative path resolves. A monorepo chat runs with cwd deep in a subtree while root
sits at the repository top, so naming from the root breaks `/survey .`. nil names from
the surveyed tree itself.

The prefix is lexical and never resolved. It is joined the way the editor joins it:
`Dir.pwd` and nvim's `getcwd` are both physical, and a survey root is `File.expand_path`
of what a human typed. A symlinked subdirectory therefore names `lib/x`, the editor
opens `<cwd>/lib/x`, and both follow the same link to the same file. `realpath` here
would mint a prefix that no longer sits under the editor's cwd at all.

It moves the address, since `#identity` is composed from the paths: one tree surveyed
from 2 roots is 2 corpora, and a mark made under one does not carry to the other.
That is the price, and it is the right way round, because a name a reader cannot resolve
is worse than a mark set that belongs to the directory it was made in.

### Collaborators are injected, all 4

The walk decides which paths enter, the projection which bytes of them do, `Bounds` how
many is too many, and the chunker how a file divides. None is constructed here. The
chunker in particular is the seam a counting chunker rides, so that "this survey chunked
nothing" is a measurement through the real stack and not a flag the subject sets about
itself.
