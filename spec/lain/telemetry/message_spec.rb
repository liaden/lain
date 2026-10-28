# frozen_string_literal: true

require "json"

# An additive session-record type, its discriminator pinned here as the on-disk
# contract -- additive by construction, so the turn-chain loader's `of_type`
# narrowing skips it and an older reader stays unaffected.
RSpec.describe Lain::Telemetry::Message do
  let(:store) { Lain::Dag::Factory.store }
  let(:parent) do
    Lain::Dag::Factory.timeline(store:).commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
  end
  let(:event) do
    Lain::EventLog::ChainWriter.new.put(parent, kind: :message, from: parent.correlation, to: "human",
                                                causal_parents: [parent.head_digest], body: { "question" => "q?" })
  end

  it "journals a :message Event as an additive `message` record, field-pinned" do
    record = described_class.from_event(event)
    expect(record.journal_type).to eq("message")
    expect(record.to_journal).to eq(
      "type" => "message", "digest" => event.digest, "kind" => :message,
      "from" => parent.correlation, "to" => "human", "payload" => { "question" => "q?" },
      "causal_parents" => event.causal_parents, "correlation" => event.correlation
    )
  end

  it "carries a :spawn Event under the same type, kind distinguishing it, a nil `to` tolerated" do
    spawn = Lain::EventLog::ChainWriter.new.put(parent, kind: :spawn, from: parent.correlation, to: nil,
                                                        causal_parents: [parent.head_digest], body: {})
    record = described_class.from_event(spawn)
    expect(record.kind).to eq(:spawn)
    expect(record.to).to be_nil
    expect(record.journal_type).to eq("message")
  end

  describe "the journal line" do
    it "matches the line the record has always written" do
      record = described_class.new(digest: "blake3:d", kind: :message, from: "blake3:f", to: "human",
                                   payload: { "question" => "q?" }, causal_parents: ["blake3:p"],
                                   correlation: "blake3:c")

      expect(JSON.generate(record.to_journal))
        .to eq('{"type":"message","digest":"blake3:d","kind":"message","from":"blake3:f","to":"human",' \
               '"payload":{"question":"q?"},"causal_parents":["blake3:p"],"correlation":"blake3:c"}')
    end

    it "keeps a nil to and correlation as null, and reads a String kind as a Symbol" do
      record = described_class.new(digest: "blake3:d", kind: "spawn", from: "blake3:f", to: nil, payload: {},
                                   causal_parents: [], correlation: nil)

      expect(JSON.generate(record.to_journal))
        .to eq('{"type":"message","digest":"blake3:d","kind":"spawn","from":"blake3:f","to":null,' \
               '"payload":{},"causal_parents":[],"correlation":null}')
      expect(record.kind).to eq(:spawn)
    end
  end

  it "is shareable when built from mutable input" do
    record = described_class.new(digest: +"blake3:d", kind: :message, from: +"blake3:f", to: +"human",
                                 payload: { "question" => +"q?" }, causal_parents: [+"blake3:p"],
                                 correlation: +"blake3:c")

    expect(record).to be_deeply_frozen
  end

  it "refuses an unknown keyword as an ArgumentError" do
    expect do
      described_class.new(digest: "d", kind: :message, from: "f", to: nil, payload: {}, causal_parents: [],
                          correlation: nil, extra: 1)
    end.to raise_error(ArgumentError, /extra/)
  end
end
