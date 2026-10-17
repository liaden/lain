# frozen_string_literal: true

RSpec.describe Lain::Compaction::Source::CompactionPrepared do
  subject(:record) do
    described_class.new(head_digest: "blake3:head", cut_digest: "blake3:cut", idle_seconds: 301, cache_state: "cold")
  end

  it "journals under its own name with its attributes" do
    expect(record.to_journal).to eq("type" => "compaction_prepared", "head_digest" => "blake3:head",
                                    "cut_digest" => "blake3:cut", "idle_seconds" => 301, "cache_state" => "cold")
  end

  it "is deeply frozen" do
    expect(Ractor.shareable?(record)).to be(true)
  end
end
