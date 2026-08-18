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
