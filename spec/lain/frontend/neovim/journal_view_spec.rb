# frozen_string_literal: true

# The journal's presentation, extracted from {Frontend::Neovim} as the third
# projection sibling of {Buffers} and {RequestBuffer}. Pure: events in, plain
# lines out -- the nvim-facing behavior stays covered by the :nvim specs.
#
# Was `spec/lain/frontend/neovim_journal_view_spec.rb` (a flat, non-mirrored
# path -- every other subject in this directory follows `lib/`'s tree, e.g.
# `buffers.rb` -> `neovim/buffers_spec.rb`) with a literal `eq("lain://journal"
# => [""])` that pinned the very defect this file's #initial spec now fixes.
# Consolidated here rather than left as two describe blocks for one class.
RSpec.describe Lain::Frontend::Neovim::JournalView do
  subject(:view) { described_class.new }

  describe "#initial" do
    # AC: an idle journal view says what it is waiting for, matching every
    # sibling view's placeholder shape (buffers.rb:260-269) instead of the
    # one-empty-line state that reads as "broken" (Surfaces#prime's own
    # stated principle).
    it "primes with a placeholder naming what it is waiting for, not a blank line" do
      expect(view.initial).to eq("lain://journal" => ["(no streamed tool output yet)"])
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
