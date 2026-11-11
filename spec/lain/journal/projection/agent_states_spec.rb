# frozen_string_literal: true

RSpec.describe Lain::Journal::Projection::AgentStates do
  telemetry = Lain::Telemetry
  main = Lain::AgentStates::MAIN
  child = "blake3:#{"c" * 64}"
  other = "blake3:#{"d" * 64}"
  digest = ->(letter) { "blake3:#{letter * 64}" }

  spawn_of = lambda do |id|
    telemetry::Message.new(digest: id, kind: :spawn, from: "main", to: "reviewer",
                           payload: { "role" => "reviewer", "lifecycle" => "launched" },
                           causal_parents: [], correlation: nil)
  end
  completion = lambda do |id, lifecycle|
    telemetry::Message.new(digest: digest.call("9"), kind: :message, from: "reviewer", to: "main",
                           payload: { "lifecycle" => lifecycle }, causal_parents: [id], correlation: nil)
  end
  progress = ->(id) { telemetry::ChildProgress.new(spawn: id, turns: 1) }
  request = lambda do |requester = nil|
    telemetry::RequestSent.new(digest: digest.call("e"), payload: {}, stream: true, extra: {},
                               prefix_digests: nil, prefix_chain_version: nil, requester:)
  end
  settled = telemetry::AskSettled.new(head: digest.call("f"), stop_reason: "end_turn", turns: 1, seconds: 1.0)
  interrupted = telemetry::RunInterrupted.new(head: nil, reason: :interrupted)
  wait_of = lambda do |id, spawn, summary: "bash"|
    telemetry::AwaitingHuman.new(kind: "approval", ref: id, summary:, requester: "reviewer", tool: "bash",
                                 tool_use_id: id, spawn:)
  end
  states = ->(*records) { described_class.over(records).agents.to_h { [_1.id, _1.state] } }

  it "starts with main idle" do
    expect(described_class.unit.agents.map(&:to_h)).to eq([{ id: main, state: :idle, what: nil }])
  end

  it "blocks the child a wait names and not main" do
    fold = described_class.over([spawn_of.call(child), wait_of.call("call_c1", child, summary: "rm -rf build")])

    expect([fold.agents.map(&:to_h), fold.rollup]).to eq(
      [[{ id: main, state: :idle, what: nil }, { id: child, state: :blocked, what: "rm -rf build" }], :blocked]
    )
  end

  it "takes main from working to done to idle on the human's sight" do
    seen = Lain::AgentStates::Seen.new(agent: main)

    trail = [request.call, settled, seen]

    expect(trail.each_index.map { |at| states.call(*trail.first(at + 1))[main] })
      .to eq(%i[working done idle])
  end

  it "does not make main working for the judge or the summarizer" do
    expect(states.call(request.call("judge"), request.call("summarizer"))).to eq(main => :idle)
  end

  it "makes a child done on its terminal completion" do
    expect(states.call(spawn_of.call(child), progress.call(child),
                       completion.call(child, "stopped"))[child]).to eq(:done)
  end

  it "keeps a child working on a settled reply" do
    expect(states.call(spawn_of.call(child), completion.call(child, "settled"))[child]).to eq(:working)
  end

  it "names a finished child by its spawn's role, and no agent before or besides that" do
    working = described_class.over([spawn_of.call(child)])
    finished = described_class.over([spawn_of.call(child), completion.call(child, "stopped"), request.call, settled])

    expect([working, finished].map { |fold| fold.agents.map(&:what) }).to eq([[nil, nil], [nil, "reviewer"]])
  end

  it "reads a spawn whose payload is nil as a child with no role" do
    bare = telemetry::Message.new(digest: child, kind: :spawn, from: "main", to: nil, payload: nil,
                                  causal_parents: [], correlation: nil)
    fold = described_class.over([bare, completion.call(child, "stopped")])

    expect(fold.agents.map(&:to_h)).to include({ id: child, state: :done, what: nil })
  end

  it "rolls up blocked over working and done" do
    fold = described_class.over([request.call, spawn_of.call(child), completion.call(child, "stopped"),
                                 spawn_of.call(other), wait_of.call("call_d1", other)])

    expect(fold.rollup).to eq(:blocked)
  end

  it "rolls up working over done and done over idle" do
    expect([states.call, described_class.over([spawn_of.call(child), completion.call(child, "stopped")]).rollup,
            described_class.over([spawn_of.call(child), completion.call(child, "stopped"), request.call]).rollup])
      .to eq([{ main => :idle }, :done, :working])
  end

  it "leaves main idle when the last record is an interrupt read back from a file" do
    line = JSON.parse(JSON.generate(interrupted.to_journal))
    untyped = telemetry.read(line, strict: false)

    expect(states.call(request.call, untyped)).to eq(main => :idle)
  end

  it "leaves a done child done when its spawn repeats" do
    expect(states.call(spawn_of.call(child), completion.call(child, "stopped"), spawn_of.call(child))[child])
      .to eq(:done)
  end

  it "keeps a child done when progress arrives after its completion" do
    expect(states.call(spawn_of.call(child), completion.call(child, "stopped"), progress.call(child))[child])
      .to eq(:done)
  end

  it "makes a child done on a completion with a result and no lifecycle, as older sessions wrote it" do
    bare = telemetry::Message.new(digest: digest.call("8"), kind: :message, from: "reviewer", to: "main",
                                  payload: { "result" => "ok" }, causal_parents: [child], correlation: nil)

    expect(states.call(spawn_of.call(child), bare)[child]).to eq(:done)
  end

  it "ends working on an interrupt" do
    expect(states.call(request.call, interrupted)).to eq(main => :idle)
  end

  it "unblocks an agent whose wait is decided" do
    decided = Lain::Approval::Parked::Queue::Pending.new(
      effect: Lain::Effect::ToolCall.new(tool_use_id: "call_c1", name: "bash", input: {}),
      identity: Lain::Requester.main, clock: -> { 0.0 }
    )

    expect(states.call(spawn_of.call(child), wait_of.call("call_c1", child), decided)[child]).to eq(:working)
  end

  it "clears one done agent on Seen and every done agent on a nil Seen" do
    done = [spawn_of.call(child), completion.call(child, "stopped"), spawn_of.call(other),
            completion.call(other, "failed")]
    one = described_class.over([*done, Lain::AgentStates::Seen.new(agent: child)])
    every = described_class.over([*done, Lain::AgentStates::Seen.new(agent: nil)])

    expect([one.done_unseen.map(&:id), every.done_unseen, described_class.over(done).done_unseen.map(&:id)])
      .to eq([[other], [], [child, other]])
  end

  describe "read back from a file" do
    t2 = File.join(__dir__, "../../../fixtures/waits/closing_records.ndjson")
    fixture = File.join(__dir__, "../../../fixtures/waits/agent_states.ndjson")
    read = lambda do |path|
      File.readlines(path).map { |line| telemetry.read(JSON.parse(line), strict: false) }
    end

    it "reads the child's completion as a Telemetry::Message" do
      expect(read.call(fixture).grep(telemetry::Message).map(&:kind)).to eq(%i[spawn message])
    end

    it "folds the same states as the live objects" do
      live = [spawn_of.call(child), progress.call(child), wait_of.call("call_c1", child),
              Lain::Approval::Parked::Queue::Pending.new(
                effect: Lain::Effect::ToolCall.new(tool_use_id: "call_c1", name: "bash", input: {}),
                identity: Lain::Requester.main, clock: -> { 0.0 }
              ),
              completion.call(child, "stopped"), request.call, interrupted, request.call, settled]

      expect(described_class.over([*read.call(t2), *read.call(fixture)]).agents)
        .to eq(described_class.over([*read.call(t2), *live]).agents)
    end

    it "ends with main and the child done" do
      expect(described_class.over([*read.call(t2), *read.call(fixture)]).agents.map(&:state)).to eq(%i[done done])
    end
  end

  describe "the laws" do
    include_examples "an incremental fold", projection: described_class,
                                            population: -> { [[spawn_of.call(child), request.call, settled]] }
  end
end
