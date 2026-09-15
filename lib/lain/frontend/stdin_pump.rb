# frozen_string_literal: true

require "active_support/core_ext/module/delegation"
require "async"

module Lain
  module Frontend
    # The in-process producer on the {InputRail}, and the one object on the chat
    # path that reads stdin. For each prompt the chat publishes it takes a line
    # from the human and puts it on the rail, stamped with the generation it was
    # typed at.
    #
    # On a terminal it runs the line editor. Off one it reads a PRIVATE
    # duplicate of the descriptor, unbuffered, and seats the original on the
    # null device: a forked child's `STDIN.reopen` hands back what its copy of a
    # buffered read held by seeking the descriptor it shares, and a regular
    # file's offset is shared, so a chat reading `lain chat < prompts.txt`
    # buffered re-read its own prompts after every mixlib call.
    #
    # The editor's read runs in a task of its own, stopped the moment its prompt
    # is withdrawn: the rail tells the pump, which never asks on a clock.
    class StdinPump
      # The chat that reads no line, so nothing is started and nothing stopped.
      module Idle
        def self.start(_task) = self
        def self.stop = nil
      end

      # The countdown's keys, one at a time, from the terminal the pump holds.
      class Keys
        delegate :raw!, :console_mode, :console_mode=, :read_nonblock, to: :@input

        def initialize(input) = @input = input

        def tty? = StdinPump.terminal?(@input)
      end

      # One prompt's drawing: a line begun before the prompt first drew stays
      # begun before it, however it ends.
      Draw = Struct.new(:prompt, :carried) do
        # The generation a line typed at this drawing carries.
        def generation = carried.unfinished? ? prompt.generation - 1 : prompt.generation
      end
      private_constant :Draw

      def self.keys(input) = Keys.new(input)

      # The process's stdin, named here so no other file on the chat path does.
      def self.process_input = $stdin

      def self.terminal?(input) = input.respond_to?(:tty?) && input.tty?

      # @param rail [InputRail] where lines go and prompts come from
      # @param screen [Frontend::TTY] composes and draws the prompt, keeps the
      #   history, and says what was held or discarded
      # @param input [IO] the process's stdin
      def initialize(rail:, screen:, input: $stdin)
        @rail = rail
        @screen = screen
        @input = input
        @editor = LineEditor.new(vi_mode: -> { screen.vi? }, notify: ->(message) { screen.render_warning(message) })
        @typeahead = Typeahead.new(input:)
        @unfinished = Typeahead::NOTHING
        @served = 0
        @ended = false
      end

      # Seats the input and serves prompts until stopped. Seating waits until
      # here because it re-points the process's own descriptor, which building
      # an object must never do.
      #
      # @param task [Async::Task] the conversation's task
      # @return [Async::Task] what stops the pump
      def start(task)
        @lines = Lines.new(seated(@input))
        @told = @rail.attach(self)
        task.async { run }
      end

      # What the human typed while no prompt was drawn, asked for by
      # {InputRail#gather}: each whole line is held, and a line still being typed
      # is kept for the next read, which starts from it.
      def sweep
        LineEditor.exclusively do
          typed = @typeahead.drain(@unfinished)
          typed.lines.each { |line| @rail.hold(line) }
          @unfinished = typed
        end
        nil
      end

      private

      def run
        loop { serve(published) }
      ensure
        @rail.detach(self)
      end

      def published
        prompt = @rail.published
        prompt = changed until prompt.generation > @served
        @served = prompt.generation
        prompt
      end

      def changed
        @told.pop
        @rail.published
      end

      def serve(prompt)
        return @rail << InputRail::Eof.new if @ended

        draw = Draw.new(prompt, Typeahead::NOTHING)
        delivered(draw, raced(draw))
      end

      # The read, stopped the moment its prompt is withdrawn.
      def raced(draw)
        reading = Async::Task.current.async { read(draw) }
        watching = Async::Task.current.async { withdrawn_under(draw.prompt, reading) }
        reading.wait
      ensure
        watching&.stop
      end

      def withdrawn_under(prompt, reading)
        @told.pop while @rail.open?(prompt)
        reading.stop
      end

      # A line finished at a prompt that was withdrawn as it was entered answers
      # nothing open now: it is held, and said to be, rather than handed to
      # whichever prompt comes next.
      def delivered(draw, value)
        return @rail << value if @rail.open?(draw.prompt) && value

        @rail.hold(value.text) if value.is_a?(InputRail::Line)
      end

      def read(draw)
        StdinPump.terminal?(@input) ? edited(draw) : streamed(draw)
      rescue EOFError, Errno::EIO
        ended
      end

      def streamed(draw)
        @screen.print_prompt(draw.prompt.text)
        text = @lines.gets
        text ? InputRail::Line.new(text:, generation: draw.prompt.generation) : ended
      end

      def ended
        @ended = true
        InputRail::Eof.new
      end

      # An answer's prompt sweeps what was typed before it drew -- and again
      # past Reline's cursor-position query, where bytes waiting on its reply
      # were typed before the prompt appeared -- so nothing typed ahead answers
      # it. A prompt that answers nothing reads typeahead as the line it is, and
      # starts from a line {#sweep} kept.
      def edited(draw)
        line = LineEditor.exclusively do
          next_line = -> { editor_read(draw) }
          if draw.prompt.answer?
            draw.carried = put_aside(@typeahead.drain(take_unfinished))
            LineEditor.before_first_draw(swept_again(draw), &next_line)
          else
            next_line.call
          end
        end
        line.nil? ? InputRail::Eof.new : typed(draw, line)
      end

      def swept_again(draw) = -> { draw.carried = put_aside(@typeahead.drain(draw.carried), noted: draw.carried) }

      def editor_read(draw)
        @screen.drawing(-> { @rail.open?(draw.prompt) }) do
          composed = @screen.compose(draw.prompt.text)
          @typeahead.type_back(take_unfinished.partial)
          @editor.read(composed)
        end
      end

      def typed(draw, line)
        @screen.remember(line)
        InputRail::Line.new(text: "#{draw.carried.partial}#{line}", generation: draw.generation)
      end

      # `noted` is the sweep already said, whose unfinished line is not said twice.
      def put_aside(typed, noted: Typeahead::NOTHING)
        typed.lines.each { |line| @rail.hold(line) }
        @screen.render_discarded(typed.partial) if typed.unfinished? && typed.partial != noted.partial
        typed
      end

      # The line {#sweep} kept, handed to exactly one read.
      def take_unfinished = @unfinished.tap { @unfinished = Typeahead::NOTHING }

      def seated(input)
        return input if StdinPump.terminal?(input) || !(input.respond_to?(:fileno) && input.fileno)

        input.dup.tap { input.reopen(File::NULL) }
      end
    end

    class StdinPump
      # Reopened rather than nested above, tty.rb's idiom.

      # Lines off a stream, read as they arrive into a buffer of the pump's own,
      # so nothing is left in an IO's buffer for a child to hand back.
      class Lines
        def initialize(input)
          @input = input
          @buffer = String.new(encoding: Encoding::BINARY)
          @scanned = 0
          @ended = false
        end

        # @return [String, nil] the next line without its ending, or nil once
        #   the stream has ended with nothing left
        def gets
          fill until @ended || line_end
          return nil if @buffer.empty?

          taken = @buffer.slice!(0, (line_end || (@buffer.size - 1)) + 1)
          @scanned = 0
          taken.force_encoding(Encoding.default_external).chomp
        end

        private

        # Only what arrived since the last look is searched, so one long line
        # read in chunks costs its length rather than its length squared.
        def line_end
          found = @buffer.index("\n", @scanned)
          @scanned = @buffer.size unless found
          found
        end

        def fill
          @buffer << @input.readpartial(4096)
        rescue EOFError
          @ended = true
        end
      end

      # What the human typed before a read opened, taken off the terminal
      # without being read AS anything ({LineEditor.typed_ahead}), and sorted
      # into the lines they finished and the one they had not. `IO#iflush`
      # would discard the bytes unseen; the human is owed them back.
      class Typeahead
        LINE_END = /\r\n|\r|\n/

        # A key typed rather than text: an escape sequence such as an arrow
        # key's `\e[A` or `\eOA`, or a bare escape.
        KEY_SEQUENCE = /\e(?:\[[\d;?]*[@-~]|O.)?/

        # Whole lines and whatever followed the last line end, keeping only
        # what says something: Enter is what a human presses at a prompt that
        # appears mid-stream, and an arrow key typed ahead is not the start of
        # a line the next answer should be joined to.
        Typed = Data.define(:lines, :partial) do
          def self.from(bytes)
            *lines, partial = bytes.b.force_encoding(Encoding::UTF_8).scrub.split(LINE_END, -1)
            new(lines: lines.select { |line| said?(line) }.freeze, partial: (said?(partial.to_s) ? partial : "").freeze)
          end

          def self.said?(text) = !Blankness.blank?(text.gsub(KEY_SEQUENCE, "").gsub(/[[:cntrl:]]/, ""))

          def unfinished? = !partial.empty?
        end

        NOTHING = Typed.new(lines: [].freeze, partial: "")

        # @param input [IO] the terminal; anything that is not one -- a spec's
        #   StringIO, a pipe -- has no typeahead to tell from input
        def initialize(input:)
          @input = input
        end

        # What is waiting now, read on from the unfinished line of an earlier
        # sweep, if there was one.
        def drain(after = NOTHING)
          Typed.from(after.partial.b + (terminal? ? LineEditor.typed_ahead(@input) : ""))
        end

        # Text put back where the next read takes its first keys from, as the
        # keys they were: Reline's gate buffer, which both its gates read ahead
        # of the terminal. Byte by byte from the end, since each `ungetc` goes
        # in front of the last.
        def type_back(text)
          text.b.bytes.reverse_each { |byte| ::Reline::IOGate.ungetc(byte) }
        end

        private

        def terminal? = StdinPump.terminal?(@input)
      end
    end
  end
end
