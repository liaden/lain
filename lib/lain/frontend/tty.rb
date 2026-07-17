# frozen_string_literal: true

require "fileutils"
require "io/console"
require "json"
require "pastel"
require "reline"
require "time"
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
      # @param history_path [String] durable reline history file, under
      #   {Paths#state_home} by default -- injectable so specs use a tmpdir
      #   instead of touching real XDG state (T12)
      # @param clock [#call] monotonic time source for {#render_countdown},
      #   injectable for tests -- the same seam {Middleware::Timeout} and
      #   {CLI::Shutdown} use, so a countdown's remaining seconds are testable
      #   without a real clock tick (T21)
      # @param state_path [String] {StatusFeed}'s published state, under
      #   `.lain/state.json` by default (a project artifact, matching
      #   {StatusFeed}'s own default -- see its class comment on why this is
      #   not an XDG path) -- injectable so specs use a tmpdir (I3)
      # @param wall_clock [#call] absolute time source for {#prompt}'s warmth
      #   snapshot, separate from `clock:` above -- {StatusFeed} publishes an
      #   absolute deadline (wall time), while `clock:` is CLOCK_MONOTONIC and
      #   answers a different question (I3)
      def initialize(channel:, output: $stdout, input: $stdin, pastel: Pastel.new(enabled: output.tty?),
                     history_path: File.join(Paths.new.state_home, "history"),
                     clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                     state_path: File.join(Dir.pwd, ".lain", "state.json"),
                     wall_clock: -> { Time.now })
        @channel = channel
        @output = output
        @input = input
        @pastel = pastel
        @history = History.new(path: history_path, notify: method(:render_warning))
        @countdown = Countdown.new(output:, input:, pastel:, clock:)
        @warmth = Warmth.new(path: state_path, clock: wall_clock)
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
        @history.load
        renderer = Thread.new { render_until_closed }
        yield self
      ensure
        @channel.close unless @channel.closed?
        renderer&.join
        # After the renderer joins (no concurrent writer left) and before the
        # screen flips back: a block that raised mid-countdown must never
        # leave the terminal raw (see Countdown's window lifecycle).
        @countdown.stop
        exit_alternate_screen
      end

      # Read one line from the human, with reline's editing and history when
      # `input` is a real terminal. A non-tty `input` (a spec's StringIO, or a
      # pipe) reads a plain line instead -- reline's line editor requires a
      # real terminal (it calls `IO#winsize`) and has no business running
      # against a StringIO in a unit spec.
      #
      # The interactive path is also where {Warmth} prepends a cache-warmth
      # glyph -- a per-prompt SNAPSHOT of {StatusFeed}'s published deadline,
      # read once right here. This is deliberate, not a shortcut: Reline's
      # `readline` fixes its prompt string for the whole wait (the approved
      # doc's documented limitation, interface-integration.md § 1), so there
      # is no mid-wait refresh to build -- tmux's status-right is where live
      # ticking lives. A non-tty `output` gets no glyph at all (gated
      # separately from `@pastel`'s own disabled-when-non-tty styling,
      # because the glyph is plain text, not an escape code Pastel would
      # already strip) -- see {#warmth_prefix}.
      #
      # @return [String, nil] the line, or nil at EOF (Ctrl-D / closed input)
      def prompt(text = "> ")
        return read_line_with_history(text) if @input.respond_to?(:tty?) && @input.tty?

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

      # Surface a question the agent has put to the human (ask_human, OM-4).
      # Synchronous and Channel-bypassing for the same reason {#render_response}
      # is: the reply-path shows the question and reads the answer inline, a
      # finished exchange rather than a concurrently-arriving stream.
      def render_question(question)
        @output.puts(@pastel.yellow.bold("the agent asks:"))
        @output.puts(@pastel.yellow(question))
        @output.flush
      end

      # One countdown tick (T21): render remaining time + offered keys on the
      # bottom status line, then make one non-blocking attempt to read a key
      # and forward it to the shutdown coordinator. Called once per tick by
      # the caller's own timer -- this method does no sleeping itself, so an
      # injected clock drives successive calls into successive renders with
      # no real waiting, and ticks keep landing even while no key arrives.
      #
      # The first interactive tick opens the countdown's WINDOW (raw+no-echo
      # terminal mode, ownership of the bottom line); the window stays open
      # across ticks until {#stop_countdown} closes it. Delegates to
      # {Countdown} rather than growing this class -- see its comment for why
      # the split exists.
      #
      # @param deadline [Numeric] absolute time (same clock as the injected
      #   `clock:`) the window closes
      # @param options [Hash] `:coordinator` (`#signal`, required), `:bindings`
      #   (single-char key -> {CLI::Shutdown} input symbol, defaults to c/w/r)
      def render_countdown(deadline:, options:)
        @countdown.render(deadline:, options:)
      end

      # End the countdown window: erase the status line from the bottom of
      # the screen, restore the terminal mode saved when the window opened,
      # and return {#render}'s channel events to the plain pre-T21 path.
      # Idempotent -- the seam T22 calls when {CLI::Shutdown}'s on_transition
      # reports :running (a cancel) or the window otherwise ends, and {#run}'s
      # ensure calls defensively.
      def stop_countdown
        @countdown.stop
      end

      private

      # `reline(…, true)` already feeds an accepted line into the in-memory
      # `Reline::HISTORY`; {History#append} durably appends it too, before the
      # next prompt is drawn (T12 -- see History's comment).
      def read_line_with_history(text)
        line = Reline.readline("#{warmth_prefix}#{@pastel.bold(text)}", true)
        @history.append(line) if line
        line
      end

      # Empty string (never nil) when `output` is not a real terminal or
      # {StatusFeed} has published nothing yet -- concatenation with "" is a
      # no-op, so the prompt text this produces is byte-identical to the
      # pre-I3 prompt in both cases (AC: non-tty output untouched, no feed
      # renders today's bare prompt).
      def warmth_prefix
        return "" unless @output.tty?

        @warmth.prefix(@pastel)
      end

      # Presentation for a collaborator's degraded-path warning ({History}'s
      # `notify:` seam) -- the palette stays in TTY proper.
      def render_warning(message)
        @output.puts(@pastel.yellow(message))
        @output.flush
      end

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
      # The print routes through {Countdown#print_above} because the countdown
      # owns the bottom line while it is active (T21): the status line steps
      # out of the way, the event prints above, the status line redraws --
      # never a torn splice. With no countdown active it degrades to the
      # pre-T21 raw print (live tool-output chunks are not line-shaped).
      def render(event)
        rendered = Decorators.for(event)&.render(@pastel)
        @countdown.print_above(rendered) unless rendered.nil?
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

    # Reopened rather than nested in TTY's own class body -- the shutdown.rb
    # idiom: each collaborator is its own responsibility, and the split keeps
    # each body within Metrics/ClassLength instead of loosening it.
    class TTY
      # Durable reline history (T12): loaded into `Reline::HISTORY` at {#run}
      # entry so history round-trips a process, write-through on each accepted
      # line rather than dump-at-exit, so a SIGKILL between prompts loses at
      # most nothing. Durable means close()-durable (the process dying), not
      # fsync-durable -- shell history does not warrant an fsync per line.
      class History
        # @param path [String] the durable history file
        # @param notify [#call] renders a degraded-path warning line
        #   ({TTY#render_warning}) -- presentation stays out of this class
        def initialize(path:, notify:)
          @path = path
          @notify = notify
          @writable = true
          @warned = false
        end

        # A missing file is the ordinary first-run case, not a failure --
        # rescued rather than pre-checked with File.exist?, which would be a
        # TOCTOU stat for nothing. Any other read error warns.
        def load
          File.readlines(@path, chomp: true).each { |line| Reline::HISTORY.push(line) }
        rescue Errno::ENOENT
          nil
        rescue SystemCallError => e
          warn_unavailable(e)
        end

        # Append-only, 0600 -- history is a secret-adjacent surface (pasted
        # keys), so the creation mode is passed to open() itself: the file is
        # never readable beyond its owner, not even between an open and a
        # chmod (umask can only remove bits, and 0600 has none it may
        # remove). A failure here (unwritable state dir) degrades to a
        # rendered warning instead of crashing the prompt loop, and only
        # warns once even if every subsequent write keeps failing.
        def append(line)
          return unless @writable

          FileUtils.mkdir_p(File.dirname(@path))
          File.open(@path, File::WRONLY | File::CREAT | File::APPEND, 0o600) { |f| f.puts(line) }
        rescue SystemCallError => e
          @writable = false
          warn_unavailable(e)
        end

        private

        def warn_unavailable(error)
          return if @warned

          @warned = true
          @notify.call("warning: history unavailable (#{error.message})")
        end
      end

      # I3's warmth collaborator: reads {StatusFeed}'s published
      # `.lain/state.json` directly -- the same "one state feed, three
      # renderers" split I1 established for tmux's status-right (never an
      # in-process registry; StatusFeed and TTY may even be different
      # processes). Split out of TTY proper for the same reason
      # {Countdown}/{History} are: a separate responsibility, one collaborator
      # each (`Agent::Budget`/`Agent::ToolRunner` precedent). Nested, not a
      # new file: the card scopes I3 to `tty.rb` alone.
      class Warmth
        WARM = "●" # filled circle -- the cache was read or written within its sliding TTL
        COLD = "○" # hollow circle -- the deadline StatusFeed last published has already passed

        # @param path [String] StatusFeed's published state file
        # @param clock [#call] absolute (wall) time source, injectable so a
        #   spec never races a real deadline comparison
        def initialize(path:, clock:)
          @path = path
          @clock = clock
        end

        # @param pastel [Pastel] presentation stays out of this class, as with
        #   every other TTY collaborator -- callers hand in the palette
        # @return [String] a colored glyph + trailing space, or "" when
        #   nothing has published a deadline yet (no file, or a fresh
        #   StatusFeed whose `cache_deadline` is still `null`) -- callers
        #   never branch on nil, they just concatenate
        def prefix(pastel)
          deadline = read_deadline
          return "" if deadline.nil?

          warm?(deadline) ? "#{pastel.green(WARM)} " : "#{pastel.dim(COLD)} "
        end

        private

        # The contract is "never raise at the prompt, for ANY file content" --
        # a missing file (StatusFeed never ran), a syntactically-malformed
        # one, and a syntactically-VALID-but-semantically-wrong one (a bad
        # timestamp string, a non-Hash top level such as a bare Array once
        # parsed) are all the same "no warmth to report" case, matching
        # {History#load}'s missing-file-is-ordinary precedent. Split into two
        # narrow rescues -- reading bytes vs. coercing them -- so the
        # coverage each guards is self-evident rather than one broad catch.
        def read_deadline
          raw = read_state["cache_deadline"]
          raw && Time.iso8601(raw)
        rescue ArgumentError, TypeError, NoMethodError
          # ArgumentError: Time.iso8601 rejected the string (bad timestamp).
          # TypeError: `["cache_deadline"]` on a parsed Array/Integer/etc.
          # NoMethodError: `["cache_deadline"]` on a parsed true/false/nil.
          nil
        end

        def read_state
          JSON.parse(File.read(@path))
        rescue Errno::ENOENT, JSON::ParserError
          {}
        end

        def warm?(deadline) = deadline > @clock.call
      end

      # T21's countdown collaborator: renders the status line, owns the
      # bottom of the screen while active, and forwards offered keys to the
      # shutdown coordinator. Split out of TTY proper because the countdown
      # is a separate responsibility (the `Agent::Budget`/`Agent::ToolRunner`
      # precedent CLAUDE.md names). Nested, not a new file: the card scopes
      # T21 to `tty.rb` alone, and this collaborator has no life outside a
      # TTY.
      class Countdown
        DEFAULT_BINDINGS = { "c" => :cancel, "w" => :extend, "r" => :wait_responses }.freeze
        LABELS = { cancel: "cancel", extend: "wait longer", wait_responses: "respond then exit" }.freeze

        def initialize(output:, input:, pastel:, clock:)
          @output = output
          @input = input
          @pastel = pastel
          @clock = clock
          # Serializes the channel-drain thread's prints against countdown
          # ticks, so the two can never interleave torn writes to @output.
          @lock = Mutex.new
          @line = nil
          @window_open = false
          @saved_mode = nil
        end

        # @param deadline [Numeric] absolute time, same clock as `clock:`
        # @param options [Hash] `:coordinator` (`#signal`, required),
        #   `:bindings` (single-char key -> input symbol, default c/w/r)
        def render(deadline:, options:)
          bindings = options.fetch(:bindings, DEFAULT_BINDINGS)
          line = status_line(deadline, bindings)

          interactive? ? render_tty(line) : render_plain(line)
          dispatch_key(options.fetch(:coordinator), bindings) if interactive?
        end

        # Close the window: erase the status line (erase, never redraw -- the
        # countdown must leave no trace), give the terminal its saved mode
        # back, and deactivate so {#print_above} returns to the plain path.
        # Idempotent: stopping a window that never opened (plain mode, or a
        # double stop) writes and restores nothing.
        def stop
          @lock.synchronize do
            close_window if @window_open
          end
        end

        # {TTY#render}'s seam: print a channel event's bytes without tearing
        # the status line. While a countdown is active it steps off the
        # bottom line, the event prints above (given its own line ending),
        # and the status line redraws; otherwise this is a plain print.
        def print_above(rendered)
          @lock.synchronize do
            active? ? above(rendered) : @output.print(rendered)
            @output.flush
          end
        end

        private

        def active? = !@line.nil?

        def above(rendered)
          @output.print(::TTY::Cursor.clear_line)
          @output.print(rendered)
          @output.puts unless rendered.end_with?("\n")
          @output.print(@pastel.bold(@line))
        end

        # Both output and input must be real terminals: escapes drawn on a
        # non-terminal output are just noise (AC: non-tty degrades to plain
        # lines), and single-key reads off a non-terminal input are reading
        # whatever this process's stdin actually is (a pipe, a redirect), not
        # an interactive choice.
        def interactive?
          @output.tty? && @input.respond_to?(:tty?) && @input.tty?
        end

        # The label fallback is deliberate: a custom binding to an action
        # LABELS does not know renders as the action's own name rather than
        # raising -- a missing label must not take down the shutdown UI at
        # the one moment it exists to serve, and the symbol name is legible.
        def status_line(deadline, bindings)
          remaining = [(deadline - @clock.call).ceil, 0].max
          offered = bindings.map { |key, action| "[#{key}] #{LABELS.fetch(action, action.to_s)}" }.join("  ")
          "closing in #{remaining}s -- #{offered}"
        end

        def render_tty(line)
          @lock.synchronize do
            open_window
            @output.print(::TTY::Cursor.clear_line)
            @output.print(@pastel.bold(line))
            @output.flush
            @line = line
          end
        end

        # The window opens once, on the first interactive tick: raw+no-echo
        # for the WHOLE window, not a per-read bracket -- a keystroke landing
        # between per-tick brackets would be cooked and ECHO would bleed it
        # onto the status line until the next tick wiped it (the review
        # panel's PTY probe caught exactly that). The mode that was in force
        # is saved so {#stop} can put it back.
        def open_window
          return if @window_open

          @window_open = true
          enter_raw
        end

        def close_window
          erase_status_line
          @line = nil
          @window_open = false
          restore_mode
        end

        def erase_status_line
          return if @line.nil?

          @output.print(::TTY::Cursor.clear_line)
          @output.flush
        end

        # A spec's StringIO has no console (`raw!`); it already returns bytes
        # without line buffering or echo, so it needs no mode at all.
        def enter_raw
          return unless @input.respond_to?(:raw!)

          @saved_mode = @input.console_mode
          @input.raw!(intr: true)
        end

        def restore_mode
          @input.console_mode = @saved_mode unless @saved_mode.nil?
          @saved_mode = nil
        end

        # Non-tty output has no bottom line to own: one plain line, no
        # escapes, and {#active?} stays false so a channel event never tries
        # to clear/redraw a line that was never drawn with cursor control.
        def render_plain(line)
          @lock.synchronize do
            @output.puts(line)
            @output.flush
          end
        end

        # Burst policy: at most one key per tick, fired the tick it is read;
        # conflicting inputs across ticks (an extend after a cancel) are the
        # coordinator's problem, and {CLI::Shutdown}'s state machine already
        # tolerates any input in any state.
        def dispatch_key(coordinator, bindings)
          key = read_key
          return unless key

          action = bindings[key]
          coordinator.signal(action) if action
        end

        # One non-blocking attempt to read a single key. The terminal is
        # already raw for the whole window (see {#open_window}), so this is
        # just the read; keys register without Enter and never echo.
        def read_key
          @input.read_nonblock(1)
        rescue IO::WaitReadable, EOFError
          nil
        end
      end
    end
  end
end
