# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Approval::Silence do
  def config_with(source)
    Dir.mktmpdir do |root|
      write_config(root, source)
      Lain::Config.load(root:)
    end
  end

  # Scenario: a silent wave gate holds each issue
  it "holds when the project leaves silence unset, naming the window nobody answered in" do
    rule = described_class.from(Lain::Config.empty)

    expect(rule.verdict(900)).to eq(Lain::Approval::Verdict::Hold.new(note: "no answer within 900s"))
  end

  # Scenario: deny is a choice
  it "denies with the word timeout when the project chooses deny" do
    rule = described_class.from(config_with("approval silence: :deny\n"))

    expect(rule.verdict(900)).to eq(Lain::Approval::Verdict::Deny.new(note: "timeout"))
  end

  it "names a long window in whole seconds" do
    expect(described_class::HOLD.verdict(1_000_000.0).note).to eq("no answer within 1000000s")
  end

  it "holds when the project says hold" do
    expect(described_class.from(config_with("approval silence: :hold\n")).verdict(0.5))
      .to eq(Lain::Approval::Verdict::Hold.new(note: "no answer within 0.5s"))
  end

  # Scenario: the prompts say what silence does
  it "says what it will do and what it did, in a prompt's words" do
    hold = described_class.from(Lain::Config.empty)
    deny = described_class.from(config_with("approval silence: :deny\n"))

    expect([hold.warning, hold.past, deny.warning, deny.past])
      .to eq(%w[postpones postponed auto-denies denied])
  end

  it "has one default, the rule a project that sets nothing gets" do
    expect(described_class::DEFAULT).to equal(described_class.from(Lain::Config.empty))
  end

  it "is the same rule however the project spells it" do
    expect(described_class.from(config_with("approval silence: :hold\n")))
      .to equal(described_class.from(Lain::Config.empty))
  end
end
