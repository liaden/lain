# frozen_string_literal: true

require "lain/toolset"

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
  end
end
