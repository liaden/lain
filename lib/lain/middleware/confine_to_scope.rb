# frozen_string_literal: true

module Lain
  module Middleware
    # Holds every session's writes and commands inside the board's scope while
    # it confines: a `write_file` or `edit_file` path, or a `bash` cwd, that
    # really lands outside the scope root is refused before any guard or human
    # is asked about it. The location is resolved against the calling
    # session's own environment, as the tool will resolve it, and then judged
    # by {Session::Confined#holds?}.
    #
    # The board's scope and not the session's: a session the flip never moved
    # -- a child spawned around it -- is still judged through the board's
    # stacks, and its write into the checkout is refused like any other.
    #
    # It confines the call's NAMED location and nothing else. A command's own
    # words can still write anywhere: whether those are confined is the
    # approval ladder's question, and a human who approves one lets it write
    # wherever it says. Plan scope is not a sandbox.
    #
    # The session is read off the context duck-typed, on
    # {Approval::Escalation.barred?}'s terms: a context that is not a session
    # resolves where the process stands, as {Session::Null} does.
    class ConfineToScope < Base
      # tool name => the input field naming where it acts, and what the
      # refusal says did not happen.
      CONFINED = { "write_file" => %w[path written], "edit_file" => %w[path written],
                   "bash" => %w[cwd run] }.freeze

      # @param scope [#current] the board's scope, read per call
      def initialize(scope:)
        @scope = scope
        super()
        freeze
      end

      def call(env, &app)
        effect = env.fetch(:effect)
        field, undone = CONFINED[effect.name]
        return downstream(env, &app) unless field

        scope = @scope.current
        named = effect.input[field] || effect.input[field.to_sym]
        return downstream(env, &app) if scope.holds?(target(env.fetch(:context), named))

        env.merge(result: refusal(effect, scope, named, undone))
      end

      private

      # A location that cannot be resolved at all keeps a NUL byte no confined
      # scope holds, so it is refused rather than guessed at.
      def target(context, named)
        session = context.respond_to?(:worker_env) ? context : Session::Null.instance
        session.worker_env.resolve(named)
      rescue TypeError, ArgumentError
        "\0#{named}"
      end

      # The location is the model's own words, so it is quoted.
      def refusal(effect, scope, named, undone)
        Tool::Result.error("#{effect.name} refused: plan scope confines this session's writes and commands to " \
                           "#{scope.root}, and #{named.inspect} lies outside it. Nothing was #{undone}. Work " \
                           "inside #{scope.root}, or ask the human to leave plan scope with /mode checkout.")
      end
    end
  end
end
