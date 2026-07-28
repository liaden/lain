# frozen_string_literal: true

RSpec.describe Lain::ContextWindow do
  describe "#window_tokens" do
    # A single-key table would pass even if the implementation ignored the
    # exact-match fast path and only ever scanned for family tokens -- the
    # queried name IS its own longest contained token either way. The decoy
    # "opus" entry with a WRONG value is what makes this genuinely exercise
    # "the full id resolves to its own entry", not just "something resolved".
    it "resolves an exact model name, not just its family" do
      book = described_class.new(windows: { "opus" => 500_000, "claude-opus-4-8" => 1_000_000 })
      expect(book.window_tokens("claude-opus-4-8")).to eq(1_000_000)
    end

    it "resolves a dated snapshot by its family token" do
      book = described_class.new(windows: { "sonnet" => 1_000_000 })
      expect(book.window_tokens("claude-3-5-sonnet-20241022")).to eq(1_000_000)
    end

    it "prefers the longest matching family token" do
      book = described_class.new(windows: {
                                   "opus" => 500_000,
                                   "claude-opus-4" => 1_000_000
                                 })
      expect(book.window_tokens("claude-opus-4-8")).to eq(1_000_000)
    end

    # Folded from .probe-TA3-adversarial.rb's "two family tokens" case: a
    # name containing BOTH "opus" and "sonnet" still resolves deterministically
    # via longest-token-wins rather than raising or drifting with Hash order.
    it "resolves deterministically when a name contains two unrelated family tokens" do
      book = described_class.new(windows: { "opus" => 500_000, "sonnet" => 1_000_000 })
      expect { book.window_tokens("claude-opus-sonnet-mix") }.not_to raise_error
    end

    # Folded from the adversarial probe: matching is case-sensitive, same as
    # PriceBook. Documented, not silently assumed.
    it "does not match a family token case-insensitively" do
      book = described_class.new(windows: { "opus" => 500_000 }, fallback: 42)
      expect(book.window_tokens("OPUS")).to eq(42)
    end

    # Folded from the adversarial probe: the docstring promises Symbol input.
    it "accepts a Symbol the same as the equivalent String" do
      book = described_class.new(windows: { "opus" => 500_000 })
      expect(book.window_tokens(:opus)).to eq(500_000)
    end

    # Review fix (Linus, SHOULD-FIX): legacy Anthropic ids resolved via the
    # bare "opus"/"sonnet" token over-estimated 5x against their real,
    # published 200,000-token window -- exactly the failure this card's own
    # escalation trigger names (compaction never fires). Pinned against the
    # real ids a `--model` flag can carry, using the bench's default table.
    describe "legacy Anthropic ids do not over-estimate" do
      subject(:book) { described_class.default }

      {
        "claude-opus-4-5" => 200_000,
        "claude-opus-4-1-20250805" => 200_000,
        "claude-sonnet-4-5-20250929" => 200_000,
        "claude-sonnet-4-20250514" => 200_000,
        "claude-3-5-sonnet-20241022" => 200_000
      }.each do |model, real_window|
        it "resolves #{model} to its real #{real_window}-token window" do
          expect(book.window_tokens(model)).to eq(real_window)
        end
      end

      # Regression pin: the new, more specific legacy keys must not shadow
      # the current-generation ids that still correctly resolve via the bare
      # family token.
      {
        "claude-opus-4-8" => 1_000_000,
        "claude-sonnet-4-6" => 1_000_000,
        "claude-haiku-4-5" => 200_000
      }.each do |model, real_window|
        it "still resolves current-generation #{model} to #{real_window}" do
          expect(book.window_tokens(model)).to eq(real_window)
        end
      end
    end

    # Review fix (Schneeman, SHOULD-FIX): a nil or blank model is a wiring
    # bug, not an unsupported provider -- CLAUDE.md's premise is that unknown
    # values fail loudly. This must hold on BOTH the fallback path (.default)
    # and the no-fallback path, and the message must name what was actually
    # passed (nil, not the coerced "").
    describe "a nil or blank model" do
      subject(:book) { described_class.default }

      it "raises for nil even though .default carries a fallback" do
        expect { book.window_tokens(nil) }.to raise_error(described_class::UnknownModel, /nil/)
      end

      it "raises for an empty string even though .default carries a fallback" do
        expect { book.window_tokens("") }.to raise_error(described_class::UnknownModel)
      end

      it "raises for a whitespace-only string even though .default carries a fallback" do
        expect { book.window_tokens("   ") }.to raise_error(described_class::UnknownModel)
      end

      it "raises for nil on a book with no fallback too" do
        strict = described_class.new(windows: {})
        expect { strict.window_tokens(nil) }.to raise_error(described_class::UnknownModel, /nil/)
      end
    end
  end

  describe ".default" do
    subject(:book) { described_class.default }

    it "answers a conservative window for an unknown, ollama-style model id" do
      expect { expect(book.window_tokens("qwen3:4b")).to be_a(Integer) }.not_to raise_error
    end

    it "is deeply frozen and Ractor-shareable" do
      expect(book).to be_deeply_frozen
    end
  end

  # The ratio {Compaction::Need::ApproachingWindow} computed inside its own
  # #fired? and threw away, made readable. The book owns the denominator, so
  # the book is where a model name becomes an occupancy.
  describe "#occupancy" do
    it "reports the fraction of the model's window a turn's tokens fill" do
      book = described_class.new(windows: { "tiny" => 8192 })

      expect(book.occupancy(4096, model: "tiny").ratio).to eq(0.5)
    end

    it "is absence, not zero, before any turn has been observed" do
      expect(described_class.default.occupancy(nil, model: "claude-opus-4-8").ratio).to be_nil
    end

    it "measures a model the book does not carry against the conservative fallback" do
      occupancy = described_class.default.occupancy(4096, model: "qwen3:4b")

      expect(occupancy.window_tokens).to eq(described_class::CONSERVATIVE_FALLBACK)
      expect(occupancy.ratio).to eq(0.5)
    end

    # The window resolves BEFORE absence is considered, so the blank-model
    # wiring bug is loud on turn zero rather than on the first turn that
    # happens to carry usage.
    it "still raises on a blank model, turn or no turn" do
      expect { described_class.default.occupancy(nil, model: nil) }
        .to raise_error(described_class::UnknownModel, /wiring bug/)
    end

    # ...and having resolved it, it KEEPS it. A pre-first-turn status line
    # renders "-- / 1,000,000" off this, so throwing the denominator away
    # because there is no numerator yet would send the caller back to the book
    # for a number the book just computed.
    it "keeps the window it resolved even with no turn to measure against it" do
      none = described_class.default.occupancy(nil, model: "claude-opus-4-8")

      expect(none.window_tokens).to eq(1_000_000)
      expect(none.used_tokens).to be_nil
    end

    it "refuses to report an occupancy against a non-positive window" do
      book = described_class.new(windows: { "broken" => 0 })

      expect { book.occupancy(1, model: "broken") }.to raise_error(ArgumentError, /window_tokens/)
    end
  end

  describe Lain::ContextWindow::Occupancy do
    it "answers the detector's question with the same numbers it answers a human's" do
      occupancy = described_class.of(used_tokens: 900, window_tokens: 1000)

      expect(occupancy.ratio).to eq(0.9)
      expect(occupancy.at_least?(0.9)).to be(true)
      expect(occupancy.at_least?(0.91)).to be(false)
    end

    # Absence is not a zero-token context: a zero would clear every threshold
    # from below, so `at_least?(0.0)` is the case that tells them apart.
    it "never fires, and has no ratio, when there is no usage to measure" do
      none = described_class.of(used_tokens: nil, window_tokens: 1000)

      expect(none.ratio).to be_nil
      expect(none.at_least?(0.0)).to be(false)
      expect(described_class.of(used_tokens: 0, window_tokens: 1000).at_least?(0.0)).to be(true)
    end

    # A Null Object that answers half the duck is not substitutable, which is
    # the only thing a Null Object is for -- {Sink::Null} is the exemplar. Every
    # reader a real reading answers, absence answers too.
    it "substitutes for a real reading across the whole duck, not half of it" do
      none = described_class.of(used_tokens: nil, window_tokens: 1000)
      real = described_class.of(used_tokens: 900, window_tokens: 1000)

      expect(none.window_tokens).to eq(1000)
      expect(none.used_tokens).to be_nil
      expect(none.to_h).to eq(used_tokens: nil, window_tokens: 1000)
      expect(none.to_h.keys).to eq(real.to_h.keys)
    end

    # {Occupancy.window!} refuses a NaN denominator BECAUSE a NaN ratio breaks
    # `==` for a caller holding two readings. Absence must not break the same
    # thing unconditionally: a status line redrawing on `reading != @last`
    # would repaint forever before the first turn.
    it "gives absence the value equality a real reading has" do
      first = described_class.of(used_tokens: nil, window_tokens: 1000)
      second = described_class.of(used_tokens: nil, window_tokens: 1000)

      expect(first).to eq(second)
      expect(first).to eql(second)
      expect(first.hash).to eq(second.hash)
      expect([first, second].uniq.size).to eq(1)
      expect({ first => :drawn }.fetch(second)).to eq(:drawn)
    end

    it "tells absence against one window from absence against another" do
      expect(described_class.of(used_tokens: nil, window_tokens: 1000))
        .not_to eq(described_class.of(used_tokens: nil, window_tokens: 2000))
    end

    it "is never equal to a real reading, not even a zero-token one" do
      expect(described_class.of(used_tokens: nil, window_tokens: 1000))
        .not_to eq(described_class.of(used_tokens: 0, window_tokens: 1000))
    end

    it "deconstructs for pattern matching the way a real reading does" do
      absent = described_class.of(used_tokens: nil, window_tokens: 1000)

      case absent
      in { used_tokens: nil, window_tokens: Integer => window }
        expect(window).to eq(1000)
      end
    end

    it "is frozen and Ractor-shareable, absent or not" do
      expect(described_class.of(used_tokens: nil, window_tokens: 1000)).to be_deeply_frozen
      expect(described_class.of(used_tokens: 900, window_tokens: 1000)).to be_deeply_frozen
    end

    # `.of` establishes the invariant; `.new` and `#with` are doors it does not
    # watch, and a nil that slips through one of them fails late and far away
    # (`undefined method 'fdiv' for nil`, from inside a frozen value). The guard
    # belongs at construction, where the house rule is loud failure.
    describe "the doors .of is not" do
      it "refuses a nil used_tokens through .new" do
        expect { described_class.new(used_tokens: nil, window_tokens: 100) }
          .to raise_error(ArgumentError, /used_tokens/)
      end

      it "refuses a nil used_tokens through Data#with" do
        expect { described_class.of(used_tokens: 900, window_tokens: 1000).with(used_tokens: nil) }
          .to raise_error(ArgumentError, /used_tokens/)
      end

      it "still allows #with to rewrite a real reading" do
        expect(described_class.of(used_tokens: 900, window_tokens: 1000).with(used_tokens: 500).ratio).to eq(0.5)
      end

      # Neither of these raises on its own: they read as Infinity and NaN, and
      # a NaN ratio also breaks `==` for a caller comparing two readings.
      it "refuses a zero window, which would otherwise read as Infinity or NaN" do
        expect { described_class.of(used_tokens: 1, window_tokens: 0) }
          .to raise_error(ArgumentError, /window_tokens/)
        expect { described_class.of(used_tokens: 0, window_tokens: 0) }
          .to raise_error(ArgumentError, /window_tokens/)
      end

      it "refuses a negative window, absent or not" do
        expect { described_class.of(used_tokens: 1, window_tokens: -1) }
          .to raise_error(ArgumentError, /window_tokens/)
        expect { described_class.of(used_tokens: nil, window_tokens: -1) }
          .to raise_error(ArgumentError, /window_tokens/)
      end
    end
  end

  describe "a book built without a fallback" do
    # A `windows: {}` table would make ANY unmatched name raise trivially --
    # even a broken token scan that never excludes anything correctly would
    # pass this. Using the real, populated default table proves "gpt-4"
    # genuinely matches none of the real family/legacy tokens, not just that
    # an empty hash has nothing to offer.
    it "raises UnknownModel naming the model, against the populated default table" do
      book = described_class.new(windows: Lain::ContextWindow::DEFAULTS)
      expect { book.window_tokens("gpt-4") }
        .to raise_error(described_class::UnknownModel, /gpt-4/)
    end
  end
end
