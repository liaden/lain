# frozen_string_literal: true

require "json"

RSpec.describe Lain::Telemetry::Verdict do
  let(:fields) { { digest: "blake3:abc", survived: true, score: 0.9, why: "holds" } }

  it "journals the scale it was judged on" do
    record = described_class.new(**fields, scale: :three)

    expect(JSON.parse(JSON.generate(record.to_journal))).to include("type" => "verdict", "scale" => "three")
  end

  it "reads an old record with no scale as unattributed" do
    expect(described_class.new(**fields).scale).to be_nil
  end

  it "stays deeply frozen with a scale" do
    expect(described_class.new(**fields, scale: +"three")).to be_deeply_frozen
  end

  it "journals the index of the refuter that judged it" do
    record = described_class.new(**fields, refuter: 2)

    expect(JSON.parse(JSON.generate(record.to_journal))).to include("refuter" => 2)
  end

  it "reads an old record with no refuter as unindexed, and stays shareable" do
    record = described_class.new(**fields)

    expect(record.refuter).to be_nil
    expect(Ractor.shareable?(record)).to be(true)
    expect(Ractor.shareable?(described_class.new(**fields, refuter: 1))).to be(true)
  end

  describe "journal bytes" do
    it "journals every field, scale as a String" do
      record = described_class.new(**fields, scale: :unit, refuter: 2)
      expect(JSON.generate(record.to_journal)).to eq(
        '{"type":"verdict","digest":"blake3:abc","survived":true,"score":0.9,"why":"holds","scale":"unit",' \
        '"refuter":2}'
      )
    end

    it "journals absent scale and refuter as null, and clamps the score" do
      record = described_class.new(**fields, score: 3, survived: false)
      expect(JSON.generate(record.to_journal)).to eq(
        '{"type":"verdict","digest":"blake3:abc","survived":false,"score":1.0,"why":"holds","scale":null,' \
        '"refuter":null}'
      )
    end

    it "interns the explanation across equal records" do
      first = described_class.new(**fields, why: +"holds")
      second = described_class.new(**fields, why: +"holds")
      expect(first.why).to equal(second.why)
    end

    it "refuses a keyword it does not declare" do
      expect { described_class.new(**fields, stray: 1) }.to raise_error(ArgumentError, /stray/)
    end
  end

  describe "blank names" do
    it "refuses why given as false, an empty Array or an empty Hash, as it did before interning" do
      [false, [], {}].each do |blank|
        expect do
          described_class.new(**fields, why: blank)
        end.to raise_error(ArgumentError, /why must explain the verdict/)
      end
    end
  end

  describe "post-settle conversions" do
    it "journals a Symbol scale as a frozen String" do
      expect(described_class.new(**fields, scale: :unit).scale).to eq("unit").and be_frozen
    end
  end
end
