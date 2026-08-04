# frozen_string_literal: true

module Lain
  module Frontend
    class Neovim
      # The C-g compose round trip (T15): the draft at the terminal prompt opens
      # in the editor as lain://compose, and `:w` there hands the edited text
      # back to the prompt for the human to review and submit themselves.
      #
      # THE SPLIT IS THE DESIGN. This object is two halves that must never be
      # one:
      #
      #   {#open}    the body of the C-g key action. It runs ON Reline's input
      #              loop, inside keypress dispatch, so it posts the draft and
      #              RETURNS -- it never waits for anything. Reline re-traps INT
      #              for the duration of a read, and the handler that would
      #              deliver an interrupt runs from that same loop, so a wait
      #              here has nothing left to interrupt it.
      #   {#settle}  the caller's own loop, OUTSIDE
      #              {Frontend::LineEditor#read}. This is where the waiting
      #              happens, on a plain blocking queue pop, so
      #              {CLI::PromptBreaker}'s `Break` still lands and unwinds it.
      #
      # The two are joined by {#marker}: {#open} leaves it in the prompt's
      # buffer (the seam's replacement return value), and {#settle} recognises
      # it on the way back. That also makes the gesture self-describing -- the
      # human sees, in the terminal, that a compose is in flight and what to do
      # about it.
      #
      # NOTHING IS EVER SUBMITTED THAT THE HUMAN DID NOT SEE. `:w` is the only
      # path that produces text to send; abandoning the buffer and letting the
      # bound expire both answer "no message", never the stale draft. Returning
      # the draft was this object's first design and it was wrong in exactly the
      # way the card warned about Reline's `vi_histedit`: a human who reads
      # their draft in the editor, decides against it and `:bd`s the buffer had
      # it sent unreviewed. {#draft} keeps the text for recovery instead.
      #
      # THREAD CONTRACT. {#open} and {#settle} both run on the PROMPT thread and
      # are the only writers of `@pending`/`@generation`/`@draft`. {#wrote} and
      # {#abandoned} run on the RPC thread and touch nothing but `@answers`, a
      # Thread::Queue. That one queue is the entire cross-thread surface, which
      # is why none of the rest needs a lock.
      class Compose
        # The one lain:// buffer nvim must be able to `:write`. Deliberately
        # absent from the runtime's BUFFERS set (00_constants.lua): it is created by the human's
        # own gesture, not primed at attach, so a session that never composes
        # never grows the buffer.
        BUFFER = "lain://compose"

        # {#marker}'s shape. It carries a per-compose number because the marker
        # is TEXT in the human's terminal: it lands in their scrollback, and a
        # marker pasted back from an earlier compose must not re-enter the one
        # it came from.
        #
        # The counter is per-Compose and starts at 1, so this distinguishes
        # composes WITHIN a session, not across them -- a new process's first
        # marker is byte-identical to the last one's. That is harmless (a match
        # also requires {#pending?}, and a fresh Compose is not) but it is not
        # the same claim, so it is not made.
        MARKER = "[composing in %s #%d -- write it there, then press Enter here]"

        # No editor took the draft: either none is attached, or the one that
        # was has died. Same notice for both, because they are the same fact
        # from the human's side.
        DETACHED = "composing needs an attached editor"

        # The buffer was closed without being written. Says only what this
        # object actually did -- what BECOMES of the draft is the caller's
        # choice, since it is handed to the re-prompt block, so a notice
        # promising "your draft is back" would be this object asserting
        # something it does not control.
        ABANDONED_NOTICE = "compose abandoned; nothing sent"

        # The bound expired with the editor silent. Same promise as an abandon:
        # nothing goes to the model on a path the human did not confirm.
        TIMED_OUT = "compose timed out; nothing sent"

        # How long {#settle} waits for the editor before giving up. Generous,
        # because a human is writing prose on the other end, and a backstop
        # rather than a deadline: the wait is interruptible, so Ctrl-C is the
        # fast path out and this only bounds the case where the editor died
        # without ever answering.
        GRACE = 300

        # Pushed by {#abandoned}. A Symbol can never collide with the Array of
        # lines {#wrote} pushes, so one queue carries both outcomes in order.
        ABANDONED = :abandoned
        private_constant :ABANDONED

        # Reports nowhere -- the {Frontend::LineEditor::SILENT} shape, for the
        # same reason: a Compose built without a notifier still has to do
        # something with a notice, and the Null keeps {#open} free of a nil
        # check.
        SILENT = ->(_message) {}

        # The Null editor, and the DEFAULT: an unwired Compose degrades
        # honestly rather than pretending. The duck answers a NOTICE explaining
        # why the draft went nowhere, or nil when it landed -- the
        # {Unbridged#offer} shape, chosen for the same reason: a boolean would
        # make the caller invent the sentence, and the object that failed is
        # the one that knows why. A live {RpcThread#open_compose} answers the
        # same notice once its editor has died, so "no --nvim" and "nvim went
        # away" reach the human as one fact.
        module Detached
          module_function

          def open_compose(_lines, _generation) = DETACHED
        end

        # @param rpc [#open_compose] the editor's inlet: takes the draft's lines
        #   and this compose's generation, and answers why it did not land
        # @param notify [#call] renders a warning line ({TTY#render_warning}),
        #   the same seam {Frontend::LineEditor} and {TTY::History} take
        # @param timeout [Numeric] see {GRACE}
        # @param clock [#call] monotonic seconds bounding {#settle}'s wait --
        #   {RunClock::MONOTONIC} by default, the same seam {Middleware::Timeout}
        #   and {CLI::Shutdown} take. Injectable so a spec can expire a 300s
        #   bound without waiting 300 seconds, which is the only way an example
        #   can tell that the bound is anchored at all (T33)
        def initialize(rpc: Detached, notify: SILENT, timeout: GRACE, clock: RunClock::MONOTONIC)
          @rpc = rpc
          @notify = notify
          @timeout = timeout
          @clock = clock
          @answers = Thread::Queue.new
          @draft = nil
          @generation = 0
          @pending = false
        end

        # What the human had typed when C-g was pressed, continuation markers
        # already joined out. Captured BEFORE the wait starts, which is what
        # makes both an interrupt and an abandon survivable: nothing else keeps
        # a copy once the prompt's buffer is gone.
        # @return [String, nil]
        attr_reader :draft

        def pending? = @pending

        # What this compose put in the prompt's buffer, nonce and all. nil when
        # nothing is in flight, so there is never a marker to match against.
        # @return [String, nil]
        def marker = @pending ? format(MARKER, BUFFER, @generation) : nil

        # The C-g key action's body. NEVER blocks: it hands the draft to the
        # editor through a non-blocking post and returns immediately.
        #
        # @param draft [String] every line typed so far, joined with "\n", with
        #   continuation backslashes still present (the T14 seam's contract)
        # @return [String, nil] the marker for the prompt to hold while the
        #   editor has it, or nil (prompt untouched) when nothing took it
        def open(draft)
          disarm
          @draft = joined(draft.to_s)
          @generation += 1
          refused = @rpc.open_compose(lines_of(@draft), @generation)
          return declined(refused) if refused

          @pending = true
          marker
        end

        # The caller's own loop, run OUTSIDE {Frontend::LineEditor#read} on
        # whatever the prompt returned. Anything but THIS compose's marker
        # passes straight through untouched -- and disarms, so a compose the
        # human walked away from cannot lie in wait for a later prompt.
        #
        # @param text [String, nil] the line the prompt just returned
        # @yieldparam draft [String] what the human had typed when they pressed
        #   C-g. Yielded when there is nothing to send (abandoned, or the bound
        #   expired) -- the caller's chance to prompt again rather than
        #   dispatch, WITH the text in hand. The key action replaced the
        #   prompt's buffer with the marker, so by then this is the only copy
        #   left; handing it over is what keeps "nothing is sent" from also
        #   meaning "nothing is kept". Without a block those paths answer nil,
        #   which most prompt loops read as end-of-conversation.
        # @return [String, nil] the edited text to dispatch, `text` unchanged,
        #   or the block's value
        def settle(text, &reprompt)
          return await(&reprompt) if pending? && text == marker

          disarm
          text
        end

        # The editor wrote lain://compose. Runs on the RPC thread, so it only
        # queues -- the whole point of that thread is that nothing agent-side
        # ever runs inline on it.
        # @param lines [Array<String>]
        # @param generation [Integer] which compose the editor is answering
        def wrote(lines, generation) = @answers.push([generation, Array(lines).map(&:to_s)])

        # The editor unloaded lain://compose without writing it. Also runs on
        # the RPC thread.
        # @param generation [Integer] which compose the editor is answering
        def abandoned(generation) = @answers.push([generation, ABANDONED])

        private

        # `:w` is the ONLY path that yields text to send. The other two answer
        # the caller's re-prompt, never the draft -- see the class comment.
        def await(&reprompt)
          answer = matching_answer
          return nothing_to_send(TIMED_OUT, &reprompt) if answer.nil?
          return nothing_to_send(ABANDONED_NOTICE, &reprompt) if answer == ABANDONED

          answer.join("\n")
        ensure
          disarm
        end

        # Pops until THIS compose's answer arrives or the bound expires,
        # dropping answers belonging to an earlier one.
        #
        # The generation is what makes a late answer harmless. Clearing the
        # queue at {#open} was a cross-thread check-then-act: the clear runs on
        # the prompt thread while {#wrote} pushes from the RPC thread, so a
        # write still in flight when the human pressed C-g again landed AFTER
        # the clear and the new compose settled on the old compose's text.
        # Dropping mismatches here means correctness no longer depends on that
        # ordering, and {#disarm}'s clear is hygiene rather than the only
        # defence.
        def matching_answer
          deadline = @clock.call + @timeout
          generation = nil
          answer = nil
          stale = true
          while stale
            generation, answer = @answers.pop(timeout: remaining(deadline))
            stale = !generation.nil? && generation != @generation
          end
          answer
        end

        def remaining(deadline) = [deadline - @clock.call, 0].max

        # Nothing the human confirmed, so nothing is sent -- but the draft goes
        # WITH the re-prompt. "Not dispatched" must not quietly become
        # "destroyed": the key action already replaced the prompt's buffer with
        # the marker, so this hand-off is the only route their text has back to
        # them.
        def nothing_to_send(notice, &reprompt)
          @notify.call(notice)
          reprompt&.call(@draft)
        end

        # Every path that stops a compose being in flight goes through here, so
        # "armed" and "has answers worth reading" can never disagree.
        def disarm
          @answers.clear
          @pending = false
        end

        # Explicit nil: this is {#open}'s return, and it is the key-action
        # seam's "leave the buffer alone" answer -- the notifier's own return
        # value must never leak into it.
        def declined(notice)
          @notify.call(notice)
          nil
        end

        # The prompt hands {#open} the RAW buffer, continuation backslashes
        # still present, but hands {#settle} the JOINED text -- T14's `#read`
        # strips them on the way out. Joining once here is what keeps the draft
        # we post, the draft we compare and the draft we keep for recovery all
        # one string.
        def joined(draft) = draft.gsub(Frontend::LineEditor::CONTINUED_LINE, "\n")

        # An empty draft is ONE empty line, not no lines. `"".split("\n", -1)`
        # gives `[]`, but an nvim buffer emptied to zero lines still holds one
        # empty line -- so sending `[]` would make the draft we posted and the
        # buffer nvim reports disagree about what "empty" means, and a write
        # with no edit would look like a change.
        def lines_of(draft) = draft.empty? ? [""] : draft.split("\n", -1)
      end
    end
  end
end
