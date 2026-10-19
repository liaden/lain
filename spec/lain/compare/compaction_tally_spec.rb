# frozen_string_literal: true

RSpec.describe Lain::Compare::CompactionTally do
  def decision(misses) = { "type" => "compaction_decision", "summary_misses" => misses }
  def prepared = { "type" => "compaction_prepared" }
  def applied = { "type" => "compaction_applied" }

  def compaction(saved:, spent:)
    { "type" => "compaction", "cost_saved" => saved, "cost_spent" => spent }
  end

  describe ".from_records" do
    it "tallies zeros and no cost figure for a journal with no compaction records" do
      tally = described_class.from_records([{ "type" => "turn_usage" }])
      expect(tally).to have_attributes(summary_misses: 0, prepared: 0, applied: 0, cost_delta: nil)
    end

    it "counts from the journal" do
      records = [decision(3), decision(1), prepared, prepared, applied]
      tally = described_class.from_records(records)
      expect(tally).to have_attributes(summary_misses: 4, prepared: 2, applied: 1, unapplied: 1)
    end

    it "sums the cost delta of the compaction records" do
      records = [compaction(saved: "0.5", spent: "0.2"), compaction(saved: "0.1", spent: "0.3")]
      expect(described_class.from_records(records).cost_delta).to eq(BigDecimal("0.1"))
    end

    it "answers a nil cost delta when any compaction record is unpriced" do
      records = [compaction(saved: "0.5", spent: "0.2"), compaction(saved: nil, spent: nil)]
      expect(described_class.from_records(records).cost_delta).to be_nil
    end

    it "reads the journal form of a real Telemetry::Compaction record" do
      record = Lain::Telemetry::Compaction.new(trigger: :tokens, cache_state: :cold, bytes_before: 10, bytes_after: 5,
                                               collapse_strategy: "eager",
                                               cost_saved: "0.5", cost_spent: "0.2").to_journal
      expect(described_class.from_records([record]).cost_delta).to eq(BigDecimal("0.3"))
    end

    it "reads a lazy enumerator of records" do
      expect(described_class.from_records([decision(2)].lazy).summary_misses).to eq(2)
    end
  end

  describe "NONE" do
    it "is a run with no journal: zero counts and no cost figure" do
      expect(described_class::NONE).to have_attributes(summary_misses: 0, unapplied: 0, cost_delta: nil)
    end
  end

  it "is Ractor-shareable" do
    expect(Ractor.shareable?(described_class.from_records([decision(1)]))).to be(true)
  end
end
