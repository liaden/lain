# frozen_string_literal: true

RSpec.describe Lain::Telemetry::JudgeRuled do
  subject(:event) { described_class.new(call: +"bash({})", verdict: "denied") }

  it "journals under its own type with the call and the verdict" do
    expect(event.to_journal).to include("type" => "judge_ruled", "call" => "bash({})", "verdict" => "denied")
  end

  it "journals a remembered verdict" do
    remembered = described_class.new(call: "bash({})", verdict: "remembered")

    expect(remembered.to_journal).to include("type" => "judge_ruled", "verdict" => "remembered")
  end

  it "refuses a verdict outside approved, denied and remembered" do
    expect { described_class.new(call: "bash({})", verdict: "deferred") }
      .to raise_error(ArgumentError, /deferred/)
  end

  it "has no default verdict, so every producer states one" do
    expect { described_class.new(call: "bash({})") }.to raise_error(ArgumentError, /verdict/)
  end

  describe "settled record" do
    it "journals byte for byte with every field set" do
      record = described_class.new(call: "bash({\"command\":\"ls\"})",
                                   verdict: "approved")
      expect(JSON.generate(record.to_journal)).to eq(
        '{"type":"judge_ruled","call":"bash({\"command\":\"ls\"})","verdict":"approved"}'
      )
    end

    it "is deeply frozen when built from mutable input" do
      given = {
        call: "bash({\"command\":\"ls\"})",
        verdict: "approved"
      }
      mutable = given.transform_values { |value| value.is_a?(String) ? value.dup : value }
      expect(described_class.new(**mutable)).to be_deeply_frozen
    end

    it "refuses a missing call, naming it" do
      given = {
        call: "bash({\"command\":\"ls\"})",
        verdict: "approved"
      }
      expect { described_class.new(**given.except(:call)) }.to raise_error(ArgumentError, /call/)
    end

    it "interns the verdict, as the old constructor did" do
      first = described_class.new(call: +"a", verdict: +"denied")
      second = described_class.new(call: +"b", verdict: +"denied")
      expect(first.verdict).to equal(second.verdict)
    end
  end
end
