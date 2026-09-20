# frozen_string_literal: true

RSpec.describe Lain::StopReason do
  it "knows exactly the non-beta enum" do
    expect(described_class::KNOWN)
      .to contain_exactly(:end_turn, :tool_use, :max_tokens, :stop_sequence, :pause_turn, :refusal)
  end

  # Beta-only. Coding against them on the non-beta path waits for an event that
  # never arrives.
  it "does not pretend the Beta-only reasons exist" do
    expect(described_class::KNOWN).not_to include(:model_context_window_exceeded, :compaction)
  end

  it "normalizes a String" do
    expect(described_class.normalize("tool_use")).to eq(:tool_use)
  end

  # The wire enums are non-exhaustive; an unrecognized value passes through
  # rather than raising, so the state machine needs somewhere to put it.
  it "maps anything unrecognized to :unknown" do
    expect(described_class.normalize("something_new_in_2027")).to eq(:unknown)
    expect(described_class.normalize(nil)).to eq(:unknown)
  end

  it "keeps :stop_sequence, which is easy to forget" do
    expect(described_class.normalize(:stop_sequence)).to eq(:stop_sequence)
  end
end
