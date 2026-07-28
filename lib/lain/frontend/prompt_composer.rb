# frozen_string_literal: true

module Lain
  module Frontend
    # The seam between "what the prompt should say" and "what the line editor
    # is handed". A RENDERER composes the string from whatever run state it
    # cares about -- model, occupancy, elapsed time -- and this class turns
    # that string into something a line editor can actually accept.
    #
    # Two jobs, and they are the two reasons the seam is an object rather than
    # a lambda at the call site:
    #
    # 1. **Split.** Reline fixes its prompt to ONE line: `line_editor.rb`
    #    rewrites a newline in the prompt to a literal backslash-n, so a
    #    two-line rendering arrives mangled rather than wrapped. The frontend
    #    prints everything above the last line itself and hands the editor only
    #    the last -- see {Rendering}.
    # 2. **Contain.** A renderer reads live run state, and live run state
    #    raises: {Agent#occupancy} raises on a blank model, so one wiring
    #    mistake in a renderer is one raise per prompt, which is an unusable
    #    REPL rather than an ugly one. A renderer that fails degrades to the
    #    text it was given and the human keeps typing.
    #
    # Containment is total but never silent, which is the same trade
    # {TTY::History} makes for an unwritable history file: the fallback is a
    # rendered warning, ONCE, not an exception and not nothing. A misspelled
    # style token is the case that forces this -- {Theme::UnknownToken} is a
    # `KeyError`, so a rescue broad enough to keep the REPL alive is broad
    # enough to hide it, and CLAUDE.md's loud-failure rule says a styling bug
    # that renders plain in silence is the outcome to avoid. Warning once
    # rather than per prompt is what keeps a broken renderer from becoming a
    # second broken thing.
    #
    # {#compose} is pure ON THE SUCCESS PATH -- a function of its argument and
    # the renderer's own state, with no memoization -- so a caller may call it
    # as often as it likes, once per prompt today or once per tick if something
    # later wants to redraw. The degrade path is deliberately NOT pure: it moves
    # the warned-once latch and calls `notify`. It does not own the bottom line
    # and does not arbitrate with {TTY::Countdown}; it only answers what the
    # prompt says.
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

      # A composed prompt, already split for the line editor: print `header`
      # (often empty), then hand `line` over. Two fields rather than one string
      # because the split is the frontend's contract with Reline, and a value
      # that has already made it cannot be handed over half-applied.
      Rendering = Data.define(:header, :line) do
        # Put the header on the screen and hand back the one line the editor
        # gets. Tell-Don't-Ask, and the reason the split is safe: a caller that
        # read `line` on its own would silently drop the header, which is the
        # exact bug the split exists to prevent. Both fields stay readable for
        # anyone asserting on a rendering rather than drawing one.
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

      # The renderer that composes nothing: the prompt is exactly the text the
      # frontend already built. Null Object rather than a `nil` check, so
      # {#compose} has one path and the default prompt is not a special case of
      # itself.
      #
      # `**` rather than a named `theme:`: it accepts every keyword a renderer
      # may be handed, today's and tomorrow's, and ignores all of them.
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
      # latch on every success. Two failures to avoid, and only this shape
      # avoids both: a warning per prompt buries the session it is trying to
      # explain, while a warning once per process hides an outage that starts
      # after the first one ended -- and run state flaps, so it does. That is
      # the difference from {TTY::History}, whose warn-once is right precisely
      # because a file that becomes unwritable stays unwritable.
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
  end
end
