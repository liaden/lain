# frozen_string_literal: true

require "json"

RSpec.describe Lain::Telemetry::GradeRecord do
  let(:fields) { { grader: "Lain::Grader::Fixture", score: 1.0, pass: true, why: "ok", subject_digest: "blake3:abc" } }

  it "journals the arm it was graded under" do
    record = described_class.new(**fields, arm: "single-thread")

    expect(JSON.parse(JSON.generate(record.to_journal))).to include("type" => "grade_record", "arm" => "single-thread")
  end

  it "reads an old record with no arm as unattributed" do
    expect(described_class.new(**fields).arm).to be_nil
  end

  it "stays deeply frozen with an arm" do
    expect(described_class.new(**fields, arm: +"single-thread")).to be_deeply_frozen
  end

  it "journals the grader digest" do
    record = described_class.new(**fields, grader_digest: "blake3:def")

    expect(JSON.parse(JSON.generate(record.to_journal))).to include("grader_digest" => "blake3:def")
  end

  it "builds from an old grade line with no grader_digest" do
    old = { "grader" => "G", "score" => 1.0, "pass" => true, "why" => "ok", "subject_digest" => "d" }
    record = described_class.new(**old.transform_keys(&:to_sym))

    expect(record.grader_digest).to be_nil
  end

  it "stays deeply frozen with a grader digest" do
    expect(described_class.new(**fields, grader_digest: +"blake3:def")).to be_deeply_frozen
  end

  describe "journal bytes" do
    it "prints every field when all are set" do
      record = described_class.new(grader: "Lain::Grader::Fixture", score: 0.5, pass: true, why: "ok",
                                   subject_digest: "blake3:abc", criteria_digest: "blake3:crit",
                                   arm: "single-thread", grader_digest: "blake3:def")

      expect(JSON.generate(record.to_journal)).to eq(
        '{"type":"grade_record","grader":"Lain::Grader::Fixture","score":0.5,"pass":true,"why":"ok",' \
        '"subject_digest":"blake3:abc","criteria_digest":"blake3:crit","arm":"single-thread",' \
        '"grader_digest":"blake3:def"}'
      )
    end

    it "prints null for every optional field and clamps the score" do
      record = described_class.new(grader: "G", score: 2, pass: false, why: "no", subject_digest: "d")

      expect(JSON.generate(record.to_journal)).to eq(
        '{"type":"grade_record","grader":"G","score":1.0,"pass":false,"why":"no","subject_digest":"d",' \
        '"criteria_digest":null,"arm":null,"grader_digest":null}'
      )
    end
  end

  it "refuses a pass that is not a real boolean" do
    expect { described_class.new(**fields, pass: "yes") }.to raise_error(ArgumentError, /pass must be true or false/)
  end

  describe "interning and refusals" do
    def build(**extra) = described_class.new(**fields, grader: +"G", why: +"ok", arm: +"arm", **extra)

    it "interns grader, why and arm across equal records" do
      a = build
      b = build

      expect([a.grader.equal?(b.grader), a.why.equal?(b.why), a.arm.equal?(b.arm)]).to eq([true] * 3)
    end

    it "refuses an unknown keyword and a missing one with ArgumentError" do
      expect { build(bogus: 1) }.to raise_error(ArgumentError)
      expect { described_class.new(**fields.except(:score)) }.to raise_error(ArgumentError)
    end
  end
end
