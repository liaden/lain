# frozen_string_literal: true

module Lain
  module Frontend
    class Neovim
      # The question round trip's Ruby end (T9): a pending {Question::Set} opens
      # in the editor as lain://question, the human ticks boxes and writes
      # indented prose, and `:w` hands the parsed {Question::AnswerSet} on.
      #
      # {Compose} is the model for the buffer discipline -- a failure comes back
      # as a NOTICE STRING rather than a boolean, because the object that failed
      # is the one that knows why -- and it is the model for what this object
      # deliberately does NOT have. Compose has a {Compose#settle} because a
      # human pressed C-g and the prompt thread is parked waiting for the answer.
      # NOTHING WAITS FOR A QUESTION: the asking agent is parked on a
      # {Lain::Promise} somebody else resolves, so there is no half of this
      # object that blocks, and adding one would be a park with no waiter.
      #
      # THE GENERATION STAMP IS THE SET'S CONTENT DIGEST (ruling 6). Compose
      # hand-rolled a counter; content-addressing already supplies one, and the
      # digest is also how the answer is routed once it leaves here. A write
      # citing a digest this view is not holding is DROPPED -- never
      # reinterpreted against whatever is open now, which is the one way a
      # human's answer could be filed against the wrong question.
      #
      # ONE SET IS OPEN, and it is the one being answered (ruling 2). {#open}
      # REFUSES while a set is open and unanswered, rather than trusting its
      # caller not to ask: that refusal is what makes {RequestBuffer}'s clobber
      # defect ("last-writer-wins on a buffer with two writers",
      # request_buffer.rb:36-42) structurally unreachable rather than merely
      # unattempted. It was written as prose here first, and a panel probe walked
      # straight into it -- a second open re-rendered over a half-ticked
      # document, and the first set's answer could then never be written, with no
      # notice on any path. A rule the structure does not enforce is a rule the
      # next caller gets to break.
      #
      # CALL SHAPE. {#wrote} runs SYNCHRONOUSLY inside nvim's `BufWriteCmd`
      # rpcrequest, so it reports a bad document by RETURNING the failure: the
      # lua half turns that into an rpcrequest error, which leaves the buffer
      # modified with the human's text intact for them to fix. A raise past this
      # object would kill the RPC thread over a mistyped line, and nothing here
      # ever re-renders on a failure -- a re-render would overwrite the very edit
      # they have to go correct.
      #
      # THREAD CONTRACT, AND THE LOCK. {#wrote} and {#abandoned} run on the RPC
      # thread; {#open} runs on whichever thread opened the set (the reply
      # consumer's fiber, today). `@open` is the only shared state, and every one
      # of the three GUARDS it and then SWAPS it -- which the digest alone cannot
      # make safe, because the digest protects the READ and nothing protected the
      # write-back. An {#open} landing between {#wrote}'s guard and its swap was
      # posted to the editor and then destroyed by that swap: the buffer on
      # screen, `open?` false, every later write answering {STALE}, and no notice
      # on any path. That is `compose.rb:214-221`'s check-then-act at a second
      # point, and a compare-and-set is only the same race in two more bytecodes.
      #
      # So one `Mutex` spans guard-and-swap in all three, and the parse sits
      # inside it -- the parse is the window, being the slowest thing here.
      # Nothing under the lock can park: the editor post is the non-blocking
      # {RenderInlet} path -- `write_nonblock`, and a `push(..., true)` that
      # raises rather than waits -- and the rail is an unbounded, never-closed
      # queue. That is a CONSTRAINT on whoever adds the question's own post, not
      # a property of `RenderQueue`: it also has a blocking `SizedQueue(1024)`
      # shape, and posting through that one would hold this lock on a full
      # queue. The
      # notifier is called OUTSIDE it, because a notice is not state and this
      # notifier is called OUTSIDE it, because a notice is not state and this
      # object must not hold a lock across somebody's terminal.
      #
      # It never resolves a promise. {Lain::Promise} wraps an `Async::Variable`
      # and must be resolved on the reactor thread, so the answer leaves through
      # an injected rail -- a queue push, popped by the same consumer that serves
      # every other editor command.
      class QuestionView
        # The one lain:// buffer that holds a question set. Like
        # {Compose::BUFFER} it is absent from the runtime's BUFFERS set (00_constants.lua): it is
        # created when a set is opened, so a session that answers nothing never
        # grows the buffer.
        BUFFER = "lain://question"

        # No editor took the document: none is attached, or the one that was has
        # died, or it has stopped draining. One notice for all three, because
        # they are one fact from the human's side ({Compose::DETACHED}'s reason).
        #
        # Only {Detached} answers this TODAY. A live editor's refusal comes back
        # from {RenderInlet#refusable} (rpc_thread.rb:200-203), which
        # hands every refused open the same {Compose::DETACHED} sentence --
        # "composing needs an attached editor", which is the wrong sentence for a
        # question. The card that adds `open_question` to that inlet owns making
        # it answer this constant instead.
        DETACHED = "answering in the editor needs an attached editor"

        # The buffer already holds a set nobody has answered (ruling 2). Named
        # rather than boolean: what the human does next differs for the two
        # cases, so the two sentences do.
        ALREADY_OPEN = "that question set is already open in #{BUFFER} -- switch to the buffer; reopening it " \
                       "would replace whatever you have typed there".freeze
        OCCUPIED = "#{BUFFER} is holding question set %s, which nobody has answered yet -- answer or close that " \
                   "one first; this set stays in the inbox until you do".freeze

        # The buffer was closed without being written. It says what this object
        # did -- nothing was submitted -- and what is therefore still true: the
        # question is still pending, and still listed in the inbox.
        ABANDONED_NOTICE = "question buffer closed; nothing was submitted, and the set is still pending"

        # A write naming a set this view is not holding: the set was answered,
        # abandoned, or replaced by a later one. Returned as a FAILURE rather
        # than swallowed, so the write does not succeed and the human keeps the
        # text they typed.
        STALE = "this buffer answers a question set that is no longer open, so nothing was submitted -- " \
                "your text is untouched, and the set it answers is listed in the inbox"

        # Reports nowhere ({Compose::SILENT}'s shape), so no path below needs a
        # nil check on the notifier.
        SILENT = ->(_message) {}

        # Routes nowhere. Safe as a DEFAULT only because the default editor is
        # {Detached}: an unwired view can never open a set, so no write can ever
        # reach this. Production hands over a queue push.
        UNROUTED = ->(_digest, _answers) {}

        # The Null editor, and the default: an unwired view refuses the open
        # honestly rather than pretending it landed. Answers the notice saying
        # why, or nil when the document went out -- the {Compose::Detached} duck.
        module Detached
          module_function

          def open_question(_lines, _digest) = DETACHED
        end

        # No set is open. The {Sink::Null} shape: it answers no digest at all,
        # so every guard below is one message send rather than a nil check.
        module Closed
          module_function

          def answers?(_digest) = false
          def open? = false
          def digest = nil
        end

        # The set the buffer holds, and the only set a write may answer. Both
        # halves travel together because they are read together: the digest says
        # whether this write belongs here, and the set is what the parse is
        # given (ruling 5).
        Open = Data.define(:digest, :set) do
          def answers?(named) = digest == named
          def open? = true
          def document = Question::Document.unanswered(set)
        end

        # This object's own state representation, private for {Compose}'s reason
        # (compose.rb:88): nothing outside constructs one or matches on one. What
        # a caller does need -- the buffer name, the notices, and the two Null
        # seams -- stays public.
        private_constant :Open, :Closed

        # @param rpc [#open_question] the editor's inlet: takes the document's
        #   lines and the digest to stamp the buffer with, and answers why it
        #   did not land
        # @param submit [#call] where a parsed {Question::AnswerSet} goes,
        #   called with `(digest, answers)`. MUST NOT block, MUST NOT raise, and
        #   MUST NOT re-enter this view -- it is called on the RPC thread, inside
        #   the editor's write, under this object's lock -- which is why it is a
        #   queue push and never a promise resolution
        # @param notify [#call] renders a warning line ({TTY#render_warning}),
        #   the seam {Compose} takes for the same reason: an abandon is news for
        #   the human at the prompt and has no caller to return it to
        def initialize(rpc: Detached, submit: UNROUTED, notify: SILENT)
          @rpc = rpc
          @submit = submit
          @notify = notify
          @open = Closed
          @slot = Mutex.new
        end

        def open? = @open.open?

        # The digest of the set the buffer holds, or nil when none is open.
        # @return [String, nil]
        def digest = @open.digest

        # Render a pending set into the editor. Refuses while a set is already
        # open (ruling 2) and otherwise never blocks: the post is the editor's
        # non-blocking path and a refusal is the answer rather than an exception.
        #
        # The set is installed AFTER the post, and both under the lock, so a
        # refused open leaves whatever was open untouched and a write for this
        # digest can never arrive before the slot holds it.
        #
        # @param set [Question::Set]
        # @param digest [String] the Q event's digest, which stamps the buffer
        #   and which every write and abandon cites back
        # @return [String, nil] the notice saying why the set is not on screen,
        #   or nil
        # @raise [ArgumentError] on a digest that names nothing
        def open(set, digest)
          holding = Open.new(digest: named!(digest), set:)
          @slot.synchronize do
            return occupied(digest) if @open.open?

            refused = @rpc.open_question(lines_of(holding.document), digest)
            return refused if refused

            @open = holding
            nil
          end
        end

        # The editor wrote lain://question. Runs on the RPC thread, INSIDE the
        # `BufWriteCmd` rpcrequest, so the parse happens here and its refusal is
        # RETURNED -- the lua half raises that back at `:w`, leaving the buffer
        # modified with the human's own text.
        #
        # @param lines [Array<String>] the buffer as the human left it
        # @param digest [String] the set this buffer was opened for
        # @return [String, nil] the failure naming the line, or nil once the
        #   answer has been handed on
        def wrote(lines, digest)
          @slot.synchronize do
            holding = @open
            return STALE unless holding.answers?(digest)

            answers = Question::Document.parse_markdown(source_of(lines), holding.set)
            # Closed BEFORE the hand-off, so a rail that raised (it must not, and
            # today cannot -- the inbox it pushes to is never closed) could not
            # leave the set open for the human's retry to submit a second time.
            @open = Closed
            @submit.call(holding.digest, answers)
            nil
          end
        rescue Question::MalformedDocument => e
          e.message
        end

        # The editor unloaded lain://question without writing it. Also on the
        # RPC thread. Nothing is handed on, so the set stays pending and stays
        # in the inbox -- the human is told exactly that, because a buffer that
        # closes in silence reads as a submit.
        #
        # An unload that FOLLOWS a submit names a set this view no longer holds,
        # so the same digest guard keeps it quiet: reporting "nothing was
        # submitted" over an answer that was is the one lie this could tell.
        #
        # @param digest [String] the set the closed buffer was holding
        # @return [void]
        def abandoned(digest)
          closed = @slot.synchronize do
            held = @open.answers?(digest)
            @open = Closed if held
            held
          end
          @notify.call(ABANDONED_NOTICE) if closed
          nil
        end

        private

        # The digest is the whole of a write's identity (ruling 6), so a blank
        # one is refused at the door and by name: `nil == nil` is true, which is
        # exactly how a buffer opened under nothing would go on to answer a write
        # citing nothing. ArgumentError rather than a notice, because this is a
        # caller handing over a value it should not have -- the human has done
        # nothing yet.
        def named!(digest)
          return digest unless Blankness.blank?(digest)

          raise ArgumentError, "a question set opens under the digest of the event that asked it, and " \
                               "#{digest.inspect} names nothing -- every write and abandon cites that digest back, " \
                               "so a blank one would let any buffer answer any set"
        end

        # Ruling 2's refusal, and it is two facts rather than one: the human
        # switches to a buffer they already have, or finishes a different set.
        def occupied(digest)
          @open.answers?(digest) ? ALREADY_OPEN : format(OCCUPIED, @open.digest)
        end

        # The document as nvim holds it: one Array element per line, terminators
        # removed. The grammar's own line shape ({Question::Document.body_lines}),
        # so what the buffer holds and what the parse reads back are the same
        # split.
        def lines_of(document) = document.lines.map { |line| line.delete_suffix("\n") }

        # The buffer as the grammar reads it. `Array()` and `join` are both
        # doing armor work: these lines crossed msgpack from lua, so a lone
        # value is one line rather than no lines, and a line that is not a
        # String becomes text the parse can refuse BY NAME rather than something
        # that crashes it -- `join` coerces each element itself, which is why
        # there is no `map(&:to_s)` here.
        def source_of(lines) = Array(lines).join("\n")
      end
    end
  end
end
