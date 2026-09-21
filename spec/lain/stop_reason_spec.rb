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

  # KNOWN is what a provider can SEND; ALL is what the loop can ROUTE. A
  # malformed response is lain's own reading of a wire reply, so it is routable
  # and never something the wire is believed to have said.
  describe "the machine-only reasons" do
    it "routes a malformed response without admitting it to the wire vocabulary" do
      expect(described_class::ALL).to include(:malformed)
      expect(described_class::KNOWN).not_to include(:malformed)
    end

    it "does not let a wire value spell its way into a machine-only reason" do
      expect(described_class.normalize("malformed")).to eq(:unknown)
      expect(described_class.normalize(:malformed)).to eq(:unknown)
    end
  end

  describe ".admit" do
    it "passes a reason that is already typed straight through" do
      expect(described_class.admit(described_class::MALFORMED)).to eq(:malformed)
      expect(described_class.admit(:tool_use)).to eq(:tool_use)
    end

    # A String is always wire, whatever it spells.
    it "normalizes everything else exactly as a wire value" do
      expect(described_class.admit("malformed")).to eq(:unknown)
      expect(described_class.admit("tool_use")).to eq(:tool_use)
      expect(described_class.admit("something_new_in_2027")).to eq(:unknown)
      expect(described_class.admit(nil)).to eq(:unknown)
    end
  end
end
