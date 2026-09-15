# frozen_string_literal: true

# The assembling entry point `bench arms` sits on. It takes a fixture path, the
# ONE resolved Lain::CLI::Backend the flags built, and an optional isolation
# NAME -- assembles the arms, the ArmTasks suite, that suite's per-task gold
# grader and the live SpawnSeam, and hands all four to #arm_report, returning
# the report String. exe/lain therefore stays a flag parser (its boundary rule
# at exe/lain:80-85).
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

  # The backend the flags build, spelled the way exe/lain and every other Backend
  # spec spell it. `max_tokens` is explicit because Context requires it
  # (`Integer(nil)` raises), and the number is the `bench arms` flag's own
  # declared default.
  def backend(**options)
    Lain::CLI::Backend.new(
      { provider: "anthropic", max_tokens: Lain::Bench::SpawnSeam::DEFAULT_MAX_TOKENS, **options }
    )
  end

  # TOOLLESS by default, and named rather than inherited: every claim in this
  # file is about ASSEMBLY -- which backend reaches the arms, which grader,
  # which price book -- and a writing toolset with nothing containing it is
  # refused at this method's door (Bench::CLI#refuse_unisolated_writes!). The
  # capability axis has its own file, spec/lain/bench/harness_spec.rb.
  def arms_report(**) = cli.arms_report(fixture_path:, backend:, provider:, tools: toolless, **)

  def toolless = Lain::Bench::Harness::NO_TOOLS

  # The Driver renders one titled table per metric, blank-line separated.
  def score_section(report) = report.split("\n\n").find { |section| section.start_with?("grader score") }

  # The isolation backend the Driver is holding. No reader exposes it (the
  # Driver's whole surface is #report), and "which backend reached the arms" is
  # exactly what this card must pin -- so it is read off the object, the way
  # cli_spec and cache_breakpoints_spec read collaborators they cannot ask for.
  def driver_isolation = drivers.last.instance_variable_get(:@isolation)

  # The arms that actually reached the Driver -- its one positional argument.
  def built_arms = driver_args.last.first

  # What an arm was actually TOLD. Context#render puts the system prompt into
  # Anthropic's block form, so the text has to be read back out of the blocks
  # rather than off the Request as a String. Read off EVERY recorded request,
  # not `last_request`: "every arm" is the claim, and the last request belongs
  # to whichever arm happened to finish last.
  def rendered_systems
    provider.requests.map { |request| request.system.map { |block| block.fetch("text") }.join("\n") }
  end

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

    # Not just "a String": all four orchestration arms over EVERY task the
    # fixture declares. The Driver's header states both counts, so a suite
    # silently truncated to the two tasks Driver demands, or an arm quietly
    # dropped, fails here.
    #
    # The header was widened, and the attribution is asserted in the SAME example
    # because it is the same claim about the same four lines: what ran, over what,
    # under what. `arms_report` is the only caller that can answer all three, so a
    # header that keeps the counts and drops the fixture is still an unattributable
    # record.
    it "compares all four arms over the whole committed suite, and says what produced the report" do
      report = arms_report

      expect(report).to include("4 arms over 8 tasks")
        .and include("single-thread").and include("orchestrator-worker")
        .and include("dual-ledger").and include("adaptive-router")
      expect(report).to include(fixture_path)
      # The model the arms were CONFIGURED with (the backend's resolved default),
      # which in this spec is deliberately not the model the mock's responses
      # report -- the header attributes what was asked for, the cost column
      # prices what each payment recorded. In production they are the same string.
      expect(report).to include(Lain::Provider::Anthropic::DEFAULT_MODEL)
    end

    # The header must attribute without leaking: a report is pasted into an
    # issue, and `Lain::CLI::Backend` holds the key and base URL the provider
    # was resolved from. spec/output_discipline_spec.rb cannot see inside a
    # String, so the claim is made here.
    it "names no API key and no provider base URL" do
      expect(arms_report).not_to match(%r{sk-ant|api_key|https?://}i)
    end

    # ArmTasks carries a gold Grader::Fixture PER TASK while the Driver threads
    # ONE grader through every run, so the assembly has to dispatch. The scripted
    # answer satisfies one task's gold and no other's: a single blanket grader
    # would score every task alike and could not produce both numbers.
    it "grades each task against ITS OWN gold rather than one blanket grader" do
      expect(score_section(arms_report)).to include("1.000").and include("0.000")
    end

    # The chunk's headline metric, end to end through the real
    # assembly. Every arm asks the same mock once per task, so the whole suite
    # is priced off one recorded model and the section must carry a real figure
    # rather than the zero an unpriced fold would render.
    it "prices every arm through the suite it actually ran" do
      report = arms_report
      section = report.split("\n\n").find { |block| block.start_with?("cost (USD)") }

      expect(section).not_to be_nil
      expect(section).to include("single-thread").and include("orchestrator-worker")
        .and include("dual-ledger").and include("adaptive-router")
      expect(section).not_to match(/\s0\.000000(\s|$)/)
    end

    # Without this the live path scores every arm near zero: the gold graders
    # read FILE...END out of assistant text, and an arm told nothing about that
    # contract answers in prose. Asserted on the Requests the provider was
    # HANDED, through the real assembly, because the offline sweep's fixture is
    # hand-authored to satisfy the parser and hid this completely.
    #
    # `system: nil` EXPLICITLY, because that is production's shape: exe/lain
    # reads the flag off an options hash, so an unset `--system` arrives here as
    # a nil value rather than as an absent keyword. Omitting the keyword would
    # pass against a default that only fires on omission -- the counterfactual
    # this card exists to rule out.
    it "teaches every arm the trajectory contract when no system prompt is given" do
      arms_report(system: nil)

      taught = rendered_systems.map { |rendered| Lain::Bench::ArmSweep::FileBlocks.parse(rendered).keys }
      expect(taught).not_to be_empty
      expect(taught).to all(include("lib/example.rb"))
    end

    it "renders an explicit system prompt instead of the taught contract" do
      arms_report(system: "be terse")

      expect(rendered_systems).not_to be_empty
      expect(rendered_systems).to all(eq("be terse"))
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

    # The header field, on the only path this command can take. `#lease_options`
    # REQUIRES a journal whenever `--isolation` is set, so the resolver always
    # returns a backend wrapped in `Isolation::Journal` -- which means every
    # resolvable name renders as the same decorator class, and the field cannot
    # answer the question it exists to answer. The operator's own word can.
    it "names the isolation backend the operator asked for, not the decorator wrapping it" do
      report = arms_report(isolation: "none", journal: Lain::Channel.new)

      expect(report).to match(/isolation:\s+none\b/)
      expect(report).not_to include(Lain::Isolation::Journal.name)
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

    # The suite fixture is user-supplied (the caller passes a path), and
    # ArmTasks owns what a missing one means -- one authority on "what a bench
    # task is".
    it "surfaces ArmTasks' own error for a fixture path that is not there" do
      expect { cli.arms_report(fixture_path: "no/such/tasks.yml", backend:, provider:, tools: toolless) }
        .to raise_error(Lain::Bench::ArmTasks::MissingFixture, %r{no/such/tasks\.yml})
    end

    # The provider flags reach the live seam, not a second parallel authority:
    # an unknown --provider raises the one Lain::CLI error every bench command
    # raises, at assembly, before an arm runs.
    it "resolves the provider through the one backend every bench command uses" do
      expect { cli.arms_report(fixture_path:, backend: backend(provider: "gpt5"), tools: toolless) }
        .to raise_error(Lain::CLI::UnknownProvider, /gpt5/)
    end

    # The command line passes --model/--max-tokens/--temperature/--seed through
    # this tail, and a silently dropped one is invisible: an unpinned --seed is
    # a reproducibility hole on a bench whose whole claim is repeatability. The
    # Request the provider was actually handed is the end of that wire.
    # EVERY request, not `last_request`: the routing arm runs last, so reading
    # the tail off the final request would assert the flags against one child of
    # one arm. The ceiling and the sampler must reach ALL of them, the routed
    # ones included -- which is what pins that `Context#with_model` copies
    # everything except the model. `--model` itself is the example below, since
    # it is the one flag an arm here is entitled to depart from.
    #
    # The ARM is named in each example because it decides which sampler flags
    # exist on the wire: `seed` is an ollama option, and the Anthropic encoder
    # would forward it to an API that defines no such field.
    it "carries every sampler flag in the tail through to an ollama provider" do
      cli.arms_report(fixture_path:, provider:, tools: toolless,
                      backend: backend(provider: "ollama", model: "claude-sonnet-4", max_tokens: 321,
                                       temperature: 0.25, seed: 99))

      expect(provider.requests.map(&:max_tokens).uniq).to eq([321])
      expect(provider.requests.map(&:extra)).to all(include("temperature" => 0.25, "seed" => 99))
    end

    it "carries temperature but not the ollama-only seed through to an Anthropic provider" do
      cli.arms_report(fixture_path:, provider:, tools: toolless,
                      backend: backend(provider: "anthropic", model: "claude-sonnet-4", max_tokens: 321,
                                       temperature: 0.25, seed: 99))

      expect(provider.requests.map(&:max_tokens).uniq).to eq([321])
      expect(provider.requests.map(&:extra)).to all(eq("temperature" => 0.25))
    end

    # THE OPERATOR'S MODEL IS THE ROSTER'S MODEL, on all four arms. The routing
    # arm may send a task to a CHEAPER sibling -- that is what the arm is -- and
    # it may never send one to a model nobody asked for. An earlier draft of
    # this card routed to two absolute ids, so `--model claude-sonnet-4` bought
    # opus on five of eight tasks while the report header still said sonnet.
    #
    # A TALLY, not a `uniq`: the set is blind to another arm drifting, since a
    # drifting single-thread would land on a model already in it. The counts say
    # which arm moved.
    it "runs every arm under the model the operator asked for, departing only where it routes cheaper" do
      cli.arms_report(fixture_path:, provider:, tools: toolless, backend: backend(model: "claude-sonnet-4"))
      tally = provider.requests.map(&:model).tally

      expect(tally.keys).to contain_exactly("claude-sonnet-4", Lain::Bench::LiveArms::CHEAP_MODEL)
      expect(tally.fetch(Lain::Bench::LiveArms::CHEAP_MODEL)).to eq(3)
    end

    # `--provider ollama` is advertised and worked before the fourth arm landed.
    # The cheap branch is an Anthropic id, so on a backend that cannot serve one
    # the roster REFUSES AT ASSEMBLY rather than asking a qwen3 endpoint for
    # `claude-haiku-4-5` on arm four, after three arms have billed.
    it "refuses a backend it has no cheaper sibling for, before any arm runs" do
      expect do
        cli.arms_report(fixture_path:, provider:, tools: toolless,
                        backend: backend(provider: "ollama", model: "qwen3:4b"))
      end.to raise_error(Lain::Bench::LiveArms::UnroutableBackend, /qwen3:4b/)
      expect(provider.call_count).to eq(0)
    end

    # The way out of that refusal, and the reason `.build` takes the keyword at
    # all: a caller with its own tier routes its own models. Without this the
    # refusal names an escape hatch that does not exist -- which is the exact
    # shape of defect this card was sent back for.
    it "lets a caller route an unpriceable backend with its own tier" do
      router = Lain::Oracle::Heuristic.new(definition: Lain::Oracle::Router.definition,
                                           predicate: ->(*) { { "model" => "qwen3:0.6b", "template" => "" } })

      cli.arms_report(fixture_path:, provider:, tools: toolless, router:,
                      backend: backend(provider: "ollama", model: "qwen3:4b"))

      expect(provider.requests.map(&:model).tally).to include("qwen3:0.6b" => 8)
    end

    # The operator's OWN way out, a flag rather than a Ruby argument --
    # `--cheap-model` names the sibling an ollama backend routes narrow tasks
    # to, so a real qwen3 backend gets a routing arm without an injected
    # `router:` of the caller's own.
    it "routes an ollama backend's narrow tasks to its own named cheap model" do
      cli.arms_report(fixture_path:, provider:, tools: toolless, cheap_model: "qwen3:4b",
                      backend: backend(provider: "ollama", model: "qwen3-coder:30b"))
      tally = provider.requests.map(&:model).tally

      expect(tally.keys).to contain_exactly("qwen3-coder:30b", "qwen3:4b")
      expect(tally.fetch("qwen3:4b")).to eq(3)
    end

    it "refuses an ollama backend naming no --cheap-model, before any arm runs" do
      expect do
        cli.arms_report(fixture_path:, provider:, tools: toolless,
                        backend: backend(provider: "ollama", model: "qwen3-coder:30b"))
      end.to raise_error(Lain::Bench::LiveArms::UnroutableBackend, /--cheap-model/)
      expect(provider.call_count).to eq(0)
    end

    it "refuses a --cheap-model equal to --model, as running the control twice" do
      expect do
        cli.arms_report(fixture_path:, provider:, tools: toolless, cheap_model: "qwen3:4b",
                        backend: backend(provider: "ollama", model: "qwen3:4b"))
      end.to raise_error(Lain::Bench::LiveArms::UnroutableBackend)
      expect(provider.call_count).to eq(0)
    end

    # An injected price book that never reaches an arm prices every run off the
    # default table instead -- a cost column that looks valid and is not.
    it "threads an injected price book into every arm" do
      book = Lain::PriceBook.new
      arms_report(price_book: book)

      # Each arm prices through its injected {Arm::Instrument}, so the book has
      # to be the one THAT is carrying -- reading the arm for a price book of its
      # own would pass on an arm that prices nothing.
      instruments = built_arms.map { |arm| arm.instance_variable_get(:@instrument) }
      expect(instruments.map(&:price_book)).to all(be(book))
    end
  end

  # The prompt that teaches the format is sent INTO the suite it is graded
  # against, so its worked example is a string every arm has in hand before it
  # reads the task. If that example names a graded path, an arm that echoes the
  # format and does no work at all collects part of a gold -- and a floor under
  # every score reads as work done, where a zero reads as a broken run.
  describe "the taught contract's worked example" do
    let(:suite) { Lain::Bench::ArmTasks.new(fixture_path:) }

    def trajectory(files) = Lain::Bench::ArmTasks::Trajectory.new(files:)

    # The DELTA against an empty answer, not the score itself: one task's
    # `excludes:` check passes vacuously against a file nobody wrote, so an
    # empty trajectory already scores above zero there and an absolute
    # assertion would be measuring that instead of this.
    it "scores no better than an empty answer on every task in the suite" do
      taught = trajectory(Lain::Bench::ArmSweep::FileBlocks.parse(Lain::Bench::ArmSweep::FileBlocks::CONTRACT))
      contamination = suite.to_h do |task|
        [task.id, task.grader.grade(taught).score - task.grader.grade(trajectory({})).score]
      end

      # `all` passes on an empty collection, so the delta alone is satisfied by
      # a CONTRACT that teaches nothing and by a suite with no tasks in it.
      expect(taught.files).not_to be_empty
      expect(contamination).not_to be_empty
      expect(contamination).to all(satisfy { |_id, delta| delta.zero? })
    end
  end

  # Arm::OrchestratorWorker's own DEFAULT_DECOMPOSE splits on LINES, and
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

  # ArmTasks enforces a unique `id`, NOT a unique `prompt`, and the fixture path
  # comes from the command line. SuiteGrader dispatches BY PROMPT, so two
  # tasks sharing one would both resolve to the first -- the second's gold scored
  # against the first's trajectory, silently. Refused where the assumption lives.
  # THE HUMAN'S RULING, at the door of the highest-spend command in the repo.
  # An unisolated arm leases through Arm::NoIsolation and runs in the operator's
  # own checkout, and the floor carries `bash` behind Effect::Handler::Live with
  # no gate in front of it.
  describe "refusing a writing toolset with nothing to contain it" do
    it "refuses the default floor when no isolation is named" do
      expect { cli.arms_report(fixture_path:, backend:, provider:) }
        .to raise_error(described_class::Refusal, /can write.*nothing isolates/m)
    end

    # `none` is not isolation: it leases over the shared process environment, so
    # it cuts no checkout. Refusing it is the difference between a guard and a
    # flag that looks like one.
    it "refuses the default floor under an isolation that contains nothing" do
      expect { cli.arms_report(fixture_path:, backend:, provider:, isolation: "none", journal: Lain::Channel.new) }
        .to raise_error(described_class::Refusal, /--isolation none does not isolate/)
    end

    it "names the flags that fix it" do
      expect { cli.arms_report(fixture_path:, backend:, provider:) }
        .to raise_error(described_class::Refusal, /--isolation worktree --journal PATH/)
    end

    it "lets a toolless run through unisolated, which is the control the bench needs" do
      expect(arms_report).to include("4 arms over")
    end
  end

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

        expect { cli.arms_report(fixture_path: path, backend:, provider:, tools: toolless) }
          .to raise_error(described_class::Refusal, /task-0.*task-1|task-1.*task-0/m)
        expect(provider.call_count).to eq(0)
      end
    end

    it "accepts a suite whose prompts are all distinct" do
      Dir.mktmpdir("lain-arm-tasks") do |dir|
        path = write_fixture(dir, ["do the thing", "do the other thing"])

        expect(cli.arms_report(fixture_path: path, backend:, provider:, tools: toolless))
          .to include("4 arms over 2 tasks")
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
