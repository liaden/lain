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
end
