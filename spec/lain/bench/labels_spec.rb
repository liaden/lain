# frozen_string_literal: true

RSpec.describe Lain::Bench::Labels do
  let(:allowed) { Lain::Compare::Attribution::KINDS.map(&:to_s) }

  def sidecar(*lines)
    path = File.join(Dir.mktmpdir, "labels.jsonl")
    File.write(path, lines.join("\n"))
    path
  end

  it "answers the label recorded for a digest" do
    labels = described_class.load(sidecar('{"digest":"abc","label":"grader","by":"joel"}'), allowed:)

    expect(labels.fetch("abc")).to eq("grader")
  end

  it "answers nil for a digest nobody labelled" do
    expect(described_class.load(sidecar('{"digest":"abc","label":"grader"}'), allowed:).fetch("zzz")).to be_nil
  end

  it "labels nothing as NONE" do
    expect(described_class::NONE.fetch("abc")).to be_nil
  end

  it "is labelled when loaded, even from an empty file, and not when it is NONE" do
    expect(described_class.load(sidecar, allowed:)).to be_labelled
    expect(described_class::NONE).not_to be_labelled
  end

  it "makes NONE a Labels of its own kind that answers unlabelled and fetches nil" do
    expect(described_class::NONE).to be_a(described_class)
    expect(described_class::NONE.class).not_to eq(described_class)
    expect(described_class::NONE.fetch("abc")).to be_nil
  end

  it "refuses a label that is not allowed, naming the line and the allowed labels" do
    path = sidecar('{"digest":"abc","label":"grader"}', '{"digest":"def","label":"maybe"}')

    expect { described_class.load(path, allowed:) }
      .to raise_error(ArgumentError, /line 2.*maybe.*environment, reasoning, grader, prompt/)
  end

  it "refuses a line that is not JSON, naming the line" do
    expect { described_class.load(sidecar("nope"), allowed:) }.to raise_error(ArgumentError, /line 1/)
  end

  [["[]", "an array"], ["5", "a number"], ["null", "null"], ['"x"', "a string"],
   ['{"label":"prompt"}', "no digest"], ['{"digest":"","label":"prompt"}', "an empty digest"],
   ['{"digest":7,"label":"prompt"}', "a non-string digest"]].each do |line, what|
    it "refuses a line that is #{what}, naming the line" do
      expect { described_class.load(sidecar(line), allowed:) }
        .to raise_error(ArgumentError, /labels line 1 is not an object with a digest/)
    end
  end

  it "accepts a digest repeated with the same label" do
    path = sidecar('{"digest":"abc","label":"grader"}', '{"digest":"abc","label":"grader","by":"b"}')

    expect(described_class.load(path, allowed:).fetch("abc")).to eq("grader")
  end

  it "refuses a digest repeated with a different label, naming both lines" do
    path = sidecar('{"digest":"abc","label":"grader"}', '{"digest":"abc","label":"prompt"}')

    expect { described_class.load(path, allowed:) }.to raise_error(ArgumentError, /abc.*line 1.*line 2|lines 1 and 2/)
  end

  it "refuses a missing file as an ArgumentError naming the path" do
    expect { described_class.load("/no/such/labels.jsonl", allowed:) }
      .to raise_error(ArgumentError, "labels file not found: /no/such/labels.jsonl")
  end
end
