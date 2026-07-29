# frozen_string_literal: true

# A fake isolation backend for AC2: it leases a distinct WorkerEnv (its own cwd)
# per worker and records every acquire/release, standing in for the real
# Isolation unit (a sibling card) over B1's WorkerEnv.
class FakeWorkerIsolation
  attr_reader :acquired, :released

  def initialize
    @acquired = []
    @released = []
  end

  # The REAL {Isolation::Lease}, not a Struct standing in for one: the arm now
  # both hands a worker back (which releases) and keeps its own `ensure
  # lease&.release`, so the idempotent-loud contract -- the reclaim runs exactly
  # once however many times release is called -- is load-bearing here.
  def acquire(worker_id)
    @acquired << worker_id
    env = Lain::WorkerEnv.new(cwd: "/tmp/#{worker_id}", env: {})
    Lain::Isolation::Lease.new(worker_env: env, on_release: -> { @released << env })
  end
end

# The worker-completion seam's duck, recording what it was handed and answering
# a canned {Isolation::WorkerHandoff::Report}. It records whether the lease was
# STILL LIVE when it was called -- the whole point of the seam is that the
# handback happens before the checkout is reclaimed -- and, like the real one,
# no-ops on an already-released lease so the arm's `ensure` costs a boolean.
class RecordingHandoff
  Call = Struct.new(:kind, :worker_id, :lease, :live)

  attr_reader :calls

  def initialize(report)
    @report = report
    @calls = []
  end

  def reclaim(lease, worker_id:) = record(:reclaim, lease, worker_id)
  def surrender(lease, worker_id:) = record(:surrender, lease, worker_id)

  def reclaims = calls.select { |call| call.kind == :reclaim }
  def surrenders = calls.select { |call| call.kind == :surrender }

  private

  def record(kind, lease, worker_id)
    return Lain::Isolation::WorkerHandoff::Report.nothing if lease.nil? || lease.released?

    @calls << Call.new(kind, worker_id, lease, !lease.released?)
    lease.release
    @report
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

    # T24: the fan-out is timed by the SAME injected instrument every other arm
    # measures with, and its return pair carries the workers' results back --
    # so the fan-out's value needs no mutable capture to escape the clock.
    it "takes elapsed off the injected instrument's clock, over the fan-out" do
      ticks = 0.0
      arm = described_class.new(instrument: Lain::Arm::Instrument.new(clock: -> { ticks += 0.25 }))

      expect(arm.run(task, spawn_seam: worker_seam, grader:).elapsed).to eq(0.25)
    end

    # Every worker's spend is priced through the instrument's OWN price book --
    # the fan-out folds three journals, and all three take that one rate.
    it "prices every worker through the instrument's price book" do
      # Nothing in the map, so every model falls to a free fallback: what is
      # pinned is WHOSE book priced the run, not the rate.
      zero = Lain::Price.per_mtok(input: 0, output: 0, cache_creation: 0, cache_read: 0)
      free = Lain::PriceBook.new(prices: {}, fallback: zero)
      arm = described_class.new(instrument: Lain::Arm::Instrument.new(price_book: free))

      priced = arm.run(task, spawn_seam: worker_seam, grader:)

      expect(priced.total_tokens).to eq(120)
      expect(priced.compare_run.cost).to eq(0)
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

  # D5: the worker-completion point. The arm hands each finished worker back
  # while its lease is still live, and folds what that did into the worker's own
  # result -- the resolver's conflict transcript stays in the child's fresh root.
  describe "a finished worker is handed back before its lease is released" do
    subject(:arm) { described_class.new(name: "ow", handoff:) }

    let(:backend) { FakeWorkerIsolation.new }
    let(:report) do
      Lain::Isolation::WorkerHandoff::Report.new(
        kind: :resolved, ref: "refs/lain/worker/ow-worker-0-c0ffee", paths: %w[alpha.txt beta.txt]
      )
    end
    let(:handoff) { RecordingHandoff.new(report) }
    let(:silent_report) { Lain::Isolation::WorkerHandoff::Report.nothing }

    def synthesis_text(run) = run.timeline.head.content.first["text"]

    it "reclaims once per worker, under the worker_id its lease was acquired with" do
      arm.run(task, spawn_seam: worker_seam, grader:, isolation: backend)

      expect(handoff.reclaims.map(&:worker_id))
        .to contain_exactly("ow-worker-0", "ow-worker-1", "ow-worker-2")
      expect(handoff.reclaims.map(&:lease)).to all(be_a(Lain::Isolation::Lease))
    end

    it "hands back while the lease is still LIVE, never after the checkout is reclaimed" do
      arm.run(task, spawn_seam: worker_seam, grader:, isolation: backend)

      expect(handoff.calls.map(&:live)).to all(be(true))
      expect(handoff.surrenders).to be_empty
    end

    it "releases each lease exactly once despite the arm's own ensure" do
      arm.run(task, spawn_seam: worker_seam, grader:, isolation: backend)

      expect(backend.released.size).to eq(3)
    end

    it "folds what the handoff did into the synthesis, naming the files and the ref" do
      text = synthesis_text(arm.run(task, spawn_seam: worker_seam, grader:, isolation: backend))

      expect(text).to include("alpha.txt").and include("beta.txt")
      expect(text).to include("refs/lain/worker/ow-worker-0-c0ffee")
      expect(text).to include("worker-done")
    end

    it "gains the resolver's result only -- never the conflict transcript" do
      text = synthesis_text(arm.run(task, spawn_seam: worker_seam, grader:, isolation: backend))

      expect(text).not_to include("<<<<<<<")
      expect(text).not_to include(">>>>>>>")
    end

    it "leaves the worker's result byte-identical when the handoff has nothing to say" do
      quiet = described_class.new(name: "ow", handoff: RecordingHandoff.new(silent_report))
      unwired = described_class.new(name: "ow")

      expect(synthesis_text(quiet.run(task, spawn_seam: worker_seam, grader:, isolation: backend)))
        .to eq(synthesis_text(unwired.run(task, spawn_seam: worker_seam, grader:, isolation: backend)))
    end

    it "carries a failed worker's handoff report on its error, where the synthesis renders it" do
      seam = ->(*, **) { raise "worker exploded" }

      run = arm.run("one subtask", spawn_seam: seam, grader:, isolation: backend)

      expect(synthesis_text(run)).to include("worker exploded").and include("alpha.txt")
    end

    it "still releases every lease with no handoff wired (the Null default)" do
      described_class.new(name: "ow").run(task, spawn_seam: worker_seam, grader:, isolation: backend)

      expect(backend.released.size).to eq(3)
    end

    # `#settle` catches only StandardError, and this arm's fan-out is
    # `Sync { ...map { Async { work } }.map(&:wait) }` -- a sibling's failure
    # cancels the rest with Async::Cancel, which is `< Exception` and reaches no
    # rescue. Releasing a `--detach`ed worktree destroys unanchored commits, so
    # no path may release without FIRST trying to anchor -- the attempt is what
    # cannot be skipped by an exception class (WorkerHandoff's class doc names
    # the one case the attempt itself cannot cover).
    it "surrenders the lease -- trying to anchor the work -- when an Interrupt takes the worker out" do
      seam = ->(*, **) { raise Interrupt }

      expect { arm.run("one subtask", spawn_seam: seam, grader:, isolation: backend) }.to raise_error(Interrupt)

      expect(handoff.surrenders.map(&:worker_id)).to eq(["ow-worker-0"])
      expect(handoff.surrenders.map(&:live)).to all(be(true))
      expect(handoff.reclaims).to be_empty
      expect(backend.released.size).to eq(1)
    end

    # DISCOVERED while pinning the cancel path, and reported rather than papered
    # over: Async::Cancel STOPS a task rather than failing it, so `Async{...}.wait`
    # answers nil and the Synthesis fold NoMethodErrors on the missing result.
    # That is a pre-existing fan-out fragility, not this seam's -- what belongs
    # here is that the `ensure` still surrendered the lease while it was live, so
    # the handback was attempted before the checkout was reclaimed.
    it "still surrenders the lease when an Async::Cancel stops the worker" do
      seam = ->(*, **) { raise Async::Cancel }

      expect { arm.run("one subtask", spawn_seam: seam, grader:, isolation: backend) }
        .to raise_error(NoMethodError, /rendered/)

      expect(handoff.surrenders.map(&:worker_id)).to eq(["ow-worker-0"])
      expect(handoff.surrenders.map(&:live)).to all(be(true))
      expect(backend.released.size).to eq(1)
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
