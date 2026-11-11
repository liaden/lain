# frozen_string_literal: true

RSpec.describe Lain::AgentStates::Tracker do
  telemetry = Lain::Telemetry
  main = Lain::AgentStates::MAIN
  child = "blake3:#{"c" * 64}"
  digest = ->(letter) { "blake3:#{letter * 64}" }

  request = lambda do
    telemetry::RequestSent.new(digest: digest.call("e"), payload: {}, stream: true, extra: {},
                               prefix_digests: nil, prefix_chain_version: nil, requester: nil)
  end
  settled = telemetry::AskSettled.new(head: digest.call("f"), stop_reason: "end_turn", turns: 1, seconds: 1.0)
  spawn_of = lambda do |id|
    telemetry::Message.new(digest: id, kind: :spawn, from: "main", to: "reviewer",
                           payload: { "role" => "reviewer", "lifecycle" => "launched" },
                           causal_parents: [], correlation: nil)
  end

  let(:now) { [0.0] }
  let(:clock) { instance_double(Lain::RunClock).tap { |double| allow(double).to receive(:elapsed) { now.first } } }
  let(:tracker) { described_class.new(clock:) }

  it "starts with main idle" do
    expect(tracker.projection.rollup).to eq(:idle)
  end

  it "tells an observer each change once, with the rollup, the changed agent and the clock's time" do
    heard = []
    tracker.on_change { heard << _1 }

    now[0] = 4.0
    tracker << request.call
    tracker << request.call
    now[0] = 9.0
    tracker << settled

    expect(heard).to eq([
                          described_class::Change.new(
                            rollup: :working,
                            agent: Lain::Journal::Projection::AgentStates::Agent.new(id: main, state: :working,
                                                                                     what: nil),
                            since: 4.0
                          ),
                          described_class::Change.new(
                            rollup: :done,
                            agent: Lain::Journal::Projection::AgentStates::Agent.new(id: main, state: :done,
                                                                                     what: nil),
                            since: 9.0
                          )
                        ])
  end

  it "steps the human's sight as a change of its own" do
    heard = []
    tracker << request.call << settled
    tracker.on_change { heard << _1.agent.state }

    tracker.seen(main)

    expect([heard, tracker.projection.rollup]).to eq([[:idle], :idle])
  end

  it "reports a spawned agent's change under that agent" do
    heard = []
    tracker.on_change { heard << [_1.agent.id, _1.agent.state] }

    tracker << spawn_of.call(child)

    expect(heard).to eq([[child, :working]])
  end

  it "lets every later observer hear every change when an earlier one raises" do
    heard = []
    tracker.on_change { raise "an observer's fault" }
    tracker.on_change { heard << [_1.agent.id, _1.agent.state] }

    tracker << spawn_of.call(child) << request.call

    expect(heard).to eq([[child, :working], [main, :working]])
  end

  it "ignores a record it does not know, and never raises" do
    tracker.on_change { raise "an observer's fault" }

    expect { tracker << Object.new << nil << request.call }.not_to raise_error
  end

  it "answers itself from <<, so it chains" do
    expect(tracker << request.call).to be(tracker)
  end
end
