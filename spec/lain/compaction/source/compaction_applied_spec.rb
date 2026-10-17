# frozen_string_literal: true

RSpec.describe Lain::Compaction::Source::CompactionApplied do
  subject(:record) { described_class.new(cut_digest: "blake3:cut", head_digest: "blake3:head") }

  it "journals under its own name with its attributes" do
    expect(record.to_journal).to eq("type" => "compaction_applied", "cut_digest" => "blake3:cut",
                                    "head_digest" => "blake3:head")
  end

  it "is deeply frozen" do
    expect(Ractor.shareable?(record)).to be(true)
  end
end
