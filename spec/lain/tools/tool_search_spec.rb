# frozen_string_literal: true

RSpec.describe Lain::Tools::ToolSearch do
  # Mirrors spec/lain/toolset/disclosure_spec.rb's helper.
  def tool(tool_name, description: "the #{tool_name} tool")
    Class.new(Lain::Tool) do
      define_method(:name) { tool_name.to_s }
      define_method(:description) { description }
      def perform(_input, _context) = Lain::Tool::Result.ok("ok")
    end.new
  end

  let(:read) do
    input = Class.new(Lain::Tool::Input) do
      field :path, :string, description: "Path to read.", required: true
    end

    Class.new(Lain::Tool) do
      input_model input

      define_method(:name) { "read_file" }
      define_method(:description) { "Reads a file's contents from disk, given a path." }
      def perform(_input, _context) = Lain::Tool::Result.ok("ok")
    end.new
  end
  let(:grep) { tool(:grep, description: "Searches file contents for a pattern.") }
  let(:bash) { tool(:bash, description: "Runs a shell command via sh -c.") }

  # The full capability set -- includes bash.
  let(:full_toolset) { Lain::Toolset.new([bash, grep, read]) }
  # What THIS agent actually holds -- bash dropped, the security-relevant case.
  let(:attenuated_toolset) { full_toolset.except(:bash) }

  subject(:search_tool) { described_class.new(toolset: -> { attenuated_toolset }) }

  it "has a model-facing name and description" do
    expect(search_tool.name).to eq("tool_search")
    expect(search_tool.description).to be_a(String)
    expect(search_tool.description).not_to be_empty
  end

  it "is not gated by approval (no subprocess, no model-controlled command string)" do
    expect(search_tool.requires_approval?).to be(false)
  end

  describe "exact-name lookup" do
    it "returns the tool's full input schema" do
      result = search_tool.call(query: "read_file")

      expect(result).to be_ok
      expect(result.content).to include("input_schema")
      expect(result.content).to include("path")
    end

    it "the returned schema matches the tool's own #to_schema, canonically" do
      result = search_tool.call(query: "read_file")

      expect(result.content).to eq(Lain::Canonical.dump(read.to_schema))
    end
  end

  describe "keyword search" do
    it "returns matching catalog entries, not full schemas" do
      result = search_tool.call(query: "file contents")

      expect(result).to be_ok
      expect(result.content).to include("grep")
      expect(result.content).not_to include("input_schema")
    end

    it "is an ok, informative empty result when nothing matches" do
      result = search_tool.call(query: "nonexistent_capability_xyz")

      expect(result).to be_ok
      expect(result.content).to be_a(String)
    end
  end

  # ---- Capability gating: the security-relevant AC --------------------------

  describe "capability gating -- possession gates disclosure, not just invocation" do
    it "an exact-name query for a tool NOT in the (attenuated) toolset does not return its schema" do
      result = search_tool.call(query: "bash")

      expect(result.content).not_to include("input_schema")
      expect(result.content).not_to include("sh -c")
    end

    it "a keyword query matching a dropped tool's description never surfaces it" do
      result = search_tool.call(query: "shell command")

      expect(result.content).not_to include("bash")
    end

    it "search is scoped to exactly the injected toolset, never a wider registry" do
      # bash exists (in full_toolset) but was never handed to search_tool --
      # a leak here would mean tool_search consults something other than the
      # toolset it was constructed with.
      full_toolset # force construction so bash unambiguously exists somewhere
      result = search_tool.call(query: "bash")

      expect(result.content).not_to include("input_schema")
    end

    # The class of bug this card exists to catch: a keyword match against the
    # FULL description while only the one-line prefix is ever rendered would
    # let a caller binary-search substrings to infer text the catalog never
    # shows. Matching must use the exact same one-line projection that gets
    # disclosed -- nothing past it is ever a match target.
    it "a substring that exists only past the first line of a description is not inferable via search" do
      secret = tool(:mem_dump, description: "Reads process memory.\nCAPABILITY_SECRET_MARKER lives here.")
      scoped = Lain::Toolset.new([secret])
      search_over_scoped = described_class.new(toolset: -> { scoped })

      result = search_over_scoped.call(query: "CAPABILITY_SECRET_MARKER")

      # A match would have surfaced mem_dump's catalog entry; the absence of
      # its name IS the proof the second line was never a match target --
      # the query text itself echoing back in a "no match" message is not a
      # leak, since the caller supplied that text.
      expect(result.content).not_to include("mem_dump")
      expect(result.content).to eq('no tools match "CAPABILITY_SECRET_MARKER"')
    end
  end
end
