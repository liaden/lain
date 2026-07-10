# frozen_string_literal: true

require "pastel"

module Lain
  module Frontend
    # The interactive approval policy: prompts a human at the terminal before a
    # tier-3 tool call is allowed to run.
    #
    # `Handler::Approving` (lib/lain/handler/approving.rb) is built to accept ANY
    # object answering `#call(effect, context) -> Boolean` as its policy, precisely
    # so that a policy which needs to print a question and read an answer does not
    # have to live in `lib/`, where output discipline forbids it. `ApproveAll` and
    # `DenyAll` stay there because they touch nothing but a Boolean; this is the
    # third option, and it belongs here because asking the question IS the
    # terminal write.
    class ApprovalPolicy
      # Anything else -- a bare "enter", "n", garbage, or EOF -- denies. Approving
      # a tier-3 shell command is the one decision in this whole harness that must
      # fail closed: an unrecognized keystroke is not consent.
      AFFIRMATIVE = /\Ay(es)?\z/i

      def initialize(output: $stdout, input: $stdin, pastel: Pastel.new)
        @output = output
        @input = input
        @pastel = pastel
      end

      # @param effect [Lain::Effect::ToolCall] the call awaiting approval
      # @param _context [Object] unused; part of the policy shape Approving calls
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

      def affirmative?(answer)
        !answer.nil? && AFFIRMATIVE.match?(answer.strip)
      end
    end
  end
end
