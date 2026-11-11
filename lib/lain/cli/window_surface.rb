# frozen_string_literal: true

require "forwardable"
require "json"

module Lain
  module CLI
    # Which surface `/fork`, `/btw` and {FleetWindows} open their windows through: herdr's tabs for a chat
    # in a plain herdr pane whose herdr has lain's plugin linked, tmux everywhere else. A cockpit's chat
    # keeps tmux, so its forks stay in the cockpit's session.
    module WindowSurface
      NOT_LINKED = "herdr: lain's plugin is not linked, so windows open in tmux only; " \
                   "lain herdr link would open them in herdr"
      PROBE_TIMEOUT = 5

      # The surface {WindowSurface.for} would choose, chosen on first use: the plugin-list probe costs a
      # process, and a chat that opens no window should never run one. With TMUX set the resolver
      # reads only a cockpit's record, and a cockpit keeps tmux, so TMUX alone answers
      # {#windows_from_here?} without a probe.
      class Lazy
        extend Forwardable

        def_delegators :surface, :window, :window_state, :popup, :rename_window, :missing_from_global_environment

        # @param resolver [#current] answers the herdr {Herdr::Target} this chat may use, or nil
        # @param notes [#puts] told once when lain's plugin is not linked
        def initialize(resolver:, notes:)
          @resolver = resolver
          @notes = notes
          @choice = Mutex.new
        end

        # @param env [#[]] the environment a window would be opened from
        # @return [Boolean]
        def windows_from_here?(env) = !env["TMUX"].to_s.empty? || surface.windows_from_here?(env)

        private

        # The probe holds the lock and its note does not: a sink may ask for the surface again.
        def surface
          chosen, told = @choice.synchronize { @surface ? [@surface, []] : choose }
          told.each { |line| @notes.puts(line) }
          chosen
        end

        def choose
          told = []
          @surface = WindowSurface.for(resolver: @resolver, notes: Collector.new(told))
          [@surface, told]
        end

        # Holds the lines {WindowSurface.for} tells, for {#surface} to pass on once the lock is free.
        Collector = Data.define(:lines) do
          def puts(line) = lines << line
        end
        private_constant :Collector
      end

      # @param resolver [#current] answers the herdr {Herdr::Target} this chat may use, or nil
      # @param notes [#puts] told once when lain's plugin is not linked
      # @param shell_out [#call] `Shell::Out.new`, or a double
      # @return [HerdrSurface, TmuxSurface]
      def self.for(resolver:, notes: Sink::Null.new, shell_out: Shell::Out.public_method(:new))
        target = resolver.current
        return TmuxSurface.new unless target&.via == :env
        return HerdrSurface.new(target:) if linked?(target, shell_out)

        notes.puts(NOT_LINKED)
        TmuxSurface.new
      end

      # @return [Boolean] whether herdr lists lain's plugin enabled; a herdr that cannot answer, or
      #   answers other than JSON (it prints "No plugins installed." as text), lists nothing
      def self.linked?(target, shell_out)
        answer = shell_out.call(target.bin, "plugin", "list", "--json", environment: target.environment,
                                                                        timeout: PROBE_TIMEOUT).tap(&:run_command)
        Shell::Out.ok?(answer) && listed?(JSON.parse(answer.stdout))
      rescue SystemCallError, Shell::Out::Timeout, JSON::ParserError
        false
      end
      private_class_method :linked?

      def self.listed?(reply)
        plugins = reply.is_a?(Hash) ? reply.dig("result", "plugins") : nil
        Array(plugins).any? { |plugin| plugin.is_a?(Hash) && plugin["plugin_id"] == HerdrSurface::PLUGIN && plugin["enabled"] != false }
      end
      private_class_method :listed?
    end
  end
end
