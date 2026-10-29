# frozen_string_literal: true

module Lain
  module CLI
    class Wiring
      # Where the human types into a chat: this process's own stdin, or another
      # pane over an input socket. Every question the chat asks about that --
      # which screen it draws on, whether a notice wraps, whether a line is kept
      # in history, which socket it binds -- is one answer, read from the same
      # three facts.
      class HumanInput
        # @param input [String, nil] `--input`
        # @param attended [Boolean] whether anyone types at all
        # @param stdin [IO] what an attended chat reads when no socket is named
        # @param paths [Lain::Paths] where the socket lives
        # @param cwd [String] the project's working directory, which names the socket's directory
        def initialize(input:, attended:, stdin:, paths:, cwd:)
          @socket_name = InputSocket.named(input)
          @attended = attended
          @stdin = stdin
          @paths = paths
          @cwd = cwd
        end

        # @return [String, nil] the socket the human is on, if any
        attr_reader :socket_name

        # The pane's scrollback is the terminal's to draw, so a notice wraps to its width.
        def pane? = @attended && !socket_name.nil?

        # A pane reads the human, so the transcript scrolls in normal scrollback.
        def alternate_screen? = @attended && !pane?

        # History is a line editor's: the pane's, over a socket, or this
        # terminal's. What a pipe feeds a chat is a script, not what a human
        # would reach for at `you>`.
        def history_for(tty)
          typed = @attended && (socket_name || Frontend::StdinPump.terminal?(@stdin))
          typed ? Frontend::Intake::Discretion.new(writer: tty) : Frontend::Intake::Unrecorded
        end

        def socket_path = InputSocket.path(name: socket_name, paths: @paths, cwd: @cwd)
      end
    end
  end
end
