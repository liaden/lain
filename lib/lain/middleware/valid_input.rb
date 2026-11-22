# frozen_string_literal: true

module Lain
  module Middleware
    # Refuses a call whose input cannot validate, as an is_error {Tool::Result}, before any guard or
    # approval rung is asked about it: a human parked on a call that will run nothing is a wasted
    # question, and a judge asked about one is a wasted model call.
    #
    # It checks shape, never safety, as {Tool::Input} does. It sits behind {RestoreIdentity} and the
    # configured tool members, so it validates the input that will actually run, and ahead of
    # {ParsedCommand}, which reads a bash call's command. A name the toolset does not hold is left to
    # the runner's own refusal. The refusal names fields the tool declares and counts unknown keys; it
    # never repeats a key or value the model sent, since it is shown back and journaled.
    class ValidInput < Base
      # @param journal [#<<] where the refusal lands as a {Telemetry::WriteRefused} decline
      def initialize(journal:)
        @journal = journal
        super()
        freeze
      end

      def call(env, &app)
        effect = ::Lain::Sensitivity::Policy.unwrapped(env.fetch(:effect))
        problem = effect.tool_call? && tool_of(env).held? && tool_of(env).invalid(effect.input)
        return downstream(env, &app) unless problem

        @journal << Telemetry::WriteRefused.new(tool_use_id: effect.tool_use_id, pattern: decline(effect))
        env.merge(result: Tool::Result.error(problem))
      end

      private

      # Names the tool only: the problem text may quote a value, and the journal must not.
      def decline(effect) = "#{CredentialPatterns::DECLINE_PREFIX}invalid_input:#{effect.name}"

      def tool_of(env) = env.fetch(:tool)
    end
  end
end
