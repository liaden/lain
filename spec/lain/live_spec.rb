# frozen_string_literal: true

RSpec.describe Lain do
  describe ".live" do
    it "calls a callable and returns what it returns" do
      expect(described_class.live(-> { 42 })).to eq(42)
    end

    it "returns a plain value as-is" do
      expect(described_class.live(42)).to eq(42)
    end

    # Every hand-written thunk site this replaces let the thunk's own raise
    # propagate rather than rescuing it -- `.live` is resolution, not policy,
    # so it stays that way.
    it "propagates a raise from the callable rather than swallowing it" do
      boom = -> { raise "boom" }

      expect { described_class.live(boom) }.to raise_error("boom")
    end

    it "passes a callable's nil through rather than defaulting it" do
      expect(described_class.live(-> {})).to be_nil
    end

    # None of the four sites this generalizes memoized their thunk -- each
    # read calls again, because the live value may differ between calls (a
    # Timeline's head moves). `.live` keeps that: it is a pure resolution, not
    # a cache.
    it "calls the callable again on a second resolution rather than memoizing" do
      calls = 0
      counting = lambda do
        calls += 1
        calls
      end

      expect(described_class.live(counting)).to eq(1)
      expect(described_class.live(counting)).to eq(2)
    end

    # Single-level: a caller who wants two layers unwrapped has to say so
    # twice, rather than `.live` deciding for them by resolving until the
    # result stops answering `#call`.
    it "resolves only one level, leaving a callable-returning-callable uncalled" do
      inner = -> { 7 }
      outer = -> { inner }

      expect(described_class.live(outer)).to equal(inner)
    end

    # The four sites this generalizes each handed a zero-arg thunk; a
    # callable requiring one is not a shape any of them produced, and `.live`
    # does not accommodate it either -- it is a public method now, so this is
    # worth a named example rather than an inherited, unstated assumption.
    it "raises ArgumentError for a callable that requires an argument" do
      needs_one = ->(x) { x }

      expect { described_class.live(needs_one) }.to raise_error(ArgumentError)
    end
  end
end
