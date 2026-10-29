# frozen_string_literal: true

RSpec.describe Lain::Bench::FixtureSections do
  it "gives the same sections on every call, naming no machine" do
    toolset = Lain::Toolset.new([])

    expect(described_class.for(toolset)).to eq(described_class.for(toolset))
    expect(described_class.for(toolset).to_h.to_s).not_to include(Dir.home)
  end
end
