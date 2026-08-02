# frozen_string_literal: true

RSpec.describe Lain::Toolset do
  # Builds a throwaway tool class with a given name. Only the name matters for
  # capability-set behavior, so the body is trivial.
  def tool(tool_name)
    Class.new(Lain::Tool) do
      define_method(:name) { tool_name.to_s }
      define_method(:description) { "the #{tool_name} tool" }
      def perform(_input, _context) = Lain::Tool::Result.ok("ok")
    end.new
  end

  let(:read)  { tool(:read_file) }
  let(:grep)  { tool(:grep) }
  let(:bash)  { tool(:bash) }
  let(:full)  { described_class.new([read, grep, bash]) }

  describe "construction" do
    it "is frozen -- a capability set does not mutate" do
      expect(full).to be_frozen
    end

    it "refuses two tools with the same name" do
      expect { described_class.new([tool(:dup), tool(:dup)]) }
        .to raise_error(described_class::DuplicateTool, /named "dup"/)
    end

    it "is Enumerable in name order regardless of construction order" do
      out_of_order = described_class.new([bash, read, grep])
      expect(out_of_order.map(&:name)).to eq(%w[bash grep read_file])
    end
  end

  describe "#fetch" do
    it "returns the tool by name, accepting a Symbol or String" do
      expect(full.fetch(:grep)).to be(grep)
      expect(full.fetch("grep")).to be(grep)
    end

    it "raises rather than returning nil for an absent capability" do
      expect { full.fetch(:nope) }.to raise_error(described_class::UnknownTool, /no tool named "nope"/)
    end
  end

  describe "attenuation" do
    it "#only returns a new, smaller, frozen Toolset" do
      restricted = full.only(:read_file, :grep)
      expect(restricted.names).to eq(%w[grep read_file])
      expect(restricted).to be_frozen
      expect(full.names).to eq(%w[bash grep read_file]) # receiver untouched
    end

    it "#except returns a new Toolset with the named tools removed" do
      expect(full.except(:bash).names).to eq(%w[grep read_file])
    end

    it "attenuation is monotonic -- a dropped capability cannot be regained" do
      expect { full.only(:read_file).only(:bash) }
        .to raise_error(described_class::UnknownTool, /absent tools: bash/)
    end

    it "refuses to reference a tool the set does not hold" do
      expect { full.only(:ghost) }.to raise_error(described_class::UnknownTool, /absent tools: ghost/)
      expect { full.except(:ghost) }.to raise_error(described_class::UnknownTool, /absent tools: ghost/)
    end
  end

  describe "#to_schema" do
    it "is sorted by name" do
      expect(full.to_schema.map { |t| t["name"] }).to eq(%w[bash grep read_file])
    end

    it "is byte-identical across constructions in different orders (cache stability)" do
      one = described_class.new([read, grep, bash])
      two = described_class.new([bash, grep, read])
      # This is the invariant Anthropic's prompt cache depends on: a Hash
      # iterating in insertion order would silently break it.
      expect(Lain::Canonical.dump(one.to_schema)).to eq(Lain::Canonical.dump(two.to_schema))
    end

    it "carries each tool's neutral schema fields" do
      expect(full.to_schema.first).to include("name" => "bash", "strict" => true)
    end

    # The schema is built once in #initialize (the digest needs it, and the
    # object freezes itself there), so every call hands back the SAME object
    # rather than a fresh normalization. Pinned because sharing is a visible
    # change of identity, even though it is not a change of value.
    it "returns the very same array on every call" do
      expect(full.to_schema).to equal(full.to_schema)
    end

    it "is deeply frozen, so sharing it cannot leak a mutable value" do
      expect(full.to_schema).to be_frozen
      expect(full.to_schema.first).to be_frozen
      expect(full.to_schema.first.fetch("input_schema")).to be_frozen
    end

    it "raises rather than letting one caller mutate what every caller sees" do
      expect { full.to_schema << {} }.to raise_error(FrozenError)
      expect { full.to_schema.first["name"] = "other" }.to raise_error(FrozenError)
    end
  end

  describe "#digest" do
    it "is the content address of the rendered schema" do
      expect(full.digest).to eq(Lain::Canonical.digest(full.to_schema))
    end

    it "is frozen -- digests are Hash keys all over" do
      expect(full.digest).to be_frozen
    end

    it "is identical across construction orders" do
      expect(described_class.new([bash, grep, read]).digest).to eq(full.digest)
    end

    it "moves under attenuation" do
      expect(full.only(:grep).digest).not_to eq(full.digest)
    end
  end

  describe "equality" do
    it "is equal for the same tools built in different orders" do
      one = described_class.new([read, grep, bash])
      two = described_class.new([bash, grep, read])
      expect(one).to eq(two)
      expect(one).to eql(two)
      expect(one.hash).to eq(two.hash)
    end

    # The empty set is the identity element of the attenuation algebra, so its
    # equality is the case a law battery leans on hardest.
    it "equates two empty Toolsets" do
      expect(described_class.new).to eq(described_class.new([]))
    end

    it "is unequal for different capability sets" do
      expect(full.only(:read_file, :grep)).not_to eq(full)
      expect(full.except(:bash)).not_to eq(full)
      expect(described_class.new).not_to eq(full)
    end

    it "works as a Hash key, found by an equal-but-distinct set" do
      table = { full => :parent }
      expect(table[described_class.new([bash, grep, read])]).to eq(:parent)
    end

    it "leaves equal? alone -- value equality is not identity" do
      expect(described_class.new([read])).not_to equal(described_class.new([read]))
    end

    it "is schema equality, not behavioral equality" do
      one = described_class.new([tool(:same)])
      two = described_class.new([Class.new(Lain::Tool) do
        def name = "same"
        def description = "the same tool"
        def perform(_input, _context) = Lain::Tool::Result.error("entirely different behavior")
      end.new])
      expect(one).to eq(two)
    end

    it "is not equal to a non-Toolset that happens to carry the same schema" do
      expect(full).not_to eq(full.to_schema)
    end
  end

  # to_s is the human-facing tool list; inspect keeps the class-tagged,
  # debug-oriented form -- the DegradedSet convention (see
  # capability/degraded_set_spec.rb).
  describe "string conversions" do
    it "renders to_s as the joined tool names, untagged" do
      expect(full.to_s).to eq("bash, grep, read_file")
    end

    it "keeps inspect class-tagged for debugging" do
      expect(full.inspect).to eq("#<Lain::Toolset bash, grep, read_file>")
    end

    it "does not alias to_s and inspect" do
      expect(full.method(:to_s)).not_to eq(full.method(:inspect))
    end
  end
end
