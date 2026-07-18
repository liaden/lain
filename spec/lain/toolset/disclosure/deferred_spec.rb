# frozen_string_literal: true

RSpec.describe Lain::Toolset::Disclosure::Deferred do
  # Mirrors spec/lain/toolset/disclosure_spec.rb's helper: a throwaway tool
  # class with a given name and description.
  def tool(tool_name, description: "the #{tool_name} tool")
    Class.new(Lain::Tool) do
      define_method(:name) { tool_name.to_s }
      define_method(:description) { description }
      def perform(_input, _context) = Lain::Tool::Result.ok("ok")
    end.new
  end

  let(:read) { tool(:read_file, description: "Reads a file's contents from disk, given a path.") }
  let(:grep) { tool(:grep, description: "Searches file contents for a pattern.") }
  let(:bash) { tool(:bash, description: "Runs a shell command via sh -c.") }
  let(:toolset) { Lain::Toolset.new([bash, grep, read]) }

  subject(:disclosure) { described_class.new }

  it "is a Disclosure arm" do
    expect(described_class.ancestors).to include(Lain::Toolset::Disclosure)
  end

  describe "#render" do
    let(:rendered) { disclosure.render(toolset) }

    it "renders one catalog entry per tool" do
      expect(rendered.size).to eq(3)
    end

    it "surfaces only name and description, never the input schema" do
      rendered.each do |entry|
        expect(entry.keys.sort).to eq(%w[description name])
      end
    end

    it "carries each tool's name" do
      expect(rendered.map { |entry| entry.fetch("name") }.sort).to eq(%w[bash grep read_file])
    end

    it "carries each tool's description" do
      entry = rendered.find { |e| e.fetch("name") == "read_file" }
      expect(entry.fetch("description")).to eq("Reads a file's contents from disk, given a path.")
    end

    it "never includes a full input_schema (the point of deferring disclosure)" do
      expect(Lain::Canonical.dump(rendered)).not_to include("input_schema")
    end

    it "truncates a multi-line description to its first line" do
      multiline = tool(:multi, description: "First line only.\nSecond line stays hidden upfront.")
      solo = Lain::Toolset.new([multiline])

      entry = disclosure.render(solo).first

      expect(entry.fetch("description")).to eq("First line only.")
    end

    it "is byte-identical regardless of construction order (cache stability)" do
      reordered = Lain::Toolset.new([read, grep, bash])

      expect(Lain::Canonical.dump(disclosure.render(toolset)))
        .to eq(Lain::Canonical.dump(disclosure.render(reordered)))
    end

    it "reflects attenuation -- a dropped tool never appears in the catalog" do
      attenuated = toolset.except(:bash)
      rendered_attenuated = disclosure.render(attenuated)

      expect(rendered_attenuated.map { |entry| entry.fetch("name") }).not_to include("bash")
    end
  end
end
