# frozen_string_literal: true

module Lain
  # A per-model context-window token limit, keyed by model name. Mirrors
  # {PriceBook}'s resolution shape so the two lookup books never disagree about
  # what a model name means: exact match, then the longest known family token
  # the name contains, then an optional explicit `fallback`, else
  # {UnknownModel}.
  #
  # Unlike {PriceBook}'s shared default (which raises on an unknown model -- a
  # silently-free price is a lie on a cost bench), {.default} here carries a
  # conservative fallback. `Backend::PROVIDERS` includes `ollama` and `bedrock`,
  # whose model ids will never appear in an Anthropic-shaped table, and this
  # book backs compaction's `Need::ApproachingWindow`, which is on by default,
  # so a raise would turn a supported provider into a startup crash. The
  # explicit constructor (no `fallback:`) still raises, for a bench arm that
  # wants that loudly.
  class ContextWindow
    class UnknownModel < Error; end

    # Anthropic's published context windows: Opus (4.6/4.7/4.8) and Sonnet 4.6
    # are 1,000,000 tokens at standard pricing (no long-context premium); Haiku
    # 4.5 is 200,000.
    #
    # Half of {DEFAULTS}; {CLOUD_WINDOWS} is the other. Named apart rather than
    # written as one literal because the table is SHARED and matched by
    # substring, so "did a new row move an old answer?" has to be a question a
    # reader -- and a spec -- can actually ask.
    #
    # Legacy dated/aliased ids get their OWN longer keys, more specific than the
    # bare family token. PriceBook can price a legacy model at its family's rate
    # (pricing is close enough across a generation), but a WINDOW is not: a
    # probe found `claude-opus-4-5`, `claude-opus-4-1-20250805`,
    # `claude-sonnet-4-5-20250929`, `claude-sonnet-4-20250514` and
    # `claude-3-5-sonnet-*` all silently over-estimating 5x against a real
    # 200,000, and an over-estimate means `Need::ApproachingWindow` never fires
    # for that model. `--model` is a free-form CLI string, so a user reaches
    # this.
    #
    # "claude-sonnet-4" is deliberately NOT a key: `"claude-sonnet-4-6"`
    # (current-gen, 1,000,000) contains it as a prefix, so that shorter token
    # would outrank "sonnet" for Sonnet 4.6 too. Sonnet 4's dated id is used
    # verbatim instead -- no substring names "Sonnet 4" without also naming
    # "Sonnet 4.6".
    #
    # "fable" and "mythos" carry no tier word at all, which is how they went
    # missing: every other current id contains "opus", "sonnet" or "haiku", so
    # `claude-fable-5` and `claude-mythos-5` were the only shipping first-party
    # models falling to the fallback -- 1M-token models measured against an
    # 8,192 guess. "mythos" covers `claude-mythos-preview` by the same substring
    # rule, and both cover their `anthropic.`-prefixed Bedrock forms.
    #
    # This table is a SNAPSHOT of a moving catalogue and has gone stale twice.
    # The durable fix is the Models API's per-model `max_input_tokens`, read
    # live rather than transcribed. Until then, `context_window_spec.rb`'s "the
    # hosted arms keep their authority" table is the tripwire, and a new family
    # means a new row there.
    ANTHROPIC_WINDOWS = {
      "opus" => 1_000_000,
      "sonnet" => 1_000_000,
      "fable" => 1_000_000,
      "mythos" => 1_000_000,
      "haiku" => 200_000,
      "claude-opus-4-5" => 200_000,
      "claude-opus-4-1" => 200_000,
      "claude-sonnet-4-5" => 200_000,
      "claude-sonnet-4-20250514" => 200_000,
      "claude-3-5-sonnet" => 200_000
    }.freeze

    # Ollama Cloud's catalogue, read from Ollama's own model library
    # (`https://ollama.com/search?c=cloud`) on 2026-08-24.
    #
    # Every key is an EXACT tag, never a family token and never a bare "cloud":
    # {#matched_key} takes the longest substring hit, so a "qwen3" key would
    # capture the local arm's own `Provider::Ollama::DEFAULT_MODEL` and measure
    # a 4B local runner against a hosted model's window.
    #
    # EVERY NUMBER BELOW IS A FLOOR, NOT A MEASUREMENT. Ollama publishes only a
    # rounded label per model -- "128K context window", "1M", "976K" -- and no
    # exact integer a client can reach without a key (`/api/show`'s `model_info`
    # carries the cloud model's `ContextLen`, but that costs a subscription; see
    # `references/ollama/api-show-and-context.md`). So each label is read as its
    # DECIMAL FLOOR, and the rows are GROUPED BY LABEL so the published string
    # and the derived integer are never separated.
    #
    # The direction is not a preference. This table has ONE hard requirement --
    # never over-estimate -- because an over-estimated window means
    # {Compaction::Need::ApproachingWindow} never fires at all. A decimal floor
    # sits at or below the true figure under EITHER reading of the same label
    # (128,000 <= 131,072; 976,000 <= 999,424); a binary reading could breach
    # it. The price is compaction firing up to ~2.4% early. The alternative --
    # no rows at all -- is a 16x under-report that switches window-pressure
    # compaction off entirely.
    #
    # {PUBLISHED} is the honest provenance for these, and it claims "Ollama
    # published this figure for this model", NOT "this is exact to the token".
    # A publisher's own rounded figure, floored, is still evidence about the
    # model actually named, which is exactly what {GUESSED} is not.
    #
    # A model whose window could not be established is simply ABSENT and falls
    # to the {GUESSED} fallback. Absent for that reason today: `nemotron-3-super`
    # and `nemotron-3-nano`'s remaining tags (their library pages advertise more
    # tags than they render), and every id retired from the cloud on 2026-06-16
    # and 2026-07-15 -- publishing a window for a model the host no longer
    # serves is a row that can only ever be wrong.
    #
    # A faster-moving snapshot than the Anthropic half: Ollama retired sixteen
    # cloud models in a single day two months before these rows were read. Same
    # durable fix -- read the window live rather than transcribing it.
    CLOUD_WINDOWS = {
      # Ollama publishes "1M".
      "deepseek-v4-flash:cloud" => 1_000_000,
      "deepseek-v4-flash:0731-cloud" => 1_000_000,
      "deepseek-v4-flash:preview-cloud" => 1_000_000,
      "deepseek-v4-pro:cloud" => 1_000_000,
      "deepseek-v4-pro:0813-cloud" => 1_000_000,

      # `/api/show` reports 524,288 (512Ki) against the page's "1M" -- a 1.9x
      # over-claim, measured 2026-08-24. A genuinely different build from
      # `deepseek-v4-pro:cloud` (`parameter_size` 1600000000000, `modified_at`
      # 2026-04-24), which is why the base tag does not cover this one.
      "deepseek-v4-pro:preview-cloud" => 524_288,
      "kimi-k3:cloud" => 1_000_000,

      # Ollama publishes "976K". Its own page's prose says "1M" in the next
      # breath; the spec field is the narrower of the two and so is the one
      # this table may use.
      "glm-5.2:cloud" => 976_000,

      # Ollama publishes "512K" for the served tag, while the prose offers "up
      # to 1M tokens with a guaranteed minimum of 512K". A guaranteed minimum
      # is the only half of that sentence a denominator may be built on.
      "minimax-m3:cloud" => 512_000,

      # Ollama publishes "256K".
      "qwen3.5:cloud" => 256_000,
      "qwen3.5:397b-cloud" => 256_000,
      "kimi-k2.7-code:cloud" => 256_000,
      "kimi-k2.6:cloud" => 256_000,
      "gemma4:cloud" => 256_000,
      "gemma4:31b-cloud" => 256_000,

      # Also "256K" on the served tag, against a readme prose claim of "1M
      # token context" -- a 4x split, the widest of the three here. The spec
      # field wins for the same reason it does above; do not "correct" this
      # upward from the prose.
      "nemotron-3-ultra:cloud" => 256_000,

      # Back to an undisputed "256K".
      "nemotron-3-super:cloud" => 256_000,
      "mistral-large-3:675b-cloud" => 256_000,

      # Ollama publishes "200K", but `/api/show` reports a trained maximum of
      # 196,608 (192Ki) -- 1.7% under the label. The weights bound the label,
      # so the narrower figure is the one that cannot over-report occupancy.
      "minimax-m2.7:cloud" => 196_608,

      # `/api/show` reports 262,144 (256Ki) where the library page says "1M" --
      # a 3.8x gap, measured 2026-08-24. A trained maximum is a hard ceiling: no
      # runner serves a window the weights were not trained for, so the label
      # cannot be right. Keyed here rather than left to the 8,192 fallback
      # because this is a MEASURED bound -- the model's ceiling, though not a
      # promise about what any given request is served.
      "nemotron-3-nano:30b-cloud" => 262_144,

      # Ollama publishes "198K".
      "glm-5.1:cloud" => 198_000,

      # Ollama publishes "128K".
      "gpt-oss:20b-cloud" => 128_000,
      "gpt-oss:120b-cloud" => 128_000
    }.freeze

    # The shipped book's table: both halves, one flat namespace, because
    # {#resolve} matches a free-form `--model` string against every key it has
    # without knowing or caring which arm the name came from. `merge` is safe
    # only while the halves stay disjoint, which the specs assert in both
    # directions rather than trusting to inspection.
    DEFAULTS = ANTHROPIC_WINDOWS.merge(CLOUD_WINDOWS).freeze

    # Ollama's `DEFAULT_MODEL` (`qwen3:4b`) and arbitrary Bedrock ids never match
    # a token above. 8,192 sits below Haiku's 200,000 -- the smallest real entry
    # -- so guessing wrong makes compaction fire EARLY; an over-estimated
    # fallback would instead mean it never fires for the provider it exists to
    # protect. That is why this number must not move upward.
    #
    # Sized against the live chat path: the base toolset
    # (`CLI::Wiring::BaseTools`, schemas only) measured ~2,984 tokens, and
    # `Need::ApproachingWindow` fires at `window * ratio`, so at the default 0.9
    # the fallback fires once used_tokens crosses ~7,372 -- above that baseline,
    # so a fresh session does not compact on turn one.
    #
    # Firing early is self-correcting but NOT harmless. `ApproachingWindow#fired?`
    # is stateless and reads LAST-TURN usage, so the signal clears once a
    # compaction drops the head -- but each firing is an irreversible lossy
    # rewrite of the run's own history. QA watched a real 32,768-token qwen3
    # runner read as ~300% full against this guess and lain rewrite its history
    # three separate times, at 75-78% of the window it actually had. So the
    # number is tagged {GUESSED} when reached and {Compaction::Source} declines
    # to spend `:approaching_window` on it: it degrades gracefully without
    # AUTHORISING anything.
    #
    # A deployment that knows its real local window should say so where it can
    # be tied to a MODEL -- an entry in `windows:`, or the served window
    # {CLI::Backend::WindowBook} probes out of ollama's `/api/ps`. An explicit
    # `fallback:` is not that: it answers for every name that matched nothing,
    # so it cannot be evidence about any of them, and is tagged {GUESSED} too.
    CONSERVATIVE_FALLBACK = 8_192

    # Where a resolved window came from, and therefore what it may authorise.
    #
    # THREE values, and the split is NOT "measured" against "not measured".
    # {Provider#context_window_tokens} answers nil for every provider but ollama,
    # so a hosted run is measured against whatever {DEFAULTS} says -- a
    # two-valued reading would file every Anthropic and Bedrock arm under
    # "unmeasured" and switch its `:approaching_window` compaction off in
    # silence, taking {Compaction::Scheduler}'s forced compaction with it.
    #
    # "Hosted therefore PUBLISHED" holds only as far as the table does. A
    # first-party id the table does not carry is {GUESSED} like any other, and
    # that is a real state: `claude-fable-5` and `claude-mythos-5` sat in it
    # until the review that found them. The suppression is right -- an 8,192
    # guess must not authorise a rewrite for a 1M-token model -- but the
    # DENOMINATOR is wrong, and that is a missing row in {DEFAULTS}, not a
    # problem here.
    #
    # - {PROBED} -- the server said so, about the runner resident right now
    #   ({CLI::Backend::WindowBook::Served}). The only measured window there is.
    # - {PUBLISHED} -- a {DEFAULTS} entry or a family-token match: a real
    #   published number, for the model actually named.
    # - {GUESSED} -- the `fallback` branch. Nothing about this model was known;
    #   the number is a floor chosen so a wrong guess errs EARLY.
    PROBED = :probed
    PUBLISHED = :published
    GUESSED = :guessed
    PROVENANCES = [PROBED, PUBLISHED, GUESSED].freeze

    Occupancy = Data.define(:used_tokens, :window_tokens)

    # How full a context is: tokens used over the window they are measured
    # against. As a value rather than a ratio computed inside
    # {Compaction::Need::ApproachingWindow}'s own `#fired?`, the number a status
    # line shows a human and the number the compaction trigger compares are the
    # same number and cannot drift apart.
    #
    # Reopened rather than filled in through `Data.define`'s block: constants
    # declared inside that block are lexically scoped to the ENCLOSING module,
    # and {None} has to hang off Occupancy itself. YARD keeps only the docstring
    # on the reopen, so this is where the class is described.
    class Occupancy
      include Declarative

      # Zero and negative windows never raise on their own -- they read as
      # Infinity and NaN, and a NaN ratio also breaks `==` for a caller holding
      # two readings -- so a bad denominator has to be refused where it ARRIVES.
      # {Compaction::Need#window!} guards its own path with its own message;
      # this is the guard for everyone who never goes through a Need.
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
      # It carries the WINDOW, because a Null Object is only worth the name if
      # it substitutes, and the denominator is what a status line still needs
      # before the first turn: "-- / 1,000,000" is a render, not a missing
      # value.
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

        # Value equality, which a reading owes its caller: a status line
        # redrawing on `reading != @last` would otherwise repaint forever before
        # the first turn -- the same defect {Occupancy.window!} refuses a NaN
        # denominator to avoid. A Data gets these three for free; a hand-written
        # Null Object has to say them, or it is only half-substitutable.
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
      # nil arriving through either used to fail late as `undefined method
      # 'fdiv' for nil`, from inside a frozen value with nothing left to name
      # who built it. The invariant belongs here, where both doors pass.
      #
      # `exclusion: [nil]` and not `presence:`, which also refuses `false` and
      # `""`: the rule is about ABSENCE specifically, and {None} is where
      # absence lives.
      #
      # Only `used_tokens` is declared -- `window_tokens` is refused by
      # {Occupancy.window!} with its own message about its own parameter.
      declare do
        attribute :used_tokens
        validates :used_tokens,
                  exclusion: { in: [nil],
                               message: "must not be nil -- absence is Occupancy::None, which .of builds" }
      end

      def initialize(used_tokens:, window_tokens:)
        self.class.check!(used_tokens:)

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

    # A window, and where the number came from -- the pair, because provenance
    # cannot ride inside the number and must not be fetched separately.
    #
    # Not inside it: {Compaction::Need#window!} does
    # `Integer(window_tokens, exception: false)`, which flattens any wrapper, and
    # a spec pins that `check(window_tokens: "1000")` coerces a String. Not
    # separately: two lookups are two chances to disagree about one model.
    #
    # The window is NOT coerced here. {Occupancy.window!} and
    # {Compaction::Need#window!} each refuse a bad denominator where it arrives,
    # with their own message about their own parameter.
    WindowResolution = Data.define(:window_tokens, :provenance) do
      include Declarative

      # Only `provenance`; the window itself is not coerced or checked here.
      declare do
        attribute :provenance
        validates :provenance,
                  inclusion: { in: PROVENANCES,
                               message: "must be one of #{PROVENANCES.inspect}, got %<value>p" }
      end

      def initialize(window_tokens:, provenance:)
        self.class.check!(provenance:)

        super
      end

      # May this window authorise an irreversible rewrite?
      #
      # Phrased as "not a guess" rather than as a list of the two that pass, so
      # a provenance added later is authoritative unless it says otherwise. The
      # other direction fails silently: compaction stops and nothing reports it.
      #
      # @return [Boolean]
      def authoritative? = provenance != GUESSED
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
    def window_tokens(model) = resolve(model).window_tokens

    # The same lookup, keeping what it learned on the way: an exact hit and a
    # family-token match are both {PUBLISHED}, the `fallback` branch is
    # {GUESSED}, and only a {CLI::Backend::WindowBook::Served} book can answer
    # {PROBED}.
    #
    # @param model [String, Symbol]
    # @return [WindowResolution]
    # @raise [UnknownModel] if nil/blank, or unmatched with no fallback configured
    def resolve(model)
      if blank?(model)
        raise UnknownModel, "no context window for model #{model.inspect} -- " \
                            "a nil or blank --model is a wiring bug, not an unsupported provider"
      end

      # PRESENCE, never truthiness. A malformed entry (a nil or false window
      # someone put in `windows:`) is answered verbatim and refused loudly
      # downstream by {Occupancy.window!}. Deciding "did we find one?" on the
      # VALUE would instead demote it to the fallback and call it a guess -- an
      # invalid table degrading in silence.
      name = model.to_s
      key = @windows.key?(name) ? name : matched_key(name)
      return WindowResolution.new(window_tokens: @windows.fetch(key), provenance: PUBLISHED) if key

      WindowResolution.new(window_tokens: @fallback || unknown!(model), provenance: GUESSED)
    end

    # How full a model's context is, given what the last turn was billed for.
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

    # Longest family token the name contains, mirroring {PriceBook#matched}'s
    # resolution order so a more specific key wins over a more general one.
    #
    # It answers the KEY where PriceBook's answers the value -- the one
    # deliberate divergence. A VALUE can be nil or false while the key exists,
    # and a caller deciding "matched?" on that would silently reroute a
    # malformed table entry to the fallback (see {#resolve}).
    def matched_key(name)
      @windows.keys.select { |token| name.include?(token) }.max_by(&:length)
    end

    # Mirrors `Provider::Ollama#blank?`'s local shape rather than pulling in
    # ActiveSupport's `Object#blank?` for one call site.
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
