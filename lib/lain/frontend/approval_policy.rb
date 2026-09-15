# frozen_string_literal: true

require "async"
require "pastel"

module Lain
  module Frontend
    # The terminal surface of {Lain::Approval::Queue}: prompts a human y/N for
    # each {Approval::Queue::Pending} it draws from the queue and decides it.
    #
    # One watcher among several, first answer winning: {Middleware::Gate}
    # holds the queue and the gated fiber parks there, which is what lets a
    # Neovim view coexist. It lives in Frontend because asking the question IS
    # the terminal write; the queue, which touches no IO, lives in lib proper.
    #
    # It is also where an {Approval::Queue::Outstanding} is RENDERED, for that
    # same reason. The rendering is a function of the PENDING alone, with no
    # collaborator and no state, and that is what keeps THIS class's own
    # instances agreeing: a live process builds up to three of them with nothing
    # coordinating them, so an injected ledger or renderer is how two would come
    # to disagree about what has been released.
    #
    # That argument reaches no FURTHER than this class. Every other surface of
    # the queue renders (or declines to render) an outstanding release on its
    # own; agreement between THOSE is a property of the pending they all read.
    class ApprovalPolicy
      # The name this surface signs its decisions with in the journal record.
      SURFACE = "tty"

      # And the name it signs a denial NOBODY answered with. A distinct name
      # because the Journal is the experiment record: signed {SURFACE}, that
      # refusal is byte-identical to someone typing `n`, so a reader counting
      # human refusals counts a broken terminal as one, and
      # {Approval::Escalation} weighs a person's authority differently from a
      # machine's.
      #
      # It BELONGS in {Approval::Escalation::Surfaces::AUTOMATIC}, beside
      # {Approval::Queue::TIMEOUT_SURFACE} and ABANDONED_SURFACE, and cannot go
      # there: that constant is evaluated while `lain/approval` loads, before
      # this class exists, so naming it there is a load-time NameError. Until
      # `AUTOMATIC` is late-bound the ladder reads this as `:human`, harmless
      # only because this surface can only ever deny.
      FAULT_SURFACE = "tty_fault"

      # Anything else -- a bare "enter", "n", garbage, or EOF -- denies. Approving
      # a tier-3 shell command is the one decision in this whole harness that must
      # fail closed: an unrecognized keystroke is not consent.
      AFFIRMATIVE = /\Ay(es)?\z/i
      private_constant :AFFIRMATIVE

      # How a prompt another surface decided ends its line.
      CLOSED = "-- decided by %<surface>s: %<verdict>s"

      # The `[y/N]` prompt as the reader is handed it: its text, still a String,
      # and the call it asks about. A read the call was decided out from under is
      # STOPPED, and the line it drew is left looking live -- a human's `n` typed
      # at it became a chat prompt. Ending that line is the terminal's to write,
      # not this surface's `output`, which under the conductor's reader is a
      # stream beside the one the prompt was drawn on; so the prompt carries the
      # sentence and the terminal asks for it on the way out.
      class Asked < String
        def initialize(text, pending)
          super(text)
          @pending = pending
          freeze
        end

        # Yields the sentence ending this prompt's line when another surface
        # decided its call -- a timeout, an oracle, the editor -- and nothing
        # while it is undecided or was answered here.
        def closed
          yield format(CLOSED, surface: @pending.surface, verdict:) if decided_elsewhere?
        end

        private

        def decided_elsewhere? = @pending.decided? && @pending.surface != SURFACE

        def verdict = @pending.approved? ? "approved" : "denied"
      end

      # `reader:` is the conductor seam: `(prompt) -> String, nil` owns BOTH the
      # terminal write and the read for one question. The exe injects one that
      # routes through {CLI::Conductor}, so approval prompts serialize with
      # ask_human replies on the one stdin, the countdown ticker is suppressed
      # for the read's span, and the read PARKS the fiber (scheduler-routed, so
      # the queue's fail-closed timer can still fire). A bare `gets` gives none
      # of that; the default is the standalone behavior.
      def initialize(output: $stdout, input: $stdin, pastel: Pastel.new, reader: nil)
        @output = output
        @input = input
        @pastel = pastel
        @reader = reader || method(:prompt_and_read)
      end

      # Runs in its own fiber beside the Repl's answer_loop, which is exactly
      # why the gated fiber's park inside tool dispatch cannot deadlock the
      # reactor -- the answerer is a sibling, not the same fiber.
      def watch(queue)
        loop { answered(queue.dequeue) }
      end

      # Answers whether THIS surface's decision won ({Pending#decide}'s
      # first-answer-wins contract); an already-decided pending is a no-op.
      #
      # @param pending [Lain::Approval::Queue::Pending]
      # @return [Boolean]
      def decide(pending)
        answer = @reader.call(Asked.new(@pastel.yellow.bold(prompt_for(pending)), pending))
        pending.decide(affirmative?(answer), surface: SURFACE)
      end

      private

      # One arrival, asked about in a CHILD fiber, let go of the moment the
      # pending is decided by anyone.
      #
      # THE READ is what needed releasing. A y/N read with no human behind it
      # never returns, so a surface that answered inline stayed inside that read
      # after the editor had already decided the call -- and every gated call
      # after it queued behind a prompt that was moot, unrendered and
      # unanswerable. Not an arrival STOLEN, an arrival HELD.
      #
      # The race is between two things that both end at {Pending#decide}, which
      # is why it needs no new primitive: `Async::Variable#resolve` signals EVERY
      # parked waiter and a waiter arriving after resolution returns at once, so
      # the ask's own answer and a sibling surface's wake this fiber identically.
      # Releasing the READ never releases the PENDING.
      #
      # It belongs HERE and not in {#decide}, whose two other callers run with no
      # reactor under them, where `Async::Task.current` raises. This is the one
      # caller with both a task and a scheduler-routed reader.
      #
      # `stop` rather than a raise IS the abandonment: `Async::Stop` is not a
      # `StandardError`, so it climbs past {#asked}'s guard instead of journaling
      # a `tty_fault` denial against a call another surface just APPROVED. It
      # also unwinds the reader through its own ensures -- the countdown ticker
      # flag cleared, Reline restoring the terminal.
      #
      # `&.` for exactly one case: this method is only ever reached from {#watch}
      # inside a spawned task, but were that to stop being true
      # `Async::Task.current` raises before the assignment and the ensure would
      # dereference a nil naming a task never spawned.
      def answered(pending)
        asking = Async::Task.current.async { asked(pending) }
        pending.await
      ensure
        asking&.stop
      end

      # Guarded, because a raise inside a single prompt used to retire this
      # fiber for the whole session, silently. This is the surface it is FATAL
      # for: a `--no-nvim` chat has no second one, so every later gated call
      # would reach nobody at all.
      #
      # THE GUARD COVERS THE ASK, AND ONLY THE ASK -- the race in {#answered}
      # sits outside it, which is what keeps an abandonment from being mistaken
      # for a terminal failure. Nothing `StandardError`-shaped is reachable on
      # the three lines left uncovered: `Async::Task#async` raises nothing of
      # its own, and `Promise#await` either returns or is unwound by the
      # `Async::Stop` that ends this whole surface.
      #
      # Fail closed and keep watching: an unanswerable gate refuses rather than
      # wedges, so the pending is denied here rather than left to the clock,
      # signed {FAULT_SURFACE} because nobody answered it. That denial is also
      # what wakes {#answered}, whose park this guard has to end on every path.
      # `StandardError`, so an `Async::Stop` ending the line keeps climbing.
      #
      # THE DENIAL LANDS BEFORE THE REPORT, and the order is the whole guard:
      # writing the reason to the terminal is the likeliest thing to raise NEXT
      # -- the failure being reported is characteristically the terminal going
      # away -- and a rescue that dies leaves the pending undecided with this
      # fiber dead, which is strictly worse than no guard at all.
      def asked(pending)
        decide(pending)
      rescue StandardError => e
        pending.deny(surface: FAULT_SURFACE)
        report(e)
      end

      # A refusal with no reason is the silence that hid the session-wide
      # approval stall in the first place -- worth attempting, and worth never
      # costing the denial above.
      #
      # KNOWN SEAM: under the injected reader `@output` is the default `$stdout`,
      # so this line reaches the terminal BESIDE the {Frontend::TTY} that owns
      # the alternate screen rather than through it, where sibling surfaces
      # render a refusal. Routing it there means holding a TTY this class has
      # never held. Left as is; the bytes land on the right terminal.
      def report(error)
        @output.puts("error: the approval surface could not ask (#{error.class}: #{error.message})")
        @output.flush
      rescue StandardError
        nil
      end

      # What a yes would RELEASE leads, so a human scanning the prompt reads the
      # sensitive fact first. The sentence is
      # {Approval::Queue::Outstanding#preamble}, shared with the editor's list so
      # the two human surfaces cannot say different things.
      #
      # WHO is asking opens the question itself: with a fleet running, the tool
      # and its input alone cannot say whether the parent or a subagent wants
      # this. It is NOT `inspect`ed where the path and the input are, because it
      # is not model-influenced -- a wired name or a {Role::Catalog} key, never a
      # string a turn produced. The real question still ENDS the rendering, which
      # is the property the escaped path above relies on.
      def prompt_for(pending)
        "#{pending.outstanding.preamble}#{pending.requester} asks: " \
          "approve #{pending.tool}(#{pending.input.inspect})? [y/N] "
      end

      def prompt_and_read(prompt)
        @output.print(prompt)
        @output.flush
        @input.gets
      end

      # Fail closed: nil (EOF / closed input) short-circuits to false via safe
      # navigation, and `|| false` maps a non-match to a Boolean so the shape of
      # the verdict never depends on what the human typed.
      def affirmative?(answer)
        answer&.strip&.match?(AFFIRMATIVE) || false
      end
    end
  end
end
