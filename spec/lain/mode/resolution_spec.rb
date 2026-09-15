# frozen_string_literal: true

require "stringio"

RSpec.describe Lain::Mode::Resolution do
  let(:journal) { Lain::Journal.new(io: StringIO.new) }
  let(:asking) { Lain::Approval::Escalation.new([], journal:, label: "ask") }
  let(:automatic) { Lain::Approval::Escalation.new([], journal:, label: "auto") }
  let(:ladders) { { ask: asking, auto: automatic } }

  def resolve(**mode) = described_class.for(mode: Lain::Mode.new(**mode), ladders:)

  describe "the gate policy" do
    it "selects the ask ladder under ask approval" do
      expect(resolve(approval: :ask).gate_policy).to be(asking)
    end

    it "selects the auto ladder under auto approval" do
      expect(resolve(approval: :auto).gate_policy).to be(automatic)
    end

    # The same object on every resolution is what lets the policy switch see
    # that a flip moved nothing.
    it "hands back the identical policy each time a level resolves" do
      expect(resolve(approval: :auto).gate_policy).to be(resolve(approval: :auto).gate_policy)
    end

    it "is not moved by a layer" do
      expect(resolve(layers: %i[auto_approve]).gate_policy).to be(asking)
    end
  end

  # No Null Object stands behind a level: a session resolved without a policy
  # for it would stop guarding in silence.
  describe "a level the session wired no policy for" do
    it "refuses by name, listing the levels it does hold" do
      expect { described_class.for(mode: Lain::Mode.new(approval: :auto), ladders: { ask: asking }) }
        .to raise_error(described_class::Unknown, /auto.*\[:ask\]/m)
    end

    it "refuses a policy that was named but is nil" do
      expect { described_class.for(mode: Lain::Mode.new, ladders: { ask: nil, auto: automatic }) }
        .to raise_error(described_class::Unknown, /ask/)
    end
  end

  describe "the resolution itself" do
    it "is a frozen value" do
      expect(resolve).to be_frozen
    end

    it "answers the gate policy, and nothing about the toolset" do
      expect(resolve.to_h.keys).to eq(%i[gate_policy])
    end
  end
end
