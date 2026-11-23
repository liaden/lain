# frozen_string_literal: true

module Lain
  class Agent
    # The hooks a {ToolRunner} calls after approval and before a call with side
    # effects runs. The list is fixed at construction; {#with} builds a longer one.
    class BeforeEffect
      # @param hooks [Array<#call>] each taking `tool:` and `context:`
      def initialize(hooks)
        @hooks = hooks.to_a.freeze
        freeze
      end

      # A hook that raises fails the call, and the hooks after it do not run.
      def call(tool:, context:)
        @hooks.each { |hook| hook.call(tool:, context:) }
        nil
      end

      # @return [BeforeEffect] this list with `hook` last
      def with(hook) = self.class.new([*@hooks, hook])

      NONE = new([])
    end
  end
end
