# frozen_string_literal: true

RSpec.describe Lain::Telemetry::JudgeRuled do
  subject(:event) { described_class.new(call: +"bash({})", verdict: "denied") }

  it "journals under its own type with the call and the verdict" do
    expect(event.to_journal).to include("type" => "judge_ruled", "call" => "bash({})", "verdict" => "denied")
  end

  it "refuses a verdict other than approved or denied" do
    expect { described_class.new(call: "bash({})", verdict: "deferred") }
      .to raise_error(ArgumentError, /deferred/)
  end

  it "has no default verdict, so every producer states one" do
    expect { described_class.new(call: "bash({})") }.to raise_error(ArgumentError, /verdict/)
  end
end
