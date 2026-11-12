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

  describe "what the model is told of a call that waits for a human" do
    def parked(silence)
      effect = Lain::Effect::ToolCall.new(name: "bash", input: { "command" => "make deploy" }, tool_use_id: "tu_1")
      Lain::Approval::Parked::Queue::Pending.new(effect:, identity: Lain::Requester.main, clock: -> { 0.0 },
                                                 timeout: 125, silence:)
    end

    let(:waits) do
      "the call waits for a human, so do not send it again: " \
        "do other work, or tell the user you are waiting for their answer"
    end

    # Scenario: a postponed call does not invite a retry
    it "says a human postponed it, in their words, and not to send it again" do
      pending = parked(described_class::HOLD)
      pending.decide(Lain::Approval::Verdict::Hold.new(note: "after lunch"), surface: "tty", authority: :human)

      expect(described_class::HOLD.told(pending)).to eq("postponed by the human: after lunch; #{waits}")
    end

    it "says a call nobody answered was postponed for want of an answer" do
      pending = parked(described_class::HOLD).tap(&:lapsed)

      expect(described_class::HOLD.told(pending)).to eq("postponed after 2:05 with no answer; #{waits}")
    end

    # Scenario: a timed-out deny is final and liftable
    it "says a silence deny in the same words" do
      pending = parked(described_class::DENY).tap(&:lapsed)

      expect(described_class::DENY.told(pending)).to eq("denied after 2:05 with no answer; #{waits}")
    end
  end

  it "has one default, the rule a project that sets nothing gets" do
    expect(described_class::DEFAULT).to equal(described_class.from(Lain::Config.empty))
  end

  it "is the same rule however the project spells it" do
    expect(described_class.from(config_with("approval silence: :hold\n")))
      .to equal(described_class.from(Lain::Config.empty))
  end
end
