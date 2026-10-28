# frozen_string_literal: true

require "json"

RSpec.describe Lain::Telemetry::OracleAnswer do
  it "prints its journal line with every field set" do
    record = described_class.new(oracle_digest: "blake3:o", question: { "q" => "why" }, answer: { "a" => 1 },
                                 model: "m1", usage: { "in" => 3 }, wall_clock: 1.5)

    expect(JSON.generate(record.to_journal)).to eq(
      '{"type":"oracle_answer","oracle_digest":"blake3:o","question":{"q":"why"},"answer":{"a":1},' \
      '"model":"m1","usage":{"in":3},"wall_clock":1.5}'
    )
  end

  it "prints the defaults for a bare answer" do
    record = described_class.new(oracle_digest: "blake3:o", question: "q", answer: nil)

    expect(JSON.generate(record.to_journal)).to eq(
      '{"type":"oracle_answer","oracle_digest":"blake3:o","question":"q","answer":null,"model":null,' \
      '"usage":{},"wall_clock":0.0}'
    )
  end

  it "is shareable when built from mutable input" do
    record = described_class.new(oracle_digest: +"blake3:o", question: { "q" => +"why" }, answer: [+"a"],
                                 model: +"m1", usage: { "in" => 3 })

    expect(record).to be_deeply_frozen
  end

  it "refuses a record naming no oracle or no question" do
    expect { described_class.new(oracle_digest: nil, question: "q", answer: nil) }
      .to raise_error(ArgumentError, /oracle_digest must name the oracle/)
    expect { described_class.new(oracle_digest: "blake3:o", question: nil, answer: nil) }
      .to raise_error(ArgumentError, /question must carry the question/)
  end
end
