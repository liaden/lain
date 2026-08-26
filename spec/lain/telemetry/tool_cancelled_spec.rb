# frozen_string_literal: true

# The record a tool-calling turn leaves behind when the run was
# interrupted in the middle of it. The EMITTER is spec'd where it lives --
# `spec/lain/agent_spec.rb` for when it is written and
# `spec/lain/seams/tool_cancellation_spec.rb` for a real tear; what is asserted
# here is the VALUE: the partition it carries, the guard that keeps a
# cancellation record from describing no cancellation, and the deep freeze every
# journalled value owes.
RSpec.describe Lain::Telemetry::ToolCancelled do
  subject(:record) do
    described_class.new(head: "blake3:aaa", cancelled: %w[tu_2 tu_3], running: %w[tu_2], completed: %w[tu_1])
  end

  it "carries the torn assistant turn and the partition of its calls" do
    expect(record).to have_attributes(head: "blake3:aaa", cancelled: %w[tu_2 tu_3],
                                      running: %w[tu_2], completed: %w[tu_1])
  end

  it "journals under a type a reader can discriminate without inspecting its shape" do
    expect(record.journal_type).to eq("tool_cancelled")
    expect(record.to_journal).to include("type" => "tool_cancelled", "head" => "blake3:aaa",
                                         "cancelled" => %w[tu_2 tu_3])
  end

  # `running` is the subset a load-side repair can never reconstruct: from a
  # journal alone, "the tool never ran" and "the tool ran and its effects are on
  # disk" are indistinguishable.
  it "reports the dispatched subset separately from the cancelled set" do
    expect(record.running - record.cancelled).to be_empty
    expect(record.completed & record.cancelled).to be_empty
  end

  # The defaults live on the carrier now (`default: -> { [] }`), so this also
  # pins that they are a fresh Array per record rather than ONE Array shared by
  # every record that omitted them -- which a bare `default: []` would be.
  it "defaults the two optional lists, for a turn torn before anything was dispatched" do
    bare = described_class.new(head: "blake3:aaa", cancelled: %w[tu_1])
    twin = described_class.new(head: "blake3:aaa", cancelled: %w[tu_1])

    expect(bare.running).to eq([])
    expect(bare.completed).to eq([])
    expect(bare.running).not_to equal(twin.running)
    expect(bare.completed).not_to equal(twin.completed)
  end

  it "refuses a record that names no torn turn" do
    expect { described_class.new(head: nil, cancelled: %w[tu_1]) }
      .to raise_error(ArgumentError, /head must name the assistant turn/)
  end

  # A turn torn AFTER every tool returned commits its real results and is not a
  # cancellation at all, so an empty `cancelled` is the one shape that would
  # read as a cancellation while describing none.
  it "refuses a cancellation record that cancels nothing" do
    expect { described_class.new(head: "blake3:aaa", cancelled: []) }
      .to raise_error(ArgumentError, /cancelled must name at least one cancelled call/)
  end

  it "is deeply frozen, ids included" do
    expect(Ractor.shareable?(record)).to be(true)
  end
end
