# frozen_string_literal: true

RSpec.describe Lain::Workspace do
  describe ".empty" do
    it "is a shared, frozen, Ractor-shareable value with no reminders" do
      first = described_class.empty
      second = described_class.empty

      expect(first).to be(second)
      expect(first).to be(described_class::EMPTY)
      expect(first).to be_frozen
      expect(Ractor.shareable?(first)).to be(true)
      expect(first.reminders).to be_empty
      expect(first).to be_empty
    end
  end

  describe "#initialize" do
    it "freezes via the Freezable concern, deeply and Ractor-shareably" do
      workspace = described_class.new(reminders: %w[a b])

      expect(workspace).to be_frozen
      expect(workspace.reminders).to be_frozen
      expect(Ractor.shareable?(workspace)).to be(true)
    end

    it "holds its reminders in order, deeply frozen" do
      expect(described_class.new(reminders: %w[a b]).reminders).to eq(%w[a b])
    end
  end

  describe "#empty?" do
    it "delegates to reminders" do
      expect(described_class.new).to be_empty
      expect(described_class.new(reminders: %w[x])).not_to be_empty
    end
  end

  describe "#with" do
    it "returns self when nothing is added, sparing the steady-state allocation" do
      workspace = described_class.new(reminders: %w[a])
      expect(workspace.with).to be(workspace)
    end

    it "returns a new frozen Workspace with the reminders appended in order" do
      workspace = described_class.new(reminders: %w[a]).with("b", "c")

      expect(workspace.reminders).to eq(%w[a b c])
      expect(workspace).to be_frozen
    end
  end

  describe "#to_blocks" do
    it "wraps each reminder in the workspace tags" do
      expect(described_class.new(reminders: %w[hi]).to_blocks)
        .to eq([{ "type" => "text", "text" => "<workspace>hi</workspace>" }])
    end
  end
end
