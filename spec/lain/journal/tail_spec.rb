# frozen_string_literal: true

RSpec.describe Lain::Journal::Tail do
  subject(:tail) { described_class.new }

  it "answers the hashes of the lines a chunk completes" do
    expect(tail << %({"type":"a"}\n{"type":"b"}\n)).to eq([{ "type" => "a" }, { "type" => "b" }])
  end

  it "holds an unterminated last line until its newline lands" do
    held = tail << %({"type":"a"}\n{"ty)
    expect([held, tail << %(pe":"b"}\n)]).to eq([[{ "type" => "a" }], [{ "type" => "b" }]])
  end

  it "joins a multibyte character cut between 2 binary chunks" do
    bytes = %({"label":"日本"}\n).b
    cut = bytes.index("\xE6".b) + 1
    expect([tail << bytes.byteslice(0, cut), tail << bytes.byteslice(cut..)]).to eq([[], [{ "label" => "日本" }]])
  end

  it "takes a binary chunk after a UTF-8 one without an encoding error" do
    tail << +%({"label":"café )
    expect(tail << "\xE2\x98\x95\"}\n".b).to eq([{ "label" => "café ☕" }])
  end

  it "skips a line that is not a record, a NUL or invalid UTF-8 included, and never raises" do
    lines = "not json\n[1]\n{\"a\":\0}\n\xFF\xFE\n{\"type\":\"kept\"}\n".b
    expect(tail << lines).to eq([{ "type" => "kept" }])
  end

  it "reads a line ending in CR LF" do
    expect(tail << %({"type":"a"}\r\n)).to eq([{ "type" => "a" }])
  end

  it "answers no hashes for a chunk with no newline" do
    expect(tail << %({"type")).to eq([])
  end
end
