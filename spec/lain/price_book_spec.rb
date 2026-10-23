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

  describe "#cost" do
    subject(:book) { described_class.default }

    it "prices a known family" do
      cost = book.cost("claude-sonnet-4", usage(input: 1_000_000))
      expect(cost).to eq(BigDecimal("3"))
    end

    # The table was quoting 15/75 for Opus against the current published
    # 5/25 -- a 3x overstatement that inflated every derived cost figure.
    it "prices an Opus model at the current published rate" do
      input_cost = book.cost("claude-opus-5", usage(input: 1_000_000))
      output_cost = book.cost("claude-opus-5", usage(output: 1_000_000))
      expect(input_cost).to eq(BigDecimal("5"))
      expect(output_cost).to eq(BigDecimal("25"))
    end

    # Haiku was quoting 0.8/4 against the current published 1/5.
    it "prices a Haiku model at the current published rate" do
      cost = book.cost("claude-haiku-4-5", usage(input: 1_000_000))
      expect(cost).to eq(BigDecimal("1"))
    end

    # The cache rows are DERIVED from the input rate (cache-write is
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

    it "prices a flat row the same whether or not a request time is given" do
      million = usage(input: 1_000_000)
      expect(book.cost("claude-opus-4-8", million)).to eq(BigDecimal("5"))
      expect(book.cost("claude-opus-4-8", million, at: Time.utc(2026, 10, 24, 20))).to eq(BigDecimal("5"))
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

  describe "the Claude 5.5 family and Fable 5.1" do
    subject(:book) { described_class.default }

    {
      "claude-opus-5-5" => [4, 20],
      "claude-sonnet-5-5" => [2, 10],
      "claude-fable-5-1" => [10, 50],
      "claude-mythos-5-1" => [10, 50]
    }.each do |model, (input, output)|
      it "prices #{model} at $#{input} in and $#{output} out per million" do
        expect(book.cost(model, usage(input: 1_000_000))).to eq(BigDecimal(input))
        expect(book.cost(model, usage(output: 1_000_000))).to eq(BigDecimal(output))
      end
    end

    it "prices Opus 5.5 cache writes at $5 and reads at $0.20 per million" do
      expect(book.cost("claude-opus-5-5", usage(creation: 1_000_000))).to eq(BigDecimal("5"))
      expect(book.cost("claude-opus-5-5", usage(read: 1_000_000))).to eq(BigDecimal("0.2"))
    end

    it "bills Haiku 5.5 at $0.10 per million for a prompt of 90,000 tokens" do
      expect(book.rate("claude-haiku-5-5", usage(input: 90_000)).input).to eq(BigDecimal("0.1") / 1_000_000)
    end

    it "bills Haiku 5.5 at $0.50 in and $2.50 out per million for a prompt of 150,000 tokens" do
      rate = book.rate("claude-haiku-5-5", usage(input: 150_000))
      expect(rate.input).to eq(BigDecimal("0.5") / 1_000_000)
      expect(rate.output).to eq(BigDecimal("2.5") / 1_000_000)
    end

    {
      "claude-opus-5-5" => [5, "0.2"],
      "claude-sonnet-5-5" => [2.5, "0.1"],
      "claude-fable-5-1" => [12.5, "0.25"],
      "claude-mythos-5-1" => [12.5, "0.25"]
    }.each do |model, (write, read)|
      it "prices #{model} cache writes at $#{write} and reads at $#{read} per million" do
        expect(book.cost(model, usage(creation: 1_000_000))).to eq(BigDecimal(write.to_s))
        expect(book.cost(model, usage(read: 1_000_000))).to eq(BigDecimal(read))
      end
    end

    it "prices Haiku 5.5 cache at $0.125 and $0.01 per million in its base tier" do
      expect(book.rate("claude-haiku-5-5", usage(creation: 50_000, read: 50_000)))
        .to have_attributes(cache_creation: BigDecimal("0.125") / 1_000_000, cache_read: BigDecimal("0.01") / 1_000_000)
    end

    it "prices Haiku 5.5 cache at $0.625 and $0.05 per million above 100,000 tokens" do
      expect(book.rate("claude-haiku-5-5", usage(creation: 100_001)))
        .to have_attributes(cache_creation: BigDecimal("0.625") / 1_000_000, cache_read: BigDecimal("0.05") / 1_000_000)
    end

    it "keeps a prompt of exactly 100,000 tokens in Haiku 5.5's low tier" do
      expect(book.rate("claude-haiku-5-5", usage(input: 100_000)).input).to eq(BigDecimal("0.1") / 1_000_000)
    end

    it "moves a prompt of 100,001 tokens into Haiku 5.5's high tier" do
      expect(book.rate("claude-haiku-5-5", usage(input: 100_001)).input).to eq(BigDecimal("0.5") / 1_000_000)
    end

    it "counts cache reads toward Haiku 5.5's prompt size" do
      expect(book.rate("claude-haiku-5-5", usage(input: 10_000, read: 95_000)).input)
        .to eq(BigDecimal("0.5") / 1_000_000)
    end

    it "keeps the older families at their own rates" do
      expect(book.cost("claude-opus-4-8", usage(input: 1_000_000))).to eq(BigDecimal("5"))
      expect(book.cost("claude-opus-4-8", usage(output: 1_000_000))).to eq(BigDecimal("25"))
      expect(book.cost("claude-haiku-4-5", usage(input: 1_000_000))).to eq(BigDecimal("1"))
      expect(book.cost("claude-haiku-4-5", usage(output: 1_000_000))).to eq(BigDecimal("5"))
    end

    it "still refuses the unpriced fable 5 and mythos 5" do
      expect { book.price("claude-fable-5") }.to raise_error(described_class::UnknownModel)
      expect { book.price("claude-mythos-5") }.to raise_error(described_class::UnknownModel)
    end
  end

  describe "the shipped table against the freshness lint" do
    let(:source) { File.read(File.expand_path("../../lib/lain/price_book.rb", __dir__)) }

    it "passes on 2026-10-23" do
      expect(PriceFreshnessLinter.check(source:, path: "price_book.rb", today: Date.new(2026, 10, 23)).ok?).to be(true)
    end

    it "passes on 2027-01-21" do
      expect(PriceFreshnessLinter.check(source:, path: "price_book.rb", today: Date.new(2027, 1, 21)).ok?).to be(true)
    end

    it "fails on 2027-01-22" do
      expect(PriceFreshnessLinter.check(source:, path: "price_book.rb", today: Date.new(2027, 1, 22)).ok?).to be(false)
    end
  end

  describe "Ollama Cloud rows" do
    subject(:book) { described_class.default }

    # Dollars per million tokens, input then output, as ollama.com/pricing lists them.
    let(:page_rates) do
      {
        "deepseek-v4.1-flash:cloud" => [0.30, 1.20], "deepseek-v4-pro:cloud" => [1.32, 3.96],
        "gemma4:cloud" => [0.14, 0.40], "gemma4:31b-cloud" => [0.14, 0.40],
        "glm-5.3:cloud" => [1.40, 4.40], "glm-5.3-flash:cloud" => [0.15, 0.50], "glm-5.2:cloud" => [1.40, 4.40],
        "gpt-oss:120b-cloud" => [0.15, 0.60], "gpt-oss:20b-cloud" => [0.07, 0.30],
        "kimi-k3:cloud" => [3.00, 15.00], "kimi-k2.7-code:cloud" => [0.95, 4.00], "kimi-k2.6:cloud" => [0.95, 4.00],
        "minimax-m3:cloud" => [0.60, 2.40], "minimax-m2.7:cloud" => [0.30, 1.20],
        "mistral-large-3:675b-cloud" => [0.50, 1.50],
        "nemotron-3-nano:30b-cloud" => [0.06, 0.24], "nemotron-3-super:cloud" => [0.015, 0.60],
        "nemotron-3-ultra:cloud" => [0.10, 3.00]
      }
    end

    it "prices every cloud row at the page's input and output rate" do
      billed = page_rates.keys.to_h do |tag|
        [tag, [book.cost(tag, usage(input: 1_000_000)), book.cost(tag, usage(output: 1_000_000))]]
      end
      expect(billed).to eq(page_rates.transform_values { |pair| pair.map { BigDecimal(_1.to_s) } })
    end

    it "has a row for exactly the cloud tags the table lists" do
      expect(described_class::DEFAULTS.keys.grep(/cloud\z/)).to match_array(page_rates.keys)
    end

    it "bills deepseek-v4-pro half on a weekend" do
      peak = Time.utc(2026, 10, 21, 14)
      weekend = Time.utc(2026, 10, 25, 14)
      expect(book.cost("deepseek-v4-pro:cloud", usage(input: 1_000_000), at: peak)).to eq(BigDecimal("1.32"))
      expect(book.cost("deepseek-v4-pro:cloud", usage(input: 1_000_000), at: weekend)).to eq(BigDecimal("0.66"))
    end

    it "bills deepseek-v4.1-flash half off-peak" do
      off_peak = Time.utc(2026, 10, 21, 20)
      expect(book.cost("deepseek-v4.1-flash:cloud", usage(output: 1_000_000), at: off_peak)).to eq(BigDecimal("0.6"))
    end

    it "leaves a local model with a cloud family name unpriced" do
      expect { book.price("gemma4:e4b") }.to raise_error(described_class::UnknownModel)
    end

    it "carries no cached-input rate on any cloud row" do
      cloud = described_class::DEFAULTS.select { |key, _| key.end_with?("cloud") }
      expect(cloud).not_to be_empty
      expect(cloud.values.map { [_1.cache_creation, _1.cache_read] }.uniq).to eq([[0, 0]])
    end

    it "gives a friction report a dollar figure for a cloud run" do
      entries = [
        { "type" => "request_sent", "digest" => "blake3:req", "payload" => { "model" => "glm-5.3:cloud" },
          "prefix_chain_version" => Lain::Request::PREFIX_CHAIN_VERSION, "prefix_digests" => [[0, "a"]] },
        { "type" => "turn_usage", "digest" => "blake3:t", "model" => "glm-5.3:cloud",
          "usage" => { "input_tokens" => 10, "output_tokens" => 10,
                       "cache_creation_input_tokens" => 0, "cache_read_input_tokens" => 0 } }
      ]
      expect(Lain::Friction::Report.new(entries).render).not_to include("no price recorded")
    end
  end

  describe "#rate" do
    it "answers a flat Price at the tier the prompt reaches" do
      tier = Lain::Price.per_mtok(input: 0.50, output: 2.50, cache_creation: 0, cache_read: 0)
      base = Lain::Price.per_mtok(input: 0.10, output: 0.50, cache_creation: 0, cache_read: 0,
                                  tiers: [Lain::Price::Tier.new(above_prompt_tokens: 100_000, price: tier)])
      book = described_class.new(prices: { "haiku" => base })

      rate = book.rate("claude-haiku-9", usage(input: 80_000, read: 30_000))

      expect(rate).to eq(tier)
      expect(rate.tiers).to be_empty
    end
  end

  describe "a row with an off-peak window" do
    let(:half) { Lain::Price.per_mtok(input: 0.5, output: 0, cache_creation: 0, cache_read: 0) }
    let(:book) do
      described_class.new(prices: {
                            "deepseek" => Lain::Price.per_mtok(input: 1, output: 0, cache_creation: 0, cache_read: 0,
                                                               off_peak: Lain::Price::OffPeak.new(price: half))
                          })
    end
    let(:sunday) { Time.utc(2026, 10, 25, 14) }

    it "costs the off-peak rate when priced on a Sunday" do
      expect(book.cost("deepseek-v4", usage(input: 1_000_000), at: sunday)).to eq(BigDecimal("0.5"))
    end

    it "answers the off-peak rate when asked on a Sunday" do
      expect(book.rate("deepseek-v4", usage(input: 1_000_000), at: sunday)).to eq(half)
    end
  end

  # The shared default is process-wide: one caller mutating its price map would
  # corrupt every later cost figure with no error anywhere (the reviewer's repro:
  # `default.instance_variable_get(:@prices).clear` made `price("sonnet")` return
  # nil instead of raising). Deep frozenness is the mechanical proof it cannot.
  it "resolves a name through the shared longest-key rule" do
    cheap = Lain::Price.per_mtok(input: 1, output: 1, cache_creation: 0, cache_read: 0)
    dear = Lain::Price.per_mtok(input: 2, output: 2, cache_creation: 0, cache_read: 0)
    book = described_class.new(prices: { "opus" => cheap, "opus-4" => dear })
    expect(book.price("claude-opus-4-5")).to eq(dear)
  end

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

# `bin/lint-price-freshness` is a repo lint (`pre-commit run --all-files`), not
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

  # A price table older than its review horizon fails the lint.
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

  # A current table passes silently.
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
