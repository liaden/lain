# frozen_string_literal: true

require "bigdecimal"
require "date"

# `load`, not `require_relative`: the file lives at `bin/lint-price-freshness`
# with no `.rb` extension (matching `bin/lint-gherkin-docs` and
# `bin/lint-commit-msg`), and Ruby's `require` family resolves a feature by
# trying known suffixes -- it does not fall back to the literal path when none
# match, so `require_relative` on an extensionless script raises LoadError even
# though the file exists. `load` takes the path as-is. It re-executes the file
# (not memoized like `require`), which is harmless here: the file only defines
# a class and, guarded by `$PROGRAM_NAME == __FILE__` (false under rspec), a CLI
# block that never runs.
load File.expand_path("../../bin/lint-price-freshness", __dir__)

RSpec.describe Lain::PriceBook do
  def usage(input: 0, output: 0, creation: 0, read: 0)
    Lain::Usage.new(input_tokens: input, output_tokens: output,
                    cache_creation_input_tokens: creation, cache_read_input_tokens: read)
  end

  describe Lain::Price do
    it "prices each token class at its own per-million rate, in BigDecimal" do
      price = described_class.per_mtok(input: 3, output: 15, cache_creation: 3.75, cache_read: 0.3)
      cost = price.cost(usage(input: 1_000_000, output: 1_000_000, creation: 1_000_000, read: 1_000_000))
      expect(cost).to be_a(BigDecimal)
      expect(cost).to eq(BigDecimal("22.05"))
    end

    # Float would accumulate error across a session; a fractional-cent price times
    # a large token count must be exact.
    it "is exact where Float would drift" do
      price = described_class.per_mtok(input: 0.1, output: 0, cache_creation: 0, cache_read: 0)
      expect(price.cost(usage(input: 3))).to eq(BigDecimal("0.0000003"))
    end
  end

  describe "#cost" do
    subject(:book) { described_class.default }

    it "prices a known family" do
      cost = book.cost("claude-sonnet-4", usage(input: 1_000_000))
      expect(cost).to eq(BigDecimal("3"))
    end

    # T1: the table was quoting 15/75 for Opus against the current published
    # 5/25 -- a 3x overstatement that inflated every derived cost figure.
    it "prices an Opus model at the current published rate" do
      input_cost = book.cost("claude-opus-5", usage(input: 1_000_000))
      output_cost = book.cost("claude-opus-5", usage(output: 1_000_000))
      expect(input_cost).to eq(BigDecimal("5"))
      expect(output_cost).to eq(BigDecimal("25"))
    end

    # T1: Haiku was quoting 0.8/4 against the current published 1/5.
    it "prices a Haiku model at the current published rate" do
      cost = book.cost("claude-haiku-4-5", usage(input: 1_000_000))
      expect(cost).to eq(BigDecimal("1"))
    end

    # T1: the cache rows are DERIVED from the input rate (cache-write is
    # Anthropic's 1.25x input, cache-read its 0.1x), so correcting input alone
    # must correct them too -- this pins that the derivation still holds
    # against the corrected Opus row.
    it "derives the Opus cache rows from its corrected input rate" do
      price = book.price("claude-opus-5")
      expect(price.cache_read).to eq(price.input * BigDecimal("0.1"))
      expect(price.cache_creation).to eq(price.input * BigDecimal("1.25"))
    end

    it "matches a dated snapshot by its family token" do
      exact = book.cost("sonnet", usage(input: 1_000_000))
      dated = book.cost("claude-3-5-sonnet-20241022", usage(input: 1_000_000))
      expect(dated).to eq(exact)
    end

    it "prefers the longest matching family token" do
      book = described_class.new(prices: {
                                   "opus" => Lain::Price.per_mtok(input: 15, output: 75, cache_creation: 0,
                                                                  cache_read: 0),
                                   "claude-opus-4" => Lain::Price.per_mtok(input: 20, output: 100, cache_creation: 0,
                                                                           cache_read: 0)
                                 })
      expect(book.cost("claude-opus-4-8", usage(input: 1_000_000))).to eq(BigDecimal("20"))
    end
  end

  # The shared default is process-wide: one caller mutating its price map would
  # corrupt every later cost figure with no error anywhere (the reviewer's repro:
  # `default.instance_variable_get(:@prices).clear` made `price("sonnet")` return
  # nil instead of raising). Deep frozenness is the mechanical proof it cannot.
  describe ".default" do
    it "is deeply frozen and Ractor-shareable, so mutation through the singleton is impossible" do
      expect(described_class.default).to be_deeply_frozen
    end

    it "refuses a write into its price map" do
      prices = described_class.default.instance_variable_get(:@prices)
      expect { prices["opus"] = nil }.to raise_error(FrozenError)
    end
  end

  describe "an unknown model" do
    it "raises rather than silently pricing at zero" do
      expect { described_class.default.cost("gpt-4", usage(input: 10)) }
        .to raise_error(described_class::UnknownModel)
    end

    it "uses an explicit fallback when one is configured" do
      fallback = Lain::Price.per_mtok(input: 1, output: 1, cache_creation: 0, cache_read: 0)
      book = described_class.new(prices: {}, fallback:)
      expect(book.cost("anything", usage(input: 1_000_000))).to eq(BigDecimal("1"))
    end
  end
