# frozen_string_literal: true

require "async"
require "pastel"

module Lain
  module Frontend
    # The terminal surface of {Lain::Approval::Parked::Queue}: prompts a human y/N for
    # each {Approval::Parked::Queue::Pending} it draws from the queue and decides it.
    #
    # One watcher among several, first answer winning: {Middleware::Gate}
    # holds the queue and the gated fiber parks there, which is what lets a
    # Neovim view coexist. It lives in Frontend because asking the question IS
    # the terminal write; the queue, which touches no IO, lives in lib proper.
    #
    # It is also where an {Approval::Parked::Queue::Outstanding} is RENDERED, for that
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
      # Decided with the automatic authority, so the ladder weighs it as a
      # machine's. EOF at the prompt is signed with it too: a closed stdin is
      # nobody answering.
      FAULT_SURFACE = "tty_fault"

      # Only a blank line reaches it: {Asked#takes?} holds any other line it
      # cannot read for the chat, and EOF is a fault. A blank still denies,
      # because an approval must fail closed: no keystroke is not consent.
      UNREAD = Approval::Verdict::Deny.new
      private_constant :UNREAD

      # Only "hold" holds here. Reply also reads "wait" and "stop" as a hold,
      # but at this prompt those open lines meant for the chat.
      HOLD = /\A\s*hold(?![[:alnum:]])/i
      private_constant :HOLD

      REFUSED = "y, n or hold answers the approval"
      REFUSED_NETWORK = "y, n, hold or network answers the approval"
      REFUSED_SECRETS = "y, n, hold, network or secrets answers the approval"

      ANSWERS = "[y/N] "
      NETWORK_ANSWERS = "[y/N/network] "
      SECRETS_ANSWERS = "[y/N/network/secrets] "

      # How a prompt another surface decided ends its line.
      CLOSED = "decided by %<surface>s: %<verdict>s"

      # A prompt waiting behind another has no line yet, so both what it says on
      # arriving and what it says when decided before it drew name the call.
      # The input is `inspect`ed for {CLI::Repl::ApprovalSurfaces::Arrivals}' reason:
      # a newline in a model-written command cannot break the line.
      QUEUED = "! %<call>s  -- its y/N is asked next"
      DROPPED = "! %<call>s  -- %<outcome>s"
      CALL = "%<preamble>s%<requester>s asks %<call>s"

      # The standalone reader's input when none is handed in: nothing is ever
      # typed there, so the answer is EOF and the call is denied.
      module NoTerminal
        def self.gets = nil
      end

      # The `[y/N]` prompt as the reader is handed it: its text, still a String,
      # and the call it asks about. A read the call was decided out from under is
      # STOPPED, and the line it drew is left looking live -- a human's `n` typed
      # at it became a chat prompt. Ending that line is the terminal's to write,
      # not this surface's `output`, which under the conductor's reader is a
      # stream beside the one the prompt was drawn on; so the prompt carries the
      # sentence and the terminal asks for it on the way out.
      class Asked < String
        def initialize(text, pending, wall_clock: -> { Time.now }, parts: Intake::NoParts)
          super(text)
          @pending = pending
          @parts = parts
          @wall_clock = wall_clock
          freeze
        end

        # The text as drawn, asked when the prompt reaches the head: one queued
        # behind another would otherwise carry the time it began to wait.
        def stamped = "#{@wall_clock.call.strftime("%H:%M:%S")} #{self}"

        # What the {Intake} publishes beside the text, for a pane that fits it
        # to its own rows.
        #
        # @return [Intake::Parts, Intake::NoParts]
        attr_reader :parts

        # Yields the sentence ending this prompt's line when its call was
        # decided anywhere else -- a timeout, an oracle, the editor, or another
        # prompt at this terminal -- and nothing while it is undecided. The rail
        # asks while the read is ending, which is before an answer typed at
        # THIS prompt is recorded, so a decided call is always someone else's.
        def closed
          yield "-- #{closing}" if decided_elsewhere?
        end

        # Yields the sentence a pane prints in place of the prompt when its call
        # was decided anywhere else, and nothing while it is undecided.
        def decision
          yield closing if decided_elsewhere?
        end

        # Yields the one line announcing this prompt while it waits its turn.
        def queued = yield format(QUEUED, call:)

        # Yields the line saying how its call was decided when this prompt left
        # the queue without ever drawing, and nothing while it is undecided.
        def dropped
          yield format(DROPPED, call:, outcome:) if decided_elsewhere?
        end

        # Whether `line` is an answer to this prompt at all: a verdict, or an
        # empty line. Anything else was meant for the chat -- `/goal off` while
        # a goal's iteration waits on this call, or a sentence for the model --
        # and read as a verdict it was both a denial nobody gave and a line
        # lost. A pasted block arrives as one string with its newlines, and is
        # prose whatever its lines say. The rail holds it for `you>` and asks
        # again ({Intake#read}), so it still decides nothing.
        def takes?(line)
          answer = line.strip
          return false if answer.include?("\n")

          answer.empty? || !ApprovalPolicy.read(answer, **ApprovalPolicy.offered(@pending))
                                          .is_a?(Approval::Reply::Unrecognised)
        end

        # Yields what is said after a refused line is held, so the human learns
        # the prompt is still waiting and what answers it.
        def refused
          offered = ApprovalPolicy.offered(@pending)
          yield(if offered[:secrets] then REFUSED_SECRETS
                elsif offered[:network] then REFUSED_NETWORK
                else REFUSED
                end)
        end

        # Told by the {Intake} when this prompt is drawn, which is when the
        # call's approval window starts running.
        def drawn = @pending.drawn

        # What the {Intake} publishes this prompt as: an answer a run waits on.
        def kind = :approval

        # The parked call this prompt asks about, so the rail announces one call
        # once however many prompts are waiting to ask about it.
        def about = @pending

        private

        def decided_elsewhere? = @pending.decided?

        def call
          format(CALL, preamble: @pending.outstanding.preamble, requester: @pending.label, call: @pending.ask_face)
        end

        # A call nobody answered is led by the call, since the line it ends may
        # have scrolled off; a decision names its decider and the call is above it.
        def closing = @pending.unanswered? ? "#{call}: #{outcome}" : outcome

        def verdict = @pending.verdict_face

        def outcome
          @pending.unanswered? ? @pending.closure : format(CLOSED, surface: @pending.surface, verdict:)
        end
      end

      # `reader:` is the conductor seam: `(prompt) -> String, nil` owns BOTH the
      # terminal write and the read for one question. The exe injects one that
      # routes through {CLI::Conductor}, so approval prompts take their answer
      # off the chat's one input rail, the read steps aside while an interrupt
      # countdown runs, and it PARKS the fiber (scheduler-routed, so the
      # queue's fail-closed timer can still fire). The standalone reader asks
      # `input:`, which is no terminal unless one is handed in -- stdin is the
      # pump's to read -- so a policy nobody wired denies.
      def initialize(output: $stdout, input: NoTerminal, pastel: Pastel.new, reader: nil, wall_clock: -> { Time.now })
        @wall_clock = wall_clock
        @output = output
        @input = input
        @pastel = pastel
        @reader = reader || method(:prompt_and_read)
      end

      # Runs in its own fiber beside the Repl's answer_loop, which is exactly
      # why the gated fiber's park inside tool dispatch cannot deadlock the
      # reactor -- the answerer is a sibling, not the same fiber.
      def watch(queue)
        loop { asked(queue.dequeue) }
      end

      # Answers whether THIS surface's decision won ({Pending#decide}'s
      # first-answer-wins contract); an already-decided pending is a no-op.
      #
      # @param pending [Lain::Approval::Parked::Queue::Pending]
      # @return [Boolean]
      def decide(pending)
        return false if pending.decided?

        answer = read_until_decided(pending)
        return pending.deny(surface: FAULT_SURFACE) if answer.nil?

        pending.decide(verdict_in(answer, pending), surface: SURFACE, authority: :human)
      end

      # {Approval::Reply}'s reading of a line typed at this prompt, where a hold
      # must be spelled "hold".
      #
      # @param line [String]
      # @param network [Boolean] whether the prompt offers the network answer
      # @param secrets [Boolean] whether the prompt offers the secrets answer
      # @return [Approval::Verdict::Approve, Approval::Verdict::Hold, Approval::Verdict::Deny,
      #   Approval::Reply::Unrecognised]
      def self.read(line, network: false, secrets: false)
        verdict = Approval::Reply.parse(line, network:, secrets:)
        return verdict unless verdict.is_a?(Approval::Verdict::Hold) && !line.match?(HOLD)

        Approval::Reply::Unrecognised.new(text: line.dup.freeze)
      end

      # @param pending [Approval::Parked::Queue::Pending]
      # @return [Hash{Symbol => Boolean}] the answers beyond y, n and hold its prompt offers, as {.read} takes them
      def self.offered(pending)
        network = pending.offers_network?
        { network:, secrets: network && pending.offers_secrets? }
      end

      private

      # The read is let go the moment the call is decided by anyone.
      #
      # THE READ is what needed releasing. A y/N read with no human behind it
      # never returns, so a surface that answered inline stayed inside that read
      # after the editor had already decided the call -- and every gated call
      # after it queued behind a prompt that was moot, unrendered and
      # unanswerable. Not an arrival STOLEN, an arrival HELD. The same holds for
      # `/approve`, which asks through {#decide}: its prompt waiting behind the
      # watcher's for the same call is withdrawn, with its closing line, rather
      # than drawn to ask a question whose answer cannot count.
      #
      # The race is between two things that both end at {Pending#decide}:
      # `Async::Promise#resolve` signals EVERY parked waiter and a waiter
      # arriving after resolution returns at once. Releasing the READ never
      # releases the PENDING.
      #
      # `stop` rather than a raise IS the abandonment: `Async::Stop` is not a
      # `StandardError`, so it never reaches {#asked}'s guard to journal a
      # `tty_fault` denial against a call another surface just APPROVED. It also
      # unwinds the reader through its own ensures -- the prompt withdrawn from
      # the rail, Reline restoring the terminal. `Sync` because {#decide} may be
      # called with no reactor under it.
      def read_until_decided(pending)
        Sync do |task|
          asked = Asked.new(@pastel.yellow.bold(prompt_for(pending)), pending, wall_clock: @wall_clock,
                                                                               parts: prompt_parts(pending))
          reading = task.async(finished: false) { @reader.call(asked) }
          letting_go = task.async { let_go(pending, reading) }
          reading.wait
        ensure
          letting_go&.stop
          # Stopping a task that has ended stops its children again, and the
          # reader's own task beneath it may still be writing its closing line.
          reading&.stop if reading&.running?
        end
      end

      def let_go(pending, reading)
        pending.await
        reading.stop
      end

      # Guarded, because a raise inside a single prompt used to retire this
      # fiber for the whole session, silently. This is the surface it is FATAL
      # for: a `--no-nvim` chat has no second one, so every later gated call
      # would reach nobody at all.
      #
      # Fail closed and keep watching: an unanswerable gate refuses rather than
      # wedges, so the pending is denied here rather than left to the clock,
      # signed {FAULT_SURFACE} because nobody answered it. `StandardError`, so an
      # `Async::Stop` ending the line keeps climbing.
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
      # {Approval::Parked::Queue::Outstanding#preamble}, shared with the editor's list so
      # the two human surfaces cannot say different things.
      #
      # WHO is asking opens the question itself: with a fleet running, the tool
      # and its input alone cannot say whether the parent or a subagent wants
      # this. It is NOT `inspect`ed where the path and the input are, because it
      # is not model-influenced -- a wired name or a {Role::Catalog} key, never a
      # string a turn produced. The real question still ENDS the rendering, which
      # is the property the escaped path above relies on.
      def prompt_for(pending)
        "#{pending.outstanding.preamble}#{landing(pending)}#{pending.label} " \
          "asks (#{pending.silence_face}#{judged(pending)}): " \
          "approve #{pending.call_face}? #{answers(pending)}"
      end

      def prompt_parts(pending)
        Intake::Parts.new(lead: "#{pending.outstanding.preamble}#{landing(pending)}#{pending.label} asks:",
                          call: pending.call_face, reasons: reasons_of(pending),
                          tail: "#{pending.silence_face}, approve? #{answers(pending)}")
      end

      # What y, network and secrets do, said on a row that reads secrets, so a push that fails for want of
      # network is no surprise.
      def answers(pending)
        return unconfined_answers(pending) unless pending.offers_network?

        choice = pending.choice_face

        "#{choice} #{ApprovalPolicy.offered(pending)[:secrets] ? SECRETS_ANSWERS : NETWORK_ANSWERS}"
      end

      # A bash call that reads no secrets runs unconfined under a plain y, and the row says so.
      def unconfined_answers(pending)
        return ANSWERS unless pending.tool == Approval::Parked::Queue::BASH && pending.containment.unstated?

        "#{pending.containment.choice} #{ANSWERS}"
      end

      # Why a call does not run contained ends the reasons; the phone never shows it, since it cannot answer network.
      def reasons_of(pending)
        [*pending.reasons, *pending.containment.note&.then { Approval::Parked::Queue::Reason.own(_1) }]
      end

      def judged(pending)
        reasons_of(pending).map { "; #{_1}" }.join
      end

      # Where a linked path lands, because its name says nothing about what it
      # opens. Both ends `inspect`ed, on the preamble's rule: both are
      # model-influenced.
      def landing(pending)
        target = pending.landing
        target ? "#{pending.path.inspect} -> #{target.inspect}: " : ""
      end

      def prompt_and_read(prompt)
        @output.print(prompt.stamped)
        @output.flush
        @input.gets
      end

      # A bare deny takes the reason the human already offered for this call ({Pending#offering}).
      def verdict_in(answer, pending)
        verdict = ApprovalPolicy.read(answer.strip, **ApprovalPolicy.offered(pending))
        verdict = UNREAD if verdict.is_a?(Approval::Reply::Unrecognised)
        return verdict unless verdict.denied? && verdict.note.nil? && pending.offered_reason

        Approval::Verdict::Deny.new(note: pending.offered_reason)
      end
    end
  end
end
