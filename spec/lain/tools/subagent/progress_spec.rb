# frozen_string_literal: true

RSpec.describe Lain::Tools::Subagent::Progress do
  let(:tee) { [] }
  let(:journal) { [] }
  let(:payment) do
    Lain::Telemetry::TurnUsage.new(digest: "blake3:t", model: "m", stop_reason: :end_turn,
                                   usage: { "input_tokens" => 5 })
  end

  def child(occupancy:) = instance_double(Lain::Agent, occupancy:)

  describe "#accounted_by" do
    it "passes every record to the journal, and tells the live views only of a payment" do
      progress = described_class.new(spawn: "blake3:spawn", tee:).measuring(ceiling: 9) { child(occupancy: 0.25) }
      other = Lain::Telemetry::RunAllowance.new(iterations: 9)

      wrapped = progress.accounted_by(journal)
      wrapped << other
      wrapped << payment

      expect(journal).to eq([other, payment])
      expect(tee.map { [_1.iterations, _1.occupancy, _1.ceiling] }).to eq([[1, 0.25, 9]])
    end

    it "counts one iteration per payment" do
      progress = described_class.new(spawn: "blake3:spawn", tee:).measuring(ceiling: 9) { child(occupancy: 0.1) }

      3.times { progress.accounted_by(journal) << payment }

      expect(tee.map(&:iterations)).to eq([1, 2, 3])
    end

    it "publishes a record with no occupancy where the window book cannot size the model" do
      agent = instance_double(Lain::Agent)
      allow(agent).to receive(:occupancy).and_raise(Lain::ContextWindow::UnknownModel, "no such model")
      progress = described_class.new(spawn: "blake3:spawn", tee:).measuring(ceiling: 9) { agent }

      progress.accounted_by(journal) << payment

      expect(tee.map { [_1.iterations, _1.occupancy, _1.ceiling] }).to eq([[1, nil, 9]])
    end

    it "publishes a record with no occupancy where the book answers a non-positive window" do
      agent = instance_double(Lain::Agent)
      allow(agent).to receive(:occupancy).and_raise(ArgumentError, "window must be positive")
      progress = described_class.new(spawn: "blake3:spawn", tee:).measuring(ceiling: 9) { agent }

      progress.accounted_by(journal) << payment

      expect(tee.map(&:occupancy)).to eq([nil])
    end
  end

  describe Lain::Tools::Subagent::Progress::Null do
    it "answers itself to measuring, so a build with no spawn asks nothing" do
      expect(described_class.measuring(ceiling: 5) { raise "never read" }).to equal(described_class)
    end

    it "hands the journal back untouched" do
      expect(described_class.accounted_by(journal)).to equal(journal)
    end
  end
end
