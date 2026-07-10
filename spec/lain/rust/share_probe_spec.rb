# frozen_string_literal: true

require "lain"

# The M4 Timeline port depends on a magnus `TypedData` object being
# `Ractor.shareable?` once frozen. This canary proves the `frozen_shareable`
# mechanism in isolation, before `Turn` relies on it -- a magnus upgrade that
# silently broke the flag would fail here rather than deep in the port.
RSpec.describe Lain::Ext::ShareProbe do
  subject(:probe) { described_class.new(42) }

  it "wraps its immutable value" do
    expect(probe.value).to eq(42)
  end

  it "is frozen on construction" do
    expect(probe).to be_frozen
  end

  it "is Ractor-shareable, which is the whole point of the port" do
    expect(Ractor.shareable?(probe)).to be(true)
  end
end
