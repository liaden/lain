# frozen_string_literal: true

# B2 (chunk-bench-arms-subcommand): the assembling entry point `bench arms` will
# sit on. It takes PLAIN VALUES -- a fixture path, the provider flags, an
# optional isolation NAME -- assembles the arms, the ArmTasks suite, that
# suite's per-task gold grader and the live SpawnSeam, and hands all four to
# #arm_report, returning the report String. exe/lain therefore stays a flag
# parser (its boundary rule at exe/lain:80-85).
#
# Every example here is driven through Provider::Mock: this entry point spends
# real money in production, so its specs must never resolve a live provider.
RSpec.describe Lain::Bench::CLI do
  subject(:cli) { described_class.new }

  def fixture_path = File.join(__dir__, "..", "..", "fixtures", "arms", "tasks.yml")

  # Satisfies exactly ONE task's gold (rename-method-and-callsite: `def
  # normalize` in lib/widget.rb, `normalize(` in app/main.rb) and no other's, so
  # a score column that is all-1.000 or all-0.000 exposes a blanket grader
  # standing in for ArmTasks' per-task Grader::Fixtures.
  let(:answer) do
    "FILE lib/widget.rb\ndef normalize\nEND\nFILE app/main.rb\nnormalize(value)\nEND"
  end

  let(:provider) do
    Lain::Provider::Mock.new(
      responses: [text_response(answer, model: "claude-sonnet-4",
                                        usage: Lain::Usage.new(input_tokens: 80, output_tokens: 20))]
    )
  end

  # What Arm::Driver was actually CONSTRUCTED with. The unset-vs-"none"
  # distinction is a KEYWORD-presence fact, not a value fact -- `isolation: nil`
  # would put the key here while an unset name must not -- so nothing short of
  # the real kwargs hash can tell the two apart.
  let(:driver_kwargs) { [] }
  let(:driver_args) { [] }
  let(:drivers) { [] }

  before do
    allow(Lain::Arm::Driver).to receive(:new).and_wrap_original do |original, *args, **kwargs|
      driver_args << args
      driver_kwargs << kwargs
      original.call(*args, **kwargs).tap { |driver| drivers << driver }
    end
  end

  def arms_report(**) = cli.arms_report(fixture_path:, provider:, **)

  # The Driver renders one titled table per metric, blank-line separated.
  def score_section(report) = report.split("\n\n").find { |section| section.start_with?("grader score") }

  # The isolation backend the Driver is holding. No reader exposes it (the
  # Driver's whole surface is #report), and "which backend reached the arms" is
  # exactly what this card must pin -- so it is read off the object, the way
  # cli_spec and cache_breakpoints_spec read collaborators they cannot ask for.
  def driver_isolation = drivers.last.instance_variable_get(:@isolation)

  # The arms that actually reached the Driver -- its one positional argument.
  def built_arms = driver_args.last.first

  def orchestrator_decompose
    built_arms.find { |arm| arm.name == "orchestrator-worker" }.instance_variable_get(:@decompose)
  end

  describe "#arms_report" do
    # Scenario: the report is returned, never printed.
    it "returns the driver's report as a String, writing nothing to stdout or stderr" do
      report = nil
      expect { report = arms_report }.to output("").to_stdout.and output("").to_stderr
      expect(report).to be_a(String)
    end

    # Not just "a String": the three arms of the reuse target (arm_sweep.rb:130-141)
    # over EVERY task the fixture declares. The Driver's header states both counts,
    # so a suite silently truncated to the two tasks Driver demands, or an arm
    # quietly dropped, fails here.
    it "compares all three arms over the whole committed suite" do
      expect(arms_report).to include("3 arms over 8 tasks")
        .and include("single-thread").and include("orchestrator-worker").and include("dual-ledger")
    end

    # ArmTasks carries a gold Grader::Fixture PER TASK while the Driver threads
    # ONE grader through every run, so the assembly has to dispatch. The scripted
    # answer satisfies one task's gold and no other's: a single blanket grader
    # would score every task alike and could not produce both numbers.
    it "grades each task against ITS OWN gold rather than one blanket grader" do
      expect(score_section(arms_report)).to include("1.000").and include("0.000")
    end

    # Scenario: an unset isolation name passes no keyword at all.
    #
    # `isolation: nil` also satisfies "the driver's default applied" -- Driver
    # would raise NoMethodError on nil.acquire, so a passing run alone proves
    # nothing about the keyword. The key's ABSENCE is the claim.
    it "passes NO isolation keyword at all when no name is given" do
      arms_report

      expect(driver_kwargs.last).not_to have_key(:isolation)
    end

    it "leaves Arm::Driver's own default in place when no name is given" do
      arms_report

      expect(driver_isolation).to be(Lain::Arm::NoIsolation)
      expect(driver_isolation.acquire("single-thread").worker_env).to be_nil
    end

    # Scenario: an explicit "none" is passed through as a resolved backend.
    #
    # `none` is NOT the unset case: it resolves a real backend whose lease
    # carries a WorkerEnv, where Arm::NoIsolation's carries nothing at all.
    it "resolves a real backend for an explicit none, distinct from the unset case" do
      arms_report(isolation: "none", journal: Lain::Channel.new)

      expect(driver_kwargs.last).to have_key(:isolation)
      expect(driver_isolation).not_to be(Lain::Arm::NoIsolation)
      expect(driver_isolation.acquire("single-thread").worker_env).to be_a(Lain::WorkerEnv)
    end

    # A resolved backend with no journal emits no Telemetry::IsolationLease at
    # all (IsolationBackend decorates BY NEED), which is an isolated bench run
    # nothing can observe -- and on the bench the record IS the deliverable.
    it "journals the lease lifecycle of a resolved backend" do
      journal = Lain::Channel.new
      arms_report(isolation: "none", journal:)

      leases = journal.drain.grep(Lain::Telemetry::IsolationLease).group_by(&:kind)
      expect(leases.fetch(:acquired)).not_to be_empty
      expect(leases.fetch(:released).size).to eq(leases.fetch(:acquired).size)
    end

    # An internally-manufactured Channel would satisfy the resolver's decorate-
    # by-need rule and then be dropped on the floor -- the records generated, the
    # run isolated, and nothing able to read either. The operator learns that at
    # the door instead of from an empty result after a paid run.
    it "refuses an isolation name with no journal to record its leases" do
      expect { arms_report(isolation: "none") }
        .to raise_error(described_class::Refusal, /journal/)
    end

    it "runs no arm when an isolation name arrives with no journal" do
      expect { arms_report(isolation: "none") }.to raise_error(described_class::Refusal)

      expect(provider.call_count).to eq(0)
      expect(driver_kwargs).to be_empty
    end

    # A journal asked for with NO name to resolve it against would be lease
    # telemetry that never arrives, silently. #arm_isolation already refuses
    # that; this entry point forwards to it rather than growing a second guard.
    it "refuses a journal handed in with no isolation name, rather than dropping it" do
      expect { arms_report(journal: Lain::Channel.new) }.to raise_error(ArgumentError, /journal/)
    end

    # Scenario: an unknown isolation name is refused before any arm runs.
    it "raises the one named error, naming the advertised set, on an unknown isolation name" do
      expect { arms_report(isolation: "wortkree", journal: Lain::Channel.new) }
        .to raise_error(Lain::CLI::IsolationBackend::Unknown, /wortkree.*none.*worktree/m)
    end

    it "runs no arm when the isolation name is unknown" do
      expect { arms_report(isolation: "wortkree", journal: Lain::Channel.new) }.to raise_error(Lain::CLI::IsolationBackend::Unknown)

      expect(provider.call_count).to eq(0)
      expect(driver_kwargs).to be_empty
    end

    # The suite fixture is user-supplied (B3 passes a path), and ArmTasks owns
    # what a missing one means -- one authority on "what a bench task is".
    it "surfaces ArmTasks' own error for a fixture path that is not there" do
      expect { cli.arms_report(fixture_path: "no/such/tasks.yml", provider:) }
        .to raise_error(Lain::Bench::ArmTasks::MissingFixture, %r{no/such/tasks\.yml})
    end

    # The provider flags reach the live seam, not a second parallel authority:
    # an unknown --provider raises the one Lain::CLI error every bench command
    # raises, at assembly, before an arm runs.
    it "resolves the provider through the one backend every bench command uses" do
      expect { cli.arms_report(fixture_path:, provider_name: "gpt5") }
        .to raise_error(Lain::CLI::UnknownProvider, /gpt5/)
    end

    # B3 passes --model/--max-tokens/--temperature/--seed through this tail, and
    # a silently dropped one is invisible: an unpinned --seed is a
    # reproducibility hole on a bench whose whole claim is repeatability. The
    # Request the provider was actually handed is the end of that wire.
    it "carries every sampler flag in the tail through to the provider" do
      arms_report(model: "claude-haiku-4-5", max_tokens: 321, temperature: 0.25, seed: 99)

      request = provider.last_request
      expect(request.model).to eq("claude-haiku-4-5")
      expect(request.max_tokens).to eq(321)
      expect(request.extra).to include("temperature" => 0.25, "seed" => 99)
    end

    # An injected price book that never reaches an arm prices every run off the
    # default table instead -- a cost column that looks valid and is not.
    it "threads an injected price book into every arm" do
      book = Lain::PriceBook.new
      arms_report(price_book: book)

      expect(built_arms.map { |arm| arm.instance_variable_get(:@price_book) }).to all(be(book))
    end
  end

  # B-1: Arm::OrchestratorWorker's own DEFAULT_DECOMPOSE splits on LINES, and
  # every prompt in the committed suite is a folded YAML scalar -- one line, so
  # one worker, so no fan-out at all. An orchestrator arm that never orchestrates
  # produces a column that looks like a measurement and is a second copy of the
  # control. The named reuse target (arm_sweep.rb:135-138) injects `decompose:`
  # for exactly this reason.
  describe "the orchestrator arm actually fans out" do
    let(:suite) { Lain::Bench::ArmTasks.new(fixture_path:) }

    it "splits every genuinely-parallel task into more than one subtask" do
      counts = suite.parallel.to_h { |task| [task.id, Lain::Bench::LiveArms::DEFAULT_DECOMPOSE.call(task.prompt).size] }

      expect(counts).not_to be_empty
      expect(counts.values).to all(be > 1)
    end

    # Not a claim about the policy in isolation: the leases the run actually took
    # name one worker each, so more than one worker key under the orchestrator
    # arm is the arm having really fanned out.
    it "leases more than one worker for the orchestrator arm" do
      journal = Lain::Channel.new
      arms_report(isolation: "none", journal:)

      workers = journal.drain.grep(Lain::Telemetry::IsolationLease)
                       .map(&:worker_key).uniq.grep(/orchestrator-worker-worker-/)
      expect(workers.size).to be > 1
    end

    it "hands the arm the decomposition it was given, not its own default" do
      arms_report(decompose: ->(task) { task.split.first(4) })

      expect(built_arms.map(&:name)).to include("orchestrator-worker")
      expect(orchestrator_decompose.call("a b c d e")).to eq(%w[a b c d])
    end
  end

  # S-1: ArmTasks enforces a unique `id`, NOT a unique `prompt`, and B3 takes the
  # fixture path from the command line. SuiteGrader dispatches BY PROMPT, so two
  # tasks sharing one would both resolve to the first -- the second's gold scored
  # against the first's trajectory, silently. Refused where the assumption lives.
  describe "the grader's dispatch key" do
    def write_fixture(dir, prompts)
      path = File.join(dir, "tasks.yml")
      tasks = prompts.each_with_index.map do |prompt, index|
        { "id" => "task-#{index}", "category" => "procedural", "prompt" => prompt,
          "gold_files" => { "lib/#{index}.rb" => "MARK_#{index}" } }
      end
      File.write(path, YAML.dump("tasks" => tasks))
      path
    end

    it "refuses a suite whose tasks share a prompt, before any arm runs" do
      Dir.mktmpdir("lain-arm-tasks") do |dir|
        path = write_fixture(dir, ["do the thing", "do the thing"])

        expect { cli.arms_report(fixture_path: path, provider:) }
          .to raise_error(described_class::Refusal, /task-0.*task-1|task-1.*task-0/m)
        expect(provider.call_count).to eq(0)
      end
    end

    it "accepts a suite whose prompts are all distinct" do
      Dir.mktmpdir("lain-arm-tasks") do |dir|
        path = write_fixture(dir, ["do the thing", "do the other thing"])

        expect(cli.arms_report(fixture_path: path, provider:)).to include("3 arms over 2 tasks")
      end
    end

    # The raise the design note argues hardest for -- "a number a bench must
    # never invent" -- is otherwise unreachable, since every arm asks the
    # verbatim prompt. const_get, because the guard is a private constant and
    # the alternative is leaving the loud path unpinned.
    it "refuses to grade a timeline whose user turns name no task in the suite" do
      grader = described_class.const_get(:SuiteGrader).new(Lain::Bench::ArmTasks.new(fixture_path:))
      timeline = Lain::Timeline.empty.commit(role: :user, content: [{ "type" => "text", "text" => "unrelated" }])

      expect { grader.grade(timeline) }.to raise_error(ArgumentError, /no task in the suite/)
    end
  end
end
