# frozen_string_literal: true

require "forwardable"
require "neovim"
require "socket"

module Lain
  module Frontend
    class Neovim
      # A second lain attaching to an editor a live one already owns, refused by
      # the injected runtime before one module of it loads (runtime.lua's head
      # states the whole check, and why it asks about LIVENESS rather than
      # presence).
      #
      # A {Lain::Error} so exe/lain presents it as a notice rather than a
      # backtrace: it is the one attach failure a human causes deliberately, by
      # pointing a second `--nvim` at the editor their chat is already in, and
      # what they need back is a sentence naming a socket and an alternative.
      #
      # It carries the OWNER's channel id, which is the one fact separating
      # "another lain is in there" from every other reason an attach fails -- and
      # is what a human can check in the editor itself against
      # `:echo luaeval('__lain.channel')`.
      class SocketOwned < Lain::Error
        # @param socket_path [String] the socket the attach was refused at
        # @param channel [Integer] the live RPC channel already serving it
        def initialize(socket_path, channel)
          super("the nvim listening at #{socket_path} is already attached to a running lain (RPC channel " \
                "#{channel}), and a second attach would take that session's :LainReply, its review writes and " \
                "its rendered buffers away from it with nothing said on either side. Quit that lain first, or " \
                "start a second nvim with its own --listen socket and point --nvim at that one.")
        end
      end

      # An editor whose LOADED lain runtime was injected from a different source,
      # announced by that runtime's successor before it loads. The handshake token
      # is a digest of the injected chunk (see {Neovim.protocol_of}), so "a
      # different runtime" is a fact the lua half establishes against what the
      # runtime in that editor published about itself -- `__lain.protocol`, which
      # `99_attach.lua` sets only once every module has executed. A leftover
      # `g:lain_rpc_version` with no runtime behind it is not this and does not
      # raise: refusing on litter costs a human their editor for nothing.
      #
      # AN ANNOUNCEMENT, NOT AN INVARIANT, and the distinction is worth the
      # sentence because {SocketOwned} next door IS an invariant. That one latches
      # and two lains never coexist. This one fires ONCE and the re-run replaces
      # the runtime -- because the token moves on every edit to any of the runtime
      # modules, so a guard that latched would cost a developer their editor each
      # time they touched a line of lua, which is worse than the hand-maintained
      # integer it replaced. What survives the replacement is whatever the older
      # runtime had and the newer one does not: a command it dropped, an autocmd
      # it stopped creating, still wired to a channel that died. This tells
      # somebody that is so. It does not undo it, and the sentence says as much.
      #
      # The consent is recorded on the runtime being replaced, never on the
      # editor, so the next runtime that differs announces itself too.
      #
      # A {Lain::Error} for {SocketOwned}'s reason -- exe/lain presents it as a
      # notice, and what the human needs back is a sentence, not a backtrace.
      class RuntimeStale < Lain::Error
        # How much of a digest a human is asked to compare by eye. Enough to be
        # sure two differ, short enough to read in a sentence -- the same trade
        # {CLI::ForkPoint} makes for a Store digest.
        SHOWN = 12

        # @param socket_path [String] the socket the attach was refused at
        # @param installed [String] the token the loaded runtime published
        # @param injecting [String] the token this gem's runtime would carry
        def initialize(socket_path, installed, injecting)
          super("the nvim listening at #{socket_path} has a lain runtime loaded that this gem did not inject " \
                "(it reports #{installed.to_s[0, SHOWN]}..., against #{injecting[0, SHOWN]}...) -- an older or " \
                "newer lain left it there. Running lain again replaces it, which is the whole of the fix for " \
                "the parts that overlap; what it cannot take back is anything that runtime has and this one " \
                "does not -- a command it defined, an autocmd it created -- which stays behind wired to a " \
                "channel that is gone. Quit the editor first if you would rather start clean.")
        end
      end

      # The outbound half of {RpcThread}'s work: the backlog of not-yet-sent
      # render commands and ITS backpressure. {RpcThread} owns attach, the
      # select loop and inbound dispatch; this owns nothing nvim-shaped except
      # turning one queued command into the right `nvim_exec_lua` call.
      class RenderQueue
        # THE ONE CHUNK every rail rides, and the whole of what Ruby now holds
        # of lua. The entry point is DATA ({RAILS}) rather than thirteen
        # near-identical strings, each of which spelled out its own
        # `local a, b = ...; _G.__lain.fn(a, b)` binding -- thirteen places an
        # argument could be dropped or transposed with nothing said, because
        # nvim discards a notify's error. `runtime/01_dispatch.lua` binds them
        # instead, where `unpack` can do neither.
        #
        # The `if _G.__lain` guard stays, and it does NOT ask the question the
        # dispatch asks: this one is a render racing a not-yet-injected runtime,
        # which is transient and harmless, so it no-ops. An entry point the
        # runtime does not have is a table row disagreeing with the lua half,
        # and that one raises over there.
        DISPATCH = "local fn, args = ...; if _G.__lain then _G.__lain.dispatch(fn, args) end"

        # One rail: the `_G.__lain` entry point it reaches, the parameters that
        # entry point declares, and whether its producer may be made to wait.
        #
        # `params` is not documentation. The lua half has to BIND what Ruby
        # sends, and a chunk taking two arguments against a queue pushing three
        # drops the third in silence -- the one failure shape a payload
        # assertion cannot see. That used to be pinned for ONE rail, by
        # asserting on the text of its chunk; spelled here it is pinned for all
        # thirteen, by a spec that reads the `function _G.__lain.<lua>(<params>)`
        # declarations out of the shipped runtime and compares them. So the
        # spelling is LUA's and not Ruby's: {RAILS}`[:thread]` says `anchor`
        # because that is what `51_thread.lua` calls it, whatever the Ruby
        # caller's own parameter is named.
        #
        # `blocking` is the producer's nature rather than the rail's: a
        # background renderer outpacing nvim can be back-pressured by the queue,
        # while every other producer here is called from a path that cannot
        # afford to park -- Reline's input loop, a reactor fiber, or somebody
        # else's lock -- so a full queue must ANSWER it instead. This field is
        # the PUSH MODE only; what {RenderInlet} does with the result is decided
        # at the door, by whether that caller handed it a sentence. The two
        # agree by construction, because the only doors that pass no sentence
        # are the two blocking rails' -- and a disagreement would be loud rather
        # than silent either way: a refusing door on a blocking rail parks, and
        # a raising door on a non-blocking one lets ThreadError out.
        Rail = Data.define(:lua, :params, :blocking)

        # Every rail, keyed by the name its callers use. A new view is a ROW:
        # it used to be a lua string, a `post_*` method pushing it, and a mirror
        # on {RenderInlet} wrapping that.
        RAILS = {
          # Append already-rendered plain lines to the journal.
          render: Rail.new(lua: "render", params: "lines", blocking: true),

          # Whole-buffer replace for a named read-only state view. The third
          # argument is OPTIONAL and is the rendering stamp: a view whose
          # gesture has to name the rendering it came from sends one, and
          # `45_views.lua` is where which views do is written down. See
          # {#post_view} -- this is the one rail the table cannot hold whole.
          view: Rail.new(lua: "set_view", params: "name, lines, gen", blocking: true),

          # Whole-buffer replace for the ONE editable view, lain://request.
          # Distinct from {view} only in the lua entry point it calls, which
          # skips the nomodifiable flip.
          request: Rail.new(lua: "set_request", params: "name, lines", blocking: true),

          # Open lain://compose on the human's draft. A third entry point rather
          # than a flag on {request}: that buffer is `nofile` and never written,
          # this one is `acwrite`, named, and SHOWN -- the two have nothing in
          # common but the word "editable".
          #
          # NOT blocking, and the first rail that was not: it is queued from
          # Reline's INPUT LOOP, inside keypress dispatch, where a blocked push
          # would freeze the prompt's rendering with the human given no feedback
          # at all. A full queue means nvim has stopped draining, which is the
          # same fact as "no editor took the draft".
          compose: Rail.new(lua: "set_compose", params: "name, lines, generation", blocking: false),

          # Open lain://question on a pending set's rendered document. {compose}'s
          # shape with the set's content digest in place of the counter -- one
          # more entry point rather than a flag, because that buffer folds per
          # question, indents to the grammar's two spaces, and its write can be
          # REFUSED; none of that is compose's.
          #
          # Not blocking for a sharper reason than {compose}'s: it is posted
          # from inside {QuestionView}'s lock, so a blocking push against a full
          # queue would hold that lock -- and the same lock is what a write in
          # the editor takes.
          question: Rail.new(lua: "set_question", params: "name, lines, digest", blocking: false),

          review: Rail.new(lua: "open_review", params: "path, generation, epic_slug", blocking: false),

          review_refusal: Rail.new(lua: "review_refused", params: "message", blocking: false),

          # No buffer NAME argument, the one difference from {view}: that entry
          # point serves five buffers and has to be told which, while the sidebar
          # is a singleton in the review's own tabpage. The stamp is REQUIRED
          # rather than optional -- a sidebar row moves the moment the scope
          # toggles, and a line count cannot tell the two renderings apart.
          #
          # `sides` is a FACT about the round -- which of {Review::SIDES} it
          # presents at all -- never a layout instruction. It rides THIS rail
          # rather than {changeset} because this one precedes the layout: the
          # editor builds its panes on the first sidebar render, so a fact sent
          # with the open arrives after the window it would have prevented.
          #
          # Not blocking for {question}'s reason rather than {compose}'s: it is
          # queued from the editor-command consumer's own fiber, so a blocking
          # push against a full queue would park the surface that answers every
          # OTHER verb on that rail -- including the refusal this one owes them.
          review_sidebar: Rail.new(lua: "set_review", params: "lines, gen, sides", blocking: false),

          # Go to the review's tabpage, building the layout first if the human
          # closed it. The ONE entry point in `41_layout.lua` that takes focus,
          # and the reason it is a separate rail rather than a flag on
          # {review_sidebar}: that one lands on every redraw and must move
          # nobody, so a flag would put "does this move the human" in the hands
          # of whoever last called the render.
          review_focus: Rail.new(lua: "review_layout", params: "", blocking: false),

          # The round is over. NO ARGUMENTS, {review_focus}'s reason: what a
          # settled round leaves on screen is the editor's own question.
          #
          # It exists because nothing about a verdict is visible in the editor --
          # the tabpage, its panes and every buffer survive one -- so the review's
          # stamps would outlive the review that issued them and a note placed
          # afterwards would name a review nobody holds (`47_diff.lua`'s
          # `review_settled` carries the measurement).
          #
          # Posted from the review session's own verdict path, which is serving
          # a gesture the human just made -- so it answers rather than parks.
          review_settled: Rail.new(lua: "review_settled", params: "", blocking: false),

          # The new side is the real file on disk, the old side a scratch buffer
          # whose content rides in this argument list. Ruby runs git, never the
          # editor: an injected chunk shelling out would put half the review model
          # in the editor. `new_lines` rides only when the checkout does not hold
          # the head, and then the new side is a copy of those lines instead.
          #
          # `revisions` is a map rather than two more positionals -- the pair is
          # two commit-ish Strings that look alike, are adjacent, and mean opposite
          # sides. `47_diff.lua` stamps each buffer with its own so a note records
          # which diff it was authored against.
          changeset: Rail.new(lua: "open_changeset", params: "path, old_lines, line, revisions, new_lines",
                              blocking: false),

          # Show one anchor's conversation in the thread pane, keyed by the
          # ANCHOR ID and not by a line: the pane's buffer is swapped as the cursor
          # moves, and a line only names a position in the rendering that drew it,
          # while an id is a stamp Ruby minted and can hand back unchanged.
          thread: Rail.new(lua: "set_thread", params: "anchor, lines", blocking: false),

          # Whole-buffer replace for lain://approval. No buffer NAME, for
          # {review_sidebar}'s reason -- the list is a singleton, so the lua half
          # names its own -- and a THIRD argument no other view sends: how many of
          # the lines are answerable rows. The keys bound in that buffer have to
          # be inert everywhere else in it (the hint line, the empty state), and a
          # count Ruby mints is the only thing that says so without lua pattern
          # matching text Ruby drew. The stamp is REQUIRED like {review_sidebar}'s:
          # a row moves the instant any other call is answered.
          #
          # `calls` and `call_index` ride beside `rows` because lua cannot
          # recover either from `lines` -- {ApprovalView::Rendering}'s own
          # comment is where the shape and the reason both live. `calls` is one
          # entry per PARKED CALL and `call_index` is `rows`-shaped, resolving a
          # cursor line to its member of `calls`.
          #
          # Not blocking for {question}'s reason, one lifetime up: it is posted
          # from the approval surface's own fiber on the reactor, and a blocking
          # push against a full queue would park the fiber that is the editor's
          # only view of a PARKED AGENT -- while the queue's fail-closed clock
          # ran down underneath it.
          approval: Rail.new(lua: "set_approval", params: "lines, gen, rows, calls, call_index",
                             blocking: false)
        }.freeze

        # What one queued render is: the `_G.__lain` entry point to call, and
        # exactly what that entry point takes, already in its order. The CHUNK
        # is no longer part of it -- every rail rides {DISPATCH} -- and holding
        # the argument LIST rather than named fields is still what lets entry
        # points of different arity share one queue and one sender.
        Command = Data.define(:entry, :args)
        private_constant :Command

        # The one byte `nvim_buf_set_lines` refuses inside an item; see
        # {#checked_lines}.
        NEWLINE = "\n"
        private_constant :NEWLINE

        # Default cap on outstanding commands; every rail shares this one queue.
        # Unbounded, a producer outpacing nvim piled up a backlog an adversarial
        # probe took to ~800K entries, and draining it -- which runs BEFORE the
        # RPC thread's select gets a turn -- took 6.4s, starving inbound acks. A
        # SizedQueue fixes both: the blocking posts cannot exceed this cap, and
        # {#drain}'s per-tick batch is capped the same way for free.
        DEFAULT_CAPACITY = 1024

        def initialize(capacity: DEFAULT_CAPACITY)
          @queue = Thread::SizedQueue.new(capacity)
        end

        # Queue one rail. Safe from any thread.
        #
        # A rail whose {Rail#blocking} is set BLOCKS the caller once the queue
        # is full, and raises ClosedQueueError once {#close} has run --
        # {Neovim#post} rescues that (see its comment). Every other rail raises
        # ThreadError rather than parking, which is what lets {RenderInlet} turn
        # a full queue into a sentence instead of a stall.
        #
        # @param rail [Symbol] a key of {RAILS}
        # @param args [Array] the entry point's arguments, in the order its own
        #   `params` declares them
        # @raise [KeyError] naming a rail no row declares. Loud HERE because it
        #   is the one place it can be: past this point the render is a notify,
        #   and nvim discards a notify's error.
        def post(rail, *args)
          declared = RAILS.fetch(rail)
          @queue.push(Command.new(entry: declared.lua, args:), !declared.blocking)
        end

        # THE ONE RAIL THE TABLE CANNOT HOLD WHOLE -- {RAILS}`[:view]`'s own
        # phrasing, and both halves of it are true: `view:` and `request:` are
        # rows like every other rail, and this adapter is what a CALLER needs on
        # top of them. Three things happen here that are not data: `editable:`
        # chooses between the two rows, the rendering stamp changes the call's
        # ARITY rather than adding an argument, and the lines are checked as no
        # other rail's are. A table carrying those would need a `sanitize`
        # column true for two rows of thirteen and an arity column that is a
        # range for one, which is worse than a method with a reason.
        #
        # @param name [String] the lain:// buffer name
        # @param lines [Array<String>]
        # @param editable [Boolean] read-only state views ride `RAILS[:view]`,
        #   lain://request rides `RAILS[:request]`, which skips the nomodifiable
        #   flip. Same queue, backpressure and death behavior either way -- one
        #   render pipeline, not two.
        # @param generation [Integer, nil] stamps the buffer so a gesture from it
        #   can say WHICH rendering the human is looking at. Its absence is
        #   ARITY, not a nil argument: a nil crosses msgpack and arrives in lua
        #   as `vim.NIL`, which is TRUTHY there. Built by branch and never by
        #   `compact`, which cannot tell "no stamp" from "no lines" -- it would
        #   send `[name, generation]` and lua would bind the stamp as the
        #   buffer's lines.
        def post_view(name, lines, editable: false, generation: nil)
          checked = checked_lines(name, lines)
          rail = editable ? :request : :view
          generation.nil? ? post(rail, name, checked) : post(rail, name, checked, generation)
        end

        # Send everything currently queued, one nvim_exec_lua notify per
        # command; the caller flushes the connection once, after this returns.
        def drain(client)
          @queue.size.times { send_command(client, @queue.pop) }
        end

        # Release any producer blocked in {#post_render}/{#post_view} with a
        # ClosedQueueError, the same shape {Lain::Channel#close} uses to
        # release its own blocked producers. MUST run once nobody will ever
        # call {#drain} again (RPC-thread death, or normal teardown after the
        # sole producer thread has already stopped) -- see RpcThread's callers.
        def close
          @queue.close unless @queue.closed?
        end

        private

        # The lua half's `checked_lines` (47_diff, 51_thread), one layer up and
        # for the SAME rule: `nvim_buf_set_lines` refuses an item containing a
        # newline, and refuses ALL-OR-NOTHING, so one bad line loses the whole
        # buffer's write. Down here that failure is silent -- {#send_command} is
        # `notify`, and nvim discards a notify's error -- and the runtime's
        # trimmed write (45_views) makes the loss PERMANENT rather than
        # intermittent: it writes from the first differing line, so the offending
        # line can never enter the buffer and `shared` can never advance past it.
        # Measured: lain://timeline frozen at the first multi-line model reply
        # while every sibling view stayed live.
        #
        # REFUSED BY NAME, in place, rather than repaired: a rendering that
        # breaks the one-line-per-record contract is a defect in the VIEW, and
        # laundering it here would make the row read as the view's own work. In
        # place rather than raised, because every caller is a render thread whose
        # death takes all five views dark; and per ROW, because two views resolve
        # a gesture through a line's position, so the count must not move.
        #
        # `include?` and not a Regexp or `split`: these bytes reach the views from
        # disk, and both of those RAISE `ArgumentError` on invalid UTF-8 --
        # measured, and measured to take {Surfaces#prime} down at attach. `nil`
        # lines pass through untouched, which keeps the stamp's arity contract
        # testable.
        def checked_lines(name, lines)
          return lines unless lines.is_a?(Array)

          lines.each_with_index.map do |line, index|
            line.is_a?(String) && line.include?(NEWLINE) ? refusal(name, index) : line
          end
        end

        def refusal(name, index)
          "[#{name} line #{index + 1}: a rendering broke the one-line-per-record contract]"
        end

        def send_command(client, command)
          client.session.notify("nvim_exec_lua", DISPATCH, [command.entry, command.args])
        end
      end

      # The way IN to the editor, for every producer that is not the RPC thread
      # itself: queue the work, wake the loop, and answer whether it landed.
      # {RenderQueue} owns the backlog and its backpressure; this owns the PAIR
      # -- a post not followed by a wake is a render that sits until the next
      # backstop tick -- and the one policy that pair needs, which is what a
      # refused post answers.
      class RenderInlet
        # The two surfaces with no view object of their own to keep their
        # sentence in. {Compose::DETACHED} and {QuestionView::DETACHED} live
        # with the objects that answer them; a review has no such half, so its
        # words live here beside the door that speaks them.
        REVIEW_DETACHED = "opening a review in the editor needs an attached editor"

        # Separate sentences and not one shared one, because each names the
        # surface the human was actually using: being told "opening a review
        # needs an attached editor" while trying to read a note is the defect
        # the refusal parameter was added to end.
        SIDEBAR_DETACHED = "rendering a changeset review needs an attached editor"
        CHANGESET_DETACHED = "opening a changed file for review needs an attached editor"
        THREAD_DETACHED = "showing a review thread needs an attached editor"
        FOCUS_DETACHED = "putting you in front of a review needs an attached editor"

        # The one refusal nobody reads: this leg exists to carry a notice INTO
        # the editor, so its failure is "the notice did not land" and there is
        # no further surface to send it to. Named rather than nil so the four
        # answers are four facts.
        UNREPORTED = "the editor did not take this notice"

        # Its own FACT: a notice that did not land cost the human a sentence,
        # while an end-of-round that did not land leaves an editor still holding
        # a review nobody is in -- stamps live, keys bound, and a note placed
        # afterwards naming a round that is over. Nobody reads this one either,
        # and it is still named rather than shared, because the two legs fail
        # differently.
        SETTLE_UNREPORTED = "the editor did not take the end of this review"

        # The backlog is BUILT here rather than injected: the loop reaches it
        # through {#drain} and {#close}, which is all the loop ever needed.
        #
        # @param waker [#call] wakes the select loop; never blocks
        # @param capacity [Integer] see {RenderQueue::DEFAULT_CAPACITY}
        def initialize(waker:, capacity: RenderQueue::DEFAULT_CAPACITY)
          @queue = RenderQueue.new(capacity:)
          @waker = waker
        end

        # The loop's own two messages: send everything queued, and release any
        # blocked producer once nobody will ever drain again (see
        # {RenderQueue#close} for why that MUST happen on death, not only on
        # teardown).
        def drain(client) = @queue.drain(client)
        def close = @queue.close

        # The BLOCKING post: a background producer outpacing nvim is
        # back-pressured by the queue, and a queue closed by RPC-thread death
        # raises ClosedQueueError through to the caller ({Neovim#post} rescues
        # it, having its own reason to treat the last render as a lost race).
        def post_render(lines) = post(:render, lines)

        # The other blocking one, and the only leg that still reaches past
        # {#post}: {RenderQueue#post_view} is the one rail that is not a table
        # row, and its own comment says why.
        def post_view(name, lines, editable: false, generation: nil)
          deliver { @queue.post_view(name, lines, editable:, generation:) }
        end

        # The NON-BLOCKING opens, one line each: the rail is a row in
        # {RenderQueue::RAILS} and all that is left to say at the door is which
        # sentence a detached editor answers with. See {#post}.
        def open_compose(lines, generation)
          post(:compose, Compose::BUFFER, lines, generation, refusal: Compose::DETACHED)
        end

        def open_question(lines, digest)
          post(:question, QuestionView::BUFFER, lines, digest, refusal: QuestionView::DETACHED)
        end

        def open_review(path, generation, epic_slug)
          post(:review, path, generation, epic_slug, refusal: REVIEW_DETACHED)
        end

        def review_refused(message) = post(:review_refusal, message, refusal: UNREPORTED)

        # The changeset review's three. Each answers a refusal rather than
        # raising for the reason above AND one of its own: {Review::Surface} is
        # a port whose adapters DECLINE in words, so a detached editor has to be
        # a value the adapter can hand back, never an exception it has to catch.
        def set_review(lines, generation, sides)
          post(:review_sidebar, lines, generation, sides, refusal: SIDEBAR_DETACHED)
        end

        # No `new_lines` is sent as ARITY, never as a nil argument, for
        # {RenderQueue#post_view}'s reason: a nil crosses msgpack as `vim.NIL`,
        # which is truthy in lua.
        def open_changeset(path, old_lines, line, revisions, new_lines = nil)
          pair = [path, old_lines, line, revisions]
          pair << new_lines unless new_lines.nil?
          post(:changeset, *pair, refusal: CHANGESET_DETACHED)
        end

        def set_thread(anchor_id, lines) = post(:thread, anchor_id, lines, refusal: THREAD_DETACHED)

        def review_focus = post(:review_focus, refusal: FOCUS_DETACHED)

        # Answers {SETTLE_UNREPORTED} rather than raising, like every other leg:
        # a detached editor is also an editor with no review tabpage to tear
        # down, so a refusal here is a fact and never an error.
        def review_settled = post(:review_settled, refusal: SETTLE_UNREPORTED)

        # lain://approval's, and its refusal is READ rather than reported:
        # {ApprovalView} withholds the stamp of a rendering nothing took, so a
        # keypress citing one is refused instead of resolving against rows nobody
        # can see.
        def set_approval(lines, generation, rows, calls, call_index)
          post(:approval, lines, generation, rows, calls, call_index, refusal: ApprovalView::DETACHED)
        end

        private

        # Every rail's one door: queue it, wake the loop, and answer whether it
        # landed.
        #
        # The `refusal` is the whole of the difference between the two kinds of
        # producer here. WITHOUT one, a full queue parks the caller and a closed
        # one raises -- that is a background renderer, which can be
        # back-pressured, and whose ClosedQueueError is {Neovim#post}'s to
        # rescue. WITH one, a full or closed queue ANSWERS that sentence
        # instead, because every other producer is called from a path that
        # cannot afford to park -- Reline's input loop, a reactor fiber, or
        # somebody else's lock -- and because from the caller's side a dead
        # thread, an editor that stopped draining, and never having attached are
        # ONE fact: no editor is taking this.
        #
        # The SENTENCE is PASSED rather than tabled, for two reasons that agree.
        # Three of them belong to the view object that speaks them
        # ({Compose::DETACHED} and its two siblings), and this file is required
        # ahead of all three in `neovim.rb`'s manifest, so a table could not name
        # them at class-body time anyway. And naming each at its own door is what
        # keeps a human answering a question from being told that composing needs
        # an attached editor -- which is the defect the parameter was added for.
        def post(rail, *args, refusal: nil)
          return deliver { @queue.post(rail, *args) } if refusal.nil?

          refusable(refusal) { @queue.post(rail, *args) }
        end

        def deliver
          yield
          @waker.call
          nil
        end

        def refusable(refusal, &block)
          deliver(&block)
        rescue ClosedQueueError, ThreadError
          refusal
        end
      end

      # The wire shape of the review writes whose answer IS the editor's
      # verdict, read at the boundary and BEFORE any listener runs -- which is
      # what makes "a malformed annotation is not recorded" a fact about the
      # order things happen in rather than a hope about the listener.
      #
      # Not a second copy of {Review::AnnotationPlaced}'s guard: that record
      # judges what the JOURNAL stores, this judges what the EDITOR authored,
      # and it has to judge it HERE, because a refusal is only worth anything
      # while the human's words are still in the buffer.
      #
      # Of the record's members only the anchor's `id` is minted on this side.
      # `revision` is the EDITOR's, off `47_diff.lua`'s `b:lain_review_revision`
      # stamp, and it has to be: the member exists so that an annotation
      # authored against one diff and submitted against another is DETECTABLE,
      # which only works if the diff the human was LOOKING at is on the record
      # rather than whatever is on screen at submit time.
      #
      # `drifted` is the EDITOR's for a harder reason: drift is the anchor text
      # against the line the number NOW names, and that line lives in the buffer
      # the human is looking at -- not in the diff a session holds, not on disk,
      # nowhere Ruby can reach without keeping a copy free to disagree with the
      # screen. For a 'fileformat=dos' file it certainly would disagree: nvim
      # strips the carriage returns the buffer never shows while git's bytes
      # carry them, so a Ruby-side comparison reports drift on every line.
      #
      # THE DROPPED KEY IS THE FAILURE THIS EXISTS FOR, and it is not
      # hypothetical: a nil value removes its key from a lua table entirely, and
      # a hole reaching a listener raises on the RPC thread -- which
      # {RpcThread#answer} answers and then RE-RAISES, ending the session over
      # one bookkeeping slip. A refusal costs the human a retype; a raise costs
      # them the editor. This boundary hands on exactly {KEYS}, so a member the
      # editor sends and that list does not name is dropped with no refusal and
      # no warning.
      #
      # The closed sets are CITED from {Lain::Review}, never restated, so a
      # second declaration cannot quietly disagree with the first.
      class ReviewWrite
        # Every key the editor must carry for Ruby to resolve an anchor and a
        # note out of it. `anchor_text` is checked for the KEY and never for
        # content: a blank line in a diff is a real anchorable position -- an
        # added empty line is a change a human may have an opinion about -- which
        # is the same distinction {Review::AnnotationPlaced} draws.
        KEYS = %w[path side line anchor_text text kind revision drifted].freeze

        # The two members the editor authors as free text, against the closed
        # sets they must land in.
        CLOSED = { "side" => :SIDES, "kind" => :ANNOTATION_KINDS }.freeze

        # The three nobody downstream can reconstruct: the file a note is on, the
        # words in it, and the revision it was authored against. All
        # blank-checked; `anchor_text` deliberately is not (see {KEYS}).
        NAMED = {
          "path" => "an annotation must name the file it is on",
          "text" => "an annotation with nothing in it records no opinion",
          "revision" => "an annotation that names no revision names no diff, so nothing can tell later " \
                        "whether it was authored against the diff it was submitted against"
        }.freeze

        # THE ARGUMENTS THEMSELVES ARE A SHAPE. `runtime/65_review.lua` records
        # a verb sending FLAT POSITIONALS and everything after the first being
        # dropped on the floor. `args.first` on a bare String answers a CHARACTER
        # and on an Integer raises NoMethodError -- inside the one guard whose
        # entire purpose is that the wire can never raise, which
        # {RpcThread#answer} then answers and re-raises, ending the session over
        # a lua typo. A flat Hash survived only because `Hash#first` happens to
        # exist, which is luck rather than defence.
        def self.flat(args)
          "a review write's arguments must arrive as ONE array holding the payload, which is the shape every " \
            "verb on this rail uses -- flat positionals silently drop everything after the first. Got " \
            "#{args.inspect}"
        end
        private_class_method :flat

        # @param args [Array, nil] the verb's ONE array of arguments; the note is
        #   its sole member, String-keyed as it crossed msgpack
        # @yieldparam note [Hash] the note, NORMALIZED (see {normalized})
        # @return [String, nil] the refusal the editor must fail its write with,
        #   or whatever the block answered
        def self.annotation(args)
          return flat(args) unless args.is_a?(Array)

          note = args.first
          refused(note) || yield(normalized(note))
        end

        # The batch `:LainNoteDone` settles: one gesture carrying every note the
        # human placed, across both sides and every file they visited, IN
        # PLACEMENT ORDER -- which is the output, since nothing else records
        # which note they wrote first.
        #
        # ATOMIC AT THIS BOUNDARY, AND ONLY AT THIS BOUNDARY. EVERY note is
        # judged before ANY is delivered, so a payload this object refuses --
        # anywhere in the batch -- delivers nothing at all. That ordering is the
        # whole difference between this and a loop over {annotation}, and it
        # matters because half a review recorded with a refusal covering the rest
        # is the one outcome a human cannot act on: they cannot tell which half
        # to retype.
        #
        # What does NOT hold: a LISTENER that takes the first note and refuses
        # the second leaves the first delivered. This method stops at that
        # refusal and answers it, `48_annotate.lua` keeps every note (its
        # `forget` sits past the `pcall`, deliberately), and the human's retry
        # therefore delivers the first note a SECOND time. Undoing a delivery is
        # the consumer's to offer, so a consumer bound here must either refuse
        # UNIFORMLY -- which is why today's do not reach that state -- or take
        # the batch whole.
        #
        # Delivered note by note to the SAME hand-off {annotation} uses, because
        # a batch-shaped method would have to be added to four listeners before
        # anything could receive it, and it is per-note downstream anyway.
        #
        # AN EMPTY BATCH IS TAKEN HERE, AND "NOTHING PENDING" IS NOT THIS
        # BOUNDARY'S QUESTION. A review the human had nothing to say about and
        # one whose notes were handed back a moment ago arrive as the same zero
        # notes, and only the EDITOR holds what tells them apart -- so
        # `48_annotate.lua` answers it there and does not call this verb when it
        # has nothing. A refusal written in here would refuse the one shape the
        # wire contract names.
        #
        # @param args [Array, nil] the verb's ONE array of arguments; the batch is
        #   its sole member, an Array of notes
        # @yieldparam note [Hash] each note, NORMALIZED, in placement order
        # @return [String, nil] the first refusal, or nil once every note is taken
        def self.notes(args)
          return flat(args) unless args.is_a?(Array)

          batch = args.first
          return unbatched(batch) unless batch.is_a?(Array)

          refused_batch(batch) || batch.lazy.map { |note| yield(normalized(note)) }.find(&:itself)
        end

        # The flat-payload refusal one level in, and it earns its own message.
        # {flat} catches `rpcrequest(..., verb, payload)` where the ARGUMENTS are
        # not an array; this catches `rpcrequest(..., verb, note)` where they are,
        # but hold a bare note instead of the batch -- the shape a lua half gets
        # by dropping one pair of braces, which reads as a single-note write and
        # would otherwise be half-accepted.
        def self.unbatched(batch)
          "a settled review's payload must be the ARRAY of notes, even when there is one of them or none: " \
            "one gesture carries every note the human placed, and the order it carries them in is the only " \
            "record of which they wrote first. Got #{batch.inspect}"
        end
        private_class_method :unbatched

        # Lazy so a malformed note stops the scan, and `first` so the human is
        # told ONE thing to go fix rather than a list.
        def self.refused_batch(batch)
          batch.lazy.filter_map { |note| refused(note) }.first
        end
        private_class_method :refused_batch

        # @param args [Array, nil] the verb's one array of arguments, holding the
        #   verdict alone
        # @return [String, nil] as {annotation}
        def self.verdict(args)
          return flat(args) unless args.is_a?(Array)

          given = Lain::Review::Wire.token(args.first)
          return yield(given) if Lain::Review::VERDICTS.include?(given)

          "this review's verdict must be #{Lain::Review::VERDICTS.join("/")} -- the vocabulary is settled in " \
            "Lain::Review::VERDICTS, not by what an editor sends -- got #{args.first.inspect}"
        end

        # Tokens interned and stripped of the whitespace a wire adds; text
        # interned and NEVER stripped, because an anchored line's indentation is
        # precisely the evidence a drift check compares. Normalizing HERE is what
        # keeps {Review::AnnotationPlaced}'s own normalization from being the
        # only thing standing between a `" new "` off the wire and a side nothing
        # recognises.
        #
        # Exactly {KEYS}, never the note as it arrived: an extra key is noise or
        # a version skew, and passing one through would let a later reader act on
        # a field this boundary never judged.
        def self.normalized(note)
          { "path" => Lain::Review::Wire.token(note["path"]),
            "side" => Lain::Review::Wire.token(note["side"]),
            "line" => note["line"],
            "anchor_text" => Lain::Review::Wire.text(note["anchor_text"]),
            "text" => Lain::Review::Wire.text(note["text"]),
            "kind" => Lain::Review::Wire.token(note["kind"]),
            "revision" => Lain::Review::Wire.token(note["revision"]),
            # NOT normalized: it is a boolean, already refused by {unmeasured}
            # unless it is exactly one, and what `Wire.token` would do to it is
            # ASYMMETRIC. It is `value && -value.to_s.strip`, so `false`
            # SHORT-CIRCUITS and comes back untouched while `true` becomes the
            # String `"true"`, which {Review::AnnotationPlaced}'s
            # `inclusion: [true, false]` refuses. Tokenizing here would leave the
            # answer MOST notes give intact and corrupt only the DRIFTED ones --
            # nothing looks wrong until a note actually drifts.
            "drifted" => note["drifted"] }
        end
        private_class_method :normalized

        # @return [String, nil] the first thing wrong with the note, or nil
        def self.refused(note)
          return "a review annotation must arrive as a table of #{KEYS.join(", ")}, got #{note.inspect}" unless
            note.is_a?(Hash)

          dropped(note) || unknown(note) || impossible_line(note) || unmeasured(note) || blank(note)
        end
        private_class_method :refused

        # REFUSED, NEVER COERCED. {Review::AnnotationPlaced} gives `drifted` no
        # default precisely so a caller that never compared cannot journal "did
        # not drift" -- a reading no later audit can tell from a real one -- and
        # a truthiness test here would hand that default straight back, since a
        # dropped key is nil is false.
        #
        # {dropped} already catches the key going missing; this catches it
        # arriving as something that is not a measurement -- a `"false"` off a
        # wire that stringified it, most of all, since that is TRUE to anything
        # testing it loosely.
        def self.unmeasured(note)
          return nil if [true, false].include?(note["drifted"])

          "this annotation's drifted must be true or false -- it is the editor's measurement of whether the " \
            "line still says what the note was anchored to, and a note nobody measured must not be recorded " \
            "as one that did not drift. Got #{note["drifted"].inspect}"
        end
        private_class_method :unmeasured

        def self.dropped(note)
          missing = KEYS.reject { |key| note.key?(key) }
          return nil if missing.empty?

          "this annotation reached lain without #{missing.join(", ")}, so nothing was recorded and your text " \
            "is untouched"
        end
        private_class_method :dropped

        # Names the value it JUDGED, in `inspect` form, for {Review::Wire.refusal}'s
        # reason: "must be one of old/new" without saying what arrived sends a
        # reader looking for a value they did not send.
        def self.unknown(note)
          CLOSED.filter_map do |field, set|
            members = Lain::Review.const_get(set)
            unless members.include?(Lain::Review::Wire.token(note[field]))
              "this annotation's #{field} must be one of #{members.join("/")}, got #{note[field].inspect}"
            end
          end.first
        end
        private_class_method :unknown

        # The domain is {Review::Anchor}'s -- ASKED here, never restated. 0 is
        # the value that actually hurts: hunk arithmetic makes `lines[-1]` out of
        # it and answers "not drifted" for a position nobody named.
        #
        # Asked HERE because downstream says the same thing by RAISING, and an
        # ArgumentError out of a listener is answered and then re-raised, ending
        # the session. Same rule, one boundary earlier, where it can still be a
        # refusal the human can act on.
        def self.impossible_line(note)
          Lain::Review::Anchor.line!(note["line"])
          nil
        rescue Lain::Review::Anchor::InvalidLine => e
          "this annotation's #{e.message}"
        end
        private_class_method :impossible_line

        # The members nobody downstream can reconstruct. {Blankness}, not
        # `strip`, because a lone U+00A0 satisfies `strip` and says nothing.
        def self.blank(note)
          NAMED.filter_map do |field, claim|
            "#{claim}, so nothing was submitted and your text is untouched" if Blankness.blank?(note[field])
          end.first
        end
        private_class_method :blank
      end

      # Which of the frontend's OWN reactions an inbound editor command
      # triggers. Routing is a table of verbs; the RPC thread is a socket and a
      # select loop.
      #
      # An ACKED command lands in {RpcThread#command_inbox} regardless of what
      # happens here, and its route runs AFTER the ack, so a slow hand-off never
      # delays the editor. A verb no route claims falls through silently -- the
      # editor's commands are not this object's to validate.
      #
      # An ANSWERED command's route RETURN VALUE is what the editor gets, so it
      # must run BEFORE any ack: a question `:w` is refused when the document
      # does not parse, and a refusal arriving after a `true` would be a buffer
      # marked saved over text the grammar rejected. Two tables rather than a
      # flag, because the kinds differ in when the route runs, what the editor is
      # told, and whether the inbox ever sees it.
      #
      # The answered ones are exactly the gestures lain can REFUSE. A review's
      # verbs split on that question alone: opening a row, marking a hunk and
      # asking a docent are hand-offs nothing here can turn down, while an
      # annotation and a verdict are WRITES whose `:w` has to fail with the
      # human's text still in front of them.
      class Router
        # Each route is handed the WHOLE command and destructures it itself,
        # because the verbs genuinely differ in what they carry: resend sends
        # lines, a compose write sends lines plus the generation it answers, an
        # abandon sends only that generation.
        #
        # @param listener [RpcThread::Listener] duck: #resend(lines),
        #   #compose_written(lines, generation), #compose_abandoned(generation),
        #   #question_written(lines, digest), #question_abandoned(digest),
        #   #review_annotated(note), #review_verdict_given(verdict).
        #   {RpcThread} is the only caller and always resolves one first (real
        #   or {RpcThread::Listener::Null}), so there is no default here.
        def initialize(listener:)
          @routes = acked(listener)
          @answers = answered(listener)
        end

        # @param arguments [Array] the command as the editor sent it: the verb,
        #   then whatever that verb carries
        def call(arguments) = @routes[arguments.first]&.call(arguments)

        def answers?(verb) = @answers.key?(verb)

        # @return [String, nil] the failure the editor must fail its write with,
        #   or nil once the command has been taken
        def answer(arguments) = @answers.fetch(arguments.first).call(arguments)

        private

        def acked(listener)
          {
            "resend" => ->(args) { listener.resend(args[1] || []) },
            "compose" => ->(args) { listener.compose_written(args[1] || [], args[2]) },
            "compose_abandon" => ->(args) { listener.compose_abandoned(args[1]) },
            "question_abandon" => ->(args) { listener.question_abandoned(args[1]) }
          }.freeze
        end

        # A question's payload is LINES, which no boundary object judges -- the
        # grammar does, later, and its refusal is the view's. Every review write
        # goes through {ReviewWrite} instead, which is a real seam and not merely
        # a way to keep this method short: see {review_writes}.
        def answered(listener)
          { "question" => ->(args) { listener.question_written(args[1] || [], args[2]) } }
            .merge(review_writes(listener)).freeze
        end

        # Each reads its payload through {ReviewWrite} FIRST, so a malformed
        # write never reaches the listener at all and "the annotation is not
        # recorded" is the shape of the code rather than a promise about it.
        #
        # `review_notes` is the note rail's `:LainNoteDone` -- the whole settled
        # batch, answered once -- kept BESIDE `review_annotate` rather than
        # replacing it, landing on the SAME hand-off, so a review binds one
        # object and answers both rails.
        def review_writes(listener)
          # One hand-off: a note reaching lain alone and a note reaching it
          # inside a settled batch are the same note, and a review that answered
          # them differently would be answering the gesture, not the note.
          annotated = ->(note) { listener.review_annotated(note) }
          { "review_annotate" => ->(args) { ReviewWrite.annotation(args[1], &annotated) },
            "review_notes" => ->(args) { ReviewWrite.notes(args[1], &annotated) },
            "review_verdict" => lambda { |args|
              ReviewWrite.verdict(args[1]) { |verdict| listener.review_verdict_given(verdict) }
            } }
        end
      end

      # The single thread that owns the nvim RPC session -- exactly one, because
      # the neovim gem's {::Neovim::Session} is single-threaded by construction
      # (`main_thread_only` raises off-thread). It attaches over a unix socket,
      # injects the runtime once ({RuntimeLoader}), then runs ONE select loop
      # that both serves inbound requests from the editor and drains queued
      # render work outbound -- the two directions the gem forces onto one
      # thread.
      #
      # The load-bearing gem traps this is built around:
      #
      # * Every touch of the session happens HERE. Other threads hand render work
      #   in through {#post_render} (a queue plus a wake pipe) and drain inbound
      #   commands from {#command_inbox}; they never call nvim themselves.
      # * The gem flushes writes only on the loop's NEXT read. This loop reads only
      #   when the socket is readable (it must also stay free to render), so it
      #   cannot lean on that -- it flushes the connection by hand after every
      #   write. That is why it constructs the {::Neovim::Connection} itself and
      #   keeps the handle rather than going through {::Neovim.attach_unix}.
      # * Renders go out as NOTIFICATIONS, not requests: a request would nest a
      #   read (waiting its response) that could swallow an inbound request into the
      #   session's pending queue. A notify plus a hand flush keeps reads confined
      #   to {#serve_inbound}, so the session's pending queue stays empty.
      # * Inbound requests are enqueue-and-acked in microseconds -- a slow response
      #   freezes the EDITOR -- so agent work never runs inline here.
      class RpcThread
        extend Forwardable

        # The hand-offs this thread makes back to its owner. One object with
        # named methods rather than positional callbacks -- a caller states its
        # reaction to each as a method instead of a hand-defaulted lambda, and
        # gets {Null} for free when it wants none of them.
        #
        # `compose_written`/`compose_abandoned` are deliberately two methods, not
        # one taking a verb argument: they carry different data, and a caller
        # forced to branch on a symbol would only be re-deriving what {Router}
        # already knows from the wire.
        class Listener
          # RPC-thread death, after {RpcThread#start} has returned. An attach
          # failure rides {#start}'s own return instead (see
          # {RpcThread#record_death}), so this never fires for one.
          def died
            raise NotImplementedError, "#{self.class} must implement #died"
          end

          # @param lines [Array<String>] the edited lain://request lines (4-2.3)
          def resend(lines)
            raise NotImplementedError, "#{self.class} must implement #resend"
          end

          # @param lines [Array<String>] the edited lain://compose lines
          # @param generation [Integer] which compose the editor is answering
          def compose_written(lines, generation)
            raise NotImplementedError, "#{self.class} must implement #compose_written"
          end

          # @param generation [Integer] which compose was unloaded unwritten
          def compose_abandoned(generation)
            raise NotImplementedError, "#{self.class} must implement #compose_abandoned"
          end

          # The human wrote lain://question, and this answers whether the
          # document parsed. It runs before the ack and inside nvim's own `:w`,
          # so it must not block AND must not raise -- a raise here would kill
          # the session over a mistyped line, which is why {QuestionView#wrote}
          # returns its failure instead.
          #
          # @param lines [Array<String>] the buffer as the human left it
          # @param digest [String] the set this buffer was opened for
          # @return [String, nil] the failure naming the offending line, or nil
          def question_written(lines, digest)
            raise NotImplementedError, "#{self.class} must implement #question_written"
          end

          # @param digest [String] the set whose buffer was unloaded unwritten
          def question_abandoned(digest)
            raise NotImplementedError, "#{self.class} must implement #question_abandoned"
          end

          # Under {#question_written}'s whole contract: runs before the ack and
          # inside nvim's own `:w`, so it may neither block nor raise. The note
          # has already been read for SHAPE by {ReviewWrite}; what is left is
          # whether this review can take it, which only the session that owns the
          # changeset knows.
          #
          # @param note [Hash] the annotation as it crossed the wire, String-keyed
          # @return [String, nil] the failure the write must fail with, or nil
          def review_annotated(note)
            raise NotImplementedError, "#{self.class} must implement #review_annotated"
          end

          # Answered rather than acked because a verdict can be INADMISSIBLE --
          # an approve standing over unreviewed hunks is the policy's call -- and
          # a refusal that arrived after a `true` would be a review recorded as
          # closed over a judgement nothing accepted.
          #
          # @param verdict [String] one of {Lain::Review::VERDICTS}
          # @return [String, nil] the failure the write must fail with, or nil
          def review_verdict_given(verdict)
            raise NotImplementedError, "#{self.class} must implement #review_verdict_given"
          end

          # The no-op Listener, so an {RpcThread} (or {Router}) built with none
          # of these reactions wired never needs an `if listener` guard.
          class Null < Listener
            # The ONE hand-off a Null must not answer with silence: nil means
            # "taken" to the editor, which clears 'modified' and reports the
            # human's text saved -- and `bufhidden = "hide"` means a
            # lain://question buffer OUTLIVES the attach that made it, so a write
            # really can arrive at a frontend wiring no view.
            UNANSWERABLE = "no question surface is wired -- nothing submitted, your text is untouched"

            # {UNANSWERABLE}'s reason for the review pair: a `nofile` review
            # buffer outlives its attach just as a question buffer does, so nil
            # here would clear 'modified' and report a note recorded by a
            # frontend with nowhere to put it. One sentence for the two because
            # it is one fact: nothing here holds a review.
            UNREVIEWABLE = "no review surface is wired -- nothing submitted, your text is untouched"

            def died = nil
            def resend(_lines) = nil
            def compose_written(_lines, _generation) = nil
            def compose_abandoned(_generation) = nil
            def question_written(_lines, _digest) = UNANSWERABLE
            def question_abandoned(_digest) = nil
            def review_annotated(_note) = UNREVIEWABLE
            def review_verdict_given(_verdict) = UNREVIEWABLE
          end
        end

        # The injected chunk is assembled from runtime.lua plus runtime/*.lua --
        # see {RuntimeLoader} for why it is concatenated rather than required.
        RUNTIME = RuntimeLoader.new.freeze

        # How long the readable-wait may block before re-checking the stop flag and
        # the render queue. The wake pipe is the real signal (posts and stop both
        # write it), so this is a pure liveness net bounding recovery from a lost
        # wakeup. It cannot serve a message the msgpack unpacker has already
        # buffered -- a timeout tick performs no read; what prevents buffered-
        # message starvation is nvim itself, which serializes blocking rpcrequests
        # (an unanswered one blocks the editor from sending another).
        BACKSTOP_SECONDS = 0.05

        # @param socket_path [String] a listening nvim's unix socket
        # @param version [String] the gem version, surfaced by :LainVersion
        # @param protocol [String, nil] the runtime.lua handshake token, or nil to
        #   digest the chunk being injected -- see {Neovim.protocol_of} and {#attach}
        # @param listener [Listener] this thread's hand-offs, bundled into one
        #   object. Every method MUST NOT block this thread: each runs inline
        #   after the microsecond ack, so a listener that needs to do real work
        #   hands off to a worker via a non-blocking queue -- never straight onto
        #   a bounded Channel, which could wedge this thread against a full
        #   render queue. Defaults to {Listener::Null}.
        # @param render_capacity [Integer] see {RenderQueue::DEFAULT_CAPACITY};
        #   overridable so a spec can saturate the queue at a scale that runs fast
        def initialize(socket_path:, version: Lain::VERSION, protocol: nil,
                       listener: Listener::Null.new,
                       render_capacity: RenderQueue::DEFAULT_CAPACITY)
          @socket_path = socket_path
          @version = version
          @protocol = protocol
          @listener = listener
          @router = Router.new(listener:)
          @command_inbox = Thread::Queue.new
          @wake_read, @wake_write = IO.pipe
          @inlet = RenderInlet.new(waker: method(:wake), capacity: render_capacity)
          @ready = Thread::Queue.new
          @stopped = @announced = false
        end

        # The exception that killed the serving loop after {#start}, or nil while
        # it lives. {Neovim#run} re-raises it so editor death is loud.
        # @return [StandardError, nil]
        attr_reader :failure

        # Commands the editor invoked and this thread enqueue-and-acked, for an
        # agent-side consumer to drain. A queue, never the session.
        # @return [Thread::Queue]
        attr_reader :command_inbox

        # Start the thread and block until it has attached and injected the runtime
        # (or re-raise whatever attach failed with, on the caller's thread).
        # @return [self]
        def start
          @thread = Thread.new { life }
          outcome = @ready.pop
          raise outcome if outcome.is_a?(Exception)

          self
        end

        # Every way IN to the editor, delegated whole to the object that owns
        # the queue-and-wake pair ({RenderInlet}, which documents each). Safe
        # from any thread: they touch only the {RenderQueue} and the wake pipe,
        # never nvim.
        def_delegators :@inlet, :post_render, :post_view, :open_compose, :open_question, :open_review,
                       :review_refused, :set_review, :review_focus, :review_settled, :open_changeset,
                       :set_thread, :set_approval

        # Stop the loop, wake it out of its select, join, and close the fds this
        # thread owns. Idempotent enough for a defensive double call.
        # @return [void]
        def stop
          @stopped = true
          wake
          @thread&.join
          @inlet.close
          [@socket, @wake_read, @wake_write].each { |io| io.close unless io.nil? || io.closed? }
        end

        private

        # The wake pipe is a SIGNAL, not a queue: one unread byte already means
        # "work pending", so a full pipe needs no further write -- and MUST not
        # get one, or a producer would block against a loop that has died (the
        # teardown-hang bug: nvim dies -> loop exits -> nobody drains the pipe ->
        # a blocking write here wedges the drainer, and run's join never returns).
        def wake
          @wake_write.write_nonblock(".")
        rescue IO::WaitWritable, IOError, Errno::EPIPE
          # Full pipe: the loop is already signalled, the byte would be redundant.
          # Closed pipe: the loop is gone and there is nobody left to wake.
        end

        def life
          attach
          @announced = true
          @ready.push(:ready)
          serve until @stopped
        rescue StandardError => e
          record_death(e)
        end

        # Before {#start} has returned, the error rides @ready and re-raises on
        # the caller's thread. After, @ready has no reader ever again -- record
        # the failure where {#failure} exposes it and tell the owner, or the
        # death would be silent and the frontend a zombie.
        #
        # Closing the {RenderQueue} HERE (not only in {#stop}) is what keeps a
        # bounded queue from re-creating the teardown-hang bug the wake pipe
        # already dodges: once this loop is dead, nobody will ever {RenderQueue#drain}
        # again, so a producer mid-post against a full queue would block
        # forever without this (see {RenderQueue#close}).
        def record_death(error)
          @failure = error
          @inlet.close
          @announced ? @listener.died : @ready.push(error)
        end

        # Built by hand rather than via {::Neovim.attach_unix} so we keep the
        # socket (to `IO.select` on) and the connection (to flush by hand). The
        # same public seam {::Neovim.attach} uses -- one blocking
        # `nvim_get_api_info` request that self-flushes -- minus the optional
        # client-info notify.
        #
        # THE INJECTION ANSWERS, and a non-nil answer is a refusal: the runtime
        # declines to load into an editor a live lain already owns. It is the
        # chunk's RETURN VALUE rather than a probe of our own because the
        # decision has to be taken INSIDE the injection -- anything asked
        # beforehand is a check-then-act with a whole round trip in the gap, and
        # what it would race is a second lain doing the same.
        def attach
          @socket = Socket.unix(@socket_path)
          @connection = ::Neovim::Connection.new(@socket, @socket)
          @client = ::Neovim::Client.from_event_loop(::Neovim::EventLoop.new(@connection))
          source = RUNTIME.source
          # Root-qualified: `Neovim` inside this body is the gem's module at
          # every other call site in this file (`::Neovim::Client` below), and
          # one spelling meaning two things is how that trap bites.
          token = @protocol || ::Lain::Frontend::Neovim.protocol_of(source)
          refusal = @client.exec_lua(source, [@version, token, @client.channel_id])
          refuse(refusal, token) unless refusal.nil?
        end

        # The two things the injection can decline, kept apart because they are
        # different news for the human: another lain is IN there, or another
        # lain's runtime was LEFT there. The token is digested off `source` rather
        # than off a second {RuntimeLoader#source} call, so it names the exact
        # bytes nvim was handed and not a re-read that could have changed
        # underneath.
        def refuse(refusal, token)
          raise SocketOwned.new(@socket_path, refusal["channel"]) if refusal["refused"] == "owned"

          raise RuntimeStale.new(@socket_path, refusal["installed"], token)
        end

        def serve
          drain_renders
          ready, = IO.select([@socket, @wake_read], nil, nil, BACKSTOP_SECONDS)
          react(ready) if ready
        end

        def react(ready)
          clear_wake if ready.include?(@wake_read)
          serve_inbound if ready.include?(@socket)
        end

        def drain_renders
          @inlet.drain(@client)
          @connection.flush
        end

        def clear_wake
          @wake_read.read_nonblock(4096)
        rescue IO::WaitReadable
          # Spurious wakeup -- the pipe had nothing buffered. Nothing to do.
        end

        def serve_inbound
          message = @client.session.next
          dispatch(message) if message.respond_to?(:sync?) && message.sync?
        end

        # Every editor command reaches this thread as an ordinary `lain_command`
        # rpcREQUEST, so nothing here handles notifications and this thread's
        # single-owner discipline is untouched. What differs is WHEN the route
        # runs relative to the ack, and {Router} owns that distinction.
        #
        # NO `lain: ` PREFIX ON ANY REFUSAL THIS THREAD ANSWERS WITH, and it is a
        # rule about the whole rail. An answered verb's refusal comes back as the
        # rpcrequest's ERROR, the lua caller catches it with `pcall` and hands it
        # to `__lain.review_refused`, and that function prepends `"lain: "`
        # itself (`65_review.lua`). Spelling it here too reached the human as
        # `lain: lain: unknown request ...`, measured against a faithful msgpack
        # peer.
        def dispatch(request)
          return respond(request.id, nil, "unknown request #{request.method_name}") unless
            request.method_name == "lain_command"

          @router.answers?(request.arguments.first) ? answer(request) : acknowledge(request)
        end

        # The ordinary path: enqueue-and-ack in microseconds, react afterwards,
        # so a slow hand-off never freezes the editor.
        def acknowledge(request)
          @command_inbox.push(request.arguments)
          respond(request.id, true)
          @router.call(request.arguments)
        end

        # The ONLY place a route runs before the ack. The answer IS the
        # response: a failure comes back as the request's error, which is what
        # makes the write fail and leaves the buffer modified with the human's
        # text. It stays OUT of the command inbox on purpose -- what a consumer
        # wants is the parsed answer set the view hands on once the document is
        # taken, not the raw lines it refused.
        #
        # THE RESCUE IS THE ORDERING'S PRICE. {#acknowledge} is structurally
        # immune to a raising listener -- the editor already has its answer --
        # and inverting that order inherits the obligation to answer anyway.
        # Measured without it: a listener raising left nvim blocked in
        # `vim.rpcrequest` for over 20 seconds, main loop frozen and the human
        # unable to type, unblocking only when the session tore down.
        #
        # It answers a REFUSAL naming the internal error rather than an ack: an
        # ack would clear 'modified' over text nothing consumed. The raise then
        # continues, so the death is still recorded and still loud.
        #
        # `ScriptError` as well as `StandardError`, because `NotImplementedError`
        # is a ScriptError -- which is exactly what {Listener}'s abstract base
        # raises, so an unimplemented hand-off walked past a StandardError-only
        # rescue and the editor was never answered AT ALL -- and because a
        # `LoadError` from an autoload inside a listener freezes the editor
        # identically. `Exception` is still refused: `Interrupt` and
        # `SignalException` must keep climbing.
        #
        # No `lain: ` prefix, for {#dispatch}'s reason: the rail prepends one.
        def answer(request)
          failure = @router.answer(request.arguments)
          failure.nil? ? respond(request.id, true) : respond(request.id, nil, failure)
        rescue StandardError, ScriptError => e
          respond(request.id, nil, "#{e.class} answering this write, so nothing was submitted and your " \
                                   "text is untouched (#{e.message})")
          raise
        end

        # Answer an inbound request, then flush by hand -- the gem otherwise defers
        # the write to the next read, which this loop may not reach until more
        # editor traffic arrives, freezing the editor on its rpcrequest.
        def respond(id, value, error = nil)
          @client.session.respond(id, value, error)
          @connection.flush
        end
      end
    end
  end
end
