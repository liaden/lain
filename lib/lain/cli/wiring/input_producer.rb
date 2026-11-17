# frozen_string_literal: true

module Lain
  module CLI
    class Wiring
      # Apart from Wiring, so the human's side of the chat and what its pane draws change in one place.
      class InputProducer
        # @param human [HumanInput] where the human types
        # @param attended [Boolean]
        # @param cockpit [Boolean] whether the chat runs with an editor; a cockpit offers a review held for its checkout
        # @param pending [Review::Queue::Pending] where a review for this checkout is held
        # @param stdin [IO]
        # @param notes [CLI::HumanNotes]
        # @param paths [Paths]
        # @param root [String] the project root a held review is looked up by
        # @param status_feed [StatusFeed] whose published state the pane's header reads
        # @param switchboard [Switchboard] whose mode switch names the layers in force
        # @param commands [#call] the command names a pane completes, read when it connects
        def initialize(human:, attended:, cockpit:, pending:, stdin:, notes:, paths:, root:, status_feed:,
                       switchboard:, commands:)
          @human = human
          @attended = attended
          @cockpit = cockpit
          @pending = pending
          @stdin = stdin
          @notes = notes
          @paths = paths
          @root = root
          @status_feed = status_feed
          @switchboard = switchboard
          @commands = commands
        end

        # @param rail [Frontend::Intake]
        # @param tty [#render_warning] the chat's own screen
        # @return [#start] the producer the Repl starts: none for a chat nobody attends, else the input
        #   pane's socket under `--input socket:<name>`, else the chat's own stdin
        def call(rail, tty)
          return Lain::Frontend::StdinPump::Idle unless @attended

          producer = @human.socket_name ? input_socket(rail, tty) : stdin_pump(rail, tty)
          @cockpit ? @pending.offering(producer, root: @root, rail:, notice: tty.method(:render_warning)) : producer
        end

        # What the input pane draws above its prompt: the one HUD line every
        # surface shows, composed from the same published struct the tmux bar and
        # the editor's lualine read, so no surface carries a second derivation.
        # The fleet tree is not drawn here: a row appearing would reprint the
        # whole header under the cursor.
        #
        # @return [String]
        def hud_line
          Lain::StatusFeed::Reading.new(@status_feed.state).hud(now: Time.now) +
            Lain::Review::Queue::Poll.hud(paths: @paths)
        end

        private

        def stdin_pump(rail, tty)
          Lain::Frontend::StdinPump.new(rail:, screen: tty, input: @stdin, notes: @notes,
                                        cycle_key: Lain::Config.keys(paths: @paths).approval_cycle)
        end

        # Bound BEFORE the conversation starts, so a second chat on one socket is
        # refused while the first is still the only one reading the human.
        # `notice:` is the chat's own screen: a pane dropped for falling behind,
        # or a line refused for its size, is something the human has to be able
        # to read, and the pane is the one surface that cannot report it.
        def input_socket(rail, tty)
          Lain::CLI::InputSocket.new(rail:, path: @human.socket_path, header: method(:hud_line), commands: @commands,
                                     layers: method(:live_layers), notice: tty.method(:render_warning),
                                     log: Lain::Review::Queue::Log.new(paths: @paths)).bind
        end

        def live_layers
          in_force = @switchboard.mode_switch.layers
          Lain::Frontend::InputPane::LAYERS.select { |layer| in_force.include?(layer) }
        end
      end
    end
  end
end
