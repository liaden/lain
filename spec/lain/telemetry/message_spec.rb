# frozen_string_literal: true

# An additive session-record type, its discriminator pinned here as the on-disk
# contract -- additive by construction, so the turn-chain loader's `of_type`
# narrowing skips it and an older reader stays unaffected.
RSpec.describe Lain::Telemetry::Message do
  let(:store) { Lain::Store.new }
  let(:parent) do
    Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
  end
  let(:event) do
    Lain::Event::ChainWriter.new.put(parent, kind: :message, from: parent.correlation, to: "human",
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
    spawn = Lain::Event::ChainWriter.new.put(parent, kind: :spawn, from: parent.correlation, to: nil,
                                                     causal_parents: [parent.head_digest], body: {})
    record = described_class.from_event(spawn)
    expect(record.kind).to eq(:spawn)
    expect(record.to).to be_nil
    expect(record.journal_type).to eq("message")
  end

  it "is a frozen, Ractor-shareable value" do
    record = described_class.from_event(event)
    expect(record).to be_deeply_frozen
  end
end
