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
    # One of the two halves of {DEFAULTS}; the ollama cloud arm's half is
    # {CLOUD_WINDOWS}. They are named apart rather than written as one literal
    # because the table is SHARED and matched by substring, so "did a new row
    # move an old answer?" has to be a question a reader -- and a spec -- can
    # actually ask.
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
    #
    # "fable" and "mythos" are the families that carry no tier word at all,
    # which is exactly how they went missing: every other current id contains
    # "opus", "sonnet" or "haiku", so `claude-fable-5` and `claude-mythos-5`
    # were the only shipping first-party models falling to the fallback --
    # 1,000,000-token models measured against a 8,192 guess. Both are 1M at
    # standard pricing. "mythos" covers `claude-mythos-preview` by the same
    # substring rule, and both cover their `anthropic.`-prefixed Bedrock forms.
    #
    # This table is a SNAPSHOT of a moving catalogue and has now gone stale
    # twice. The durable fix is the Models API's per-model `max_input_tokens`,
    # read live rather than transcribed; it is a future card, not this one.
    # Until then, `context_window_spec.rb`'s "the hosted arms keep their
    # authority" table is the tripwire, and a new family means a new row there.
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
    # (`https://ollama.com/search?c=cloud` and each model's `ollama.com/library`
    # page) on **2026-08-24**. Every key is an EXACT tag, never a family token
    # and never a bare "cloud": {#matched_key} scans by substring and takes the
    # longest hit, so a "qwen3" key would capture the local arm's own
    # `Provider::Ollama::DEFAULT_MODEL` and measure a 4B local runner against a
    # hosted model's window. The ollama-to-ollama capture is the real hazard
    # here; the shared table's Anthropic tokens are checked too, and none of
    # these ids contains one.
    #
    # EVERY NUMBER BELOW IS A FLOOR, NOT A MEASUREMENT. Do not read 128_000 as
    # a figure anyone read off the model. Ollama publishes only a ROUNDED LABEL
    # per model -- "128K context window", "1M", "976K" -- and no exact integer
    # anywhere a client can reach without a key: `/api/show`'s `model_info`
    # carries the cloud model's own `ContextLen`, but that costs a subscription
    # (see `references/ollama/api-show-and-context.md`). So each label is read
    # as its DECIMAL FLOOR, and the rows are GROUPED BY THAT LABEL so the
    # published string and the derived integer are never separated: "128K" ->
    # 128_000, "1M" -> 1_000_000, "976K" -> 976_000.
    #
    # The floor is deliberate, and the direction is not a preference. This table
    # has ONE hard requirement -- never over-estimate -- because an
    # over-estimated window means {Compaction::Need::ApproachingWindow} never
    # fires at all, which `CONSERVATIVE_FALLBACK` below ranks as worse than the
    # crash it replaces. A decimal floor sits at or below the true figure under
    # EITHER reading of the same label (128,000 <= 131,072; 976,000 <= 999,424),
    # so it cannot breach that requirement; a binary reading could. The price is
    # that compaction may fire up to ~2.4% early. The alternative -- no rows at
    # all -- is a 16x under-report that ALSO switches window-pressure compaction
    # off entirely, which is the damage case this card exists to close.
    #
    # {PUBLISHED} is still the honest provenance for these, and it is worth
    # being precise about what it claims: "Ollama published this figure for this
    # model", NOT "this is exact to the token". The tag governs whether a number
    # may authorise an irreversible rewrite, and a publisher's own rounded
    # figure, floored, is evidence about the model actually named -- which is
    # exactly what {GUESSED} is not.
    #
    # A model whose window could not be established is simply ABSENT, and falls
    # to the tagged-{GUESSED} fallback like any other unknown. Absent for that
    # reason today: `nemotron-3-super`'s and `nemotron-3-nano`'s remaining tags
    # (their library pages advertise more tags than they render), and every id
    # retired from the cloud on 2026-06-16 and 2026-07-15
    # (`https://docs.ollama.com/cloud`) -- publishing a window for a model the
    # host no longer serves is a row that can only ever be wrong.
    #
    # This section is a SNAPSHOT of a moving catalogue, and a faster-moving one
    # than the Anthropic half above: Ollama retired sixteen cloud models in a
    # single day two months before these rows were read. It will go stale, the
    # same way that table already has twice, and the same durable fix applies --
    # read the window live rather than transcribing it.
    CLOUD_WINDOWS = {
      # Ollama publishes "1M".
      "deepseek-v4-flash:cloud" => 1_000_000,
      "deepseek-v4-flash:0731-cloud" => 1_000_000,
      "deepseek-v4-flash:preview-cloud" => 1_000_000,
      "deepseek-v4-pro:cloud" => 1_000_000,
      "deepseek-v4-pro:0813-cloud" => 1_000_000,

      # `/api/show` reports 524,288 (512Ki) against the page's "1M" -- a 1.9x
      # over-claim. It is a genuinely different build from `deepseek-v4-pro:cloud`
      # (`parameter_size` 1600000000000, `modified_at` 2026-04-24), which is why
      # the base tag's 1,048,576 does not cover this one. Measured 2026-08-24.
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
      # a 3.8x gap, measured 2026-08-24 across a 17-model sweep. A trained
      # maximum is a hard ceiling: no runner serves a window the weights were
      # not trained for, so the published label cannot be right. Keyed here
      # rather than left to the 8,192 fallback because 262,144 is a MEASURED
      # bound and the fallback is a guess -- but it is the model's ceiling, not
      # a promise about what any given request is served.
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
    # fallback does not compact on turn one.
    #
    # AMENDED (T9). This paragraph used to end "this is self-correcting, not a
    # one-shot latch", and that argument is still TRUE and still insufficient.
    # It is about FREQUENCY: `ApproachingWindow#fired?` is stateless and is fed
    # A2's LAST-TURN usage rather than the cumulative run total, so once a
    # compaction drops the head the next turn's occupancy falls back under the
    # line and the signal clears on its own. What it never covered is DAMAGE.
    # Each firing is an irreversible lossy rewrite of the run's own history, so
    # "it stops after a few" is not a defence -- QA watched a real 32,768-token
    # qwen3 runner read as ~300% full against this 8,192 guess and lain rewrite
    # its history three separate times, at 75-78% of the window it actually had.
    #
    # So the guess still degrades gracefully, it just no longer AUTHORISES
    # anything: this number is now tagged {GUESSED} when it is reached, and
    # {Compaction::Source} declines to spend `:approaching_window` on it. The
    # number itself is unchanged and must stay so -- an over-estimated fallback
    # means compaction never fires at all for the provider it exists to protect,
    # which is the worse of the two failures (see the paragraph above).
    #
    # A deployment that knows its real local window should say so where it can
    # be tied to a MODEL -- an entry in `windows:`, or the served window
    # {CLI::Backend::WindowBook} probes out of ollama's `/api/ps`. An explicit
    # `fallback:` is not that: it answers for every name that matched nothing,
    # so it cannot be evidence about any of them, and it is tagged {GUESSED}
    # like this one.
    CONSERVATIVE_FALLBACK = 8_192

    # Where a resolved window came from, and therefore what it may authorise.
    #
    # THREE values, and the split is NOT "measured" against "not measured".
    # {Provider#context_window_tokens} answers nil for every provider but ollama
    # (`provider.rb:77-79`, overridden only at `ollama.rb:189`), so a hosted run
    # is measured against whatever {DEFAULTS} says -- a two-valued reading would
    # file every Anthropic and Bedrock arm under "unmeasured" and switch its
    # `:approaching_window` compaction off in silence. {Compaction::Scheduler}
    # reads the same signal to decide a FORCED compaction, so the forcing
    # behaviour would have gone with it.
    #
    # "Hosted therefore PUBLISHED" holds only as far as the table does. A
    # first-party id the table does not carry is {GUESSED} like any other, which
    # is a real state and not a hypothetical: `claude-fable-5` and
    # `claude-mythos-5` sat in it until the review that found them. The
    # suppression is still right there -- an 8,192 guess must not authorise a
    # rewrite for a 1M-token model -- but the DENOMINATOR is wrong, and that is
    # a missing table row, fixed in {DEFAULTS} rather than here.
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

    # A window, and where the number came from -- the pair, because provenance
    # cannot ride inside the number and must not be fetched separately.
    #
    # Not inside it: {Compaction::Need#window!} does
    # `Integer(window_tokens, exception: false)`, which flattens any wrapper, and
    # a spec pins that `check(window_tokens: "1000")` coerces a String. So the
    # parameter's type is fixed, and provenance travels ALONGSIDE it.
    #
    # Not separately: two lookups are two chances to disagree about one model,
    # and "the number and what it is worth" is one answer to one question.
    #
    # The window is NOT coerced here. {Occupancy.window!} and
    # {Compaction::Need#window!} each refuse a bad denominator where it arrives,
    # with their own message about their own parameter, and a third guard in
    # front of both would only get in the way of theirs.
    WindowResolution = Data.define(:window_tokens, :provenance) do
      def initialize(window_tokens:, provenance:)
        unless PROVENANCES.include?(provenance)
          raise ArgumentError, "unknown provenance #{provenance.inspect} -- one of #{PROVENANCES.inspect}"
        end

        super
      end

      # May this window authorise an irreversible rewrite?
      #
      # Phrased as "not a guess" rather than as a list of the two that pass, so
      # a provenance added later is authoritative unless it says otherwise --
      # the safe default is that a real number keeps working, since the failure
      # of the other direction is silent (compaction stops, nothing reports it).
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
    # {PROBED}. Those are the three branches `#window_tokens` always had --
    # nothing new is decided here, it just stops being thrown away.
    #
    # @param model [String, Symbol]
    # @return [WindowResolution]
    # @raise [UnknownModel] if nil/blank, or unmatched with no fallback configured
    def resolve(model)
      if blank?(model)
        raise UnknownModel, "no context window for model #{model.inspect} -- " \
                            "a nil or blank --model is a wiring bug, not an unsupported provider"
      end

      # PRESENCE, never truthiness. `fetch`'s block does not run for a key that
      # is present, so a malformed entry (a nil or false window someone put in
      # `windows:`) used to be answered verbatim and refused loudly downstream
      # by {Occupancy.window!} / {Compaction::Need#window!}. Deciding "did we
      # find one?" on the VALUE would instead demote it to the fallback and
      # call it a guess -- an invalid table degrading in silence, which is the
      # inversion CLAUDE.md rejects. So the key is what is tested, and a bad
      # value keeps failing where it always failed.
      name = model.to_s
      key = @windows.key?(name) ? name : matched_key(name)
      return WindowResolution.new(window_tokens: @windows.fetch(key), provenance: PUBLISHED) if key

      WindowResolution.new(window_tokens: @fallback || unknown!(model), provenance: GUESSED)
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

    # Longest family token the name contains, mirroring {PriceBook#matched}'s
    # resolution order so a more specific key wins over a more general one were
    # both present.
    #
    # It answers the KEY, where PriceBook's answers the value -- the one
    # deliberate divergence. A key is present or it is nil; a VALUE can be nil
    # or false while the key exists, and a caller deciding "matched?" on that
    # would silently reroute a malformed table entry to the fallback (see
    # {#resolve}). Returning the key keeps the found/not-found question
    # unambiguous, and lets the value stay whatever the table said.
    def matched_key(name)
      @windows.keys.select { |token| name.include?(token) }.max_by(&:length)
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
