# frozen_string_literal: true

require "async"
require "delegate"

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
        # @param registration [Daemon::Registration, Daemon::Registration::Null] where the daemon pushes review offers
        def initialize(human:, attended:, cockpit:, pending:, stdin:, notes:, paths:, root:, status_feed:,
                       switchboard:, commands:, registration:)
          @registration = registration
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

          producer = queue_offers(@human.socket_name ? input_socket(rail, tty) : stdin_pump(rail, tty), rail, tty)
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
                                     layers: method(:live_layers), notice: tty.method(:render_warning)).bind
        end

        def queue_offers(producer, rail, tty)
          QueueOffers.new(producer, registration: @registration, rail:, notice: tty.method(:render_warning),
                                    log: Lain::Review::Queue::Log.new(paths: @paths))
        end

        def live_layers
          in_force = @switchboard.mode_switch.layers
          Lain::Frontend::InputPane::LAYERS.select { |layer| in_force.include?(layer) }
        end

        # The chat's input producer, which also puts each review the daemon
        # pushes to the human and tells the daemon what became of it. The row
        # is marked seen here, and only once the human presses Enter at the
        # offer. Neither the request nor the row is trusted: any same-uid
        # process can send an offer, so both are checked before anything shows.
        class QueueOffers < SimpleDelegator
          REFUSED = "lain queue: an offer was dropped: %<reason>s"
          UNREPLIED = "lain queue: the daemon was not told what became of an offer: %<reason>s"
          # Nothing in the chat reads an offered request's repo_root, so no clone is looked up.
          NO_CHECKOUTS = ::Lain::Review::Queue::Checkouts.new(roots: [])
          private_constant :NO_CHECKOUTS

          # @param producer [#start, #stop] the chat's input producer
          # @param registration [#on, #call] the chat's place in the daemon's list
          # @param rail [Frontend::Intake]
          # @param log [Review::Queue::Log] where an offer the human takes marks its row seen
          # @param notice [#call] the chat's own screen
          def initialize(producer, registration:, rail:, log:, notice:)
            super(producer)
            @registration = registration
            @rail = rail
            @log = log
            @notice = notice
            @offers = []
          end

          # @param task [Async::Task] the conversation's, which each offer runs under
          # @return [self]
          def start(task)
            @task = task
            @started = __getobj__.start(task)
            @registration.on("offer") { |params| pushed(params.first) }
            self
          end

          # Offers end before the producer stops, so an Enter already typed
          # still marks its row seen; a line still being built is stopped once
          # {Lain::Frontend::Intake::OFFERS_END} passes.
          #
          # @return [void]
          def stop(**)
            @rail.end_offer
            ended_offers if Async::Task.current?
            @started&.stop(**)
          end

          private

          # Each offer waits on the human in a task of its own, under the
          # conversation rather than the fiber delivering pushes, so that fiber
          # never waits on the human and a lost daemon connection never ends
          # an offer.
          def pushed(push)
            fields = push.is_a?(Hash) ? push : {}
            @offers = @offers.reject(&:finished?) << @task.async { offered(fields) }
          end

          # An offer that fails for any other reason is refused naming no
          # field, so the sender is not left waiting out the daemon's bound.
          def offered(fields)
            mark = ::Lain::Review::Queue::Mark.load(fields["row"])
            request = ::Lain::Review::Queue::Request.load(fields["request"], checkouts: NO_CHECKOUTS)
            answer = @rail.offer(request) { |outcome| replied(fields, "outcome" => outcome.to_s) }
            mark.seen(@log, notice: @notice) if answer == :taken
          rescue ::Lain::Review::Queue::Request::Refused => e
            replied(fields, "outcome" => "refused", "field" => Utf8.escaped(e.field))
            dropped(e)
          rescue StandardError => e
            replied(fields, "outcome" => "refused")
            dropped(e)
          end

          def dropped(error) = @notice.call(format(REFUSED, reason: Utf8.escaped(error.message)))

          # A refused reply is an offer the daemon stopped waiting on, which the
          # human has nothing to do about.
          def replied(fields, said)
            @registration.call("offer.reply", said.merge("offer_id" => fields["offer_id"]))
          rescue ::Lain::Core::Client::Refused
            nil
          rescue StandardError => e
            @notice.call(format(UNREPLIED, reason: Utf8.escaped(e.message)))
          end

          def ended_offers
            deadline = clock + Lain::Frontend::Intake::OFFERS_END
            @offers.dup.each { |offer| ended(offer, deadline) }
          end

          def ended(offer, deadline)
            Async::Task.current.with_timeout((deadline - clock).clamp(0, nil)) { offer.wait }
          rescue Async::TimeoutError
            offer.stop
          end

          def clock = RunClock::MONOTONIC.call
        end
      end
    end
  end
end
