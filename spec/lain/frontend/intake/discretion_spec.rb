# frozen_string_literal: true

RSpec.describe Lain::Frontend::Intake::Discretion do
  let(:writer) { Struct.new(:kept) { def remember(line) = kept << line }.new([]) }
  let(:discretion) { described_class.new(writer:) }

  it "hands an ordinary line to the writer" do
    discretion.remember("fix the flaky spec")

    expect(writer.kept).to eq(["fix the flaky spec"])
  end

  it "withholds a line shaped like a credential the write tier names" do
    ["export OPENAI_API_KEY=sk-#{"a" * 24}", "AKIA#{"A" * 16}", "the password: hunter2",
     "-----BEGIN PRIVATE KEY-----"].each { |line| discretion.remember(line) }

    expect(writer.kept).to be_empty
  end

  # The content tier's yaml shape matches any `word: text` line of prose, which
  # at a prompt is most of what a human types.
  it "judges by the write tier, so a line of ordinary prose with a colon is still kept" do
    discretion.remember("note: the build is green")

    expect(writer.kept).to eq(["note: the build is green"])
  end

  # A terminal can hand over bytes that are not valid in the encoding they are
  # labelled with, and a raise here would unwind the read the line answered.
  it "judges a line whose bytes are not valid UTF-8 without raising" do
    discretion.remember((+"caf\xE9 token=abc").force_encoding(Encoding::UTF_8))
    discretion.remember((+"caf\xE9 au lait").force_encoding(Encoding::UTF_8))

    expect(writer.kept.map(&:b)).to eq(["caf\xE9 au lait".b])
  end
end
