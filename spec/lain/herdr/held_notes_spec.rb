# frozen_string_literal: true

RSpec.describe Lain::Herdr::HeldNotes do
  subject(:notes) { described_class.new }

  let(:said) { [] }

  it "holds each note until it is bound, then says them in order" do
    notes.puts("first")
    notes.puts("second")
    expect(said).to be_empty

    notes.bind(said.method(:<<))

    expect(said).to eq(%w[first second])
  end

  it "says a note at once after it is bound" do
    notes.bind(said.method(:<<))
    notes.puts("now")

    expect(said).to eq(%w[now])
  end
end
