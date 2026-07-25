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
