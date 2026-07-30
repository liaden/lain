# frozen_string_literal: true

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
      expect(usage).to be_deeply_frozen
    end
  end

  # The Anthropic wire's usage object had three hand-written decoders --
  # Provider::Anthropic, Provider::Bedrock and SessionRecord::Salvage each
  # spelled the same four string keys out. Salvage's copy is the one that
  # matters: it decodes bytes replayed from the WAL, so a key that drifted there
  # would under-report spend on exactly the turn nobody was watching.
  describe ".from_anthropic_wire" do
    it "maps the four wire keys onto the four fields" do
      wire = { "input_tokens" => 10, "output_tokens" => 4,
               "cache_creation_input_tokens" => 2, "cache_read_input_tokens" => 8 }

      expect(described_class.from_anthropic_wire(wire))
        .to eq(described_class.new(input_tokens: 10, output_tokens: 4,
                                   cache_creation_input_tokens: 2, cache_read_input_tokens: 8))
    end

    # A turn with no cache activity omits both cache keys entirely.
    it "reads absent cache keys as zero" do
      decoded = described_class.from_anthropic_wire({ "input_tokens" => 3, "output_tokens" => 1 })

      expect(decoded.cache_creation_input_tokens).to eq(0)
      expect(decoded.cache_read_input_tokens).to eq(0)
    end

    # An assembled stream with no usage event at all hands over `{}`, and the
    # sync path's `body["usage"]` can be nil outright. Both are the absence of
    # billing information, which is exactly zero -- not a reason to raise.
    it "reads an empty or missing usage object as zero" do
      expect(described_class.from_anthropic_wire({})).to eq(described_class.zero)
      expect(described_class.from_anthropic_wire(nil)).to eq(described_class.zero)
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
                     identity: described_class.zero,
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

  # The laws above, said in `lib/` beside `#+`. One `commutative_monoid` line
  # files BOTH claims, which is what lets a walk hold `#+` to identity,
  # associativity and commutativity without knowing which structure contains
  # which.
  describe "the declared algebra" do
    # Declarations only: a Refutation carries no identity, so an unfiltered
    # `about` would raise instead of diffing the day somebody files one here.
    let(:declarations) { Lain::Algebra.registry.about(described_class).grep(Lain::Algebra::Declaration) }

    it "declares both the monoid and the commutative monoid on #+" do
      expect(declarations.map { |claim| [claim.structure, claim.operation] })
        .to eq([%i[monoid +], %i[commutative_monoid +]])
    end

    # The very object the two law groups above are run with.
    it "names ZERO as the unit of both" do
      expect(declarations.map(&:identity)).to contain_exactly(be(described_class.zero), be(described_class.zero))
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
