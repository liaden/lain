# The Neovim runtime protocol, 2 through 15

A closed record. Until 2026-09-12 the Ruby frontend and the injected Lua runtime
each carried a hand-maintained integer, bumped in lockstep whenever the injected
protocol changed -- the commands, the render entry points, or the handshake's own
shape. The history below sat in `lib/lain/frontend/neovim.rb` as an in-source
changelog and was swept by two specs.

The integer is gone. The handshake token is now a blake3 digest of the exact
runtime chunk the gem injects, which cannot be forgotten on a change because it is
derived from the thing it guards, and this file will not grow another entry. It is
kept because the entries say WHAT CHANGED at each step, which is the only account
anywhere of how the editor surface evolved -- git has the diffs, and this has the
sentences that go with them.

Nothing reads this file. It is history, not a contract.

## Protocol 2

:LainReply and the inbox drain autocmd.

## Protocol 3

The User LainAttach/LainRender events, b:lain_view on every lain:// buffer, lain://workspace in
the runtime's buffer set, and the six documented lain* syntax groups.

## Protocol 4

The lain://compose round trip -- the set_compose render entry point, and the
"compose"/"compose_abandon" commands its BufWriteCmd/BufUnload autocmds send back.

## Protocol 5

The review surface -- the open_review/review_refused render entry points, :LainAnnotate and
:LainReviewDone, and the b:lain_review_generation / b:lain_review_epic_slug stamps.

## Protocol 6

The lain://question round trip -- the set_question render entry point, b:lain_question_digest,
the question fold predicate, and the "question"/"question_abandon" commands. "question" is the
FIRST command whose answer is not an ack: its response is the write's verdict (see
{RpcThread#answer}).

## Protocol 7

The inbox's open gesture -- :LainOpen and the "open" command it sends, carrying the CURSOR LINE,
with <CR> and `r` both bound to it.

## Protocol 8

Set_view gained an OPTIONAL third argument, the rendering stamp it writes to
b:lain_view_generation, and "open"'s second argument moved from the line COUNT to that stamp.

## Protocol 9

The changeset review surface. Render entry points __lain.set_review, __lain.open_changeset and
__lain.set_thread; __lain.review_layout / __lain.review_place and the tabpage slots those place
through; __lain.review_notes_held. Commands :LainReviewOpen, :LainNote, :LainNoteDone and
:LainThread. A config hooking protocol 3 must re-read one thing: b:lain_view no longer names a
VIEW, since the diff pair's old side carries lain://review/OLD/<path> and differs per FILE.
Dispatch on b:lain_review_side / b:lain_review_revision / b:lain_review_path instead -- stamped
on both sides of the live pair and WITHDRAWN when you move off a file.

## Protocol 10

:LainReviewMark {state} sends "review_mark" -- the cursor's line, the state, and
b:lain_view_generation -- bound in lain://review as `x` (reviewed) and `u` (unreviewed), ONE KEY
PER STATE, because the state rides the wire and a toggle computed from a rendering that has
since moved flips the wrong hunk in silence. :LainReviewVerdict {verdict} sends
"review_verdict", the first ANSWERED verb outside a review buffer: its return leg is what the
command fails with, and it names Lain::Review::VERDICTS rather than restating the vocabulary in
lua. No new render entry point -- a refused mark comes back on __lain.review_refused.

## Protocol 11

One lain per editor. The injected chunk now RETURNS -- nil once it has loaded, and a refusal
table BEFORE it loads anything at all when a live RPC channel already owns this editor, which
{RpcThread#attach} raises as {SocketOwned}. The owner is named by the runtime's __lain.channel,
this table's first non-function member: the channel id was a chunk local nothing could read, so
a re-injection silently repointed every :Lain* command at a channel that then died. LIVENESS,
never presence -- a marker left behind by a lain that has gone away must not cost the human
their editor, so the recorded channel is asked of nvim rather than trusted.

## Protocol 12

The approval surface. Render entry point __lain.set_approval draws lain://approval, stamping
b:lain_view_generation with the rendering and b:lain_approval_rows with how many of its leading
lines are answerable calls. :LainApprove and :LainDeny answer the call under the cursor, bound
in that buffer as `y` and `n`; both send the "approval" verb carrying the line, the verdict and
the stamp. ONE COMMAND PER VERDICT, protocol 10's rule for the same reason: the verdict rides
the wire, because a decision computed from a rendering that has since moved answers the
neighbouring call in silence. ACKED, never answered -- a verdict resolves a promise, which must
happen on the reactor, so it rides the command inbox to the consumer fiber rather than being
served on the RPC thread.

## Protocol 13

__lain.set_review gained a THIRD argument, `sides` -- which of {Lain::Review::SIDES} the round
presents at all, as a list. A survey of files as they stand answers `["new"]`; a changeset
answers both, including for a file it added. A FACT, never an instruction: the editor opens the
navigator plus the round's sides and leaves the rest of the slot vocabulary unopened. The
vocabulary itself is unchanged at sidebar/old/new.

## Protocol 14

__lain.set_approval gained TWO more arguments, `calls` and `call_index`, stamping
b:lain_approval_calls and b:lain_approval_call_index. A wrapped item's command is cut and re-
indented across several of lain://approval's rendered lines, so a reader who reassembles one by
joining them gets INDENT lodged mid-token; these two variables are the reader's own unbroken
copy. `calls` is ONE ENTRY PER PARKED CALL, never per row -- msgpack does not dedupe shared
objects, so a copy per row a wrapped item spans made the wire payload quadratic in that call's
length. `call_index` is b:lain_approval_rows-shaped (one entry per row, 1-based) and names which
member of `calls` the row resolves to -- `calls[call_index[N]]` is row N's command in full.

## Protocol 15

lain://status joins the runtime's BUFFERS set, so the User LainAttach payload names it, and it
is built with the "markdown" filetype rather than the shared "lain" one: it carries a mermaid
code fence of the epic's issue graph, and markdown is the filetype an image plugin draws one
under. It rides the existing __lain.set_view entry point; no new command.
