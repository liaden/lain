# frozen_string_literal: true

RSpec.describe Lain::Tool::Room do
  def room = described_class.new(window: 32_768, usage: Lain::Usage.zero, ceiling: 16_384)

  it "names the window, the last turn's usage and the reply ceiling" do
    expect(room).to have_attributes(window: 32_768, usage: Lain::Usage.zero, ceiling: 16_384)
  end

  it "is deeply frozen" do
    expect(room).to be_deeply_frozen
  end
end
