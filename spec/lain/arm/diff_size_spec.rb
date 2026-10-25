# frozen_string_literal: true

RSpec.describe Lain::Arm::DiffSize do
  def turn(role, text) = Struct.new(:role, :content).new(role, [{ "text" => text }])
  def timeline_of(*turns) = Data.define(:turns) { def to_a = turns }.new(turns)
  def timeline_saying(*texts) = timeline_of(*texts.map { |text| turn("assistant", text) })

  it "counts the files and lines of every FILE block the assistant wrote" do
    size = described_class.of(timeline_saying("FILE a.rb\none\ntwo\nEND", "FILE b.rb\nthree\nEND"))

    expect([size.files, size.lines]).to eq([2, 3])
  end

  it "counts zero for a run that wrote no FILE block" do
    expect(described_class.of(timeline_saying("done"))).to have_attributes(files: 0, lines: 0)
  end

  it "ignores text a user turn carried" do
    user = timeline_of(turn("user", "FILE a.rb\nx\nEND"))

    expect(described_class.of(user)).to have_attributes(files: 0)
  end

  # Pins what FileBlocks.parse reads today; fixing parse should flip this on purpose.
  it "counts as FileBlocks.parse reads it, so a malformed END swallows the next block" do
    size = described_class.of(timeline_saying("FILE a\nx\nEND \nFILE b\ny\nEND"))

    expect(size.files).to eq(1)
  end
end
