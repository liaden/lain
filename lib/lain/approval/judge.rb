# frozen_string_literal: true

require "async"

module Lain
  module Approval
    # One bounded question to the `auto_approver` role: may this call run?
    # {Judged} asks it on the live gate path, so it waits
    # with the call unparked and must answer within {TIMEOUT} whatever the
    # child does.
    #
    # Only a lone verdict token is a verdict. Prose, a hedge or an empty answer
    # is `:defer`; an error result, a raise or the bound running out is
    # `:fault`, because then nobody judged the call at all.
    class Judge
      # The bound matters only for a hung judge: an unsure one answers defer
      # as soon as it says so.
      TIMEOUT = 30

      # A fresh root over the shared Store, so the judge reads only the call.
      ROLE = :auto_approver
      CONTEXT_MODE = :fresh

      VERDICT = /\A(approve|deny|defer)\.?\z/i
      IGNORED = ->(_cause) {}
      private_constant :VERDICT, :IGNORED

      # @param role_spawn [#never_parking] the
      #   `(role, context_mode, prompt) -> Tool::Result` seam ({Skill::RoleSpawn})
      # @param timeout [Numeric] seconds the judge may take
      def initialize(role_spawn:, timeout: TIMEOUT)
        @role_spawn = role_spawn.never_parking
        @timeout = timeout
        freeze
      end

      # `Async::TimeoutError` is a StandardError, so the bound lands in the
      # rescue with every other failure; `Async::Stop` is not, so cancelling
      # the asker still unwinds it.
      #
      # @param requester [String] who made the call
      # @param tool [String]
      # @param input [Hash]
      # @yieldparam cause [String] what made the judge fault, so the caller can journal it
      # @return [Symbol] `:approve`, `:deny`, `:defer` or `:fault`
      def call(requester:, tool:, input:, &on_fault)
        on_fault ||= IGNORED
        bounded { parse(@role_spawn.call(ROLE, CONTEXT_MODE, prompt_for(requester, tool, input)), on_fault) }
      rescue StandardError => e
        faulted(on_fault, "#{e.class}: #{e.message}")
      end

      private

      # `Sync` reuses the caller's reactor and makes one when there is none, so
      # the child always runs inside the timed task and the timeout unwinds it.
      def bounded(&) = Sync { |task| task.with_timeout(@timeout, &) }

      def parse(result, on_fault)
        return faulted(on_fault, "the judge's child returned an error: #{text_of(result)}") unless result.ok?

        match = text_of(result).strip.match(VERDICT)
        match ? match[1].downcase.to_sym : :defer
      end

      def faulted(on_fault, cause)
        on_fault.call(cause)
        :fault
      end

      def text_of(result)
        content = result.content
        content.is_a?(String) ? content : content.filter_map { |block| block["text"] }.join("\n")
      end

      def prompt_for(requester, tool, input)
        <<~PROMPT
          A tool call is requesting approval. Judge it and answer with exactly one word.

          requester: #{requester}
          tool: #{tool}
          input: #{input.inspect}

          Answer APPROVE only if the call is plainly safe and appropriate, DENY if it is
          plainly unsafe, and DEFER if you are not sure. When in doubt, DEFER -- never
          approve on doubt.
        PROMPT
      end
    end
  end
end
