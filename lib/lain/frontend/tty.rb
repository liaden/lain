# frozen_string_literal: true

require "pastel"
require "reline"
require "tty-cursor"
require "tty-screen"

module Lain
  module Frontend
    # Owns the terminal. The only class in this codebase permitted to write to
    # $stdout (see spec/output_discipline_spec.rb, which is scoped to lib/lain/frontend/).
    #
    # Two duties, kept in one class because they share the same terminal state:
    #
    # 1. {#run} takes the alternate screen so chat state never smears into REPL
    #    scrollback, and drains an injected {Lain::Channel} on a background
    #    thread -- rendering each attributed {Lain::Telemetry} as it arrives. This
    #    is the consumer whose existence keeps the Channel's blocking backpressure
    #    (see Channel's doc) from ever deadlocking a producer.
    # 2. {#prompt} and {#render_response} are the synchronous half: reading the
    #    next line from the human and printing the model's finished turn. These
    #    do NOT go through the Channel -- Agent#ask already returns the whole
    #    Response synchronously, so routing it through the Channel would buy
    #    nothing but a second protocol for the same information. The Channel
    #    exists for things that arrive concurrently WHILE a call is still
    #    running (a bash tool's live stdout); a finished Response is not that.
    #
    # On scope -- why this is a small hand-rolled surface and not irb/debug or a
    # richer TTY gem: the design plan settles it (see the "Interface" section,
    # "TTY first, Neovim next (M4)"). The TTY is deliberately minimal -- an
    # alternate-screen chat surface (M1b) over `tty-screen`/`tty-cursor`/`pastel`,
    # with `reline` (stdlib) already doing line editing and history in {#prompt}.
    # The richer interactive interface is not a bigger TTY or an embedded Ruby
    # console; it is the Neovim frontend (M4), which subscribes to the same
    # Journal over msgpack-RPC and gets the editable `lain://request` buffer. So
    # this class stays small on purpose; growth goes to Neovim, not here.
    class TTY
      # Raw escapes for the DEC private mode `tput smcup`/`rmcup` uses. tty-cursor
      # has no alternate-screen verb of its own, and pulling in a full terminfo
      # dependency for two escape codes would be a strange trade.
      ALTERNATE_SCREEN_ON = "\e[?1049h"
      ALTERNATE_SCREEN_OFF = "\e[?1049l"

      # @param channel [Lain::Channel] drained by {#run}'s background thread
      # @param output [#print, #puts, #flush] default $stdout, a StringIO in specs
      # @param input [#gets, #tty?] default $stdin, a StringIO in specs
      # @param pastel [Pastel]
      def initialize(channel:, output: $stdout, input: $stdin, pastel: Pastel.new(enabled: output.tty?))
        @channel = channel
        @output = output
        @input = input
        @pastel = pastel
      end

      # Non-blocking: render whatever is queued right now and return. The
      # building block {#run}'s background thread polls via #pop; specs call
      # this directly so an assertion needs no thread and no race.
      #
      # @return [Integer] number of events rendered
      def drain_and_render
        events = @channel.drain
        events.each { |event| render(event) }
        events.size
      end

      # Take the alternate screen, start draining the Channel in the background,
      # yield self to the caller, and ALWAYS give the terminal back -- even if
      # the caller's block raises, because a wedged agent must never strand the
      # human's shell inside chat mode.
      #
      # The caller is responsible for closing the Channel when the session ends
      # (typically by ending its own loop); {#run} closes it too, defensively, so
      # the background thread is guaranteed to observe the close and exit rather
      # than leak past `run`'s return.
      def run
        enter_alternate_screen
        renderer = Thread.new { render_until_closed }
        yield self
      ensure
        @channel.close unless @channel.closed?
        renderer&.join
        exit_alternate_screen
      end

      # Read one line from the human, with reline's editing and history when
      # `input` is a real terminal. A non-tty `input` (a spec's StringIO, or a
      # pipe) reads a plain line instead -- reline's line editor requires a
      # real terminal (it calls `IO#winsize`) and has no business running
      # against a StringIO in a unit spec.
      #
      # @return [String, nil] the line, or nil at EOF (Ctrl-D / closed input)
      def prompt(text = "> ")
        return Reline.readline(@pastel.bold(text), true) if @input.respond_to?(:tty?) && @input.tty?

        @output.print(text)
        @output.flush
        line = @input.gets
        line&.chomp
      end

      # Render the model's finished turn. Not Channel-sourced -- see the class
      # comment on why a synchronous Response bypasses the Channel entirely.
      def render_response(response)
        @output.puts(@pastel.cyan(response.text))
        @output.puts(rule)
        @output.flush
      end

      def render_error(message)
        @output.puts(@pastel.red.bold("error: #{message}"))
        @output.flush
      end

      private

      # The background render loop: blocking drain of the Channel so live tool
      # output (a running bash command's stdout) renders as it arrives rather
      # than waiting for a poll tick. {Channel#drain}'s block form pops-until-
      # closed and yields each event, returning once the Channel is closed AND
      # drained -- this thread's only exit.
      def render_until_closed
        @channel.drain { |event| render(event) }
      end

      # Render one Channel event: find the decorator that presents it and print
      # its output, or skip an event this frontend does not render (the Channel
      # may also carry, e.g., {Telemetry::Dropped}, which the TTY ignores). The
      # color/format knowledge lives in the decorator, not here -- see
      # {Frontend::Decorators} for why presentation is frontend-owned and never a
      # `Renderable` mixed into the lib value object.
      def render(event)
        rendered = Decorators.for(event)&.render(@pastel)
        return if rendered.nil?

        @output.print(rendered)
        @output.flush
      end

      # Leading `::` is load-bearing: unqualified `TTY::Screen` would resolve
      # `TTY` to this very class (Lain::Frontend::TTY) rather than the
      # tty-screen gem's top-level module, since we are lexically inside a
      # class of the same name.
      def rule
        @pastel.dim("-" * ::TTY::Screen.width)
      end

      def enter_alternate_screen
        @output.print(ALTERNATE_SCREEN_ON)
        @output.print(::TTY::Cursor.clear_screen)
        @output.flush
      end

      def exit_alternate_screen
        @output.print(ALTERNATE_SCREEN_OFF)
        @output.flush
      end
    end
  end
end
