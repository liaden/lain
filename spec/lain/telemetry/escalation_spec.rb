# frozen_string_literal: true

RSpec.describe Lain::Telemetry::Escalation do
  let(:effect) { Lain::Effect::ToolCall.new(name: "bash", input: {}, tool_use_id: "tu_1") }
  let(:ruling) { Lain::Approval::Escalation::Ruling }
  let(:journal) { [] }
  let(:role_context) { Struct.new(:requester).new("researcher") }

  def written = journal.sole

  it "journals under the escalation type" do
    expect(described_class.new(tool: "bash", tool_use_id: "tu_1", requester: "chat", rule: nil,
                               ruling: ruling.deny(rung: "gate", because: "no")).to_journal)
      .to include("type" => "escalation", "tool" => "bash", "tool_use_id" => "tu_1", "requester" => "chat")
  end

  [
    ["the gate", -> { _1.deny(rung: "config", because: "refused", final: true) }],
    ["a remembered denial", -> { _1.deny(rung: "remembered", because: "asked", authority: :human, said: "no") }],
    ["the judge", -> { _1.deny(rung: "judge", because: "unsure") }],
    ["the ladder", -> { _1.deny(rung: "ladder", because: "nothing answered", fault: true) }]
  ].each do |source, build|
    it "gives the ruling from #{source} one shape" do
      given = build.call(ruling)

      described_class.write(journal, given, effect, nil)

      expect(written).to include("type" => "escalation", "tool" => "bash", "tool_use_id" => "tu_1",
                                 "requester" => Lain::Approval::Queue::REQUESTER, "rung" => given.rung,
                                 "verdict" => "deny", "authority" => given.authority.to_s)
    end
  end

  it "keeps the authority a remembered denial was given" do
    described_class.write(journal, ruling.deny(rung: "remembered", because: "b", authority: :human), effect, nil)

    expect(written).to include("authority" => "human")
  end

  it "names the requester the context names" do
    described_class.write(journal, ruling.deny(rung: "gate", because: "b"), effect, role_context)

    expect(written).to include("requester" => "researcher")
  end

  it "prefers a requester it was given over the context's" do
    described_class.write(journal, ruling.deny(rung: "gate", because: "b"), effect, role_context, requester: "fixed")

    expect(written).to include("requester" => "fixed")
  end

  it "carries the rule the ruling names and leaves the key off when none" do
    described_class.write(journal, ruling.deny(rung: "gate", because: "b"), effect, nil)

    expect(written).not_to have_key("rule")
  end

  it "carries extra fields, dropping the nil ones" do
    described_class.write(journal, ruling.deny(rung: "judge", because: "b"), effect, nil, error: "boom", bar: nil)

    expect(written).to include("error" => "boom").and(satisfy { !_1.key?("bar") })
  end

  it "writes to a Journal as one parseable record" do
    io = StringIO.new

    described_class.write(Lain::Journal.new(io:), ruling.deny(rung: "gate", because: "b"), effect, nil)

    expect(Lain::Journal.records(io.string.lines, type: "escalation").sole).to include("tool" => "bash")
  end

  it "never raises when the journal does" do
    dead = Class.new { def <<(_entry) = raise(IOError, "the journal is gone") }.new

    expect { described_class.write(dead, ruling.deny(rung: "gate", because: "b"), effect, nil) }.not_to raise_error
  end

  describe ".requester_of" do
    it "answers the given name, else the context's, else the default" do
      expect([described_class.requester_of(role_context, "fixed"), described_class.requester_of(role_context),
              described_class.requester_of(nil)])
        .to eq(["fixed", "researcher", Lain::Approval::Queue::REQUESTER])
    end
  end
end
