# frozen_string_literal: true

RSpec.describe Lain::Telemetry::JudgeApproved do
  subject(:event) { described_class.new(call: +"bash({})") }

  it "journals under its own type with the call" do
    expect(event.to_journal).to include("type" => "judge_approved", "call" => "bash({})")
  end

  it "is shareable across Ractors, like every other journaled value" do
    expect(Ractor.shareable?(event)).to be(true)
  end
end
