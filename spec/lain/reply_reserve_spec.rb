# frozen_string_literal: true

RSpec.describe Lain::ReplyReserve do
  def reserve(window, ceiling, **) = described_class.for(window:, ceiling:, **)

  it "floors a small window at 4,096 tokens" do
    expect(reserve(32_768, 16_384).tokens).to eq(4_096)
  end

  it "caps a large window at the output ceiling" do
    expect(reserve(262_144, 32_768).tokens).to eq(32_768)
  end

  it "takes an eighth of a window between the floor and the ceiling" do
    expect(reserve(100_000, 50_000).tokens).to eq(12_500)
  end

  it "never reserves more than the ceiling, even under the floor" do
    expect(reserve(32_768, 1_000).tokens).to eq(1_000)
  end

  # A reserve the size of the window would put the compaction trigger at zero
  # and fire it every turn.
  it "never reserves more than half the window" do
    expect(reserve(4_096, 4_096).tokens).to eq(2_048)
  end

  it "names the window provenance it was computed from" do
    expect(reserve(32_768, 16_384, basis: :probed).basis).to eq(:probed)
  end

  it "is deeply frozen" do
    expect(reserve(32_768, 16_384)).to be_deeply_frozen
  end
end
