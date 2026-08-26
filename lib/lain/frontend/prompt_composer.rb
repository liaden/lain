# frozen_string_literal: true

require "tty-screen"

module Lain
  module Frontend
    # The seam between "what the prompt should say" and "what the line editor
    # is handed". A RENDERER composes the string from whatever run state it
    # cares about -- model, occupancy, elapsed time -- and this class turns
    # that string into something a line editor can actually accept.
    #
    # Two jobs, and they are why the seam is an object rather than a lambda at
    # the call site:
    #
    # 1. **Split.** Reline fixes its prompt to ONE line: `line_editor.rb`
    #    rewrites a newline in the prompt to a literal backslash-n, so a
    #    two-line rendering arrives mangled rather than wrapped. The frontend
    #    prints everything above the last line itself and hands the editor only
    #    the last.
    # 2. **Contain.** A renderer reads live run state, and live run state raises
    #    -- {Agent#occupancy} on a blank model, {Ext::Prompt} on an unknown style
    #    word at RENDER time. A renderer is called once per prompt, so one such
    #    mistake is not an ugly REPL but an unusable one. The shipped renderer
    #    contains both cases itself, closer to where it knows what they mean, so
    #    this net is here for the renderer nobody has written yet.
    #
    # Containment is total but never SILENT: the fallback is a rendered warning,
    # once. {Theme::UnknownToken} is a `KeyError`, so a rescue broad enough to
    # keep the REPL alive is broad enough to hide a misspelled style token, and
    # a styling bug that renders plain in silence is the outcome to avoid.
    # Warning once rather than per prompt is what keeps a broken renderer from
    # becoming a second broken thing.
    #
    # {#compose} is pure ON THE SUCCESS PATH -- a function of its argument and
    # the renderer's own state, no memoization -- so a caller may call it as
    # often as it likes. The degrade path is deliberately NOT pure: it moves the
    # warned-once latch and calls `notify`.
    #
    # Named `PromptComposer`, not `Prompt`, because `Prompt` here would SHADOW
    # {Lain::Prompt} -- the prompt-format language -- for every file lexically
    # inside `module Frontend`, which is the hazard tty.rb's leading `::` on
    # `::TTY::Screen` already guards against once. `cli/repl.rb` sits next door
    # and uses the format language; a bare `Prompt` there would silently
    # resolve to this class.
    class PromptComposer
      # What a renderer's failure looks like. `StandardError` is the ordinary
      # case; `ScriptError` catches the half-built renderer (`raise
      # NotImplementedError`, a `LoadError` from an optional dependency) that
      # is NOT a StandardError and would otherwise take the prompt down; and
      # `SystemStackError` catches a renderer that recurses into run state.
      #
      # Deliberately NOT `Exception`: `Interrupt`, `SignalException`,
      # `SystemExit` and `NoMemoryError` are the human's or the OS's decision,
      # not the renderer's bug. Swallowing Ctrl-C here would leave no way to
      # interrupt a renderer that has gone wrong in some way a rescue cannot
      # fix.
      RENDERER_FAULTS = [StandardError, ScriptError, SystemStackError].freeze

      # The Null notifier ({Sink::Null}'s shape): satisfies the same `#call`
      # duck and sends the message nowhere, so {#compose} never asks whether
      # anyone is listening. A frontend passes `method(:render_warning)`.
      SILENT = ->(_message) {}

      # Two fields rather than one string because the split is the frontend's
      # contract with Reline, and a value that has already made it cannot be
      # handed over half-applied.
      Rendering = Data.define(:header, :line) do
        # Tell-Don't-Ask, and the reason the split is safe: a caller that read
        # `line` on its own would silently drop the header, which is the exact
        # bug the split exists to prevent.
        #
        # @param output [#puts, #flush] the frontend's stream, never $stdout
        #   directly -- this class is inside lib/lain/frontend, but the stream
        #   is still the caller's to own
        def editor_line(output)
          header.each { |above| output.puts(above) }
          output.flush
          line
        end
      end

      # The renderer that composes nothing, so {#compose} has one path and the
      # default prompt is not a special case of itself. `**` rather than a named
      # `theme:`: it accepts every keyword a renderer may be handed and ignores
      # all of them.
      class Null
        def call(text:, **) = text
      end

      # @param theme [Frontend::Theme] handed to the renderer on every call,
      #   the {TTY::Warmth#prefix} precedent -- presentation config is passed
      #   in rather than held, so one theme serves the whole frontend
      # @param renderer [#call] `call(text:, theme:) -> String`; the string may
      #   contain newlines
      # @param notify [#call] renders a degraded-path warning line
      #   ({TTY#render_warning}) -- presentation stays out of this class, as it
      #   does out of {TTY::History}
      def initialize(theme:, renderer: Null.new, notify: SILENT)
        @theme = theme
        @renderer = renderer
        @notify = notify
        @warned = false
      end

      # @param text [String] the prompt the frontend would show with nobody
      #   composing anything -- already styled, already carrying whatever
      #   prefix the frontend prepends
      # @return [Rendering]
      def compose(text)
        rendering = split(@renderer.call(text:, theme: @theme))
        @warned = false
        rendering
      rescue *RENDERER_FAULTS => e
        warn_degraded(e)
        split(text)
      end

      private

      # Once per contiguous failure RUN, which is why {#compose} re-arms the
      # latch on every success. A warning per prompt buries the session it is
      # trying to explain, while a warning once per process hides an outage that
      # starts after the first one ended -- and run state flaps, so it does.
      def warn_degraded(error)
        return if @warned

        @warned = true
        @notify.call("warning: prompt renderer unavailable (#{error.message})")
      end

      # `split("\n", -1)` keeps the trailing empty field, so a rendering that
      # ends in a newline means an empty editor line rather than a silently
      # dropped header. An empty string splits to `[]` -- Ruby special-cases
      # it -- which destructures to `line = nil`, hence the `to_s`.
      #
      # A `Data` instance is already frozen, but the Array inside it is not.
      # Freezing it is free here and makes the rendering immutable all the way
      # down, which is what a value handed across a seam should be.
      def split(rendered)
        *header, line = rendered.split("\n", -1)
        Rendering.new(header: header.freeze, line: line.to_s.freeze)
      end
    end

    class PromptComposer
      # Reopened rather than grown inside the body above -- tty.rb's idiom,
      # which keeps each body inside Metrics/ClassLength instead of loosening
      # it. This half fills the renderer seam.

      # The prompt lain ships with, beside {Lain::Prompt}'s other prompt assets
      # under `lib/lain/prompt/`. `lain.gemspec` builds `spec.files` from `git
      # ls-files` with a reject list that spares `lib/`, so a committed TOML
      # ships with the gem and needs no manifest line of its own.
      DEFAULT_CONFIG = File.expand_path("../prompt/default.toml", __dir__)

      # Room a composed line has when the config names no `max_width`. Read ONCE
      # per chat -- {Formatted#resolve_room} has the fork/exec reason.
      #
      # The leading `::` is the class doc's shadow warning from this side: bare
      # `TTY` inside `module Frontend` is {Frontend::TTY}, and `TTY::Screen`
      # would be a NameError under it.
      SCREEN = -> { ::TTY::Screen.width }

      # The project's own, then the machine's, then what we ship: narrowest
      # scope that answered wins. NOT `$XDG_STATE_HOME/lain`, where the state
      # feed lives -- a prompt format is something a user writes and may commit,
      # and machine state is not.
      def self.config_path(paths: Paths.new, project: Dir.pwd)
        [File.join(project, ".lain", "prompt.toml"), File.join(paths.config_home, "prompt.toml")]
          .find { |candidate| File.exist?(candidate) } || DEFAULT_CONFIG
      end

      # The renderer a run's prompts go through.
      #
      # A config that will not parse degrades to {Null} -- today's prompt --
      # and says so once, naming the file. Loud, because a config silently
      # ignored is a config the human keeps editing; non-fatal, because a typo
      # in a prompt format must not cost a chat.
      #
      # `EncodingError` is in the rescue list because it is NOT under
      # {Lain::Error}: {Lain::Ext::Prompt.from_toml} refuses non-UTF-8 bytes with
      # Ruby's own class, and nothing above catches it. Without it, one Latin-1
      # byte in a config aborted the REPL with a backtrace BEFORE a prompt
      # existed.
      #
      # @param state [#to_h] the run's readings; a {RunState} in a live chat
      # @param path [String] the config to compile
      # @param screen [#call] columns available, called at most ONCE
      # @param notify [#call] the caller's startup-notice seam
      # @return [#call] `call(text:, theme:) -> String`
      def self.renderer(state:, path: config_path, screen: SCREEN, notify: SILENT)
        Formatted.new(format: Lain::Ext::Prompt.from_toml(File.read(path)), state:, path:, screen:, notify:)
      rescue Lain::Error, EncodingError, SystemCallError => e
        notify.call("warning: prompt config #{path} did not load (#{e.message}); using the plain prompt")
        Null.new
      end

      # Today's prompt with the run's state composed ABOVE it, never around it:
      # the text this is handed is already styled and already carries the
      # frontend's warmth prefix, and interpolating it as a variable would strip
      # every control byte out of it, since the formatter sanitizes Cc on the way
      # in. So the composed line takes its own row and the editor's line arrives
      # byte for byte.
      class Formatted
        # The WIDEST of its lines, never `.width` over the whole string: that
        # counts a literal "\n" as zero, so a multi-line source reports the SUM
        # of its lines' widths, which is not a terminal column. Graphemes, not
        # characters, is the other half -- unicode-width 0.2 stopped defining a
        # str's width as the sum of its chars', which is why a ZWJ family emoji
        # is one glyph here and three under a naive per-char sum.
        def self.columns(rendered)
          rendered.lines.map { |line| Lain::Ext::Prompt.width(line) }.max.to_i
        end

        # What a screen that will not answer is worth assuming. The classic
        # terminal default, and the same number `TTY::Screen` itself falls back
        # to when every one of its detection strategies comes up empty.
        FALLBACK_COLUMNS = 80

        # @param format [Lain::Ext::Prompt] compiled once, rendered per prompt
        # @param state [#to_h] the run's readings -- a Hash answers this too,
        #   which is why a spec needs no stand-in class
        # @param path [String] the config this format was read from. Required,
        #   not defaulted: every degraded-path warning names the file the human
        #   has to open, and with three config layers a default would let a
        #   caller silently misattribute one.
        # @param screen [#call] columns available, called at most ONCE
        # @param notify [#call] renders a degraded-path warning line
        def initialize(format:, state:, path:, screen: SCREEN, notify: SILENT)
          @format = format
          @state = state
          @path = path
          @notify = notify
          @warned = false
          @room = resolve_room(screen)
        end

        def call(text:, theme:)
          status = @format.render(@state.to_h, color: theme.enabled?)
          @warned = false
          fits?(status) ? "#{status}\n#{text}" : text
        rescue Lain::Ext::Prompt::StyleError => e
          warn_unstyled(e)
          text
        end

        private

        # A composed line wider than its room wraps, and a wrapped row above the
        # cursor smears the moment anything redraws. A blank rendering takes the
        # same path -- a chat with nothing to report is not owed an empty row.
        def fits?(status)
          !status.strip.empty? && Formatted.columns(status) <= @room
        end

        # Read ONCE, here, and not at all when the config named its own
        # `max_width`. `TTY::Screen.width` looks cheap and is not: it memoizes
        # nothing, and with no ioctl answer -- a pty whose winsize was never set,
        # the default in plenty of pty and CI contexts -- its chain falls through
        # to `size_from_tput`, which shells out `tput lines` AND `tput cols`.
        # Measured: 200 subprocess spawns per 100 width reads, 3.0 ms per prompt
        # against 9 us for the render itself. Avoiding a fork/exec per prompt is
        # the ENTIRE argument for composing in process.
        #
        # Deliberately NOT refreshed on SIGWINCH. Reline installs its own WINCH
        # handler for the line editor's redraw and `Signal.trap` REPLACES rather
        # than chains, so trapping it here would break the editor's resize to
        # keep a status row from wrapping. A terminal resized mid-chat keeps the
        # width it started with.
        def resolve_room(screen)
          usable(@format.settings["max_width"]) || usable(read_screen(screen)) || FALLBACK_COLUMNS
        end

        def usable(value) = value.is_a?(Integer) && value.positive? ? value : nil

        # Total, because an injected thunk is a caller's code and this runs
        # while a chat is being assembled: a nil, a String, or a raise all mean
        # "no answer", and {FALLBACK_COLUMNS} stands in. A prompt must not be
        # lost over a screen measurement.
        def read_screen(screen)
          screen.call
        rescue StandardError
          nil
        end

        # A `$style` variable resolves at RENDER time, so an unknown word is a
        # per-prompt refusal compiling the config could not have caught. Rescued
        # here rather than by {PromptComposer}'s own net because only this object
        # knows a CONFIG supplied the word.
        #
        # Once per contiguous failure RUN, {PromptComposer#warn_degraded}'s
        # policy: a `$style` word arrives in the variables, which is run state,
        # and run state flaps.
        def warn_unstyled(error)
          return if @warned

          @warned = true
          @notify.call("warning: prompt config #{@path} style unusable (#{error.message})")
        end
      end

      # What the run knows, in the vocabulary a prompt format writes against.
      # Separate from {Formatted} because "what is happening" and "how a format
      # says it" are two questions, and only this half touches the Agent.
      #
      # Every reading is ABSENT rather than zero when it has nothing to say, so
      # a format's `( ... )` group elides instead of rendering "fleet 0".
      class RunState
        MINUTE = 60
        HOUR = 3600

        # Past this a reading says nothing a human wants at a prompt. A ratio
        # over 1.0 is ORDINARY rather than a bug: a model no book carries and no
        # server reports on divides by {ContextWindow::CONSERVATIVE_FALLBACK},
        # which is deliberately small so compaction fires early. "412%" is noise
        # either way, and {CLI::Up::Hud} clamps for the same reason.
        FULL = 1.0

        # @param agent [#occupancy, #context, #dispatching?] the LIVE agent, so
        #   a /model switch shows at the next prompt rather than at the next run,
        #   and so a dispatch in flight can silence a reading that would lie
        # @param clock [Lain::RunClock] the run's own, the instance
        #   {CLI::Conductor} records input on
        # @param status_feed [#state] the published struct; `"fleet"` and
        #   `"derivation_refusal_streak"` are the readings this class takes
        #   from it
        # @param mode [#posture, #layers, nil] the session's live mode -- a
        #   {Lain::Mode} value or a {Mode::Switch} both answer this duck. nil
        #   until the mode ladder is wired into a live chat, so a caller that
        #   passes nothing gets a `#to_h` reporting no mode.
        def initialize(agent:, clock:, status_feed:, mode: nil)
          @agent = agent
          @clock = clock
          @status_feed = status_feed
          @mode = mode
        end

        def to_h
          { "model" => @agent.context.model, "occupancy" => occupancy, "fleet" => fleet, "idle" => idle,
            "mode" => mode, "compaction" => compaction }
        end

        private

        # NO keyword, deliberately: the book is the AGENT's, set once when the
        # chat was wired, so this segment and the state feed report one occupancy
        # for one turn. Passing a book here would be this class deciding a
        # denominator it has no way to resolve, which is how the two surfaces
        # came to disagree.
        #
        # The book is loud about a blank model slot and {Lain::Agent#occupancy}
        # lets it raise. A prompt is not the place to answer for a wiring bug:
        # absence is the only honest reading left, and the missing segment is
        # itself the signal.
        def occupancy
          ratio = @agent.occupancy
          ratio && "#{(ratio.clamp(0.0, FULL) * 100).round}%"
        rescue ContextWindow::UnknownModel, ArgumentError
          nil
        end

        def fleet
          size = @status_feed.state["fleet"].size
          size.positive? ? size.to_s : nil
        end

        # ABSENT for a healthy session, {#fleet}'s convention, so the `( ... )`
        # group elides rather than rendering a standing "compaction ok" nobody
        # asked for. {Compaction::Source::Derived.stalled?} decides WHETHER a
        # streak is a stall -- asked, never re-implemented here, because a
        # threshold exported across two namespaces grows a second `>=` in the
        # next reader and the two drift.
        #
        # `to_i` rather than a nil guard: a feed that has published no streak
        # reads as zero, which is healthy, and absence must never render as a
        # stall. That covers a state struct written before the field existed AND
        # a `--no-journal --no-nvim` run, where no tee is built and this reads
        # absent for the life of the session.
        #
        # THE READING LATCHES, deliberately. Only a SUCCESSFUL derivation clears
        # the streak, so a session that refused twice and then settled into the
        # warm-cache defer band goes on reporting a stall while nothing is being
        # refused. What "stalled" says is: no derivation has succeeded since
        # `stalled?`'s worth of consecutive refusals -- this session has stopped
        # shrinking its context and is rendering the full history. It does NOT
        # say a derivation was attempted and failed on this turn.
        #
        # Decaying it was refused. `compacted: false` covers both a defer and a
        # refusal, and a refusing turn writes both records, so a sink clearing on
        # it would clear the streak on the very turn that just refused. And a
        # defer is no evidence the chain became derivable: refusals are
        # deterministic over a history that only grows, so clearing on one trades
        # a reading that is LATE for one that is WRONG.
        def compaction
          streak = @status_feed.state["derivation_refusal_streak"].to_i

          Compaction::Source::Derived.stalled?(streak) ? "stalled" : nil
        end

        # The posture's own lighter, then every active layer's, in the precedence
        # order {Mode#describe} reports -- `LayerSet#layers` already
        # canonicalizes to declaration order. An empty result is nil for {#fleet}
        # and {#occupancy}'s reason: a `( ... )` group elides a variable that is
        # absent, never one that is an empty String rendered anyway.
        def mode
          return nil unless @mode

          lighters = [@mode.posture.lighter, *@mode.layers.layers.map(&:lighter)].reject(&:empty?)
          lighters.empty? ? nil : lighters.join(" ")
        end

        # {RunClock#idle} answers seconds since the human last TYPED, which only
        # describes the run while nothing is running. The two diverge at the
        # `human>` prompt a parked `ask_human` opens: a dispatch is in flight,
        # the composer runs anyway, and the line read "qwen3-coder:30b idle 0s"
        # while ollama was prefilling 4,339 tokens. An operator driving on "retry
        # until the status leaves idle" turned one prompt into four journaled
        # turns on the strength of it.
        #
        # {Agent#dispatching?} rather than {Agent#state}: the state records what
        # the loop was last DOING, so a torn turn leaves it parked in
        # `:awaiting_model` and would suppress this reading for the rest of the
        # session. The clock is not wrong and is not changed -- the segment
        # simply has nothing to say mid-dispatch, and the shipped format keeps
        # the literal word "idle" inside the same `( ... )` group, so eliding the
        # reading elides the claim.
        #
        # NOT an endless method: `def idle = expr unless cond` parses as
        # `(def idle = expr) unless cond`, so the guard would run once at
        # class-body level against a nil receiver rather than per call. Verified
        # -- it raised NoMethodError while lain.rb was still loading.
        def idle
          humanize(@clock.idle) unless @agent.dispatching?
        end

        # Coarse on purpose, {TTY::Inbox#age_of}'s shape: a prompt answers "how
        # long have I been away", never "when exactly".
        def humanize(seconds)
          return "#{seconds.round}s" if seconds < MINUTE
          return "#{(seconds / MINUTE).round}m" if seconds < HOUR

          "#{(seconds / HOUR).round}h"
        end
      end
    end
  end
end
