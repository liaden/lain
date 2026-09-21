# frozen_string_literal: true

require "tmpdir"

# A backend whose lease names a checkout of its own -- the shape
# `--isolation worktree` resolves to, reduced to the one member an arm has to
# carry forward. Kept out of the RSpec block for Lint/ConstantDefinitionInBlock.
class LeasedIsolation
  # `released?` and `release` complete the Isolation::Lease duck
  # Isolation::WorkerHandoff guards on.
  Lease = Struct.new(:worker_env) do
    def release = nil
    def released? = false
  end

  def initialize(worker_env) = @worker_env = worker_env

  def acquire(_worker_id = nil) = Lease.new(@worker_env)
end

# An Arm is orchestration TOPOLOGY made swappable: single-thread control,
# orchestrator-worker, dual-ledger, adaptive-router -- each answering the same
# question ("run this task, hand back a graded trajectory") in the same shape
# (`#run -> Run`). These specs pin the SEAM itself: the base is an abstract
# contract, the Run is scored by Compare::Run.from_timeline (and nothing
# arm-specific), and the default isolation is a null that leases nothing.
RSpec.describe Lain::Arm do
  describe "the seam is a contract" do
    it "is abstract -- a bare Arm has no topology, so #run fails loudly" do
      expect { described_class.new(name: "bare").run("task", spawn_seam: -> {}, grader: nil) }
        .to raise_error(NotImplementedError, /must implement #run/)
    end

    it "names the arm it was built with" do
      expect(described_class.new(name: :control).name).to eq("control")
    end
  end

  describe Lain::Arm::Run do
    # A recorded run's usage lives in the Journal, so a Run is priced through a
    # journal-sourced Ledger -- the same construction Compare::Run.from_timeline
    # documents.
    def recorded(input:, output:, model: "claude-sonnet-4")
      timeline = Lain::Timeline.empty(store: Lain::Store.new)
                               .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
                               .commit(role: :assistant, content: [{ "type" => "text", "text" => "yo" }])
      ledger = Lain::Ledger.from_journal([{ "type" => "turn_usage", "digest" => timeline.head_digest,
                                            "model" => model, "stop_reason" => "end_turn",
                                            "usage" => { "input_tokens" => input, "output_tokens" => output } }])
      [timeline, ledger]
    end

    subject(:run) do
      timeline, ledger = recorded(input: 1000, output: 200)
      described_class.new(arm: "control", timeline:, grade:, elapsed: 0.5, ledger:)
    end

    let(:grade) { Lain::Grader::Grade.new(score: 1.0, why: "ok") }

    it "scores its Timeline through Compare::Run.from_timeline" do
      allow(Lain::Compare::Run).to receive(:from_timeline).and_call_original

      compare_run = run.compare_run

      expect(Lain::Compare::Run).to have_received(:from_timeline)
        .with(hash_including(name: "control", timeline: run.timeline, ledger: run.ledger, grade:))
      expect(compare_run).to be_a(Lain::Compare::Run)
      expect(compare_run.score).to eq(1.0)
    end

    it "exposes tokens off the recorded Timeline without needing a price" do
      expect(run.total_tokens).to eq(1200)
    end

    it "carries the grade and the wall-clock elapsed" do
      expect(run.score).to eq(1.0)
      expect(run.elapsed).to eq(0.5)
    end

    # The reachability contract, made executable (panel dist_probe). A Run prices
    # over the UNIQUE turns REACHABLE from its timeline's head -- the repo's
    # content-addressed accounting model. So a fan-out arm that returns a Run over
    # ONE worker's head, leaving other paid workers' turns on unreachable heads,
    # prices those workers at ZERO. This pins that undercount so the fan-out
    # synthesis fold (which makes every worker head reachable) is a contract,
    # not folklore.
    it "prices only the turns reachable from its timeline -- unreachable paid turns count zero" do
      store = Lain::Store.new
      worker_a = Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => "a" }])
                               .commit(role: :assistant, content: [{ "type" => "text", "text" => "A" }])
      worker_b = Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => "b" }])
                               .commit(role: :assistant, content: [{ "type" => "text", "text" => "B" }])
      # BOTH workers were paid for (240 tokens total), but the Run carries only
      # worker_a's head -- worker_b's turns are not reachable from it.
      ledger = Lain::Ledger.from_journal([worker_a, worker_b].map do |timeline|
        { "type" => "turn_usage", "digest" => timeline.head_digest, "model" => "claude-sonnet-4",
          "stop_reason" => "end_turn", "usage" => { "input_tokens" => 100, "output_tokens" => 20 } }
      end)

      run = described_class.new(arm: "fan-out", timeline: worker_a, grade:, elapsed: 0.0, ledger:)

      expect(run.total_tokens).to eq(120) # only worker_a, NOT 240
      expect(ledger.usage(worker_a, worker_b).total_tokens).to eq(240) # both, when both are reachable
    end
  end

  # The spawn_seam duck is `call(journal:, **spawn_opts) -> Agent` (panel
  # seam_probe): a spawn-time router must pass `model:` at the boundary, and
  # a fixed-arity `->(journal:) {}` would reject it. This pins that a concrete arm
  # can pass an extra spawn opt through and the seam receives it.
  describe "the spawn_seam duck carries extra spawn-time options" do
    # A toy arm standing in for a spawn-time router: it forwards a `model:` choice
    # through spawn_seam alongside the journal, exactly as a real router will.
    routing_arm = Class.new(described_class) do
      def run(task, spawn_seam:, grader:, isolation: Lain::Arm::NoIsolation)
        isolation.acquire(name)
        agent = spawn_seam.call(journal: Lain::Channel.new, model: "claude-haiku-4")
        agent.ask(task)
        Lain::Arm::Run.new(arm: name, timeline: agent.timeline, grade: grader.grade(agent.timeline),
                           elapsed: 0.0, ledger: Lain::Ledger.from_journal([]))
      end
    end

    it "lets a routing arm pass model: through to a seam that accepts the tail" do
      seen = {}
      seam = lambda do |journal:, **spawn_opts|
        seen.merge!(spawn_opts)
        Lain::Agent.new(
          provider: Lain::Provider::Mock.new(responses: [text_response("ok")]),
          toolset: Lain::Toolset.new([]),
          context: Lain::Context.new(model: "claude-opus-4-8", max_tokens: 256),
          journal:
        )
      end
      grader = Lain::Grader::Fixture.new("s") { |f| f.check("a") { |timeline| !timeline.to_a.empty? } }

      run = routing_arm.new(name: "router").run("go", spawn_seam: seam, grader:)

      expect(seen).to eq(model: "claude-haiku-4")
      expect(run).to be_a(described_class::Run)
    end
  end

  # The lease bracket lives ONCE, on the base: acquire under the arm's own name,
  # run the arm's work under the lease, reclaim on the settled path, and
  # surrender from an `ensure` whatever happened -- the sequencing every
  # concrete arm's isolation spec pins, in the one place it is written.
  describe "#leased -- the lease bracket, once" do
    # A toy arm whose body is NOTHING but the bracket, so what is pinned here is
    # the bracket rather than any topology's work.
    bracket_arm = Class.new(described_class) do
      def initialize(work:, **)
        super(**)
        @work = work
      end

      def run(_task = "t", isolation: Lain::Arm::NoIsolation, **)
        leased(isolation:) { |lease| @work.call(lease) }
      end
    end

    let(:handoff) { instance_double(Lain::Isolation::WorkerHandoff) }
    let(:lease) { Lain::Isolation::Lease.new(worker_env: Lain::WorkerEnv.default, on_release: -> {}) }
    let(:isolation) { instance_double(Lain::Isolation::Null, acquire: lease) }

    before do
      allow(handoff).to receive_messages(reclaim: Lain::Isolation::WorkerHandoff::Report.nothing,
                                         surrender: Lain::Isolation::WorkerHandoff::Report.nothing)
    end

    it "acquires under the arm's own name and yields the lease to the work" do
      seen = []
      bracket_arm.new(name: "bracketed", work: ->(acquired) { seen << acquired }, handoff:).run(isolation:)

      expect(isolation).to have_received(:acquire).with("bracketed")
      expect(seen).to eq([lease])
    end

    it "hands the block's own value back, so each arm assembles its own Run" do
      arm = bracket_arm.new(name: "bracketed", work: ->(_lease) { :the_arms_own_run }, handoff:)

      expect(arm.run(isolation:)).to eq(:the_arms_own_run)
    end

    it "reclaims on the settled path, then surrenders -- both under the arm's name" do
      bracket_arm.new(name: "bracketed", work: ->(_lease) { :done }, handoff:).run(isolation:)

      expect(handoff).to have_received(:reclaim).with(lease, worker_id: "bracketed").ordered
      expect(handoff).to have_received(:surrender).with(lease, worker_id: "bracketed").ordered
    end

    # Interrupt and Async::Cancel are `< Exception`, so no rescue sees them --
    # the `ensure` is the only thing that gets to try to anchor the work before
    # the checkout is reclaimed.
    it "surrenders and never reclaims when the work raises past every rescue" do
      arm = bracket_arm.new(name: "bracketed", work: ->(_lease) { raise Interrupt }, handoff:)

      expect { arm.run(isolation:) }.to raise_error(Interrupt)

      expect(handoff).to have_received(:surrender).with(lease, worker_id: "bracketed")
      expect(handoff).not_to have_received(:reclaim)
    end
  end

  describe "the default isolation backend leases nothing" do
    it "acquires a lease whose release is a no-op and whose worker_env is nil" do
      lease = Lain::Arm::NoIsolation.acquire("worker-1")

      expect(lease.worker_env).to be_nil
      expect(lease.release).to be_nil
    end
  end

  # EVERY ARM CARRIES ITS LEASE FORWARD, and this is the assertion that keeps
  # the next one from regressing it.
  #
  # An arm that acquires a lease and drops its environment spawns into the
  # process cwd instead of the checkout the lease cut -- so `--isolation
  # worktree` bills for a worktree, journals it, and then writes everywhere it
  # was supposed not to. Three of the four arms did exactly that: only
  # OrchestratorWorker threaded `worker_env:`, because only it had a per-worker
  # lease it could not avoid noticing.
  #
  # Asserted on the SEAM's own arguments rather than on a filesystem, so it
  # holds for an arm whose topology writes nothing.
  describe "every arm threads its lease's worker env into the spawn seam" do
    let(:worker_env) { Lain::WorkerEnv.new(cwd: Dir.pwd, env: { "LAIN_ARM" => "leased" }) }
    let(:isolation) { LeasedIsolation.new(worker_env) }
    let(:spawns) { [] }

    # A whole-file answer, so the dual-ledger arm's progress reader sees the
    # ledger move and the loop settles rather than running to its ceiling.
    let(:provider) do
      Lain::Provider::Mock.new(responses: [text_response("FILE lib/a.rb\ndone\nEND",
                                                         usage: Lain::Usage.new(input_tokens: 10,
                                                                                output_tokens: 2))])
    end

    let(:grader) do
      Lain::Grader::Fixture.new("any") { |fixture| fixture.check("ran") { |timeline| timeline.to_a.any? } }
    end

    # Records what each arm asked for and answers a real Agent, so the arms run
    # their real loops rather than a stub of one.
    def seam
      lambda do |journal:, **spawn_opts|
        spawns << spawn_opts
        Lain::Agent.new(provider:, toolset: Lain::Toolset.new([]), journal:,
                        context: Lain::Context.new(model: "m", max_tokens: 64),
                        timeline: spawn_opts[:timeline] || spawn_opts[:base_timeline])
      end
    end

    # NON-VACUITY LIVES HERE, not in an example of its own, so EVERY arm carries
    # it and a sixth one added below inherits it rather than being trusted.
    #
    # `all(...)` over an empty list passes, so an arm that regressed to spawning
    # NOTHING would sail past its own safety assertion -- the exact vacuous-pass
    # shape this bench keeps turning up. Measured: patching
    # OrchestratorWorker#fan_out to fan out zero workers left the arm's
    # `all(eq(worker_env))` example green at `1 example, 0 failures`.
    def envs_seen(arm)
      arm.run("write the file", spawn_seam: seam, grader:, isolation:)
      expect(spawns).not_to be_empty
      spawns.map { |opts| opts[:worker_env] }
    end

    it "threads it from the single-thread arm" do
      expect(envs_seen(Lain::Arm::SingleThread.new(name: "control"))).to all(eq(worker_env))
    end

    it "threads it from the adaptive-router arm" do
      router = Lain::Oracle::Router.heuristic(short_model: "m", long_model: "m", long_after_chars: 1)

      expect(envs_seen(Lain::Arm::AdaptiveRouter.new(router:))).to all(eq(worker_env))
    end

    it "threads it from the dual-ledger arm, on every step" do
      expect(envs_seen(Lain::Arm::DualLedger.new)).to all(eq(worker_env))
    end

    it "threads it from the orchestrator-worker arm" do
      expect(envs_seen(Lain::Arm::OrchestratorWorker.new)).to all(eq(worker_env))
    end
  end

  # The whole point of the pin above, through real objects: a bench arm holding
  # the production floor, spawned through the real Bench::SpawnSeam under a real
  # lease, must write into the checkout the lease cut and NOT into the tree the
  # command was run from. Bench::CLI refuses an unisolated writing toolset and
  # names `--isolation` as the fix, so this is the claim that refusal rests on.
  describe "a leased arm's writes land in the leased checkout", :seam do
    it "writes where the lease says, not where the process was started" do
      Dir.mktmpdir("lain-arm-lease") do |leased|
        Dir.mktmpdir("lain-arm-cwd") do |started_in|
          provider = Lain::Provider::Mock.new(
            responses: [tool_response(["tu_1", "write_file", { "path" => "notes.md", "content" => "leased" }]),
                        text_response("done")]
          )
          seam = Lain::Bench::SpawnSeam.new(backend: Lain::CLI::Backend.new({ provider: "anthropic",
                                                                              model: "m", max_tokens: 64 },
                                                                            root: Dir.pwd),
                                            provider:)
          grader = Lain::Grader::Fixture.new("any") { |f| f.check("ran") { |timeline| timeline.to_a.any? } }
          isolation = LeasedIsolation.new(Lain::WorkerEnv.new(cwd: leased, env: {}))

          Dir.chdir(started_in) do
            Lain::Arm::SingleThread.new(name: "control").run("write it", spawn_seam: seam, grader:, isolation:)
          end

          expect(File.exist?(File.join(leased, "notes.md"))).to be(true)
          expect(File.exist?(File.join(started_in, "notes.md"))).to be(false)
        end
      end
    end
  end
end
