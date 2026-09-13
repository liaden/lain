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
    # Deliberately MINIMAL -- an alternate-screen chat surface over
    # `tty-screen`/`tty-cursor`/`pastel`, with stdlib `reline` doing line
    # editing and history. The richer interactive interface is not a bigger TTY
    # or an embedded Ruby console; it is the Neovim frontend, which subscribes
    # to the same Journal. Growth goes there, not here.
    class TTY
      # Raw escapes for the DEC private mode `tput smcup`/`rmcup` uses. tty-cursor
      # has no alternate-screen verb of its own, and pulling in a full terminfo
      # dependency for two escape codes would be a strange trade.
      ALTERNATE_SCREEN_ON = "\e[?1049h"
      ALTERNATE_SCREEN_OFF = "\e[?1049l"

      # @param channel [Lain::Channel] drained by {#run}'s background thread
      # @param output [#print, #puts, #flush] default $stdout, a StringIO in specs
      # @param input [#gets, #tty?] default $stdin, a StringIO in specs
      # @param pastel [Pastel] the raw palette, still handed to the nested
      #   collaborators below
      # @param theme [Frontend::Theme] the named style vocabulary this class
      #   renders through -- derived from `pastel:` so an injected disabled
      #   palette stays disabled, and injectable on its own so a caller can
      #   restyle without restating the palette
      # @param prompt_renderer [#call] composes the prompt string from run
      #   state -- `call(text:, theme:) -> String`, newlines allowed. The
      #   default composes nothing, which is what keeps the bytes the line
      #   editor receives identical to the pre-seam prompt. Only the renderer
      #   is injectable, not the {PromptComposer} around it: the theme is this class's
      #   to hand over, and a second one passed in could disagree with it
      # @param history_path [String] durable reline history file, under
      #   {Paths#state_home} by default -- injectable so specs use a tmpdir
      #   instead of touching real XDG state
      # @param clock [#call] monotonic time source for {#render_countdown},
      #   injectable for tests -- the same injected-clock seam {CLI::Shutdown}
      #   uses, so a countdown's remaining seconds are testable without a real
      #   clock tick
      # @param state_path [String] {StatusFeed}'s published state, resolved
      #   through {ProjectDir} -- the one locator {StatusFeed} and {CLI::Up}
      #   default through too, so the three renderers of one feed cannot name
      #   three different files. Injectable so specs use a tmpdir
      # @param wall_clock [#call] absolute time source for {#prompt}'s warmth
      #   snapshot, separate from `clock:` above -- {StatusFeed} publishes an
      #   absolute deadline (wall time), while `clock:` is {RunClock::MONOTONIC}
      #   and answers a different question. There is deliberately no shared
      #   WALL constant to pair with it -- see {RunClock::MONOTONIC}
      # @param vi_mode [Boolean] ask the line editor for vi mode; off unless
      #   asked, in which case {LineEditor} leaves Reline as it found it
      # @param completion_sources [Completion::Sources] where a `/command` or
      #   `@path` candidate comes from -- injectable so a caller that HAS the
      #   command registry and the skill catalog can hand them over, and so a
      #   spec completes against a fixture tree rather than the real cwd.
      #   Only the sources are injectable, not the {Completion} around them:
      #   the theme and the screen are this class's to hand over
      def initialize(channel:, output: $stdout, input: $stdin, pastel: Pastel.new(enabled: output.tty?),
                     theme: Theme.new(pastel:), prompt_renderer: PromptComposer::Null.new,
                     history_path: File.join(Paths.new.state_home, "history"),
                     clock: RunClock::MONOTONIC,
                     state_path: ProjectDir.new.state_path,
                     wall_clock: -> { Time.now }, vi_mode: false, completion_sources: Completion::Sources.new)
        @channel = channel
        @output = output
        @input = input
        @pastel = pastel
        @theme = theme
        build_prompt_stack(prompt_renderer:, vi_mode:, history_path:)
        @countdown = Countdown.new(output:, input:, pastel:, clock:)
        @warmth = Warmth.new(path: state_path, clock: wall_clock)
        @inbox = Inbox.new(output:, pastel:, clock: wall_clock)
        # Built here, CLAIMED in #run: constructing a TTY must not rebind the
        # human's keys. Draws through {Countdown#draw}, the existing owner of
        # writing to the screen while the prompt is live.
        @completion = Completion.new(sources: completion_sources, theme:, screen: @countdown.method(:draw))
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

      # ALWAYS gives the terminal back, even on a raising block, because a
      # wedged agent must never strand the human's shell inside chat mode. The
      # Channel is closed here too, defensively, so the background thread is
      # guaranteed to observe the close rather than leak past `run`'s return.
      #
      # Claiming the completion key happens HERE and not in #initialize because
      # it mutates process-global Reline state, and this is the moment lain is
      # entitled to it -- the terminal is ours from here.
      def run
        enter_alternate_screen
        Completion.install(@completion, notify: method(:render_warning))
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
      # The read goes through {Frontend::LineEditor}, so a line ending in a
      # backslash continues and the human's next line joins it: what arrives
      # here is one message, however many lines they typed. vi COMMAND
      # mode is the one exception -- Enter submits there regardless; see
      # {Frontend::LineEditor}'s comment for why that is not worked around.
      #
      # The interactive path is also where {Warmth} prepends a cache-warmth
      # glyph -- a per-prompt SNAPSHOT of {StatusFeed}'s published deadline. A
      # snapshot deliberately: Reline fixes its prompt string for the whole
      # wait, so there is no mid-wait refresh to build, and tmux's status-right
      # is where live ticking lives. A non-tty `output` gets no glyph, gated
      # separately from `@pastel`'s own disabled-when-non-tty styling because
      # the glyph is plain text rather than an escape Pastel would strip.
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
        render_turn(@theme.paint(:response, response.text))
      end

      # A command's structured answer. One paint call PER SEGMENT, each under
      # the token that segment named, rather than one call over the whole line
      # -- the difference between "/status shows a warm marker" and "/status is
      # cyan". It closes through {#render_turn}, so a command's answer and a
      # model's turn end the same way BY CONSTRUCTION rather than by two copies
      # that happen to agree.
      def render_renderable(renderable)
        render_turn(renderable.paint(@theme))
      end

      def render_error(message) = render_line(:error, "error: #{message}")

      # Surface a question the agent has put to the human (ask_human).
      # Synchronous and Channel-bypassing for the same reason {#render_response}
      # is: the reply-path shows the question and reads the answer inline, a
      # finished exchange rather than a concurrently-arriving stream.
      def render_question(question)
        @output.puts(@theme.paint(:question_label, "the agent asks:"))
        @output.puts(@theme.paint(:question, question))
        @output.flush
      end

      # A question ARRIVES as one line, not as {#render_question}'s modal
      # block -- the human keeps whatever they were doing and drains at their
      # own pace (/inbox here, or the nvim lain://inbox buffer).
      #
      # @param question [Tools::AskHuman::Announcement, String] a whole set
      #   wearing its one-line summary, or one question's bytes
      # @param from [#to_s, nil] who is stuck -- the item's own attribution.
      #   Absent, the note is today's unattributed line rather than a
      #   placeholder standing in for a name nobody supplied.
      def render_arrival(question, from: nil)
        @inbox.arrival(question, from:)
      end

      # The TTY-only drain. Lists every pending item (sender, age,
      # question), reads ONE answer, and yields it to the block when the human
      # actually typed one -- resolution stays the caller's (AskHuman#reply is
      # the Repl's seam, never this class's). `reader:` is injectable for the
      # same reason the Repl routes replies through the conductor's
      # read_reply: while a countdown ticker owns the bottom line, a bare
      # prompt read would race it for stdin (see exe/lain's approval_surface
      # comment); specs and direct callers get the plain prompt.
      #
      # The item that answer belongs to is yielded BESIDE it: a caller working
      # out which set an answer resolved on its own disagreed with this one the
      # moment the human drained from a prompt that was not the oldest item's.
      # One value names both the document that was printed and the set that gets
      # the answer, so they cannot come apart.
      #
      # @param items [Enumerable<#question>] the pending set to list, each
      #   answering to `#question`, `#from` and `#asked_at`
      # @param reader [#call] reads one line; injectable so a countdown ticker's
      #   ownership of stdin isn't raced (see exe/lain's approval_surface
      #   comment) -- defaults to the plain prompt read
      # @param answering [#question] the item this drain answers -- the oldest
      #   listed by default, which is what `/inbox` at `you>` means, and the
      #   parked item when a reply prompt drains mid-ask
      def drain_inbox(items, reader: method(:prompt), answering: items.first, &on_answer)
        @inbox.drain(items, reader:, answering:, &on_answer)
      end

      # One countdown tick: render remaining time + offered keys on the
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
      # @param options [Hash] the window's collaborators, passed through whole
      # @option options [#signal] :coordinator required; where a pressed key lands
      # @option options [Hash] :bindings single-char key -> {CLI::Shutdown} input
      #   symbol; defaults to c/w/r
      def render_countdown(deadline:, options:)
        @countdown.render(deadline:, options:)
      end

      # End the countdown window: erase the status line from the bottom of
      # the screen, restore the terminal mode saved when the window opened,
      # and return {#render}'s channel events to the plain no-window path.
      # Idempotent -- the seam shutdown calls when {CLI::Shutdown}'s on_transition
      # reports :running (a cancel) or the window otherwise ends, and {#run}'s
      # ensure calls defensively.
      def stop_countdown
        @countdown.stop
      end

      private

      # `reline(…, true)` already feeds an accepted line into the in-memory
      # `Reline::HISTORY`; {History#append} durably appends it too.
      #
      # The bare prompt this class builds -- warmth glyph plus painted text --
      # is what {PromptComposer} composes, and what it falls back to when a
      # renderer raises. Everything the rendering puts ABOVE the editor's line is
      # printed here, because Reline's prompt is one line and it mangles a
      # newline into a literal backslash-n rather than wrapping.
      #
      # The completion menu is torn down HERE rather than by the key action that
      # drew it: a menu belongs to the prompt it was drawn under. In an `ensure`
      # because a prompt has THREE exits -- a submitted line, EOF, and the
      # {CLI::PromptBreaker} Interrupt {LineEditor}'s dispatch deliberately lets
      # through, which unwinds straight past a trailing statement.
      def read_line_with_history(text)
        composed = @composer.compose("#{warmth_prefix}#{@theme.paint(:prompt, text)}")
        line = @line_editor.read(composed.editor_line(@output))
        @history.append(line) if line
        line
      ensure
        @completion.clear
      end

      # Empty string, never nil, when `output` is not a real terminal or
      # {StatusFeed} has published nothing yet: concatenation with "" is a no-op,
      # so the prompt is byte-identical to one with no warmth glyph.
      def warmth_prefix
        return "" unless @output.tty?

        @warmth.prefix(@pastel)
      end

      # The frontend's ONE-LINE note seam, and the palette stays in TTY proper.
      # Two callers, one shape: a collaborator's degraded-path warning
      # ({History}'s and {Completion}'s `notify:`), and the run's line to the
      # human ({CLI::Wiring#told}), which is how `request_review` says a file is
      # waiting on them now that no desktop surface does.
      def render_warning(message) = render_line(:warning, message)

      # One themed line, printed and flushed -- a forgotten flush is invisible
      # until it is not. {#render_question} is deliberately NOT folded in: it
      # prints two lines under one flush, and routing it through here would cost
      # an extra flush per question.
      def render_line(token, text)
        @output.puts(@theme.paint(token, text))
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

      # Find the decorator that presents this event, or skip one this frontend
      # does not render. The color/format knowledge lives in the decorator.
      #
      # The print routes through {Countdown#print_above} because the countdown
      # owns the bottom line while it is active: the status line steps out of the
      # way, the event prints above, the status line redraws -- never a torn
      # splice. With no countdown active the only line-ending question left is
      # the decorator's own, so its answer travels with its bytes. The guard
      # covers BOTH ways an event can decline to print: no decorator at all, and
      # a decorator that rendered nothing.
      def render(event)
        decorator = Decorators.for(event)
        rendered = decorator&.render(@theme)
        @countdown.print_above(rendered, line_shaped: decorator.line_shaped?) unless rendered.nil?
      end

      # How a finished turn ENDS: the already-styled body, the rule beneath it,
      # then flush. One method rather than one copy per renderer, so a change to
      # the ending reaches a model's turn and a command's alike.
      #
      # The leading `::` below is load-bearing: unqualified `TTY::Screen` would
      # resolve `TTY` to this very class, since we are lexically inside a class
      # of the same name.
      def render_turn(styled)
        @output.puts(styled)
        @output.puts(rule)
        @output.flush
      end

      def rule
        @theme.paint(:rule, "-" * ::TTY::Screen.width)
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

    class TTY
      # Reopened rather than nested in TTY's own class body -- the shutdown.rb
      # idiom, which keeps each body within Metrics/ClassLength instead of
      # loosening it.

      private

      # The three collaborators {#read_line_with_history} drives, in the order it
      # drives them: compose the prompt string, read a line with it, durably
      # record what was accepted. Placed HERE, beside the collaborators it
      # builds, because this block is where the parts that are not "owning the
      # terminal" live. They share a `notify:` because a degraded collaborator
      # reports through the frontend's one warning line.
      def build_prompt_stack(prompt_renderer:, vi_mode:, history_path:)
        @composer = PromptComposer.new(theme: @theme, renderer: prompt_renderer, notify: method(:render_warning))
        @line_editor = LineEditor.new(vi_mode:, notify: method(:render_warning))
        @history = History.new(path: history_path, notify: method(:render_warning))
      end

      # Durable reline history: write-through on each accepted line rather
      # than dump-at-exit, so a SIGKILL between prompts loses at most nothing.
      # Durable means close()-durable (the process dying), not fsync-durable --
      # shell history does not warrant an fsync per line.
      #
      # WRITE-ONLY, and that is the whole of what changed: nothing reads this
      # file back. Up-arrow walks `Reline::HISTORY`, which Reline fills from the
      # lines THIS process accepted, so recall is scoped to the session the
      # human is sitting in.
      #
      # The file is not LOADED, because one path (`Paths#state_home`) is shared
      # by every session of every project and `lain up` puts several chat panes
      # on it at once -- so the ring a human walked was a merge of other
      # projects, other days, and the pane next door, ordered by whichever
      # process happened to flush first.
      #
      # It keeps being written because the write is what a project-scoped recall
      # would later read: {Paths#sessions_dir} already partitions by project, so
      # scoping the RECALL is a path argument at one call site.
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

      # The cache marker at the prompt. Reads {StatusFeed}'s published state
      # FILE rather than an in-process registry, since StatusFeed and TTY may be
      # different processes -- and reads it through {StatusFeed::Reading}, which
      # is the one place the deadline comparison and the two glyphs live. This
      # class is what is LEFT once that moves out: which palette colour each
      # answer takes, and the fact that "nothing published" draws nothing at all.
      #
      # Re-read on every render, deliberately. The marker a human watches for
      # while idle is the one that has to go cold on its own, and the published
      # HUD string cannot -- it is stamped at publish time, and a publish needs
      # an event.
      class Warmth
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
          case StatusFeed::Reading.at(@path).warmth(now: @clock.call)
          when :warm then "#{pastel.green(StatusFeed::Reading::WARM)} "
          when :cold then "#{pastel.dim(StatusFeed::Reading::COLD)} "
          else ""
          end
        end
      end

      # The arrival note and the /inbox drain listing. Presentation only: the
      # reply RESOLUTION stays with the caller's block.
      class Inbox
        # Both surfaces, always: which one is live is not a fact this class can
        # hold -- nvim dies mid-session and `/inbox` answers regardless -- so a
        # note naming only one would be wrong the moment the editor came or
        # went.
        POINTER = "/inbox here, or the inbox buffer in nvim"

        # {Neovim::InboxView::SENDER} clamps the same names for the editor's
        # own inbox column. Stated here rather than reached for across the
        # layer, because a frontend that has to load another to draw a line is
        # a dependency in the wrong direction.
        NAME_WIDTH = 19

        # What a human can do HERE, said once above the prompt. The document
        # below renders the same checkboxes the editor ticks and a terminal
        # has no gesture for them, so prose is the only answer this surface
        # takes -- and a row of `- [ ]` with nothing that can tick it is a
        # puzzle nobody should have to solve.
        GESTURE = "type a reply -- ticking boxes is the nvim buffer"

        # A note is one line on the TERMINAL, which is a stronger claim than
        # "holds no \n": a lone \r redraws it from column 0, so the asker and
        # everything before it is overwritten by whatever follows. Every
        # character a terminal reads as a line break is replaced by a space.
        # Stated here because this class owns the screen -- the value object
        # bounds its summary, but what a terminal does with the bytes is ours.
        BREAKS = /[\r\n\v\f\u{0085}\u{2028}\u{2029}]/

        # @param output [#puts, #flush] where the arrival note and drain listing are written
        # @param pastel [Pastel] presentation stays out of this class, as with
        #   every other TTY collaborator -- callers hand in the palette
        # @param clock [#call] absolute (wall) time for ages, {Warmth}'s seam
        def initialize(output:, pastel:, clock:)
          @output = output
          @pastel = pastel
          @clock = clock
        end

        # One line, never {TTY#render_question}'s modal block -- and one line
        # whatever the arrival's size, because what is announced is the value's
        # own `#summary`: {Announcement#summary} for a question set, already
        # the row the editor's inbox shows, and
        # {Tools::AskHuman::Handback#summary} for a reply handed back, which is
        # the bound's one-sentence measurement rather than the reply itself.
        def arrival(question, from: nil)
          @output.puts(@pastel.yellow(one_line("? #{asker(from)}#{summarized(question)}  (#{POINTER})")))
          @output.flush
        end

        # List, print the document of the set being answered, read one answer
        # through `reader`, and yield it when the human typed one. An empty
        # inbox says so and never prompts.
        #
        # `answering` is the caller's own object and is not handed back: it
        # already knows which item it named, and a round trip would only offer
        # a second place for the two to disagree.
        def drain(items, reader:, answering:)
          return render_empty if items.empty?

          @output.puts(listing(items, answering))
          @output.flush
          answer = accepted(answering, reader)
          yield answer unless answer.empty?
        end

        private

        # Read until the human types something the record can carry. Three
        # outcomes, two of which end the read: nothing typed (""), an answer the
        # record accepts, and a REFUSAL -- a reply past the answer set's byte
        # bound, or bytes that are not UTF-8 -- rendered where they typed it and
        # asked again. Raising instead unwound into the caller's `ensure` and
        # retired the only line the question could be answered through.
        #
        # Lazy, so the first settled line stops the reads; iterative rather than
        # recursive, because a caller that never types anything acceptable is a
        # real caller and each attempt would cost a frame.
        def accepted(answering, reader)
          Enumerator.produce { reader.call("human> ").to_s }
                    .lazy.filter_map { |typed| settled(answering, typed) }.first
        end

        # nil is "ask again", the one value `filter_map` drops. {Blankness}
        # rather than `strip` so this agrees, character for character, with
        # what {Question::AnswerSet} treats as no prose at all: a
        # whitespace-only line used to be yielded, dropped there as blank, and
        # rendered back as a document asserting the human had answered
        # nothing -- a claim they never made, delivered as their reply.
        def settled(answering, typed)
          return "" if Blankness.blank?(typed)

          answered(answering, typed)
        rescue ArgumentError => e
          refuse(e)
          nil
        end

        def refuse(error)
          @output.puts(@pastel.yellow("that reply cannot be recorded -- #{error.message}"))
          @output.flush
        end

        def render_empty
          @output.puts(@pastel.dim("(no questions pending)"))
          @output.flush
        end

        # Every pending item as one line, then the document of the ONE item
        # this drain answers -- never a document per item. The drain reads
        # exactly one answer, so a document for any other set would show a
        # human the questions their reply is not going to answer, which is the
        # one thing a reply surface must never do.
        def listing(items, answering)
          [*items.map { |item| line_for(item) }, *document_for(answering.question)]
        end

        # The block below the listing, asked OF the value rather than
        # assembled here: a question set renders the same markdown the editor
        # opens it in, so the two surfaces show one document rather than two
        # renderings that can disagree, and a handback of the human's own
        # oversized reply renders that reply -- which is where "shown their own
        # text again" is served, the one-line row above being the wrong place
        # for it. Type-tested for the set alone, this drew nothing at all for a
        # handback, so `/inbox` offered a confirmation with nothing to confirm.
        #
        # A bare String on this seam has no document, which is a documented
        # case rather than an oversight.
        def document_for(question)
          return [] unless question.respond_to?(:document)

          ["", question.document.chomp, "", @pastel.dim(GESTURE)]
        end

        # A typed reply answers the WHOLE set in prose, and the caller resolves
        # with that value's own rendering -- byte-identical to the editor's `:w`
        # path, so the model cannot tell which surface a prose answer came from.
        # The human's words are blockquoted there, so nothing they type can forge
        # the grammar.
        #
        # A question carrying no set answers with the line as typed, still held
        # to what the record can hold: an answer that cannot be written reaches
        # the Store and raises THERE, one frame past every surface that could
        # have let the human retype it.
        def answered(item, answer)
          question = item.question
          return Question::Rules.prose(answer, "a typed reply") unless question.is_a?(Tools::AskHuman::Announcement)

          Question::AnswerSet.new(questions: question.set, text: answer).render
        end

        # Sender and age lead so a glance answers "who is stuck, and for how
        # long" before the question itself is read. One line per item, which
        # is the summary's job and not the bytes': for a LONE question those
        # bytes are the body verbatim, so a question with a table in it was a
        # five-line row that buried the item under it and then repeated,
        # verbatim, in the document below.
        def line_for(item)
          one_line("#{@pastel.yellow(clamped(item.from))} #{@pastel.dim(age_of(item.asked_at))}  " \
                   "#{summarized(item.question)}")
        end

        # An {Announcement}'s BYTES are a lone question's body verbatim -- a
        # table or a fenced diff, deliberately, because the document below
        # renders them -- so every one-line surface reads the summary it
        # derived instead. Bounded there, never re-clamped here.
        #
        # Asked by MESSAGE, not by class, and the class test is what broke:
        # {Tools::AskHuman::Handback} is a String subclass too, and its bytes
        # are the measurement followed by the entire oversized reply. Passed
        # through as a bare String it printed 64 KiB -- or 5 MiB -- as one
        # unwrapped terminal line, where the same seam clamps a 5,000-byte
        # {Announcement} to under 200. A genuinely bare String is still its own
        # summary: that is what a caller announcing prose meant.
        def summarized(question)
          question.respond_to?(:summary) ? question.summary : question
        end

        def one_line(text) = text.gsub(BREAKS, " ")

        # "" for an arrival nobody attributed, so the note concatenates back to
        # the unattributed line rather than branching on a missing name.
        def asker(from)
          name = clamped(from)
          name.empty? ? "" : "#{name} "
        end

        def clamped(from) = from.to_s[0, NAME_WIDTH]

        # Coarse on purpose: the inbox answers "how stale", not "when exactly".
        def age_of(asked_at)
          seconds = (@clock.call - asked_at).to_i
          return "#{seconds}s" if seconds < 60
          return "#{seconds / 60}m" if seconds < 3600

          "#{seconds / 3600}h"
        end
      end

      # Renders the status line, owns the bottom of the screen while active, and
      # forwards offered keys to the shutdown coordinator. Nested rather than its
      # own file: this collaborator has no life outside a TTY.
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
        # @param options [Hash] the window's collaborators, passed through whole
        # @option options [#signal] :coordinator required; where a pressed key lands
        # @option options [Hash] :bindings single-char key -> input symbol;
        #   defaults to {DEFAULT_BINDINGS}
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
        # and the status line redraws; otherwise the decorator's own answer
        # decides whether the bytes get terminated.
        #
        # @param rendered [String] the decorator's bytes
        # @param line_shaped [Boolean] the decorator's answer to whether those
        #   bytes are a whole line. Required rather than defaulted: a caller
        #   that has not asked is exactly the caller this guard was filed against.
        def print_above(rendered, line_shaped:)
          @lock.synchronize do
            active? ? above(rendered) : plain(rendered, line_shaped)
            @output.flush
          end
        end

        # Bytes straight to the screen, under the SAME lock {#print_above}
        # holds. The completion menu draws through here rather than
        # inventing a lock of its own: a menu, a countdown tick and a channel
        # event all write to one terminal while the prompt is live, and two
        # locks over one stream is two locks that can interleave a torn write.
        # No status-line dance, because the menu carries its own cursor
        # discipline (save / step down / clear below / restore) and asks this
        # class for nothing but serialization.
        def draw(bytes)
          @lock.synchronize do
            @output.print(bytes)
            @output.flush
          end
        end

        private

        def active? = !@line.nil?

        # Unconditionally terminated, for BOTH decorators: the fresh row here
        # is the redrawn STATUS LINE's need, not the content's, and it is
        # equally needed after a mid-line tool chunk. Asking the decorator here
        # would land the bold status line inside such a chunk.
        def above(rendered)
          @output.print(::TTY::Cursor.clear_line)
          @output.print(rendered)
          terminate(rendered)
          @output.print(@pastel.bold(@line))
        end

        # No status line to protect, so the newline is the decorator's question
        # rather than the terminal's -- and a tool chunk answering no keeps its
        # bytes exactly where the command put them.
        def plain(rendered, line_shaped)
          @output.print(rendered)
          terminate(rendered) if line_shaped
        end

        def terminate(rendered)
          @output.puts unless rendered.end_with?("\n")
        end

        # Both output and input must be real terminals: escapes drawn on a
        # non-terminal output are noise, and single-key reads off a non-terminal
        # input read whatever this process's stdin actually is -- a pipe, a
        # redirect -- rather than an interactive choice.
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

        # The window opens once, on the first interactive tick: raw+no-echo for
        # the WHOLE window, not a per-read bracket -- a keystroke landing between
        # per-tick brackets would be cooked and ECHO would bleed it onto the
        # status line until the next tick wiped it, caught by a PTY probe. The
        # mode in force is saved so {#stop} can put it back.
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
