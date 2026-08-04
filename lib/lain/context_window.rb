# frozen_string_literal: true

module Lain
  # A per-model context-window token limit, keyed by model name. Mirrors
  # {PriceBook}'s resolution shape (`price_book.rb:50-70`) so the two lookup
  # books never disagree about what a model name means: exact match, then the
  # longest known family token the name contains, then an optional explicit
  # `fallback`, else {UnknownModel}.
  #
  # Unlike {PriceBook}'s shared default (which raises on an unknown model --
  # a silently-free price is a lie on a cost bench), {.default} here carries a
  # conservative fallback. `Backend::PROVIDERS` includes `ollama` and
  # `bedrock` (`cli/backend.rb:27`), whose model ids will never appear in an
  # Anthropic-shaped table, and this book backs compaction's
  # `Need::ApproachingWindow`, which is on by default (A8). A raise here would
  # turn a supported provider into a startup crash; the explicit constructor
  # (no `fallback:`) still raises, for a bench arm that wants that loudly.
  class ContextWindow
    class UnknownModel < Error; end

    # Context windows in tokens, for the Anthropic model families this bench
    # actually targets (`Provider::Anthropic::DEFAULT_MODEL` is
    # "claude-opus-4-8"; `Provider::BedrockReference::DEFAULT_MODEL` is
    # "anthropic.claude-opus-4-8", which still resolves through the "opus"
    # token). Figures are Anthropic's published context windows: Opus
    # (4.6/4.7/4.8) and Sonnet 4.6 are 1,000,000 tokens at standard pricing
    # (no long-context premium); Haiku 4.5 is 200,000.
    #
    # Legacy dated/aliased ids get their OWN longer keys, more specific than
    # the bare family token: PriceBook can price a legacy Anthropic model at
    # its family's rate (an accepted approximation -- pricing is close enough
    # across a generation), but a WINDOW is not close enough -- the review
    # panel's probe found `claude-opus-4-5`, `claude-opus-4-1-20250805`,
    # `claude-sonnet-4-5-20250929`, `claude-sonnet-4-20250514`, and
    # `claude-3-5-sonnet-*` all silently over-estimating 5x against a real
    # 200,000, which is exactly the failure this card's own escalation
    # trigger warns about: an over-estimate means `Need::ApproachingWindow`
    # never fires for that model. `--model` is a free-form CLI string, so a
    # user reaches this.
    #
    # "claude-sonnet-4" is deliberately NOT a key: `"claude-sonnet-4-6"`
    # (current-gen, 1,000,000) contains "claude-sonnet-4" as a prefix, so
    # that shorter token would incorrectly outrank "sonnet" for Sonnet 4.6
    # too. Sonnet 4's dated id is used verbatim instead -- there is no
    # substring that names "Sonnet 4" without also naming "Sonnet 4.6".
    DEFAULTS = {
      "opus" => 1_000_000,
      "sonnet" => 1_000_000,
      "haiku" => 200_000,
      "claude-opus-4-5" => 200_000,
      "claude-opus-4-1" => 200_000,
      "claude-sonnet-4-5" => 200_000,
      "claude-sonnet-4-20250514" => 200_000,
      "claude-3-5-sonnet" => 200_000
    }.freeze

    # Ollama's `DEFAULT_MODEL` (`qwen3:4b`) and arbitrary Bedrock ids never
    # match a token above. 8,192 is comfortably below Haiku's 200,000 -- the
    # smallest real entry -- so guessing wrong makes compaction fire EARLY.
    # An over-estimated fallback would instead mean compaction never fires
    # for the provider it exists to protect, which is worse than the crash
    # it replaces (see A3's escalation trigger).
    #
    # Sized against the live chat path, not picked arbitrarily: the review
    # panel measured the base toolset (`CLI::Wiring::BaseTools`, schemas
    # only, before subagent/ask_human/run_skill/role-prelude additions) at
    # ~2,984 tokens. `Need::ApproachingWindow` fires at `window * ratio`, so
    # at the default 0.9 ratio the fallback fires once used_tokens crosses
    # ~7,372 -- comfortably above that baseline, so a fresh session under the
    # fallback does not compact on turn one. This is self-correcting, not a
    # one-shot latch: `ApproachingWindow#fired?` is stateless
    # (`need.rb:66-68`) and A6 feeds it A2's LAST-TURN usage, not the
    # cumulative run total, so once a compaction drops the head, the next
    # turn's occupancy falls back under the line and the signal clears on its
    # own. A deployment that knows its real local window (e.g. a specific
    # Ollama model's num_ctx) should construct its own book with an explicit
    # `fallback:` rather than rely on this one.
    CONSERVATIVE_FALLBACK = 8_192

    # How full a context is: tokens used over the window they are measured
    # against. {Compaction::Need::ApproachingWindow} computed this ratio inside
    # its own `#fired?` and threw it away; as a value, the number a status line
    # shows a human and the number the compaction trigger compares are the same
    # number, and cannot drift apart.
    Occupancy = Data.define(:used_tokens, :window_tokens)

    class Occupancy
      # Reopened rather than filled in through `Data.define`'s block: constants
      # declared inside that block are lexically scoped to the ENCLOSING module,
      # and {None} has to hang off Occupancy itself (CLAUDE.md's trap list).

      # The window, coerced and checked. Zero and negative windows never raise
      # on their own -- they read as Infinity and NaN, and a NaN ratio also
      # breaks `==` for a caller holding two readings -- so a bad denominator
      # has to be refused where it ARRIVES. {Compaction::Need#window!} does the
      # same on its own path and keeps its own message; this is the guard for
      # everyone who never goes through a Need.
      #
      # @return [Integer]
      # @raise [ArgumentError]
      def self.window!(window_tokens)
        tokens = Integer(window_tokens, exception: false)
        return tokens if tokens&.positive?

        raise ArgumentError, "window_tokens must be a positive Integer, got #{window_tokens.inspect} -- " \
                             "an occupancy measured against it is Infinity or NaN, never a reading"
      end

      # No turn has been observed yet. Absence, never zero -- a resumed
      # session's Accounting is fresh while its Timeline is not, so a zero here
      # would read as an empty context and clear every threshold from below.
      #
      # It carries the WINDOW, and answers every reader a real reading answers:
      # a Null Object is only worth the name if it substitutes ({Sink::Null} is
      # the exemplar), and the denominator is exactly what a status line still
      # needs before the first turn -- "-- / 1,000,000" is a render, not a
      # missing value. The book has already resolved that number by the time
      # absence is known; throwing it away would send the caller back for it.
      class None
        attr_reader :window_tokens

        def initialize(window_tokens:)
          @window_tokens = Occupancy.window!(window_tokens)
          freeze
        end

        def used_tokens = nil
        def ratio = nil
        def at_least?(_fraction) = false
        def to_h = { used_tokens: nil, window_tokens: }

        # Value equality, which {Occupancy.window!} above already treats as
        # something a reading owes its caller: it refuses a NaN denominator
        # precisely because a NaN ratio breaks `==` for anyone holding two
        # readings, and absence breaking the same `==` unconditionally would be
        # the identical defect with none of the noise -- a status line
        # redrawing on `reading != @last` repaints forever before the first
        # turn. A Data gets these three for free; a hand-written Null Object
        # has to say them, or it is only half-substitutable again.
        def ==(other) = other.instance_of?(self.class) && other.window_tokens == window_tokens
        alias eql? ==
        def hash = [self.class, window_tokens].hash

        # Deconstructs on the same keys a real reading does, so one `case ... in`
        # reads both.
        def deconstruct_keys(keys) = keys.nil? ? to_h : to_h.slice(*keys)
      end

      # @param used_tokens [Integer, nil] nil is absence, and answers {None}
      # @param window_tokens [Integer] the model's context-window size in
      #   tokens -- the reading's denominator, resolved by {ContextWindow}
      #   before either arm is built.
      # @return [Occupancy, Occupancy::None]
      def self.of(used_tokens:, window_tokens:)
        used_tokens.nil? ? None.new(window_tokens:) : new(used_tokens:, window_tokens:)
      end

      # `.of` is not the only door -- `.new` and `Data#with` are two more, and a
      # nil arriving through either used to survive construction and fail late
      # as `undefined method 'fdiv' for nil`, from inside a frozen value object
      # with nothing left to name who built it. The invariant belongs here,
      # where both doors pass, and `#with` keeps working for every rewrite that
      # is not a nil.
      def initialize(used_tokens:, window_tokens:)
        if used_tokens.nil?
          raise ArgumentError, "used_tokens must not be nil -- absence is Occupancy::None, which .of builds"
        end

        super(used_tokens:, window_tokens: Occupancy.window!(window_tokens))
      end

      # @return [Float] 0.5 means half the window is spoken for
      def ratio = used_tokens.fdiv(window_tokens)

      # The MULTIPLIED form (`used >= window * fraction`), deliberately, and
      # not `ratio >= fraction`: the two disagree wherever the division rounds,
      # and this is the compaction trigger's comparison, which must land on
      # exactly the token it landed on before the ratio became a value.
      def at_least?(fraction) = used_tokens >= window_tokens * fraction
    end

    # @return [ContextWindow] the bench's default book, degrading gracefully
    def self.default = DEFAULT

    # @param windows [Hash{String=>Integer}] family/model token => window size
    # @param fallback [Integer, nil] used for an unmatched model; nil means raise
    def initialize(windows: DEFAULTS, fallback: nil)
      # Deep-frozen for the same reason as PriceBook: `transform_keys` and a
      # fresh Hash literal are both mutable by default, and the shared
      # {DEFAULT} must not be corruptible through them.
      @windows = windows.to_h { |key, tokens| [-key.to_s, tokens] }.freeze
      @fallback = fallback
      freeze
    end

    # The context window, in tokens, for a model name.
    #
    # A nil or blank `model` always raises, fallback or not: it is a wiring
    # bug (a Context built with no model resolved), not an unsupported
    # provider, and CLAUDE.md's premise throughout is that an unknown value
    # fails loudly rather than degrading in silence.
    #
    # @param model [String, Symbol]
    # @return [Integer]
    # @raise [UnknownModel] if nil/blank, or unmatched with no fallback configured
    def window_tokens(model)
      if blank?(model)
        raise UnknownModel, "no context window for model #{model.inspect} -- " \
                            "a nil or blank --model is a wiring bug, not an unsupported provider"
      end

      name = model.to_s
      @windows.fetch(name) { matched(name) || @fallback || unknown!(model) }
    end

    # How full a model's context is, given what the last turn was billed for.
    # The book owns the denominator, so the book is where a model name becomes
    # an occupancy -- a caller holding a token count never has to know which
    # table resolves it.
    #
    # The window resolves BEFORE absence is considered, so a blank model raises
    # on turn zero rather than staying silent until the first turn that carries
    # usage -- the same reason {Compaction::Need} coerces its window outside the
    # detector that short-circuits on a nil count.
    #
    # @param used_tokens [Integer, nil] the last turn's input tokens; nil before
    #   any turn
    # @param model [String, Symbol]
    # @return [Occupancy, Occupancy::None]
    # @raise [UnknownModel] on a blank model, or an unmatched one with no fallback
    def occupancy(used_tokens, model:)
      Occupancy.of(used_tokens:, window_tokens: window_tokens(model))
    end

    # The bench's default book as a shared value -- a constant, not a
    # memoized class ivar, so there is no first-call race.
    DEFAULT = new(windows: DEFAULTS, fallback: CONSERVATIVE_FALLBACK)

    private

    # Longest family token the name contains, mirroring {PriceBook#matched}
    # so a more specific key wins over a more general one were both present.
    def matched(name)
      key = @windows.keys.select { |token| name.include?(token) }.max_by(&:length)
      key && @windows.fetch(key)
    end

    # nil first (never coerce a nil to check it), then whitespace-only --
    # mirrors `Provider::Ollama#blank?` (`ollama.rb:177`)'s local shape rather
    # than pulling in ActiveSupport's `Object#blank?` for one call site.
    def blank?(model)
      model.nil? || model.to_s.strip.empty?
    end

    # @param model [String, Symbol] the ORIGINAL argument, not the coerced
    #   String -- naming what was actually passed is the point (a Symbol
    #   shows as `:foo`, distinguishable from the String `"foo"`).
    def unknown!(model)
      raise UnknownModel, "no context window for model #{model.inspect}; configure a fallback to degrade"
    end
  end
end
