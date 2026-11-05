# frozen_string_literal: true

module Lain
  module CLI
    class Wiring
      # What `auto` approval asks first, built at the first judged call, so a
      # chat that never judges never builds the judge's provider.
      class JudgeSource
        # @param backend [Backend]
        # @param journal [#<<] the session file and never the tee, since a live
        #   view would read the judge's payment as the chat's turn
        # @param config [Config] whose judge timeout bounds the judge
        # @return [JudgeSource]
        def self.for(backend, journal:, config:)
          new(provider: -> { backend.provider(requester: Approval::Judge::ROLE) }, model: backend.model,
              slots: backend.slots, journal:, timeout: config.judge_timeout)
        end

        # @param provider [#call] builds the provider the judge asks through
        # @param model [String]
        # @param slots [Prompt::Slots] what the judge's sealed prompt renders from
        # @param journal [#<<] the session file, where the judge's request and payment are recorded
        # @param timeout [Numeric] seconds the judge may take
        def initialize(provider:, model:, slots:, journal:, timeout: Config::DEFAULT_JUDGE_TIMEOUT)
          @provider = provider
          @built = { model:, slots:, journal:, timeout: }
        end

        # A judge that cannot be built is a fault like any other the judge has,
        # so the call goes to a human rather than out of the rung as a raise.
        #
        # @param question [Hash] the requester, tool and input being judged
        # @yieldparam why [String] what went wrong, when the judge faults
        # @return [Symbol] the judge's verdict, or `:fault`
        def call(**question, &on_fault)
          @judge ||= Approval::Judge.new(provider: @provider.call, **@built)
          @judge.call(**question, &on_fault)
        rescue StandardError => e
          on_fault&.call("#{e.class}: #{e.message}")
          :fault
        end
      end
    end
  end
end
