# frozen_string_literal: true

require "pastel"
require "tty-color"

module Lain
  module Frontend
    # A named style vocabulary over Pastel. Renderers name a TOKEN -- `:error`,
    # `:response`, `:tool_error` -- and the theme is the only object that knows
    # which colour a token resolves to. That indirection is what lets a value
    # outside `lib/lain/frontend/` (a command's renderable) describe how it wants
    # to read without importing colour knowledge into non-frontend code, which
    # output discipline keeps out.
    #
    # Every token names INTENT, never a mechanism: `:error` is the harness's own
    # error line, `:tool_error` is a subprocess's fd-2 bytes. They are two ideas
    # that happen to share a colour family, and neither is named `:stderr` --
    # keying the vocabulary off `Telemetry::ToolOutput`'s stream enum would make
    # this class break whenever that enum grew. The stream -> token mapping lives
    # with the decorator that knows about streams.
    #
    # **What `#enabled?` and `#depth` each promise.** `enabled?` is the ONLY test
    # for "will this emit escape sequences": it is the palette's own switch, and
    # it is what a caller checks before assuming plain bytes. `depth` is
    # advisory. It reports what the terminal claims to support, and a terminal
    # can claim 0 while the palette is still enabled (`TERM=dumb` on a real tty:
    # `enabled? == true`, `depth == 0`, and `paint` still emits `\e[36m`). Depth
    # changes exactly one thing about rendering -- the bright downgrade below --
    # and nothing else should be predicted from it.
    #
    # Pastel 0.8 offers 16 named colours and their bright variants -- no hex, no
    # 256, no `38;2` -- so there is deliberately no SGR quantizer here. A token
    # resolves to Pastel attribute names, and the one depth rule that exists is
    # that a `bright_` variant degrades to its base colour below 16 colours.
    # Both depth and the resolved table are settled in the constructor:
    # detection shells out to terminfo, and doing it lazily would fork a
    # subprocess from inside the render loop -- and race, because {TTY} shares
    # one theme between the main thread and the channel-drain thread.
    #
    # There is no `Theme::Null`, and that is the point of the loud-failure rule:
    # a null theme would have to answer EVERY token, including a misspelled one,
    # and answering it silently is exactly why `StringInquirer` was rejected
    # (see CLAUDE.md). The no-colour theme is this same class holding a disabled
    # Pastel -- {.for} on a non-tty stream builds it -- so it satisfies the same
    # duck, emits no escapes, and still raises on `:erorr`.
    class Theme
      # Raised for a token nobody registered. A missing token must never render
      # plain: silent plain text is a styling bug that survives to production.
      class UnknownToken < KeyError; end

      # The vocabulary, and the literal Pastel call each token replaced. Deeply
      # frozen: this is public, callers `merge` into it, and a mutable value
      # array would let one caller permanently restyle every theme in the
      # process. The deep freeze is also what makes it `Ractor.shareable?`.
      # `:tool_output` and `:plain` are registered with NO style on purpose --
      # their renderer names a token either way, so both branches go through the
      # vocabulary instead of one naming red and the other naming nothing, and a
      # misspelled token still raises rather than quietly rendering as prose.
      # `:warm`/`:cold` are the cache's own two states ({CLI::Command::Status},
      # {TTY::Warmth}), a single intent with two values -- not a colour pair.
      DEFAULT_TOKENS = {
        response: %i[cyan],              # TTY#render_response
        rule: %i[dim],                   # TTY#rule
        error: %i[red bold],             # TTY#render_error
        question_label: %i[yellow bold], # TTY#render_question's heading
        question: %i[yellow],            # TTY#render_question's body
        warning: %i[yellow],             # TTY#render_warning
        prompt: %i[bold],                # TTY#read_line_with_history
        label: %i[dim],                  # Decorators::ToolOutput's attribution
        tool_error: %i[red],             # a tool subprocess's stderr bytes
        tool_output: [],                 # a tool subprocess's stdout bytes
        plain: [],                       # a Renderable's own unstyled prose
        warm: %i[green],                 # the prompt cache is still inside its TTL
        cold: %i[dim],                   # the cache went cold, or never warmed
        match: %i[green bold]            # the characters a query matched (Completion::Menu)
      }.transform_values(&:freeze).freeze

      # Colour is off unless the stream is a real terminal, matching {TTY}'s own
      # default palette rule.
      #
      # A caller may pass `pastel:` through, and it wins over the tty-derived
      # palette. That is the intended override seam -- forcing colour on for a
      # pipe (`--color=always`) or off for a terminal is a real request, and
      # this is the one place to make it.
      #
      # @param stream [#tty?] the stream this theme will be styling for
      def self.for(stream, **)
        new(pastel: Pastel.new(enabled: stream.tty?), **)
      end

      # @return [Integer] what the terminal claims to support (tty-color's
      #   0/8/16/256/16_777_216), or 0 when this theme emits no colour at all.
      #   Advisory -- see the class comment; {#enabled?} is the plain-bytes test.
      attr_reader :depth

      # @param pastel [Pastel] the palette; a disabled one makes this the
      #   no-colour theme
      # @param tokens [Hash{Symbol=>Array<Symbol>}] token -> Pastel attributes
      # @param detect [#call] colour-depth source, injectable so a spec never
      #   depends on the terminal it happens to run under. Called at most once,
      #   here, and not at all when the palette is disabled.
      def initialize(pastel:, tokens: DEFAULT_TOKENS, detect: -> { ::TTY::Color.mode })
        @pastel = pastel
        @depth = pastel.enabled? ? detect.call : 0
        @styles = resolve(tokens)
      end

      # @param token [Symbol] a registered token
      # @param text [String]
      # @return [String] `text` styled, or `text` itself when the palette is
      #   disabled or the token carries no attributes
      # @raise [UnknownToken] when nobody registered `token`
      def paint(token, text)
        @pastel.decorate(text, *styles_for(token))
      end

      def enabled? = @pastel.enabled?

      # @return [Array<Symbol>] the registered vocabulary
      def tokens = @styles.keys

      def token?(name) = @styles.key?(name)

      private

      # Resolved once, in the constructor: below 16 colours every paint would
      # otherwise re-derive the same downgraded array, and a renderable paints
      # once per segment.
      def resolve(tokens)
        tokens.transform_values { |styles| within_depth(styles).freeze }.freeze
      end

      # Bright variants are a 16-colour feature; below that the base colour is
      # the honest rendering of the same intent.
      #
      # The `dup` is what keeps {#resolve}'s freeze off a caller's own array:
      # below 16 colours `map` already returns a copy, so without it a caller
      # passing `tokens: { mine: array }` would find `array` frozen on a
      # 256-colour terminal and untouched on an 8-colour one. A side effect that
      # only reproduces on some machines is worse than the allocation it saves.
      def within_depth(styles)
        return styles.dup if @depth >= 16

        styles.map { |style| style.to_s.delete_prefix("bright_").to_sym }
      end

      def styles_for(token)
        @styles.fetch(token) { raise UnknownToken, unknown_message(token) }
      end

      def unknown_message(token)
        "unknown style token #{token.inspect}; registered: #{tokens.map(&:inspect).join(", ")}"
      end
    end
  end
end
