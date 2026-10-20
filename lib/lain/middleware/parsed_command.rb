# frozen_string_literal: true

require "delegate"

module Lain
  module Middleware
    # Parses a bash call's command once, at the head of a gated stack, so each
    # member and ladder rung below reads one {Shell::Named} instead of parsing
    # the same text again and, with its own spelling of the directory, naming
    # different paths.
    #
    # The ladder is asked a context rather than the env, so the parse also rides
    # on the context, read by respond_to? as {Approval::Escalation::Noted} is.
    class ParsedCommand < Base
      # @!attribute parsed_command [Shell::Named]
      class Parsed < SimpleDelegator
        attr_reader :parsed_command

        def initialize(context, named)
          super(context)
          @parsed_command = named
        end
      end

      # @param context [Object]
      # @param effect [Lain::Effect]
      # @param home [String, nil]
      # @return [Shell::Named] the parse a {ParsedCommand} left on the context, else a fresh one
      def self.named_in(effect, context, home:)
        context.respond_to?(:parsed_command) ? context.parsed_command : Shell::Named.for_call(effect, context, home:)
      end

      # @param home [String, nil] for a `~` in the command, as the session's path policy reads it
      def initialize(home: nil)
        @home = home
        super()
        freeze
      end

      def call(env, &app)
        effect = ::Lain::Sensitivity::Policy.unwrapped(env.fetch(:effect))
        return downstream(env, &app) unless effect.tool_call? && effect.name == "bash"

        context = env[:context]
        named = Shell::Named.for_call(effect, context, home: @home)
        # A caller threading no session has no context to carry it.
        downstream(env.merge(named:, context: context && Parsed.new(context, named)), &app)
      end
    end
  end
end
