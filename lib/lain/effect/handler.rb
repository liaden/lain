# frozen_string_literal: true

module Lain
  module Effect
    # Interprets an {Lain::Effect} -- the one object permitted to touch the world.
    #
    # The loop produces pure Effect data; a Handler is the algebra that gives
    # those effects meaning, so swapping the handler swaps the semantics without
    # changing the loop: {Live} runs a tool for real, {Mock} returns a canned
    # result -- same effects, two interpretations.
    #
    # It lives under {Effect} deliberately: a handler is the interpreter of the
    # effect algebra, and "Handler" alone reads as an EventHandler.
    #
    # A handler TERMINATES the tool phase's {Lain::Middleware::Stack}; it never
    # decorates another handler. Everything that may refuse, park or observe a
    # call before it runs is a middleware in front of it, so the whole path a
    # call takes is one inspectable list with the interpreter at the end.
    # {Agent::ToolRunner#dispatch} is the one place the two meet.
    class Handler
      class UnhandledEffect < Error; end

      # @param env [#fetch, #[]] the tool phase's env: `:effect`, `:tool` (the
      #   one resolution the stack judged), `:context`
      # @return [Lain::Tool::Result]
      def call(env)
        interpret(tool_call(env.fetch(:effect)), env)
      end

      private

      # A subclass's interpretation of the tool call; the base has none.
      def interpret(_effect, _env)
        raise UnhandledEffect, "#{self.class} does not interpret an effect; a subclass defines #interpret"
      end

      # An {Effect::Approval} reaching an interpreter is treated as already
      # approved: a stack with no gate in it would otherwise wedge on every
      # wrapped call. Recursive, because an Approval may wrap another.
      #
      # Anything that is not a tool call is refused loudly -- a dropped effect
      # is a turn that quietly does nothing.
      def tool_call(effect)
        return tool_call(effect.effect) if effect.approval?
        raise UnhandledEffect, "#{self.class} cannot interpret #{effect.class}" unless effect.tool_call?

        effect
      end
    end
  end
end
