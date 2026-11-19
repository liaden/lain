# frozen_string_literal: true

require "async"

RSpec.describe Lain::AgentStates::Notices do
  telemetry = Lain::Telemetry
  digest = ->(letter) { "blake3:#{letter * 64}" }
  request = telemetry::RequestSent.new(digest: digest.call("e"), payload: {}, stream: true, extra: {},
                                       prefix_digests: nil, prefix_chain_version: nil, requester: nil)
  settled = telemetry::AskSettled.new(head: digest.call("f"), stop_reason: "end_turn", turns: 1, seconds: 1.0)

  let(:now) { [1000.0] }
  let(:clock) { class_double(Time).tap { |c| allow(c).to receive(:now) { now.first } } }
  let(:sent) { [] }
  let(:notifier) do
    log = sent
    Object.new.tap { |n| n.define_singleton_method(:notify) { |note| log << note } }
  end
  let(:layers) { Lain::Mode::LayerSet.new }
  let(:probes) { [] }
  let(:answer) { [false] }
  let(:window) do
    asked = probes
    reply = answer
    Object.new.tap do |f|
      f.define_singleton_method(:focused?) do
        asked << :asked
        reply.first
      end
    end
  end
  let(:run_clock) { instance_double(Lain::RunClock, elapsed: 0.0) }
  let(:tracker) { Lain::AgentStates::Tracker.new(clock: run_clock) }

  def notices(delay: 30, poll: 1)
    described_class.new(tracker:, notifier:, focus: window, delay:, layers: -> { layers }, clock:, poll:)
  end

  def change(tracker, agent)
    tracker.send(:tell, Lain::AgentStates::Tracker::Change.new(rollup: agent.state, agent:, since: 0.0))
  end

  def blocked(id = "main", what = "approve bash")
    Lain::Journal::Projection::AgentStates::Agent.new(id:, state: :blocked, what:)
  end

  def done(id = "main") = Lain::Journal::Projection::AgentStates::Agent.new(id:, state: :done, what: nil)

  def working(id = "main") = Lain::Journal::Projection::AgentStates::Agent.new(id:, state: :working, what: nil)

  def failed(why, id = "main")
    Lain::Journal::Projection::AgentStates::Agent.new(id:, state: :done, what: nil, failure: why)
  end

  it "says a failed ask failed, and why, where a finished one says done" do
    subject = notices
    change(tracker, failed("max_tokens"))
    now[0] += 31
    subject.tick

    expect(sent).to eq(["failed: main (max_tokens)"])
  end

  it "notifies once about a wait that outlasts the delay" do
    subject = notices
    change(tracker, blocked)
    now[0] += 31
    2.times { subject.tick }

    expect(sent).to eq(["blocked: approve bash"])
  end

  it "names the parked command, masked, in the notice a journaled approval produces" do
    pending = Lain::Approval::Parked::Queue::Pending.new(
      effect: Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash",
                                         input: { "command" => "cargo test --release" }),
      identity: Lain::Requester.new(name: "main"), clock: -> { 0.0 }
    )
    subject = notices
    tracker << request << telemetry::AwaitingHuman.approval(pending)
    now[0] += 31
    subject.tick

    expect(sent).to eq(["blocked: bash cargo test --release"])
  end

  it "says nothing about a wait settled within the delay, and never probes focus" do
    subject = notices
    change(tracker, blocked)
    now[0] += 10
    change(tracker, working)
    now[0] += 40
    subject.tick

    expect([sent, probes]).to eq([[], []])
  end

  it "does not probe focus while no notice is due" do
    subject = notices
    change(tracker, blocked)
    now[0] += 5
    3.times { subject.tick }

    expect(probes).to be_empty
  end

  it "notifies about a finished agent after the delay" do
    subject = notices
    change(tracker, done("child-c"))
    now[0] += 31
    subject.tick

    expect(sent).to eq(["done: child-c"])
  end

  it "marks a finished agent seen, and sends nothing, when the human is at the window" do
    answer[0] = true
    subject = notices
    tracker << request << settled
    now[0] += 31
    subject.tick

    expect([sent, tracker.projection.agents.map(&:state)]).to eq([[], [:idle]])
  end

  it "sends nothing while the quiet layer is up" do
    quiet = Lain::Mode::LayerSet.new.enable(:quiet)
    subject = described_class.new(tracker:, notifier:, focus: window, delay: 30, layers: -> { quiet }, clock:)
    change(tracker, blocked)
    now[0] += 31
    subject.tick

    expect(sent).to be_empty
  end

  it "spawns a fiber that ticks until stopped" do
    subject = notices(delay: 0, poll: 0.01)
    change(tracker, blocked)
    Sync do |task|
      fiber = subject.spawn(task)
      task.sleep(0.05)
      fiber.stop
      expect(sent).to eq(["blocked: approve bash"])
      expect(fiber).not_to be_running
    end
  end
end
