# frozen_string_literal: true

RSpec.describe Lain::Frontend::Decorators::JudgeRuled do
  let(:theme) { Lain::Frontend::Theme.new(pastel: Pastel.new(enabled: false)) }
  let(:event) { Lain::Telemetry::JudgeRuled.new(call: 'bash({"command" => "git log --oneline -5"})', verdict: "approved") }

  it "names the call and that the judge approved it" do
    expect(described_class.new(event).render(theme))
      .to eq('the judge approved bash({"command" => "git log --oneline -5"})')
  end

  it "names the call and that the judge denied it" do
    denied = Lain::Telemetry::JudgeRuled.new(call: 'bash({"command" => "ls -la /home/u"})', verdict: "denied")

    expect(described_class.new(denied).render(theme)).to eq('the judge denied bash({"command" => "ls -la /home/u"})')
  end

  it "names a remembered approval apart from the judge's own" do
    remembered = Lain::Telemetry::JudgeRuled.new(call: "bash({})", verdict: "remembered")

    expect(described_class.new(remembered).render(theme)).to eq("the judge approved this earlier: bash({})")
  end

  it "names a replay of the human's own yes as theirs, never the judge's, dimmed" do
    dyed = Lain::Frontend::Theme.new(pastel: Pastel.new(enabled: true))
    yours = Lain::Telemetry::JudgeRuled.new(call: 'bash({"command" => "git push"})', verdict: "human_remembered")

    expect(described_class.new(yours).render(theme)).to eq('you approved this earlier: bash({"command" => "git push"})')
    expect(described_class.new(yours).render(dyed))
      .to eq(dyed.paint(:label, 'you approved this earlier: bash({"command" => "git push"})'))
  end

  it "dims a remembered approval and leaves the judge's own line plain" do
    dyed = Lain::Frontend::Theme.new(pastel: Pastel.new(enabled: true))
    remembered = Lain::Telemetry::JudgeRuled.new(call: "bash({})", verdict: "remembered")

    expect(described_class.new(remembered).render(dyed)).to eq(dyed.paint(:label,
                                                                          "the judge approved this earlier: bash({})"))
    expect(described_class.new(event).render(dyed)).not_to include("\e[")
  end

  it "cuts a long call to a fixed width with an ellipsis" do
    long = Lain::Telemetry::JudgeRuled.new(call: "bash(#{"x" * 100_000})", verdict: "approved")
    line = described_class.new(long).render(theme)

    expect(line.length).to be <= described_class::WIDTH + "the judge approved ".length
    expect(line).to end_with("...")
  end

  it "keeps a multi-line call on one line" do
    multi = Lain::Telemetry::JudgeRuled.new(call: "bash(a\nb\r\nc\e[2J)", verdict: "approved")
    line = described_class.new(multi).render(theme)

    expect(line).not_to match(/[[:cntrl:]]/)
  end

  it "drops bidi and other format characters" do
    flipped = Lain::Telemetry::JudgeRuled.new(call: "bash(\u202Eevil\u200B)", verdict: "approved")

    expect(described_class.new(flipped).render(theme)).to eq("the judge approved bash( evil )")
  end

  it "is one stamped, whole line" do
    decorator = described_class.new(event)

    expect([decorator.line_shaped?, decorator.stamped?]).to eq([true, true])
  end

  it "is what the frontend renders the event with" do
    expect(Lain::Frontend::Decorators.for(event)).to be_a(described_class)
  end
end
