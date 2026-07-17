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
    class ApprovalPolicy
      # The name this surface signs its decisions with in the journal record.
      SURFACE = "tty"

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
        loop { decide(queue.dequeue) }
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

      def prompt_for(pending)
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
