# frozen_string_literal: true

RSpec.describe Lain::CLI::Said do
  it "carries the words and the exit status of a command" do
    said = described_class.new(text: "stopped demo", status: 1)

    expect([said.text, said.status]).to eq(["stopped demo", 1])
  end

  it "is shareable, so a command's answer cannot be changed after it is given" do
    expect(Ractor.shareable?(described_class.new(text: +"done", status: 0))).to be(true)
  end
end
