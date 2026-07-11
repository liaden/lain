# frozen_string_literal: true

require "json"

require "lain/ledger/index"
require "lain/usage"

# The Index folds a Journal's turn_usage records into digest => payments,
# one Entry per RECORD (see Event::TurnUsage: the digest is a join key).
RSpec.describe Lain::Ledger::Index do
  def record(digest:, model: "claude-sonnet-4", usage: { "input_tokens" => 10, "output_tokens" => 5 })
    { "type" => "turn_usage", "digest" => digest, "model" => model,
      "stop_reason" => "end_turn", "usage" => usage }
  end

  describe ".from_journal" do
    it "keeps only turn_usage records out of a mixed NDJSON stream" do
      lines = [
        JSON.generate(record(digest: "blake3:aa")),
        JSON.generate("type" => "tool_result", "tool_use_id" => "tu_1", "content" => "x"),
        "not json at all {",
        JSON.generate(record(digest: "blake3:bb", model: "claude-haiku-3-5"))
      ]
      index = described_class.from_journal(lines)

      expect(index.entries_for("blake3:aa")).not_to be_empty
      expect(index.entries_for("blake3:bb")).not_to be_empty
      expect(index.entries_for("tu_1")).to be_empty
    end

    it "accepts already-parsed Hashes, symbol keys included -- the same duck Handler::Recorded takes" do
      index = described_class.from_journal([
                                             record(digest: "blake3:aa"),
                                             { type: "turn_usage", digest: "blake3:bb", model: "claude-haiku-3-5",
                                               stop_reason: "end_turn",
                                               usage: { input_tokens: 1, output_tokens: 2 } }
                                           ])
      expect(index.entries_for("blake3:aa")).not_to be_empty
      expect(index.entries_for("blake3:bb").first.usage.total_tokens).to eq(3)
    end

    it "parses each record's usage into a Lain::Usage and keeps its model" do
      index = described_class.from_journal([record(digest: "blake3:aa")])
      entry = index.entries_for("blake3:aa").first

      expect(entry.usage).to eq(Lain::Usage.new(input_tokens: 10, output_tokens: 5))
      expect(entry.model).to eq("claude-sonnet-4")
    end

    it "keeps a nil model nil -- a bare mock reports none" do
      index = described_class.from_journal([record(digest: "blake3:aa", model: nil)])
      expect(index.entries_for("blake3:aa").first.model).to be_nil
    end

    it "raises loudly on a turn_usage record with no usage -- a corrupt payment must not price as free" do
      corrupt = { "type" => "turn_usage", "digest" => "blake3:aa", "model" => "claude-sonnet-4" }
      expect { described_class.from_journal([corrupt]) }
        .to raise_error(ArgumentError, /usage/)
    end

    it "retains one Entry per RECORD when a digest repeats: payments, not content" do
      index = described_class.from_journal([
                                             record(digest: "blake3:same"),
                                             record(digest: "blake3:same", model: "claude-haiku-3-5")
                                           ])
      entries = index.entries_for("blake3:same")

      expect(entries.size).to eq(2)
      expect(entries.map(&:model)).to eq(["claude-sonnet-4", "claude-haiku-3-5"])
    end
  end

  describe "#entries_for" do
    it "answers an empty Array for a digest it never saw" do
      index = described_class.from_journal([])
      expect(index.entries_for("blake3:unknown")).to eq([])
    end
  end

  describe "immutability" do
    it "is deeply frozen and Ractor-shareable" do
      index = described_class.from_journal([JSON.generate(record(digest: "blake3:aa"))])
      expect(Ractor.shareable?(index)).to be(true)
    end

    it "hands out frozen entry lists, even the empty one" do
      index = described_class.from_journal([record(digest: "blake3:aa")])
      expect(index.entries_for("blake3:aa")).to be_frozen
      expect(index.entries_for("blake3:missing")).to be_frozen
    end
  end
end
