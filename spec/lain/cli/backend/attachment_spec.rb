# frozen_string_literal: true

RSpec.describe Lain::CLI::Backend::Attachment do
  let(:switch) { Lain::Context::ModelSwitch.new("qwen3:4b", journal: instance_double(Lain::Journal, record: nil)) }
  let(:board) { Struct.new(:model_switch).new(switch) }
  let(:channel) { [] }
  let(:shared) { Lain::Budget::Shared.new }
  let(:attached) { described_class.new(board:, channel:, spend: shared) }

  describe "before a board is attached" do
    subject(:detached) { described_class::Detached.new("qwen3:4b") }

    it "answers the launch model and pays nowhere" do
      expect([detached.model, detached.spend]).to eq(["qwen3:4b", Lain::Budget::Shared::Null])
    end

    it "admits any board and channel" do
      expect { detached.admit!(board, channel, shared) }.not_to raise_error
    end
  end

  it "follows the board's model switch" do
    attached
    switch.switch("qwen3-coder:30b", surface: :spec)

    expect(attached.model).to eq("qwen3-coder:30b")
  end

  it "admits the same board on the same channel again" do
    expect { attached.admit!(board, channel, shared) }.not_to raise_error
  end

  it "refuses another board, another channel, or both, naming what moved" do
    other = Struct.new(:model_switch).new(switch)

    expect { attached.admit!(other, channel, shared) }
      .to raise_error(Lain::CLI::Backend::Rebound, /attached to another board\z/)
    expect { attached.admit!(board, [], shared) }
      .to raise_error(Lain::CLI::Backend::Rebound, /attached to another channel\z/)
    expect { attached.admit!(other, [], shared) }
      .to raise_error(Lain::CLI::Backend::Rebound, /attached to another board and channel\z/)
  end

  it "refuses another spend on the same board, so the tiers are never re-pointed to pay elsewhere" do
    expect { attached.admit!(board, channel, Lain::Budget::Shared.new) }
      .to raise_error(Lain::CLI::Backend::Rebound, /attached to another spend\z/)
  end
end
