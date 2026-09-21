# frozen_string_literal: true

require "async"
require "io/console"
require "socket"

module Lain
  module Frontend
    # `lain input`: the pane the human types in while the chat scrolls its
    # transcript somewhere else. It is a {InputRail} PRODUCER at the far end of
    # a Unix socket, and it holds nothing of the chat -- no registry, no agent,
    # no session. What it draws, it was told.
    #
    # IT RUNS THE SAME RAIL IT FEEDS. A local {InputRail} mirrors the chat's
    # publications and a local {StdinPump} serves them, so the line editor, the
    # history, the completion menu and the typeahead rule are the ones a plain
    # chat has rather than a second implementation of them. The generation on
    # the wire is the CHAT's: a line only ever leaves here as the answer to the
    # prompt it was read at, because the local rail has already held anything
    # typed before that prompt drew.
    #
    # THE HEADER IS THE CHAT'S TOO, and it arrives with the prompt. A header
    # that changes while nothing has been typed republishes the prompt, so an
    # idle `you>` shows a live HUD with no keypress; one that changes under a
    # half-typed line waits for the next prompt, because redrawing Reline's
    # prompt mid-line needs a private API and would cost the human their words.
    #
    # ITS OWN GEOMETRY IS THE ONE THING IT WATCHES RATHER THAN IS TOLD. A pane
    # resized under itself loses the header off the top and nothing upstream can
    # see that happen, so it polls {Geometry} and repaints what it last drew.
    #
    # A stream that simply ends is the chat restarting, and the pane reconnects
    # to the same path. Only the chat's `closed` goodbye ends the pane.
    class InputPane
      # The layers this surface acts on, asked for by name: `vi` chooses the
      # editor's keymap and `notify` rings an arrival. Enumerated rather than
      # shipping a {Mode::LayerSet} over the wire, since those two are the whole
      # of what a pane can do with one.
      LAYERS = %i[vi notify].freeze

      # How long between connection attempts, how often the pane says whether
      # anything has been typed at the prompt it draws, and how often it looks
      # at its own geometry.
      TICK = 0.1

      # The pane that has said nothing yet about what it is drawing.
      NOTHING_DRAWN = { "generation" => 0 }.freeze

      # Back to column 0 and erase to the end of the row. Written here rather
      # than taken from tty-cursor because it is two bytes of meaning and the
      # pane must not depend on a screen library to redraw its own header.
      CLEAR_ROW = "\r\e[K"

      # @param path [String] the chat's input socket, from {CLI::InputSocket.path}
      # @param tty [Frontend::TTY] the pane's own terminal; it owns this pane
      #   and nothing else writes to it
      # @param input [IO] the keyboard
      # @param commands [Array] filled from the chat's `context` frame, and
      #   BORROWED by the completion sources the terminal was built with
      # @param layers [Array] the same, for the layers in force
      # @param tick [Numeric] the reconnect, touch-report and repaint cadence,
      #   in seconds
      # @param geometry [#moved!] the pane's own window, measured off the
      #   terminal it was handed; {Geometry::Blind} where there is none
      def initialize(path:, tty:, input: StdinPump.process_input, commands: [], layers: [], tick: TICK,
                     geometry: Geometry.for(input))
        @path = path
        @tty = tty
        @input = input
        @commands = commands
        @layers = layers
        @tick = tick
        @geometry = geometry
        @rail = InputRail.new(screen: tty)
        @drawn = NOTHING_DRAWN
        @reported = nil
        @client = nil
        @quit = false
        @pump = StdinPump::Idle
        @relay = Relay.new
        @rail.route(@relay)
      end

      # The pane a `lain input` process is, terminal and all: the completion
      # sources and the layer thunk read the same arrays the pane fills from the
      # chat, so a `/command` learned at connect completes at the next prompt.
      #
      # @return [InputPane]
      def self.open(path:, output: $stdout, input: StdinPump.process_input, **terminal)
        commands = []
        layers = []
        tty = TTY.new(channel: Lain::Channel.new, output:, input: StdinPump.keys(input),
                      completion_sources: Completion::Sources.new(skills: commands),
                      layers: -> { layers }, **terminal)
        new(path:, tty:, input:, commands:, layers:)
      end

      # Draw, type, send, until the chat says goodbye.
      #
      # @return [Integer] the process's exit status
      def run
        CLI::Signals.new(sink: @relay).guarding do
          Sync do |task|
            relaying = task.async { @relay.each { |name| signal(name) } }
            # The screen is claimed only once there is something to draw on it:
            # a pane waiting for a chat that has not started yet says so on the
            # ordinary scrollback, where the human can still read it.
            @client = greeted(task)
            @tty.run { conversing(task) } unless @client.nil?
          ensure
            relaying&.stop
          end
        end
        0
      ensure
        @relay.dispose
      end

      private

      # A signal the pane's traps or its line editor recorded. With a chat to
      # carry it to, it goes there -- the run a Ctrl-C means is the chat's, and
      # nothing here is interrupted. With NO chat, the human is interrupting the
      # only thing in front of them, which is this pane, and it ends.
      def signal(name)
        return @quit = true if @client.nil?

        emit(@client, { "v" => "signal", "name" => name.to_s })
      end

      # The first connection, and the one line said while waiting for it.
      # Answers nil when the human gave up on it instead.
      def greeted(task)
        first = connect
        return first if first

        @tty.print_prompt("waiting for a lain chat on #{@path} -- Ctrl-C to leave\n")
        connected(task)
      end

      def conversing(task)
        pumping = start_pump(task)
        Enumerator.produce { attached(task) }.lazy.find { |farewell| farewell }
      ensure
        # The pump is a child of this task, and a task waits for its children:
        # left running, the goodbye below would never return.
        pumping&.stop
      end

      def start_pump(task)
        @pump = StdinPump.new(rail: @rail, screen: @tty, input: @input)
        @pump.start(task)
      end

      # One connection's life. A frame stream that ends without a goodbye is the
      # chat going away, which is not this pane's cue to -- but a human who
      # signalled while nothing was connected is.
      def attached(task)
        client = @client ||= connected(task)
        return :quit if client.nil?

        serving(task, client)
      ensure
        stop_drawing
        @client = nil
        close_quietly(client)
      end

      # Waits for the chat, and gives up the moment the human says to. Answers
      # the connection or nothing, and never the sleep's own value: a truthy
      # non-socket here claimed the screen and then died reaching for `#close`.
      def connected(task)
        Enumerator.produce { connect }.lazy.find { |client| client || waited(task) }
      end

      # A tick between attempts, and the human's word that they are done waiting.
      def waited(task)
        task.sleep(@tick)
        @quit
      end

      def connect
        UNIXSocket.new(@path)
      rescue SystemCallError
        nil
      end

      def serving(task, client)
        reporting = task.async { ticking(task, client) }
        frames(client).find { |frame| received(task, client, frame) == :closed }
      rescue IOError, SystemCallError
        nil
      ensure
        reporting&.stop
      end

      def frames(client)
        Enumerator.produce { client.gets }.lazy
                  .take_while { |line| !line.nil? }
                  .filter_map { |line| CLI::InputSocket::Codec.load(line) }
      end

      # A frame kind this pane does not know is dropped: an older pane against a
      # newer chat draws what it understands rather than dying.
      def received(task, client, frame)
        case frame["v"]
        when "prompt" then prompted(task, client, frame)
        when "unpublished" then stop_drawing
        when "context" then @commands.replace(Array(frame["commands"]))
        when "closed" then :closed
        end
      end

      def prompted(task, client, frame)
        @layers.replace(Array(frame["layers"]).map(&:to_sym))
        return if drawing_already?(frame)

        redraw(task, client, frame)
      end

      # The THIRD thing that can call for a draw, and neither of the other two
      # can stand in for it: the frame the chat would republish is byte-identical,
      # so the chat's own latch suppresses it and {#drawing_already?} would drop
      # it here. Measured before this existed -- the header stayed gone from a
      # restored pane until the next ask completed, while the status feed carried
      # the right string throughout.
      #
      # Mid-edit the repaint is declined for the reason a changed header is -- a
      # repaint is a fresh read, and a fresh read starts from nothing -- but not
      # lost, which is what {Geometry}'s latch buys: a human who discards the
      # half-typed line gets the header back on the next tick.
      def repainted(task, client)
        moved = @geometry.moved!
        frame = @drawn
        redraw(task, client, frame) if moved && !frame.equal?(NOTHING_DRAWN) && !editing?
      end

      # Whatever called for it, a draw replaces the read that was open: the
      # header goes out through {#over_the_prompt}, the one writer, and the
      # editor reopens under it. ANY draw settles a pending geometry change, so
      # the latch is cleared here rather than where it is read.
      def redraw(task, client, frame)
        @geometry.painted
        stop_drawing
        @drawn = frame
        @reported = nil
        @drawing = task.async { drawn(client, frame) }
      end

      # The same prompt with a new header is redrawn only while the editor is
      # empty: a redraw is a fresh read, and a fresh read starts from nothing.
      def drawing_already?(frame)
        return false unless @drawn["generation"] == frame["generation"]

        frame["header"] == @drawn["header"] || editing?
      end

      # Whether the human has words in the editor right now. Off a terminal
      # there is no editor to have them in -- a stream's next line is its next
      # line whatever prompt it lands at -- so nothing is ever mid-edit there.
      def editing? = StdinPump.terminal?(@input) && !@pump.untouched?(@rail.published)

      # The header is printed HERE rather than composed into the prompt: the
      # line editor fixes its prompt to one line, and the chat's own renderer
      # has already decided what the row above it says.
      def drawn(client, frame)
        return counted(client, frame) if frame["kind"] == "countdown"

        over_the_prompt(frame["header"])
        line = @rail.read(frame["kind"].to_sym, frame["text"].to_s, header: frame["header"].to_s)
        emit(client, line.nil? ? { "v" => "eof" } : answer(line, frame))
      end

      # The cursor is wherever the read this frame replaced left it -- mid-row,
      # after a `you> ` the editor had already drawn -- so the row is taken back
      # before the header goes on it. Without this a redraw printed
      # `you> ❄ fleet:4 inbox:0` as one line and cost the pane a row of its six.
      def over_the_prompt(header)
        return if header.to_s.empty?

        @tty.print_prompt("#{CLEAR_ROW}#{header}\n")
      end

      def answer(line, frame) = { "v" => "line", "text" => line, "generation" => frame["generation"] }

      # The countdown owns the pane while it is up, exactly as it owns the
      # bottom line of a plain chat's screen: no line editor opens under it, and
      # each offered key leaves as the signal it names.
      def counted(client, frame)
        keys = frame["keys"].to_h { |key, name| [key, name.to_sym] }
        Keys.new(input: @input, tick: @tick, terminal: @pump)
            .offering(@tty, "#{CLEAR_ROW}#{frame["header"]}\n#{frame["text"]}") do |pressed|
              emit(client, { "v" => "signal", "name" => keys[pressed].to_s }) if keys.key?(pressed)
            end
      end

      def stop_drawing
        @drawing&.stop
        @drawing = nil
        @drawn = NOTHING_DRAWN
      end

      # The two things the pane has to notice on its own clock, neither of which
      # anything upstream can see: whether the human has typed at the prompt it
      # drew, and whether its own window has moved under it. The `loop` needs no
      # break -- the fiber is stopped with the connection.
      def ticking(task, client)
        loop do
          touch(client)
          repainted(task, client)
          task.sleep(@tick)
        end
      end

      # The rail asks its producers whether anything has been typed at a drawn
      # prompt before it takes the terminal for an answer. The chat's rail
      # cannot see this keyboard, so the pane says.
      def touch(client)
        untouched = !editing?
        return if @drawn.equal?(NOTHING_DRAWN) || untouched == @reported

        @reported = untouched
        emit(client, { "v" => "touch", "generation" => @drawn["generation"], "untouched" => untouched })
      end

      # A frame with nowhere to go is dropped: between the chat going away and
      # the reconnect there is no chat to tell.
      def emit(client, frame)
        return nil if client.nil?

        client.write(CLI::InputSocket::Codec.dump(frame))
        client.flush
      rescue IOError, SystemCallError
        nil
      end

      def close_quietly(client)
        client&.close unless client.nil? || client.closed?
      rescue IOError, SystemCallError
        nil
      end
    end

    class InputPane
      # Reopened rather than nested, tty.rb's idiom.

      # Where a signal is RECORDED, so that what a trap does here is the one
      # nonblocking pipe write {CLI::Shutdown::Ingress} exists to be -- a socket
      # write in trap context is exactly what that class's rules forbid. A live
      # fiber reads each recorded signal back out and sends it to the chat, the
      # same "record in the trap, route from a fiber" shape a plain chat's idle
      # `you>` uses.
      class Relay
        def initialize = @ingress = CLI::Shutdown::Ingress.new

        # Trap context: one `write(2)`.
        def signal(name) = @ingress.signal(name)

        # Nothing here runs an ask -- this pane holds no agent and no session
        # -- so a `/stop` stays the line it is and travels to the chat, whose
        # own rail is the one that knows whether there is a run to stop.
        def ask_in_flight? = false

        # Each recorded signal, until the relay retires.
        def each(&block)
          Enumerator.produce { @ingress.read }.lazy.take_while { |name| name != :retired }.each(&block)
        end

        def dispose = @ingress.dispose
      end

      # The pane's own window, as an ioctl on its own terminal answers for it.
      # tmux resizes a pane by changing exactly this and saying nothing else --
      # its `window-layout-changed` hook is a bare `resize-pane` -- so this is
      # the only witness the pane has that its rows moved.
      #
      # NOT a SIGWINCH trap and NOT `TTY::Screen`, both foreclosed before this
      # existed: `Signal.trap` REPLACES rather than chains, so trapping WINCH
      # would take the line editor's own resize redraw away, and `TTY::Screen`
      # shells out `tput` whenever no ioctl answer is set -- two subprocess
      # spawns per read, measured. An ioctl on a held descriptor costs neither.
      #
      # A LATCH rather than a diff against the last size painted at, because the
      # gesture this exists for ENDS WHERE IT STARTED: a poller comparing sizes
      # across a squeeze and a restore reads the size it read before and finds
      # nothing to do. Remembering that something moved survives that, and the
      # pane clears the latch when it paints.
      class Geometry
        # A pane with nothing to measure: `lain input` over a pipe, a spec's
        # StringIO. Nothing can resize it, so nothing ever repaints and no caller
        # has to ask whether it has a window. `nil` rather than `false` for one
        # reason only -- `Naming/PredicateMethod` fires on a bare `false` body
        # under a name without a `?` -- and nothing can tell: the one call site
        # reads truthiness.
        module Blind
          def self.moved! = nil
          def self.painted = nil
        end

        # @param io [IO] the pane's terminal
        # @return [Geometry, Blind] whichever can answer for this one
        def self.for(io) = StdinPump.terminal?(io) && io.respond_to?(:winsize) ? new(io) : Blind

        def initialize(io)
          @io = io
          @seen = size
          @moved = false
        end

        # Whether the window has moved since the pane last painted AND has since
        # stopped moving. Bang, not a plain predicate: LOOKING advances the
        # "since", so two looks in one tick are two questions.
        #
        # `now == @seen` is the settle half, and the whole difference between this
        # and a naive poller -- a drag arrives as a RUN of sizes, each repaint
        # costs a six-row pane a row, so a run is worth one repaint at its end.
        def moved!
          now = size
          return false if now.nil?

          @moved ||= !@seen.nil? && now != @seen
          settled = @moved && now == @seen
          @seen = now
          settled
        end

        # The pane painted, so whatever the window did is on the screen now.
        def painted = @moved = false

        private

        # A look that cannot answer is NO INFORMATION, not a new size, and the
        # difference is not cosmetic: read as a size, a terminal going away is a
        # differing look followed by two matching ones -- the settle rule's own
        # shape -- so a dying tty earned itself one repaint, into a write on the
        # descriptor that had just gone. `[0, 0]` IS an answer: `PTY.spawn` opens
        # at it, and the real size arriving after is a genuine change, harmlessly
        # so because nothing is drawn that early.
        def size
          @io.winsize
        rescue IOError, SystemCallError
          nil
        end
      end

      # Single keys off the pane's own terminal, for the one prompt that is
      # answered with a keystroke rather than a line. The raw window is opened
      # ONCE around the whole countdown -- a per-read bracket would leave a key
      # pressed between reads cooked, and echo would bleed it onto the screen --
      # and the mode in force is given back however the window ends.
      #
      # THE WINDOW OPENS ONLY ONCE THE LINE EDITOR IS OUT OF IT, which is the
      # other half of "the countdown owns the pane". A countdown arrives while
      # a read is open at the prompt it replaces -- a Ctrl-C at a parked
      # `[y/N]` is exactly that -- and that read unwinds on the pump's fiber
      # AFTER this frame is handled, putting the mode it found back as it goes.
      # So the pump's own hold on the terminal is taken first.
      class Keys
        # @param input [IO] the keyboard this window reads single keys from
        # @param tick [Numeric] how often a nonblocking look is taken
        # @param terminal [#exclusively] the pump that owns this terminal; the
        #   idle one, which holds nothing, for a pane with no reader behind it
        def initialize(input:, tick:, terminal: StdinPump::Idle)
          @keys = StdinPump.keys(input)
          @tick = tick
          @terminal = terminal
        end

        # What the human is told when the line editor would not let go in time.
        # It names the CONSEQUENCE, and the consequence is that a key can be
        # lost: the degraded window switches the terminal raw while the editor
        # is still reading the same descriptor, so a keypress can be taken by
        # the editor and reach the chat as a typed line rather than as the
        # signal it named. That is the race the hold removes, deliberately
        # preferred here over refusing to read at all -- so the words have to
        # tell the human to press again.
        UNHELD = "the input pane could not take the terminal from its line editor: " \
                 "a key pressed now may be swallowed or arrive as text -- press it again."

        # @param screen [Frontend::TTY] where the window's words are drawn
        # @param words [String] the countdown as the chat composed it
        # @yieldparam key [String] each key the human pressed
        def offering(screen, words, &pressed)
          screen.print_prompt("#{words}\n")
          return unless @keys.tty?

          @terminal.exclusively do |held|
            # Degraded rather than dead: the countdown's words are already on
            # the screen, so refusing to read at all would leave offered keys
            # that do nothing and say nothing.
            #
            # PRINTED, never noted. {TTY::Notes} holds a note while a prompt
            # drawn by another fiber is still open, and that is exactly this
            # path's premise -- the read that would not let go still has its
            # prompt published -- so a noted sentence would arrive only once
            # that read ended, which is the event whose absence caused the
            # degrade. It goes out the way the countdown's own words above do.
            screen.print_prompt("#{UNHELD}\n") unless held
            raw_window(&pressed)
          end
        end

        private

        def raw_window(&pressed)
          saved = @keys.console_mode
          @keys.raw!(intr: true)
          loop { press(&pressed) }
        ensure
          @keys.console_mode = saved unless saved.nil?
        end

        # One nonblocking look per tick, {Frontend::TTY::Countdown#read_key}'s
        # policy: the window is raw for its whole length, so a key registers
        # without Enter and never echoes.
        def press
          key = @keys.read_nonblock(1)
          yield key if key
        rescue IO::WaitReadable, IOError
          nil
        ensure
          Async::Task.current.sleep(@tick)
        end
      end
    end
  end
end
