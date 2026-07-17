# frozen_string_literal: true

# The journal's presentation, extracted from {Frontend::Neovim} as the third
# projection sibling of {Buffers} and {RequestBuffer}. Pure: events in, plain
# lines out -- the nvim-facing behavior stays covered by the :nvim specs.
RSpec.describe Lain::Frontend::Neovim::JournalView do
  subject(:view) { described_class.new }

  describe "#initial" do
    it "primes the journal to the one-empty-line state a fresh buffer holds" do
      expect(view.initial).to eq("lain://journal" => [""])
    end
  end

  describe "#lines" do
    it "attributes each ToolOutput line with its tool_use_id and stream" do
      event = Lain::Telemetry::ToolOutput.new(tool_use_id: "t1", stream: :stdout, bytes: "a\nb\n")

      expect(view.lines(event)).to eq(["[t1 stdout] a", "[t1 stdout] b"])
    end

    it "keeps interior blanks as the bare prefix, stripping only the trailing newline" do
      event = Lain::Telemetry::ToolOutput.new(tool_use_id: "t9", stream: :stderr, bytes: "a\n\nc\n")

      expect(view.lines(event)).to eq(["[t9 stderr] a", "[t9 stderr]", "[t9 stderr] c"])
    end

    it "renders nothing for an event the journal does not present" do
      expect(view.lines(:not_a_tool_output)).to eq([])
    end
  end
end
