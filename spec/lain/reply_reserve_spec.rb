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
end