end

# T2: `bin/lint-price-freshness` is a repo lint (`pre-commit run --all-files`), not
# application code -- DEFAULTS gains no runtime freshness check. Its logic is spec'd
# here, against the actual card file, rather than in a new lib/ unit, because the
# card's scope is `bin/lint-price-freshness` plus this spec, nothing under `lib/`.
#
# Every example below pins its OWN `today:` rather than reading `Date.today`. A spec
# that asked "is the real marker fresh right now" would pass today and fail, unattended,
# 91 days after being written with no code change -- a time bomb, not a lint. The hook's
# CLI entrypoint (guarded by `$PROGRAM_NAME == __FILE__`, so requiring the file here does
# not run it) is the only place allowed to read the system clock.
RSpec.describe "bin/lint-price-freshness" do
  def source_with_marker(date)
    <<~RUBY
      # Reviewed #{date} against the published list rates for the Opus
      # 5/4.8/4.7/4.6 family, Sonnet, and Haiku 4.5.
      DEFAULTS = {}.freeze
    RUBY
  end

  # Gherkin AC 1 (T2): a price table older than its review horizon fails the lint.
  it "fails a marker dated more than 90 days before the injected clock, naming the marker and the file" do
    result = PriceFreshnessLinter.check(
      source: source_with_marker("2026-01-01"),
      path: "lib/lain/price_book.rb",
      today: Date.new(2026, 8, 18)
    )

    expect(result.ok?).to be(false)
    expect(result.message).to include("2026-01-01")
    expect(result.message).to include("lib/lain/price_book.rb")
  end

  # Gherkin AC 2 (T2): a current table passes silently.
  it "passes with no message when the marker is dated at the injected clock" do
    result = PriceFreshnessLinter.check(
      source: source_with_marker("2026-08-18"),
      path: "lib/lain/price_book.rb",
      today: Date.new(2026, 8, 18)
    )

    expect(result.ok?).to be(true)
    expect(result.message).to be_nil
  end

  it "passes at exactly the 90-day horizon, and fails one day past it" do
    at_horizon = PriceFreshnessLinter.check(
      source: source_with_marker("2026-05-20"), path: "x", today: Date.new(2026, 8, 18)
    )
    past_horizon = PriceFreshnessLinter.check(
      source: source_with_marker("2026-05-19"), path: "x", today: Date.new(2026, 8, 18)
    )

    expect(at_horizon.ok?).to be(true)
    expect(past_horizon.ok?).to be(false)
  end

  it "fails with a named reason when no reviewed-on marker is present at all" do
    result = PriceFreshnessLinter.check(source: "DEFAULTS = {}.freeze\n", path: "x", today: Date.new(2026, 8, 18))

    expect(result.ok?).to be(false)
    expect(result.message).to include("marker")
  end
end
