# frozen_string_literal: true

require "lain/usage"

RSpec.describe Lain::Usage do
  def usage(input: 0, output: 0, creation: 0, read: 0)
    described_class.new(input_tokens: input, output_tokens: output,
                        cache_creation_input_tokens: creation, cache_read_input_tokens: read)
  end

  let(:population) do
    Array.new(12) do
      usage(input: rand(0..5000), output: rand(0..2000), creation: rand(0..3000), read: rand(0..9000))
    end
  end

  describe "construction" do
    it "defaults every field to zero" do
      expect(described_class.new).to eq(described_class.zero)
    end

    # Cache fields are nullable on the wire. Normalizing to 0 keeps the monoid
    # total so no caller has to guard against nil.
    it "coerces nil cache fields to zero" do
      expect(usage(read: nil).cache_read_input_tokens).to eq(0)
    end

    it "is frozen" do
      expect(usage).to be_frozen
    end
  end

  # These are not decoration. Aggregating a branched Timeline sums over a set of
  # turns in no particular order; the laws are what make the total independent of
  # the walk order.
  describe "the commutative monoid laws" do
    random_usage = lambda do
      usage(input: rand(0..5000), output: rand(0..2000), creation: rand(0..3000), read: rand(0..9000))
    end

    include_examples "a monoid",
                     operation: ->(a, b) { a + b },
                     identity: Lain::Usage.zero,
                     generator: random_usage

    include_examples "a commutative monoid",
                     operation: ->(a, b) { a + b },
                     generator: random_usage

    it "sums the same regardless of the order it is folded in" do
      shuffled = population.shuffle.reduce(described_class.zero, :+)
      ordered = population.reduce(described_class.zero, :+)
      expect(shuffled).to eq(ordered)
    end

    it "refuses to add a non-Usage" do
      expect { usage + 1 }.to raise_error(TypeError, /cannot add Integer/)
    end
  end

  describe "totals" do
    subject(:u) { usage(input: 100, output: 20, creation: 30, read: 70) }

    it "counts everything billed on the way in" do
      expect(u.total_input_tokens).to eq(200)
    end

    it "counts everything" do
      expect(u.total_tokens).to eq(220)
    end
  end

  # A silent prompt-cache invalidator shows up here as a ratio that quietly falls
  # to zero while nothing errors. Hence: first-class bench metric.
  describe "#cache_hit_ratio" do
    it "is the read share of input" do
      expect(usage(input: 100, read: 100).cache_hit_ratio).to eq(0.5)
    end

    it "is zero when nothing came in, rather than dividing by zero" do
      expect(described_class.zero.cache_hit_ratio).to eq(0.0)
    end

    it "is 1.0 on a full cache hit" do
      expect(usage(read: 4096).cache_hit_ratio).to eq(1.0)
    end
  end

  it "answers zero?" do
    expect(described_class.zero).to be_zero
    expect(usage(input: 1)).not_to be_zero
  end
end
