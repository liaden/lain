# frozen_string_literal: true

RSpec.describe Lain::ReplyReserve do
  def reserve(window, ceiling) = described_class.tokens(window:, ceiling:)

  it "floors a small window at 4,096 tokens" do
    expect(reserve(32_768, 16_384)).to eq(4_096)
  end

  it "scales the floor to a quarter of a window under 16,384 tokens" do
    expect(reserve(8_192, 16_384)).to eq(2_048)
  end

  it "caps a large window at the output ceiling" do
    expect(reserve(262_144, 32_768)).to eq(32_768)
  end

  it "takes an eighth of a window between the floor and the ceiling" do
    expect(reserve(100_000, 50_000)).to eq(12_500)
  end

  it "never reserves more than the ceiling, even under the floor" do
    expect(reserve(32_768, 1_000)).to eq(1_000)
  end

  # A reserve the size of the window would put the compaction trigger at zero
  # and fire it every turn.
  it "never reserves more than half the window" do
    expect(reserve(4_096, 4_096)).to eq(1_024)
  end

  it "never shrinks when the window or the ceiling grows" do
    sizes = [1, 2, 100, 1_000, 4_096, 8_192, 16_384, 32_768, 100_000, 262_144, 1_000_000]
    sizes.product(sizes).each do |window, ceiling|
      expect(reserve(window + 1, ceiling)).to be >= reserve(window, ceiling)
      expect(reserve(window, ceiling + 1)).to be >= reserve(window, ceiling)
    end
  end

  describe ".room" do
    it "is the window less what is used and the reply reserve" do
      expect(described_class.room(window: 200_000, used: 150_000, ceiling: 8_192)).to eq(200_000 - 150_000 - 8_192)
    end

    it "is the room Need, Source and RoundBudget each compute for the same turn" do
      expected = described_class.room(window: 200_000, used: 150_000, ceiling: 8_192)
      need_state = Lain::Compaction::Need.const_get(:State)
                                         .new(head_bytes: 0, fixed_bytes: 0, used_tokens: 150_000,
                                              window_tokens: 200_000, manual: false, plan_step_completed: false,
                                              reply_ceiling: 8_192)
      resolution = Struct.new(:window_tokens).new(200_000)
      source_room = Lain::Compaction::Source.allocate.send(:room_left, 150_000, resolution, 8_192)
      usage = Lain::Usage.new(input_tokens: 100_000, output_tokens: 50_000)
      limit = Lain::Tool::RoundBudget.window.instance_variable_get(:@limit)
                                     .call(Lain::Tool::Room.new(window: 200_000, usage:, ceiling: 8_192))

      expect([need_state.room, source_room, limit.bytes])
        .to eq([expected, expected, (expected * Lain::Oracle::Handoff::BYTES_PER_TOKEN).floor])
    end

    it "goes negative once the turn has eaten into the reserve" do
      expect(described_class.room(window: 32_768, used: 30_000, ceiling: 16_384)).to eq(-1_328)
    end
  end
end
