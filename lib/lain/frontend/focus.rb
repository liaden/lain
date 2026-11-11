# frozen_string_literal: true

module Lain
  module Frontend
    # Whether the human is looking at the chat's window: its tmux window is the
    # one showing and a client is attached to the session. Asked about the
    # WINDOW, not the pane, because `lain up` selects the input pane and the
    # chat pane is never the active one while the human is at the cockpit.
    class Focus
      TIMEOUT = 2

      # `session_attached` is a client COUNT, so 0 is nobody watching.
      FORMAT = "\#{window_active} \#{session_attached}"

      SESSION = %w[TMUX TMUX_PANE].freeze

      # Never focused: the answer outside tmux, where nobody can be asked.
      module Never
        def self.focused? = false
      end

      # @param env [#[], #slice] the chat process's environment
      # @param shell_out [#call] builds the command, `Shell::Out.new`'s shape
      # @return [Focus, Never]
      def self.tmux(env: ENV, shell_out: Shell::Out.public_method(:new))
        env["TMUX"].to_s.empty? || env["TMUX_PANE"].to_s.empty? ? Never : new(env:, shell_out:)
      end

      # Where the chat runs decides who is asked: a cockpit inside herdr needs tmux AND herdr, because a
      # tmux client inside a herdr pane says nothing about whether herdr shows that pane; a plain herdr
      # pane asks herdr; anything else asks tmux. The resolver is asked at each probe, since the pane
      # may only be reportable later.
      class Routed
        def initialize(tmux:, resolver:, herdr:)
          @tmux = tmux
          @resolver = resolver
          @herdr = herdr
        end

        def focused?
          target = @resolver.current
          return @tmux.focused? unless target

          target.via == :cockpit ? @tmux.focused? && @herdr.call(target).focused? : @herdr.call(target).focused?
        end
      end

      # @param env [#[], #slice] the chat process's environment
      # @param resolver [#current] {Herdr::Target::Resolver}
      # @param shell_out [#call] builds the tmux command, `Shell::Out.new`'s shape
      # @param herdr [#call] target to a {Herdr::Focus}
      # @return [Routed]
      def self.for(env:, resolver:, shell_out: Shell::Out.public_method(:new),
                   herdr: ->(target) { Herdr::Focus.new(target:) })
        Routed.new(tmux: tmux(env:, shell_out:), resolver:, herdr:)
      end

      def initialize(env:, shell_out:)
        @env = env
        @shell_out = shell_out
      end

      # Every failure reads as "not focused": the caller then rings, which is
      # the safe side of not knowing.
      def focused?
        run = @shell_out.call("tmux", "display-message", "-p", "-t", @env["TMUX_PANE"], FORMAT,
                              environment: @env.slice(*SESSION), timeout: TIMEOUT)
        run.run_command
        run.exitstatus.zero? && attended?(run.stdout)
      rescue StandardError
        false
      end

      private

      def attended?(answer)
        active, attached = answer.to_s.split
        active == "1" && attached.to_i.positive?
      end
    end
  end
end
