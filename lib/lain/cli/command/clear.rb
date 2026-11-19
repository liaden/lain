# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/clear`: ends this chat through a restart exit (a {Quit} that leaves the input pane
      # waiting) while the cockpit's tmux server respawns the chat pane, so the next chat
      # starts on a fresh session file with the same epic mounted and the input and editor
      # panes left standing. Nothing is cleared in place: lease release, the journal close
      # and the parked-approval drop are the ordinary exit's, which is why the exit has to
      # be clean.
      class Clear
        USAGE = "/clear -- restart this chat fresh in the same cockpit"

        # @param pane [String, nil] the pane this chat runs in
        # @param restart [#call] schedules the respawn; answers false outside a cockpit
        def initialize(pane: ENV.fetch("TMUX_PANE", nil), restart: Up.method(:respawn_chat))
          @pane = pane
          @restart = restart
          freeze
        end

        def name = "clear"

        def usage = USAGE

        def returns_action?(_args) = true

        def call(_args, _env)
          raise Error, refusal unless restarting?

          :restart
        end

        private

        # Quitting without a waiter armed would leave a dead pane, so a tmux that refuses keeps the chat.
        def restarting?
          @restart.call(pane: @pane)
        rescue Up::TmuxUnavailable => e
          raise Error, "the restart could not be set up, so this chat stays: #{e.message}"
        end

        def refusal
          "/clear restarts the chat pane of a `lain up` cockpit, and this plain chat has no cockpit pane to restart " \
            "-- use /rewind 0 to empty its context in place"
        end
      end
    end
  end
end
