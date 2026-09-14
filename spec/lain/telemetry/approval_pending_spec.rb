# frozen_string_literal: true

RSpec.describe Lain::Telemetry::ApprovalPending do
  subject(:event) { described_class.new(requester: "agent", tool: "bash", tool_use_id: "tu_1") }

  it "journals as approval_pending naming the requester, the tool, and the call" do
    expect(event.journal_type).to eq("approval_pending")
    expect(event.to_journal).to eq(
      "type" => "approval_pending", "requester" => "agent", "tool" => "bash", "tool_use_id" => "tu_1"
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
    pending = Lain::Approval::Queue::Pending.new(
      effect: Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input: { "cmd" => "ls" }),
      requester: "the-agent", clock: -> { 0.0 }
    )

    record = described_class.from(pending)
    expect(record).to have_attributes(requester: "the-agent", tool: "bash", tool_use_id: "tu_1")
    expect(record).to be_deeply_frozen
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
