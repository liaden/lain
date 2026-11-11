# frozen_string_literal: true

require "json"

module Lain
  module Herdr
    Target = Data.define(:bin, :pane, :socket, :via)

    # The herdr pane a chat may report to: the binary to run, the pane id, and the socket of the
    # herdr server that owns the pane. `via` says where it came from: `:env` when the chat runs in
    # the herdr pane itself, `:cockpit` when `lain up` recorded it on the tmux session.
    class Target
      # The tmux session option `lain up` records its herdr pane in.
      OPTION = "@lain_herdr"

      VARIABLES = %w[HERDR_BIN_PATH HERDR_PANE_ID HERDR_SOCKET_PATH].freeze

      # @param env [Hash{String=>String}]
      # @return [Target, nil] the pane herdr says this process runs in
      def self.from_env(env)
        bin, pane, socket = env.values_at(*VARIABLES)
        new(bin:, pane:, socket:, via: :env) if env["HERDR_ENV"] == "1" && filled?(bin, pane, socket)
      end

      # @param text [String] what {#to_option} wrote
      # @return [Target, nil]
      def self.from_option(text)
        fields = JSON.parse(text)
        return unless fields.is_a?(Hash)

        bin, pane, socket = fields.values_at("bin", "pane", "socket")
        new(bin:, pane:, socket:, via: :cockpit) if filled?(bin, pane, socket)
      rescue JSON::ParserError
        nil
      end

      # @param values [Array<Object>]
      # @return [Boolean] true when every value is a non-empty String
      def self.filled?(*values) = values.all? { |value| value.is_a?(String) && !value.empty? }

      # @return [Hash{String=>String}] what a herdr child needs to reach this pane's server
      def environment = { "HERDR_SOCKET_PATH" => socket }

      # JSON rather than a delimiter, because a binary or socket path may hold any character.
      #
      # @return [String]
      def to_option = JSON.generate({ "bin" => bin, "pane" => pane, "socket" => socket })

      # Finds the pane this chat may report to. The candidate is looked up on every call, since
      # `lain up` may reattach from another pane; who holds a pane is asked once, since herdr
      # answers it with a process spawn and an agent that holds a pane keeps it.
      class Resolver
        # A probe that hangs must not hold a chat turn open.
        TIMEOUT = 5

        # @param env [Hash{String=>String}] the chat's environment
        # @param interactive [Boolean] false for a scripted run, which is never a herdr agent of its own
        # @param shell_out [#call] `Shell::Out.new`, or a double
        # @param notes [#puts] told once per pane when lain may not report there
        def initialize(env:, interactive:, shell_out: Shell::Out.public_method(:new), notes: Sink::Null.new)
          @env = env
          @interactive = interactive
          @shell_out = shell_out
          @notes = notes
          @holders = {}
          @asking = Mutex.new
        end

        # @return [Target, nil]
        def current
          target = candidate
          target if target && free?(target)
        end

        private

        def candidate
          return unless @interactive

          inside_tmux? ? recorded_by_cockpit : Target.from_env(@env)
        end

        def inside_tmux? = !@env["TMUX"].to_s.empty?

        # Only the cockpit's chat pane may report: `/fork`, `/btw` and fleet windows share its
        # session, and an inherited HERDR_PANE_ID may be the pane of whatever started lain.
        def recorded_by_cockpit
          pane = @env["TMUX_PANE"].to_s
          return if pane.empty? || session_option(pane, CLI::Up::Panes::CHAT) != pane

          option = session_option(pane, OPTION)
          Target.from_option(option) if option
        end

        def session_option(pane, name)
          answer = run("tmux", "show-options", "-v", "-t", pane, name, environment: { "TMUX" => @env["TMUX"] })
          answer.stdout.strip if answer && Shell::Out.ok?(answer)
        end

        # The note is written after the lock is released, so a sink that asks again reads the
        # cached verdict instead of locking twice.
        def free?(target)
          holder, note = decide(target)
          @notes.puts(note) if note
          holder.free?
        end

        # Under a lock because the reporter, focus and the window surface share 1 resolver, and
        # each thread would otherwise spawn its own `agent get` and write its own note.
        def decide(target)
          key = target.with(via: nil)
          @asking.synchronize do
            known = @holders[key]
            known ? [known, nil] : first_answer(key, target)
          end
        end

        def first_answer(key, target)
          holder = @holders[key] = Holder.read(agent_get(target))
          [holder, holder.note(target.pane)]
        end

        def agent_get(target) = run(target.bin, "agent", "get", target.pane, environment: target.environment)

        def run(*argv, environment:)
          @shell_out.call(*argv, environment:, timeout: TIMEOUT).tap(&:run_command)
        rescue SystemCallError, Shell::Out::Timeout
          nil
        end
      end

      Holder = Data.define(:name, :state)

      # Who herdr says holds a pane, read from `agent get`. Anything but lain's own name or herdr's
      # `agent_not_found` counts as held, so an answer lain cannot read never lets it report.
      class Holder
        UNNAMED = "an agent herdr does not name"

        # herdr 0.9.5 prints an agent on stdout with exit 0, and every error, `agent_not_found`
        # included, on stderr with exit 1; so the reply is whichever stream has one.
        #
        # @param answer [#stdout, #stderr, nil] the finished `agent get`, nil when it could not run
        # @return [Holder]
        def self.read(answer)
          return unreadable unless answer

          reply = answer.stdout.strip.empty? ? answer.stderr : answer.stdout
          parse(JSON.parse(reply))
        rescue JSON::ParserError
          unreadable
        end

        # @return [Holder]
        def self.unreadable = new(name: nil, state: :unknown)

        # @param reply [Object] the parsed JSON
        # @return [Holder]
        def self.parse(reply)
          return unreadable unless reply.is_a?(Hash)
          return new(name: nil, state: :free) if reply.dig("error", "code") == "agent_not_found"

          agent = reply.dig("result", "agent")
          return unreadable unless agent.is_a?(Hash)

          name = agent["agent"].to_s
          return new(name:, state: :free) if lain?(name)

          new(name: name.empty? ? UNNAMED : name, state: :held)
        end

        # @param name [String] the agent name `agent get` shows
        # @return [Boolean]
        def self.lain?(name) = name == AGENT || name.start_with?("#{AGENT}-")

        # @return [Boolean] true when lain may report to the pane
        def free? = state == :free

        # @param pane [String]
        # @return [String, nil] why lain will not report to the pane, nil when it may
        def note(pane)
          case state
          when :held then "herdr: pane #{pane} belongs to #{name}; lain will not report there"
          when :unknown then "herdr did not answer; lain will not report to #{pane} this chat"
          end
        end
      end
    end
  end
end
