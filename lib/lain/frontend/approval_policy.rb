# frozen_string_literal: true

require "pastel"

module Lain
  module Frontend
    # The interactive approval policy: prompts a human at the terminal before a
    # tier-3 tool call is allowed to run.
    #
    # {Effect::Handler::Gate} (lib/lain/effect/handler/gate.rb) is built to accept
    # ANY object answering `#call(effect, context) -> Boolean` as its policy,
    # precisely so that a policy which needs to print a question and read an answer
    # does not have to live in `lib/`, where output discipline forbids it.
    # `ApproveAll` and `DenyAll` stay there because they touch nothing but a
    # Boolean; this is the third option, and it belongs here because asking the
    # question IS the terminal write.
    #
    # On splitting this into a pure decision object + a separate `UserPrompt` that
    # owns the I/O: not adopted, because it would not buy the thing that would
    # justify it. The decision is ALREADY pure and IO-free -- {#affirmative?} is a
    # total function of the answer String, and the spec pins every arm of it
    # through `#call` against a real StringIO, no mocks. And the object Gate
    # actually holds must answer `#call(effect,
    # context)` by DEFINITION, and here asking the question is the terminal write
    # (the sole reason this class lives in Frontend at all); a decision object that
    # never touched IO would not be the thing Gate holds -- you would still need
    # the prompt wrapper, so the split relocates the IO into a second class rather
    # than removing it. Two objects to express what one already separates cleanly.
    # The spec drives `#call` through a StringIO, which is a genuine, cheap IO seam,
    # not a heavyweight mock the split would let us shed.
    class ApprovalPolicy
      # Anything else -- a bare "enter", "n", garbage, or EOF -- denies. Approving
      # a tier-3 shell command is the one decision in this whole harness that must
      # fail closed: an unrecognized keystroke is not consent.
      AFFIRMATIVE = /\Ay(es)?\z/i
      private_constant :AFFIRMATIVE

      def initialize(output: $stdout, input: $stdin, pastel: Pastel.new)
        @output = output
        @input = input
        @pastel = pastel
      end

      # @param effect [Lain::Effect::ToolCall] the call awaiting approval
      # @param _context [Object] unused; part of the policy shape Gate calls
      # @return [Boolean]
      def call(effect, _context)
        @output.print(@pastel.yellow.bold(prompt_for(effect)))
        @output.flush
        affirmative?(@input.gets)
      end

      private

      def prompt_for(effect)
        "approve #{effect.name}(#{effect.input.inspect})? [y/N] "
      end

      # Fail closed: nil (EOF / closed input) short-circuits to false via safe
      # navigation, and `|| false` maps a non-match to a Boolean so the shape of
      # the return value never depends on what the human typed.
      def affirmative?(answer)
        answer&.strip&.match?(AFFIRMATIVE) || false
      end
    end
  end
end
