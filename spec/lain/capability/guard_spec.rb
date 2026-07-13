# frozen_string_literal: true

RSpec.describe Lain::Capability::Guard do
  def set(*caps)
    Lain::Capability::DegradedSet.new(caps)
  end

  it "passes when two degraded sets are equal" do
    expect(described_class.guard!(set(:thinking), set(:thinking))).to be(true)
  end

  it "passes when both degraded sets are empty" do
    expect(described_class.guard!(set, set)).to be(true)
  end

  it "ignores construction order when comparing" do
    expect(described_class.guard!(set(:thinking, :server_tools), set(:server_tools, :thinking)))
      .to be(true)
  end

  it "raises Mismatch when the degraded sets differ" do
    expect { described_class.guard!(set(:thinking), set(:server_tools)) }
      .to raise_error(described_class::Mismatch, /thinking.*server_tools|server_tools.*thinking/m)
  end

  it "raises when one run degraded and the other did not" do
    expect { described_class.guard!(set(:thinking), set) }
      .to raise_error(described_class::Mismatch)
  end
end
