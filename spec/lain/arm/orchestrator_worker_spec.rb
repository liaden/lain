# frozen_string_literal: true

# A fake isolation backend for AC2: it leases a distinct WorkerEnv (its own cwd)
# per worker and records every acquire/release, standing in for the real
# Isolation unit (a sibling card) over B1's WorkerEnv.
class FakeWorkerIsolation
  Lease = Struct.new(:worker_env, :log) do
    def release = log << worker_env
  end

  attr_reader :acquired, :released

  def initialize
    @acquired = []
    @released = []
  end

  def acquire(worker_id)
    @acquired << worker_id
    Lease.new(Lain::WorkerEnv.new(cwd: "/tmp/#{worker_id}", env: {}), @released)
  end
end

# The orchestrator-worker arm: a lead decomposes a task into N independent
# subtasks, fans workers out over ONE shared Store, then a synthesis turn folds
# their results into a single multi-parent causal Event (the FIRST one written
# through any arm). Driven over Provider::Mock so it spends no tokens.
RSpec.describe Lain::Arm::OrchestratorWorker do
  # A FRESH worker Agent per spawn (Provider::Mock is stateful), built over the
  # `base_timeline` the arm roots in the SHARED Store and journaling into the
  # recording channel the arm injects so each worker's spend can be priced. It
  # accepts the widened spawn_seam tail (`base_timeline:`, `worker_env:`,
  # `spawned_from:`) the arm passes, per the B7 duck `call(journal:, **opts)`.
  def worker_seam(tokens: 40, on_call: ->(*) {})
    lambda do |journal:, base_timeline:, worker_env: nil, spawned_from: nil, **|
      agent = worker_agent(base_timeline:, journal:, tokens:, worker_env:)
      on_call.call(worker_env:, spawned_from:, session: agent.session)
      agent
    end
  end

  # The seam wires the leased WorkerEnv onto the worker's Session (sent-not-stored),
  # so the worker's tools resolve under the lease. A nil env (the NoIsolation
  # default) means "the shared process environment", so Session falls back to
  # WorkerEnv.default -- the byte-identical no-isolation path.
  def worker_agent(base_timeline:, journal:, tokens:, worker_env: nil)
    session = worker_env ? Lain::Session.new(worker_env:) : Lain::Session.new
    Lain::Agent.new(
      provider: Lain::Provider::Mock.new(
        responses: [text_response("worker-done", model: "claude-sonnet-4",
                                                 usage: Lain::Usage.new(input_tokens: tokens, output_tokens: 0))]
      ),
      toolset: Lain::Toolset.new([]),
      context: Lain::Context.new(model: "claude-opus-4-8", max_tokens: 256),
      timeline: base_timeline, journal:, session:
    )
  end

  # Grades the synthesized Timeline: a deterministic Fixture, no model in the loop.
  let(:grader) do
    Lain::Grader::Fixture.new("synthesized") do |f|
      f.check("the lead committed a synthesis turn folding the workers") do |timeline|
        timeline.head.role == "assistant" && !timeline.head.causal_parents.empty?
      end
    end
  end

  # Three independent subtasks, one per line.
  let(:task) { "subtask one\nsubtask two\nsubtask three" }

  describe "#run — fan out, then synthesize" do
    subject(:run) { described_class.new.run(task, spawn_seam: worker_seam, grader:) }

    it "returns an Arm::Run over a lead user -> synthesis assistant Timeline" do
      expect(run).to be_a(Lain::Arm::Run)
      expect(run.timeline.to_a.map(&:role)).to eq(%w[user assistant])
    end

    it "writes ONE synthesis event naming the N worker result turns as causal parents" do
      expect(run.timeline.head.causal_parents.size).to eq(3)
    end

    it "grades the synthesized Timeline with the injected grader" do
      expect(run.grade).to be_a(Lain::Grader::Grade)
      expect(run.grade).to be_pass
    end

    it "records a non-negative wall-clock elapsed" do
      expect(run.elapsed).to be_a(Float).and be >= 0
    end

    # The reachability contract (arm.rb): the returned head must price EVERY
    # worker the arm paid for. Three workers at 40 tokens each -> 120, not the
    # single-worker undercount a naive fan-out would report.
    it "prices ALL workers' tokens through the returned head" do
      expect(run.total_tokens).to eq(120)
      expect(run.compare_run.total_tokens).to eq(120)
    end
  end

  # AC2: each worker's tools operate under its OWN leased WorkerEnv. The arm
  # leases per worker, threads `lease.worker_env` through the spawn_seam tail, and
  # the seam wires it onto the worker's Session -- so worker tools resolve paths
  # and shell out under the lease, not the shared process environment.
  describe "the injected isolation backend leases per worker" do
    let(:backend) { FakeWorkerIsolation.new }

    it "acquires a distinct lease per worker and releases each" do
      described_class.new(name: "ow").run(task, spawn_seam: worker_seam, grader:, isolation: backend)

      expect(backend.acquired).to contain_exactly("ow-worker-0", "ow-worker-1", "ow-worker-2")
      expect(backend.released.size).to eq(3)
    end

    it "wires each worker's leased WorkerEnv onto its session so tools resolve under the lease" do
      sessions = []
      seam = worker_seam(on_call: ->(session:, **) { sessions << session })

      described_class.new(name: "ow").run(task, spawn_seam: seam, grader:, isolation: backend)

      expect(sessions.map { |session| session.worker_env.cwd })
        .to contain_exactly("/tmp/ow-worker-0", "/tmp/ow-worker-1", "/tmp/ow-worker-2")
    end
  end

  # Escalation trigger: a worker's failure must NOT silently vanish -- it is a
  # named input the synthesis sees, and the Run still comes back.
  describe "a worker failure is a named input, not an omission" do
    it "folds the failing worker's error into the synthesis and still returns a Run" do
      boom = ->(*) { raise "worker exploded" }
      seam = lambda do |journal:, base_timeline:, **|
        Lain::Agent.new(provider: Lain::Provider::Mock.new(responses: []),
                        toolset: Lain::Toolset.new([]),
                        context: Lain::Context.new(model: "claude-opus-4-8", max_tokens: 256),
                        timeline: base_timeline, journal:).tap { boom.call }
      end

      run = described_class.new.run("only one subtask", spawn_seam: seam, grader:)

      expect(run).to be_a(Lain::Arm::Run)
      expect(run.timeline.head.content.first["text"]).to include("worker exploded")
    end
  end
end
