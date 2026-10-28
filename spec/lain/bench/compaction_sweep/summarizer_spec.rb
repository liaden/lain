# frozen_string_literal: true

RSpec.describe Lain::Bench::CompactionSweep::Summarizer do
  let(:definition) { Lain::Oracle::Summarize.definition }
  let(:question) { definition.render({ "source" => "a long tool result" }) }
  let(:answer_record) do
    { "type" => "oracle_answer", "oracle_digest" => definition.digest, "question" => question,
      "answer" => { "summary" => "a short recap" } }
  end
  let(:journal) { Data.define(:entries).new(entries: [answer_record]) }

  describe Lain::Bench::CompactionSweep::Summarizer::Recorded do
    subject(:summarizer) { described_class.new }

    it "answers a tier from the journal" do
      expect(summarizer.tier(definition, journal).ask({ "source" => "a long tool result" }).await.summary)
        .to eq("a short recap")
    end

    it "names itself to the tier as recorded and spends nothing" do
      tier = summarizer.tier(definition, journal)
      expect([tier.model, tier.usage]).to eq(["recorded", {}])
    end

    it "builds an oracle that replays the journal" do
      oracle = summarizer.oracle(definition, journal, answers_to: [])
      expect(oracle.ask({ "source" => "a long tool result" }).await.summary).to eq("a short recap")
    end

    it "is quiet about a miss and named recorded" do
      expect([summarizer.loud?, summarizer.name]).to eq([false, "recorded"])
    end
  end

  describe Lain::Bench::CompactionSweep::Summarizer::Local do
    subject(:summarizer) { described_class.new(factory) }

    let(:tier) do
      answer = definition.answer({ "summary" => "asked" })
      Object.new.tap do |each|
        each.define_singleton_method(:ask) { |_inputs = {}| answer }
        each.define_singleton_method(:model) { "stub" }
        each.define_singleton_method(:usage) { {} }
      end
    end
    let(:factory) { ->(each) { each.equal?(definition) ? tier : raise("wrong definition") } }

    it "returns what its factory builds as the tier" do
      expect(summarizer.tier(definition, journal)).to be(tier)
    end

    it "builds an oracle that asks the factory's tier and journals the answer" do
      written = []
      oracle = summarizer.oracle(definition, journal, answers_to: written)
      oracle.ask({ "source" => "a long tool result" })
      expect(written).to all(be_a(Lain::Telemetry::OracleAnswer)).and have_attributes(size: 1)
    end

    it "is loud about a miss and named local" do
      expect([summarizer.loud?, summarizer.name]).to eq([true, "local"])
    end
  end
end
