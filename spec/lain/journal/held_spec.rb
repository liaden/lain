# frozen_string_literal: true

RSpec.describe Lain::Journal::Held do
  subject(:held) { described_class.new }

  let(:journal) { [] }

  it "keeps a record until it is released" do
    held << { "type" => "early" }

    expect(journal).to be_empty
  end

  it "writes what it kept on release, in the order it came" do
    held << { "type" => "first" } << { "type" => "second" }
    held.release(journal)

    expect(journal).to eq([{ "type" => "first" }, { "type" => "second" }])
  end

  it "passes a record straight through once released" do
    held.release(journal)
    held << { "type" => "late" }

    expect(journal).to eq([{ "type" => "late" }])
  end

  it "writes a kept record once however often it is released" do
    held << { "type" => "early" }
    2.times { held.release(journal) }

    expect(journal).to eq([{ "type" => "early" }])
  end
end
