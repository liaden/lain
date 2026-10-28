# frozen_string_literal: true

RSpec.describe Lain::Telemetry::ApprovalPending do
  subject(:event) { described_class.new(requester: "agent", tool: "bash", tool_use_id: "tu_1") }

  it "journals as approval_pending naming the requester, the tool, the call and who may decide it" do
    expect(event.journal_type).to eq("approval_pending")
    expect(event.to_journal).to eq(
      "type" => "approval_pending", "requester" => "agent", "tool" => "bash", "tool_use_id" => "tu_1",
      "humans_only" => false
    )
  end

  # The Pending it is built from holds a clock and a mutable decision, so the
  # record must be a SEPARATE value -- this is the assertion that keeps it one.
  it "is deeply frozen and Ractor-shareable even when built from mutable Strings" do
    mutable = described_class.new(requester: +"agent", tool: +"bash", tool_use_id: +"tu_1")
    expect(mutable).to be_deeply_frozen
  end

  # The house idiom (Effect::ToolCall's own `-name.to_s`): two equal records
  # must share one String object, not hold two copies of the same bytes.
  it "interns its strings, so equal records share their bytes" do
    twin = described_class.new(requester: +"agent", tool: +"bash", tool_use_id: +"tu_1")
    expect(event).to eq(twin)
    expect(event.tool).to equal(twin.tool)
    expect(event.requester).to equal(twin.requester)
    expect(event.tool_use_id).to equal(twin.tool_use_id)
  end

  it "is built from a parked Pending, carrying neither its clock nor its decision" do
    pending = Lain::Approval::Parked::Queue::Pending.new(
      effect: Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input: { "cmd" => "ls" }),
      identity: Lain::Requester.new(name: "the-agent"), clock: -> { 0.0 }
    )

    record = described_class.from(pending)
    expect(record).to have_attributes(requester: "the-agent", tool: "bash", tool_use_id: "tu_1", humans_only: false)
    expect(record).to be_deeply_frozen
  end

  it "carries the digest of the parked call's input, and never the input" do
    effect = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input: { "command" => "rm -rf build" })
    pending = Lain::Approval::Parked::Queue::Pending.new(effect:, identity: Lain::Requester.main, clock: -> { 0.0 })

    journaled = described_class.from(pending).to_journal
    expect(journaled).to include("input_digest" => Lain::Canonical.digest(effect.input))
    expect(journaled.to_json).not_to include("rm -rf build")
    expect(event.to_journal).not_to have_key("input_digest")
  end

  it "says so when the Pending it is built from may be decided by a person only" do
    pending = Lain::Approval::Parked::Queue::Pending.new(
      effect: Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input: {}),
      identity: Lain::Requester.main, clock: -> { 0.0 }, humans_only: true
    )

    expect(described_class.from(pending).humans_only).to be(true)
  end

  it "carries a kind that defaults to tool and is journaled only when it is not" do
    decision = Lain::Approval::Parked::Queue::Decision.new(requester: "egress", kind: "egress", summary: "s",
                                                           digest: "b3_abc")
    pending = Lain::Approval::Parked::Queue::DecisionPending.new(
      decision:, identity: Lain::Requester.new(name: "egress"), clock: -> { 0.0 }
    )

    expect(event.kind).to eq("tool")
    expect(event.to_journal).not_to have_key("kind")
    expect(described_class.from(pending).to_journal).to include("kind" => "egress", "tool_use_id" => "b3_abc")
  end

  it "carries the notes of the Pending it is built from, and omits the key when there are none" do
    pending = Lain::Approval::Parked::Queue::Pending.new(
      effect: Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input: {}),
      identity: Lain::Requester.main, clock: -> { 0.0 }, notes: ["cat is /bin/cat"]
    )

    record = described_class.from(pending)
    expect(record.to_journal["notes"]).to eq(["cat is /bin/cat"])
    expect(record).to be_deeply_frozen
    expect(event.to_journal).not_to have_key("notes")
  end

  describe "journal lines, byte for byte" do
    def line(**fields)
      JSON.generate(described_class.new(requester: "agent", tool: "bash", tool_use_id: "tu_1", **fields).to_journal)
    end

    it "prints every field when none equals its default" do
      expect(line(humans_only: true, notes: ["cat is /bin/cat"], kind: "egress", input_digest: "blake3:abc")).to eq(
        '{"type":"approval_pending","requester":"agent","tool":"bash","tool_use_id":"tu_1","humans_only":true,' \
        '"notes":["cat is /bin/cat"],"kind":"egress","input_digest":"blake3:abc"}'
      )
    end

    it "omits notes, kind and input_digest while they are at their defaults" do
      expect(line).to eq(
        '{"type":"approval_pending","requester":"agent","tool":"bash","tool_use_id":"tu_1","humans_only":false}'
      )
    end

    it "omits each default on its own" do
      expect(line(notes: ["n"])).to end_with('"humans_only":false,"notes":["n"]}')
      expect(line(kind: "egress")).to end_with('"humans_only":false,"kind":"egress"}')
      expect(line(input_digest: "blake3:abc")).to end_with('"humans_only":false,"input_digest":"blake3:abc"}')
    end
  end

  it "interns the notes, the kind and the input digest too" do
    one = described_class.new(requester: "a", tool: "b", tool_use_id: "c", notes: [+"n"], kind: +"egress",
                              input_digest: +"d")
    two = described_class.new(requester: "a", tool: "b", tool_use_id: "c", notes: [+"n"], kind: +"egress",
                              input_digest: +"d")

    expect([one.notes.first, one.kind, one.input_digest]).to eq(%w[n egress d])
    expect(one.notes.first).to equal(two.notes.first)
    expect(one.kind).to equal(two.kind)
    expect(one.input_digest).to equal(two.input_digest)
  end

  it "refuses false for each identifier, as it refuses nil" do
    expect do
      described_class.new(requester: false, tool: "b", tool_use_id: "c")
    end.to raise_error(ArgumentError, /requester/)
    expect { described_class.new(requester: "a", tool: false, tool_use_id: "c") }.to raise_error(ArgumentError, /tool /)
    expect { described_class.new(requester: "a", tool: "b", tool_use_id: false) }
      .to raise_error(ArgumentError, /tool_use_id/)
  end

  it "journals humans_only as true only for exactly true" do
    record = described_class.new(requester: "a", tool: "b", tool_use_id: "c", humans_only: "yes")

    expect(record.humans_only).to be(false)
  end

  it "still refuses an unknown keyword" do
    expect { described_class.new(requester: "a", tool: "b", tool_use_id: "c", extra: 1) }.to raise_error(ArgumentError)
  end

  # Loud failure, the same validate-then-freeze contract every sibling record
  # has: a nameless park would journal `{"tool":""}` and read as evidence.
  it "refuses a record that names no tool, no call, or no requester" do
    expect(Lain::Telemetry::Carriers::ApprovalPending.new(requester: nil, tool: nil, tool_use_id: nil))
      .to be_invalid
    expect { described_class.new(requester: "agent", tool: nil, tool_use_id: "tu_1") }
      .to raise_error(ArgumentError, /tool must name the gated tool/)
    expect { described_class.new(requester: "agent", tool: "bash", tool_use_id: nil) }
      .to raise_error(ArgumentError, /tool_use_id must name the gated call/)
    expect { described_class.new(requester: nil, tool: "bash", tool_use_id: "tu_1") }
      .to raise_error(ArgumentError, /requester must name who the call was asked for/)
  end
end
