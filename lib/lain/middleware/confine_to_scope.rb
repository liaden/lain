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
    # In plan scope it confines the call's NAMED location and nothing else. A
    # command's own words can still write anywhere: whether those are confined
    # is the approval ladder's question, and a human who approves one lets it
    # write wherever it says. Plan scope is not a sandbox.
    #
    # A child held to its lease reads the words too ({Reach}): every stage
    # after a `cd` runs where it lands, so a `cd` out of the lease is refused
    # whatever follows it, and so is a path the command writes there. A read
    # elsewhere, and a command whose paths cannot be named, stay the ladder's.
    #
    # The session is read off the context duck-typed, on
    # {Approval::Escalation.barred?}'s terms: a context that is not a session
    # resolves where the process stands, as {Session::Null} does.
    class ConfineToScope < Base
      # tool name => the input field naming where it acts, and what the
      # refusal says did not happen. `epic_write` is left out by name: an epic's
      # artifacts are planning documents the epic home owns, and planning is
      # what plan scope exists for.
      CONFINED = { "write_file" => %w[path written], "edit_file" => %w[path written],
                   "bash" => %w[cwd run] }.freeze

      # What a session held in plan scope is told. Each wording names the
      # tool, the root, the location as written and what did not happen.
      PLAN = "%<tool>s refused: plan scope confines this session's writes and commands to %<root>s, and " \
             "%<named>s lies outside it. Nothing was %<undone>s. Work inside %<root>s, or ask the human to leave " \
             "plan scope with /mode checkout."

      # What a child held to the directory it was leased is told: no mode
      # lifts that, so pointing it at one would be advice it cannot take.
      LEASE = "%<tool>s refused: this session's writes and commands are confined to %<root>s, the directory it " \
              "was leased, and %<named>s lies outside it. Nothing was %<undone>s. Work inside %<root>s, and put " \
              "anything meant for elsewhere in your answer instead."

      # A write to one of these reaches the process's own streams, never a
      # file in any tree.
      STREAMS = %r{\A/dev/(?:null|stdout|stderr|tty|fd/\d+)\z}

      # The paths a command names that a lease must also hold: each `cd`
      # target and each path it writes. An opaque command still names what
      # came before the point it turned opaque, resolved where it runs, so
      # `echo x > /out && cd - && ls` is held to its first stage; what follows
      # is the ladder's. An expansion anywhere leaves the whole command to the
      # ladder, since the parse is then read as a whole and names nothing.
      Reach = Data.define(:home) do
        # @param command [String, nil] as the model wrote it
        # @param cwd [String] absolute, where the command starts
        # @return [Array<String>] absolute
        def call(command, cwd)
          Shell::Named.of(command.to_s, cwd:, home:).paths
                      .select { _1.directory || _1.written }.map(&:resolved).grep_v(STREAMS)
        end
      end

      CWD_ONLY = ->(_command, _cwd) { [] }

      # @param scope [#current] the scope judged against, read per call
      # @param wording [String] the refusal, {PLAN} or {LEASE}
      # @param reach [#call] `(command, cwd) -> paths` the scope must hold
      #   besides a command's cwd
      def initialize(scope:, wording: PLAN, reach: CWD_ONLY)
        @scope = scope
        @wording = wording
        @reach = reach
        super()
        freeze
      end

      def call(env, &app)
        effect = env.fetch(:effect)
        field, undone = CONFINED[effect.name]
        return downstream(env, &app) unless field

        scope = @scope.current
        named = effect.input[field] || effect.input[field.to_sym]
        outside = locations(effect, named, target(env.fetch(:context), named)).find { !scope.holds?(_2) }
        return downstream(env, &app) unless outside

        env.merge(result: refusal(effect, scope, outside.first, undone))
      end

      private

      def locations(effect, named, landed)
        Enumerator.new do |out|
          out << [named, landed]
          reached(effect, landed).each { out << [_1, _1] }
        end
      end

      def reached(effect, cwd)
        effect.name == "bash" ? @reach.call(effect.input["command"] || effect.input[:command], cwd) : []
      end

      # A location that cannot be resolved at all keeps a NUL byte no confined
      # scope holds, so it is refused rather than guessed at.
      def target(context, named)
        session = context.respond_to?(:worker_env) ? context : Session::Null.instance
        session.worker_env.resolve(named)
      rescue TypeError, ArgumentError
        "\0#{named}"
      end

      # Inspected, so a location holding a space or a newline still reads as
      # one value.
      def refusal(effect, scope, named, undone)
        Tool::Result.error(format(@wording, tool: effect.name, root: scope.root, named: named.inspect, undone:))
      end
    end
  end
end
