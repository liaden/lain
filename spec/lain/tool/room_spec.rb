# frozen_string_literal: true

RSpec.describe Lain::Tool::Room do
  def room = described_class.new(window: 32_768, usage: Lain::Usage.zero, ceiling: 16_384, head: "blake3:asked")

  it "names the window, the last turn's usage, the reply ceiling and the head" do
    expect(room).to have_attributes(window: 32_768, usage: Lain::Usage.zero, ceiling: 16_384, head: "blake3:asked")
  end

  it "is deeply frozen" do
    expect(room).to be_deeply_frozen
  end
end
