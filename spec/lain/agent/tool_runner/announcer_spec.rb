# frozen_string_literal: true

RSpec.describe Lain::Agent::ToolRunner::Announcer do
  let(:display) { [] }
  let(:ticks) { [10.0, 10.4] }
  let(:clock) { -> { ticks.shift } }
  let(:secrets) { Lain::Sensitivity::Secrets::Source::DEFAULT }
  let(:announcer) { described_class.new(display:, secrets:, clock:) }

  def tool_use(input) = Struct.new(:id, :name, :input).new("tu_1", "bash", input)

  def run_call(input, block: { "is_error" => false })
    announcer.begin(tool_use(input), nil).tap { |call| call.finish(block) }
  end

  it "announces a call's start and its end, with the seconds between" do
    run_call({ "command" => "ls" })

    expect(display.map { |event| [event.class, event.phase, event.summary, event.outcome] })
      .to eq([[Lain::Telemetry::ToolCalled, "start", "ls", nil], [Lain::Telemetry::ToolCalled, "end", "ls", "ok"]])
    expect(display.last.seconds).to be_within(0.001).of(0.4)
  end

  it "masks a credential and clips the summary with the fleet's ellipsis" do
    token = "ghp_aB3dE5gH7jK9mN1pQ3sT5vX7zA9cE1gI3kM5"

    run_call({ "command" => "#{"a" * 70} #{token}" })

    expect(display.first.summary).to eq("#{"a" * 70} <redacted:1>#{Lain::StatusFeed::Fleet::Row::ELLIPSIS}")
  end

  it "clips at the same width the fleet's rows do" do
    run_call({ "command" => "é" * 200 })

    expect(display.first.summary).to eq(Lain::StatusFeed::Fleet::Row.clamped("é" * 200))
  end

  it "closes a call once, so abandoning after finishing adds nothing" do
    call = run_call({ "command" => "ls" })
    call.abandon

    expect(display.map(&:phase)).to eq(%w[start end])
  end

  it "reports an abandoned call as interrupted" do
    announcer.begin(tool_use({ "command" => "ls" }), nil).abandon

    expect(display.last.outcome).to eq("interrupted")
  end

  it "names a failure with the masked first line of its error" do
    run_call({ "command" => "ls" }, block: { "is_error" => true, "content" => "boom\nmore" })

    expect(display.last.outcome).to eq("failed boom")
  end

  it "survives a display that raises" do
    broken = Class.new { def <<(_event) = raise("display down") }.new

    expect { described_class.new(display: broken, secrets:, clock:).begin(tool_use({}), nil) }.not_to raise_error
  end

  describe ".for" do
    it "builds a Silent announcer over a null display, which shows nothing" do
      silent = described_class.for(display: Lain::Channel::Null.new, secrets:, clock:)

      expect(silent).to be_a(described_class::Silent)
      expect(silent.begin(tool_use({}), nil).finish({})).to be_nil
    end

    it "builds a real announcer over any other display" do
      expect(described_class.for(display:, secrets:, clock:)).to be_a(described_class)
    end
  end
end
