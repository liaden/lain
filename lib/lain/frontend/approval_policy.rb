# frozen_string_literal: true

require "pastel"

module Lain
  module Frontend
    # The terminal surface of {Lain::Approval::Queue}: prompts a human y/N for
    # each {Approval::Queue::Pending} it draws from the queue and decides it.
    #
    # This class used to BE Gate's policy (`#call(effect, context)`, ask inline,
    # answer inline). It became a surface when the queue took over that seam
    # (I4): {Effect::Handler::Gate} now holds the queue, the gated fiber parks
    # there, and this object is just one watcher answering pendings -- which is
    # what lets a second surface (a Neovim view) coexist, first answer winning.
    # It still lives in Frontend because asking the question IS the terminal
    # write; the queue, which touches no IO, lives in lib proper.
    #
    # It is also where an {Approval::Queue::Outstanding} is RENDERED, for that
    # same reason -- a pending can carry the sensitive regions a yes would
    # release, and putting them in front of a human is a terminal write. The
    # rendering is a function of the PENDING alone, with no collaborator and no
    # state, and that is what keeps THIS class's own instances agreeing: a live
    # process builds up to three of them (the switchboard's `/approve` prompt,
    # {CLI::Repl::ApprovalSurfaces}' watch surface, {CLI::Command::Surface}'s
    # fallback) with nothing coordinating them, so an injected ledger or
    # renderer is how two would come to disagree about what has been released.
    #
    # That argument reaches no FURTHER than this class. The queue has other
    # surfaces -- {Notify}, {Neovim::ApprovalView}, {Approval::AutoSurface} --
    # and each renders (or declines to render) an outstanding release on its
    # own; agreement between THOSE is a property of the pending they all read,
    # not of anything here.
    class ApprovalPolicy
      # The name this surface signs its decisions with in the journal record.
      SURFACE = "tty"

      # And the name it signs a denial NOBODY answered with -- the terminal
      # itself failed, so the fail-closed refusal is the surface's, not a
      # person's. A distinct name because on a study bench the Journal is the
      # experiment record: signed {SURFACE}, that refusal is byte-identical to
      # someone typing `n`, so a reader counting human refusals counts a broken
      # terminal as one, and {Approval::Escalation} weighs a person's authority
      # differently from a machine's. {Approval::Queue::TIMEOUT_SURFACE} and
      # {Approval::Queue::ABANDONED_SURFACE} are the same idea for the other two
      # ways a pending gets decided by nobody -- and BESIDE THEM, in
      # {Approval::Escalation::Surfaces::AUTOMATIC}, is where this name belongs.
      # It cannot go there: that constant is evaluated while `lain/approval`
      # loads, before this class exists, so naming it there is a load-time
      # NameError. Until `AUTOMATIC` is late-bound -- a change to how every
      # surface is classified, owed to its own card -- the ladder reads this as
      # `:human`, which is harmless only because this surface can only ever
      # deny (see the note in `spec/lain/approval/escalation_spec.rb`).
      FAULT_SURFACE = "tty_fault"

      # Anything else -- a bare "enter", "n", garbage, or EOF -- denies. Approving
      # a tier-3 shell command is the one decision in this whole harness that must
      # fail closed: an unrecognized keystroke is not consent.
      AFFIRMATIVE = /\Ay(es)?\z/i
      private_constant :AFFIRMATIVE

      # `reader:` is the conductor seam: `(prompt) -> String, nil` owns BOTH
      # the terminal write and the read for one question. The exe injects
      # `-> (prompt) { conductor.read_reply(tty, prompt) }` so approval prompts
      # serialize with ask_human replies on the one stdin, the countdown
      # ticker is suppressed for the read's span, and the read parks the fiber
      # (a scheduler-routed read, so the queue's fail-closed timer can still
      # fire) -- a bare `gets` gives none of that. The default preserves the
      # standalone behavior: print to `output`, block on `input`.
      def initialize(output: $stdout, input: $stdin, pastel: Pastel.new, reader: nil)
        @output = output
        @input = input
        @pastel = pastel
        @reader = reader || method(:prompt_and_read)
      end

      # The surface loop: park on the queue, answer each arrival at this
      # terminal. Runs in its own fiber beside the Repl's answer_loop (the exe
      # hosts and stops it), which is exactly why the gated fiber's park inside
      # tool dispatch cannot deadlock the reactor -- the answerer is a sibling,
      # not the same fiber.
      def watch(queue)
        loop { answered(queue.dequeue) }
      end

      # Answer ONE pending approval: print the y/N question, read the answer,
      # decide. Answers whether this surface's decision won ({Pending#decide}'s
      # own first-answer-wins contract); an already-decided pending is a no-op.
      #
      # @param pending [Lain::Approval::Queue::Pending]
      # @return [Boolean]
      def decide(pending)
        answer = @reader.call(@pastel.yellow.bold(prompt_for(pending)))
        pending.decide(affirmative?(answer), surface: SURFACE)
      end

      private

      # One arrival, guarded -- because a raise inside a single prompt used to
      # retire this fiber for the whole session, silently. That is the failure
      # {Approval::Queue::Pending}'s own comment names, and every sibling
      # surface already guards it ({Approval::QueueSurface#swept},
      # {CLI::HumanReplies::AnswerLoop#exchange}); this is the one it is FATAL
      # for, because a `--no-nvim` chat has no second surface and every later
      # gated call would then reach nobody at all (T15).
      #
      # Fail closed and keep watching: {Effect::Handler::Gate}'s doctrine is
      # that an unanswerable gate refuses rather than wedges, so the pending
      # this surface could not ask about is denied here rather than left to the
      # clock -- signed {FAULT_SURFACE}, because nobody answered it.
      # `StandardError`, so an `Async::Stop` ending the line keeps climbing.
      #
      # THE DENIAL LANDS BEFORE THE REPORT, and the order is the whole guard.
      # Writing the reason to the terminal is the likeliest thing to raise NEXT
      # -- the failure being reported is, characteristically, the terminal
      # going away -- and a rescue that dies leaves the pending undecided with
      # this fiber dead, which is strictly worse than no guard at all. So the
      # verdict is settled first and the reporting carries its own rescue,
      # {Approval::QueueSurface#journal_fault}'s shape exactly.
      def answered(pending)
        decide(pending)
      rescue StandardError => e
        pending.deny(surface: FAULT_SURFACE)
        report(e)
      end

      # A refusal with no reason is the silence that hid T15 in the first place,
      # so this is worth attempting -- and worth never costing the denial above.
      #
      # Known seam, stated rather than wished away: under the injected reader
      # `@output` is the default `$stdout`, so this line reaches the terminal
      # beside the {Frontend::TTY} that owns the alternate screen rather than
      # through it, where the sibling surfaces render a refusal via
      # `tty.render_error`. Routing it there means holding a TTY this class has
      # never held, and the one spec that would notice is the parameter-list pin
      # below. Left as is deliberately; the bytes land on the right terminal.
      def report(error)
        @output.puts("error: the approval surface could not ask (#{error.class}: #{error.message})")
        @output.flush
      rescue StandardError
        nil
      end

      # What a yes would RELEASE leads, and the ordinary question stays
      # byte-identical behind it: a human scanning a prompt reads the sensitive
      # fact first. The sentence itself is {Approval::Queue::Outstanding#preamble},
      # which is where its rulings (the path is escaped, the bytes and the
      # detector's reason are withheld) are argued -- it is shared with the
      # editor's list so the two human surfaces cannot say different things.
      #
      # WHO is asking opens the question itself, as it opens the editor's row
      # ({Frontend::Neovim::ApprovalView#row_for}): with a fleet running, the
      # tool and its input alone cannot say whether the parent or a subagent
      # wants this. It is NOT `inspect`ed where the path and the input are,
      # because it is not model-influenced -- it is a wired name
      # ({Tools::Subagent}'s `announces_as:`) or a {Role::Catalog} key, never a
      # string a turn produced. The real question still ENDS the rendering,
      # which is the property the escaped path above relies on.
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
