# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

# Answers every `git` the worktree backend shells out with success, recording
# the argv. This spec's claim is WHICH backend reaches the arms, not what git
# does with a checkout -- spec/lain/cli/isolation_backend_spec.rb runs the real
# thing -- so faking the subprocess keeps an arm run off the filesystem.
class BenchArmShells
  Fake = Struct.new(:argv, :exitstatus, :stderr, :stdout) do
    def run_command = self
  end

  def initialize
    @calls = []
  end

  attr_reader :calls

  def call(*argv, **)
    @calls << argv
    Fake.new(argv, 0, "", stdout_for(argv))
  end

  private

  # The worktree backend names the branch HEAD is on when it resolves, then
  # reads that branch's tip as a full SHA per lease; every other git call is
  # answered empty.
  def stdout_for(argv)
    return "refs/heads/main\n" if argv.include?("symbolic-ref")
    return "#{"0" * 40}\n" if argv.include?("rev-parse")

    ""
  end
end

# Records the isolation backend the {Lain::Arm::Driver} hands each `#run` and
# then IS the control arm: the lease lifecycle under observation is
# {Lain::Arm::SingleThread}'s own acquire/release, not a mock of it.
#
# `isolation:` is REQUIRED here, unlike on every real arm. Re-declaring the
# base's `NoIsolation` default would let this arm supply the very value the
# spec then credits the DRIVER with, so a driver that stopped passing
# `isolation:` at all would still read as one defaulting to NoIsolation.
# Required, that driver is a loud ArgumentError instead.
class IsolationRecordingArm < Lain::Arm::SingleThread
  def initialize(name:, instrument: Lain::Arm::Instrument.new(clock: -> { 0.0 }))
    super
    @isolations = []
  end

  attr_reader :isolations

  def run(task, isolation:, **rest)
    @isolations << isolation
    super
  end
end

# Stands in for the operator's Ctrl-C arriving mid-run. The single-thread arm
# runs first in {Lain::Bench::LiveArms.build}'s roster and asks the provider
# exactly once per task (the canned response ends the turn with no tool
# call), so raising on the (n+1)th call leaves exactly n runs graded -- the
# same n this provider was told to let through.
class InterruptingProvider < Lain::Provider::Mock
  def initialize(allow:, **rest)
    super(**rest)
    @allow = allow
  end

  def complete(request, **rest)
    raise Interrupt if call_count >= @allow

    super
  end
end

# Two altitude tasks at ONE size, which is the smallest suite that folds a
# distribution (Altitude's own n >= 2 rule). A constant rather than a heredoc
# inside the helper: the body is what pushed that method over MethodLength, and
# the suite is a fixture rather than a step of the helper's work.
#
# The subjects are named ABSOLUTELY, at the committed projects: a suite's
# subject paths resolve against its own directory, and this one is written into
# a temp dir that holds no projects of its own.
ALTITUDE_CLI_SUBJECTS = File.expand_path("../../fixtures/altitude/subjects", __dir__)

ALTITUDE_CLI_SUITE = <<~YAML.freeze
  tasks:
    - id: order-total
      size: small
      subject: #{ALTITUDE_CLI_SUBJECTS}/order-total
      level: unit
      prompt: "add a refund to Order"
    - id: invoice-lines
      size: small
      subject: #{ALTITUDE_CLI_SUBJECTS}/invoice-lines
      level: unit
      prompt: "net the invoice"
YAML

# Bench::CLI is ALL of `exe/lain bench`'s assembly: exe/lain only parses flags,
# calls these methods, and `say`s the returned Strings. Every refused input is
# a {Lain::Error} -- {CLI::Refusal} for the user's own mistakes, with the path
# context only this layer still holds, plus Session::Corrupt and the key gate
# -- so the exe rescues Lain::Error ALONE and a programmer bug's ArgumentError
# keeps its backtrace. Nothing here rescues for the user, nothing here prints.
RSpec.describe Lain::Bench::CLI do
  # Runs the block for its SIDE EFFECTS, swallowing the refusal under test: the
  # claim is about what reached the filesystem, not about the message.
  def suppress(error)
    yield
  rescue error
    nil
  end

  fixture_dir = File.expand_path("../../fixtures/sessions/variance", __dir__)

  subject(:cli) { described_class.new }

  # The whole point of the taxonomy: exe/lain rescues Lain::Error only, so a
  # refusal must BE one, and a bare ArgumentError must stay a loud bug.
  it "classes every bench refusal under Lain::Error" do
    expect(described_class::Refusal).to be < Lain::Error
    expect(described_class::MissingAPIKey).to be < Lain::Error
  end

  describe "#variance_report" do
    it "assembles the Variance report over every *.ndjson under a directory" do
      report = cli.variance_report([fixture_dir])
      expect(report).to start_with("Variance — 3 recordings")
      expect(report).to include("== Determinism", "== Divergence", "== Distribution ==")
    end

    it "returns a String and writes nothing to stdout or stderr" do
      expect { cli.variance_report([fixture_dir]) }.not_to output.to_stdout
      expect { cli.variance_report([fixture_dir]) }.not_to output.to_stderr
    end

    it "loads a directory's sessions in sorted filename order" do
      sorted = Dir.children(fixture_dir).sort.map { |name| File.join(fixture_dir, name) }
      expect(cli.variance_report([fixture_dir])).to eq(cli.variance_report(sorted))
    end

    it "converts Variance's n>=2 guard into a Refusal naming the sources" do
      expect { cli.variance_report([File.join(fixture_dir, "one.ndjson")]) }
        .to raise_error(described_class::Refusal, /one\.ndjson.*at least two/m)
    end

    # A typo'd or empty directory must not fall through to "needs at least two
    # recordings" -- the experimenter typed a directory, so name the directory.
    it "refuses a directory holding no *.ndjson sessions, naming the directory" do
      Dir.mktmpdir do |tmp|
        expect { cli.variance_report([tmp]) }
          .to raise_error(described_class::Refusal, /#{Regexp.escape(tmp)}/)
      end
    end

    # Dir.glob would read "run[1]" as a character class and match nothing; a
    # directory's name must never be parsed as a pattern.
    it "loads a directory whose name carries glob metacharacters" do
      Dir.mktmpdir do |tmp|
        dir = File.join(tmp, "run[1]")
        FileUtils.mkdir(dir)
        Dir.children(fixture_dir).each { |name| FileUtils.cp(File.join(fixture_dir, name), dir) }
        expect(cli.variance_report([dir])).to start_with("Variance — 3 recordings")
      end
    end

    # DryReplay's 1:1 guard fires while Variance CONSTRUCTS, long after the
    # paths are gone -- so this layer probes each recording as it loads and
    # names the one file to regenerate, not the whole directory.
    it "refuses an orphan-baseline recording as a Refusal naming the file" do
      Dir.mktmpdir do |tmp|
        FileUtils.cp(File.join(fixture_dir, "one.ndjson"), tmp)
        bytes = File.read(File.join(fixture_dir, "two.ndjson"))
        orphan = bytes.each_line.find { |line| line.include?("request_sent") }
        File.write(File.join(tmp, "two.ndjson"), bytes + orphan)
        expect { cli.variance_report([tmp]) }
          .to raise_error(described_class::Refusal, /two\.ndjson.*baseline/m)
      end
    end

    # Corrupt's own message names a digest; only this layer still holds the
    # path, and an experimenter with a directory of n sessions needs to know
    # WHICH file to regenerate.
    it "lets Session::Corrupt raise on a tampered file, naming the file" do
      Dir.mktmpdir do |tmp|
        FileUtils.cp(File.join(fixture_dir, "one.ndjson"), tmp)
        forged = File.read(File.join(fixture_dir, "two.ndjson")).sub("aspirin", "forged!")
        File.write(File.join(tmp, "two.ndjson"), forged)
        expect { cli.variance_report([tmp]) }
          .to raise_error(Lain::Bench::Session::Corrupt, /two\.ndjson/)
      end
    end

    # The other half of that sentence. A null inside a message record's
    # causal_parents is MALFORMED rather than dangling, and it used to survive
    # MessageReplay's compacting pre-check and reach the experimenter as a bare
    # Store::MissingObject with no path attached at all. It is refused a layer
    # down now; what this pins is the door -- same damage, same file, same
    # named answer, whichever layer catches it.
    it "names the file when a message record's causal_parents holds a null" do
      Dir.mktmpdir do |tmp|
        FileUtils.cp(File.join(fixture_dir, "one.ndjson"), tmp)
        payload = Lain::Event::Payload.new(kind: :message, body: { "text" => "which dose?" })
        event = Lain::Event.new(kind: :message, carried_payload: payload, from: "agent", to: "human")
        malformed = Lain::Telemetry::Message.from_event(event).to_journal.merge("causal_parents" => [nil])
        File.write(File.join(tmp, "two.ndjson"),
                   File.read(File.join(fixture_dir, "two.ndjson")) + "#{JSON.generate(malformed)}\n")
        expect { cli.variance_report([tmp]) }
          .to raise_error(Lain::Bench::Session::Corrupt, /two\.ndjson/)
      end
    end

    # Compare's two comparability guards speak in the RECORDINGS' vocabulary and
    # name no file, so an experimenter who pointed this at a directory of twelve
    # sessions reads "checkout/ask vs checkout/auto" with no way back to the
    # two at fault. Only this layer still holds the paths -- the same sentence
    # the orphan-baseline refusal above is built on.
    describe "refusing recordings that are not comparable" do
      # `fixture_dir` is a local of the enclosing block, so these stay inline
      # rather than becoming `def` helpers, which would not close over it.
      let(:flip) { { "type" => "mode_switch", "from_scope" => "checkout", "to_scope" => "checkout" } }

      it "refuses recordings under different modes as a Refusal naming the sources" do
        Dir.mktmpdir do |tmp|
          { "one.ndjson" => %w[ask auto], "two.ndjson" => %w[auto ask] }.each do |name, (from, to)|
            line = JSON.generate(flip.merge("from_approval" => from, "to_approval" => to))
            File.write(File.join(tmp, name), File.read(File.join(fixture_dir, name)) + "#{line}\n")
          end
          expect { cli.variance_report([tmp]) }
            .to raise_error(described_class::Refusal,
                            %r{one\.ndjson.*two\.ndjson.*checkout/ask → checkout/auto.*checkout/auto → checkout/ask}m)
        end
      end

      it "refuses recordings whose degraded sets differ as a Refusal naming the sources" do
        Dir.mktmpdir do |tmp|
          FileUtils.cp(File.join(fixture_dir, "one.ndjson"), tmp)
          degraded = { "type" => "capability_degraded", "capability" => "prompt_caching" }
          File.write(File.join(tmp, "two.ndjson"),
                     File.read(File.join(fixture_dir, "two.ndjson")) + "#{JSON.generate(degraded)}\n")
          expect { cli.variance_report([tmp]) }
            .to raise_error(described_class::Refusal, /one\.ndjson.*two\.ndjson/m)
        end
      end
    end

    it "refuses a missing session file with a Refusal, not a raw ENOENT" do
      expect do
        cli.variance_report([File.join(fixture_dir, "absent.ndjson"), File.join(fixture_dir, "one.ndjson")])
      end.to raise_error(described_class::Refusal, /no session file/)
    end
  end

  describe "#sweep_report" do
    it "returns the five-arm retrieval report as a String, without printing" do
      report = nil
      # One build serves all three assertions -- a sweep is ~0.3s, and the
      # output matcher runs its block anyway, so silence and content are the
      # same observation. (Only the frontend may print; see
      # spec/output_discipline_spec.rb for the whole-tree guarantee.)
      expect { report = cli.sweep_report(k: 5) }.to output("").to_stdout.and output("").to_stderr
      expect(report).to include("manifest").and include("bm25").and include("vector")
        .and include("hybrid").and include("graph")
    end

    it "is deterministic across calls" do
      expect(cli.sweep_report(k: 5)).to eq(cli.sweep_report(k: 5))
    end

    # Refusal parity with record's --n: user input refuses in the experimenter's
    # vocabulary through the exe's `rescue Lain::Error`, never a bare
    # ArgumentError backtrace.
    it "refuses a non-positive k with a Refusal, not a deep ArgumentError" do
      expect { cli.sweep_report(k: 0) }.to raise_error(described_class::Refusal, /whole number|at least/)
    end

    it "refuses a fractional k rather than silently truncating recall@2.5 to recall@2" do
      expect { cli.sweep_report(k: 2.5) }.to raise_error(described_class::Refusal, /whole number/)
    end
  end

  # An arm run leases its workers from the SAME `--isolation` resolver the chat
  # fleet uses, so a backend name means one thing across commands -- and the
  # resolved backend has to reach EVERY arm, or the comparison is between arms
  # that ran under different confinement.
  describe "#arm_report" do
    let(:spawn_seam) do
      lambda do |journal:, **|
        Lain::Agent.new(
          provider: Lain::Provider::Mock.new(
            responses: [text_response("done", model: "claude-sonnet-4",
                                              usage: Lain::Usage.new(input_tokens: 100, output_tokens: 20))]
          ),
          toolset: Lain::Toolset.new([]),
          context: Lain::Context.new(model: "claude-opus-4-8", max_tokens: 256),
          journal:
        )
      end
    end

    let(:grader) do
      Lain::Grader::Fixture.new("settled") do |f|
        f.check("committed an assistant turn") { |timeline| timeline.to_a.map(&:role).include?("assistant") }
      end
    end

    let(:arms) { [IsolationRecordingArm.new(name: "arm-a"), IsolationRecordingArm.new(name: "arm-b")] }
    let(:tasks) { ["procedural task", "another task"] }

    # What every arm was handed, across every task in the suite.
    def isolations = arms.flat_map(&:isolations)

    it "returns the driver's report as a String, without printing" do
      report = nil
      expect { report = cli.arm_report(arms, tasks:, spawn_seam:, grader:) }
        .to output("").to_stdout.and output("").to_stderr
      expect(report).to include("arm-a").and include("arm-b").and include("grader score")
    end

    it "leaves every arm with Arm::NoIsolation when no isolation option is given" do
      cli.arm_report(arms, tasks:, spawn_seam:, grader:)

      expect(isolations).to all(be(Lain::Arm::NoIsolation))
    end

    # THE ONE JOURNAL, READ BY TWO CONSUMERS -- and the only example in the tree
    # that holds `#arm_report`'s half of the grade wiring. `journal:` is named
    # explicitly on this method rather than left riding `**backend_options`,
    # because a keyword the isolation resolver merely forwards could never also
    # reach Arm::Driver; delete that and every OTHER example here stays green,
    # since the journal is exercised for lease telemetry and read for a verdict
    # nowhere else.
    it "journals every arm's grade into the same journal the leases are recorded in" do
      journal = Lain::Channel.new
      cli.arm_report(arms, tasks:, spawn_seam:, grader:, isolation: "none", journal:)

      records = journal.drain.grep(Lain::Telemetry::GradeRecord)
      expect(records.size).to eq(arms.size * tasks.size)
      expect(records.map(&:grader).uniq).to eq([Lain::Grader::Fixture.name])
      expect(records.map(&:score)).to all(eq(1.0))
    end

    # An unset flag is NOT `--isolation none`. Unset keeps the arm-local
    # NoIsolation, whose lease carries NO WorkerEnv at all; `none` resolves a
    # real Isolation::Null that leases the shared process environment. Passing
    # the resolver's own nil-means-default through here would collapse the two,
    # and that distinction is what tells a report's reader whether a run was
    # isolated by a backend or never leased anything.
    it "distinguishes an unset flag from an explicit isolation of none" do
      cli.arm_report(arms, tasks:, spawn_seam:, grader:, isolation: "none")

      expect(isolations).to all(be_a(Lain::Isolation::Null))
      expect(isolations.map { |backend| backend.acquire("arm-a").worker_env }).to all(be_a(Lain::WorkerEnv))
      expect(Lain::Arm::NoIsolation.acquire("arm-a").worker_env).to be_nil
    end

    it "reaches every arm with ONE resolved backend, each arm leasing under its own name" do
      Dir.mktmpdir("lain-bench-project") do |project|
        Dir.mktmpdir("lain-bench-runtime") do |runtime|
          FileUtils.mkdir_p(File.join(project, ".git"))
          journal = Lain::Channel.new
          cli.arm_report(arms, tasks:, spawn_seam:, grader:, isolation: "worktree", root: project, journal:,
                               paths: Lain::Paths.new(env: { "XDG_RUNTIME_DIR" => runtime,
                                                             "XDG_STATE_HOME" => runtime }),
                               shell_out_factory: BenchArmShells.new)

          leases = journal.drain.grep(Lain::Telemetry::IsolationLease).group_by(&:kind)
          acquired = leases.fetch(:acquired)
          expect(isolations.uniq.size).to eq(1)
          expect(acquired.size).to eq(arms.size * tasks.size)
          expect(acquired.map(&:worker_key).uniq).to contain_exactly("arm-a", "arm-b")
          expect(acquired.map(&:backend).uniq).to eq([Lain::Isolation::Worktree.name])
          # Acquire alone is not the claim: a backend that leaked every lease
          # would satisfy it. The record is a LIFECYCLE, so every acquire the
          # arms took must have a release journaled against it.
          expect(leases.fetch(:released).size).to eq(acquired.size)
        end
      end
    end

    # Forwarding backend options to a resolver that is never called would drop
    # them in silence -- and a caller who passes `journal:` for lease telemetry
    # but no name would get neither the telemetry nor a word about it, while the
    # same key one flag later (`isolation: "none", bogus: 1`) is a loud unknown-
    # keyword ArgumentError. A wiring bug, so it crashes like one.
    it "refuses backend options given with no isolation name, rather than dropping them" do
      expect { cli.arm_report(arms, tasks:, spawn_seam:, grader:, journal: Lain::Channel.new) }
        .to raise_error(ArgumentError, /journal/)
    end

    # Parity with record's unknown --provider: the ONE named Lain error, raised
    # at resolution, so the exe's `rescue Lain::Error` presents it and no arm is
    # dispatched under a backend the operator did not ask for.
    it "raises the one named Lain error on an unknown isolation name" do
      expect { cli.arm_report(arms, tasks:, spawn_seam:, grader:, isolation: "docker") }
        .to raise_error(Lain::CLI::IsolationBackend::Unknown, /docker/)
    end
  end

  # The four-arm DECOMPOSITION comparison, assembled. It spends more than
  # `bench arms` does -- the epic arms drive a whole epic per task -- so every
  # example here drives scripted seams through a Provider::Mock and resolves no
  # live provider.
  describe "#altitude_report" do
    # The seams the epic and planned arms are driven by. Anonymous classes
    # rather than named ones: a constant defined in an example group is a
    # Lint/ConstantDefinitionInBlock offence, and these have no life outside it.
    let(:launch) { Struct.new(:actor).new(Object.new) }

    let(:fleet) do
      Class.new do
        def find(*) = :row
        def retire(_row) = "anchored"
      end.new
    end

    # A driver whose run CARRIED an issue: one that carried none refuses, which
    # is right, but it is not what this example is about.
    let(:driver) do
      Class.new do
        def run(**)
          Lain::CLI::EpicDriver::Run::Result.new(
            landed: [Lain::CLI::EpicDriver::Run::Landed.new(issue_id: "ledger", sha: "a" * 40)],
            reported: [], stopped: nil
          )
        end
      end.new
    end

    # The per-issue grades the driver's grading hook collects -- in production a
    # {Lain::Grader::LeaseHarness} bound to each issue's own leased checkout.
    # Without them threaded, both epic arms roll up nothing and every cell in
    # their rows reads "not measured".
    let(:epic_grades) do
      -> { { "ledger" => Lain::Grader::Grade.new(score: 1.0, pass: true, why: "all 2 examples passed") } }
    end

    let(:seams) do
      Lain::Bench::LiveArms::Seams.new(
        planner: ->(*, **) { "Subject: lib/order.rb\n" }, actors: ->(*, **) { launch },
        supervisor: fleet, progressive: driver, hands_off: driver, slug: "demo", records: -> { [] },
        grades: epic_grades
      )
    end

    let(:said) { [] }

    # A sink that records rather than prints: the warning is the operator's, and
    # nothing in lib may reach a real stream.
    let(:sink) do
      recorder = said
      Class.new { define_method(:puts) { |*args| recorder << args.join(" ") } }.new
    end

    let(:grader) { Lain::Grader::Fixture.new("settled") { |f| f.check("ran at all") { true } } }

    let(:provider) do
      Lain::Provider::Mock.new(
        responses: Array.new(6) do
          text_response("done", model: "claude-sonnet-4",
                                usage: Lain::Usage.new(input_tokens: 80, output_tokens: 20))
        end
      )
    end

    # The key is never needed: an injected provider short-circuits the backend's
    # own resolution, and anthropic's model default is a constant.
    def backend
      Lain::CLI::Backend.new({ provider: "anthropic", max_tokens: Lain::Bench::SpawnSeam::DEFAULT_MAX_TOKENS },
                             root: Dir.pwd)
    end

    def with_fixture
      Dir.mktmpdir("lain-altitude-cli") do |dir|
        path = File.join(dir, "tasks.yml")
        File.write(path, ALTITUDE_CLI_SUITE)
        yield path
      end
    end

    # TOOLLESS, for #arms_report's reason one describe up: every claim here is
    # about the roster and the report, and a writing toolset with nothing
    # containing it is refused at this method's door.
    def altitude_report(path, **)
      cli.altitude_report(fixture_path: path, backend:, seams:, grader:, sink:, provider:,
                          tools: Lain::Bench::Harness::NO_TOOLS, **)
    end

    # The "grader score" table, arm => its mean cell. Read as CELLS rather than
    # asserted with `include`, because "not measured" is a perfectly good
    # substring of a report and satisfies every `include("epic-hands-off")` an
    # unmeasured row would ever be checked with.
    def score_rows(report)
      block = report.split("\n\n").find { |part| part.start_with?("grader score\n") }
      block.lines.drop(3).to_h do |line|
        cells = line.chomp.split(/\s{2,}/)
        [cells.first, cells[2]]
      end
    end

    # THE WHOLE ROSTER IS WHAT THE COMMAND BUILDS, so every one of the four rows
    # has to carry a real number. Two of them reading "not measured" is the
    # comparison silently not happening.
    it "returns the report as a String, with a real score for every arm on the roster" do
      with_fixture do |path|
        report = nil

        expect { report = altitude_report(path) }.to output("").to_stdout.and output("").to_stderr
        expect(report).to be_a(String)
        expect(report).to include("== small ==")
        expect(score_rows(report).keys).to eq(%w[one-shot plan-only epic-progressive epic-hands-off])
        expect(score_rows(report).values).to all(match(/\A\d+\.\d+\z/))
      end
    end

    # The warning is said BEFORE the first arm, and is deliberately not part of
    # the report: a report is pasted into an issue, where a spend warning would
    # read as a property of the experiment rather than of the command.
    it "says what it is about to spend before the first arm, and keeps it out of the report" do
      with_fixture do |path|
        report = altitude_report(path)

        expect(said.first).to include("spends real API money")
        expect(report).not_to match(/spends real/i)
      end
    end

    # The same pair `bench arms` refuses, refused by the same two guards rather
    # than by a second copy of them.
    it "refuses a set isolation with no journal to record its leases in" do
      with_fixture do |path|
        expect { altitude_report(path, isolation: "worktree") }
          .to raise_error(described_class::Refusal, /--isolation worktree/)
      end
    end

    it "refuses a journal given with no isolation name to resolve it for" do
      with_fixture do |path|
        expect { altitude_report(path, journal: Lain::Channel.new) }
          .to raise_error(ArgumentError, /journal/)
      end
    end
  end

  # One provider serves every arm, so its own records go to the one file this
  # comparison has: the journal its grades and leases land in.
  describe "#arms_report's provider" do
    let(:journal) { Lain::Channel.new }
    let(:backend) { Lain::CLI::Backend.new({ provider: "anthropic", max_tokens: 64 }, root: Dir.pwd) }
    let(:uncaching) do
      Lain::Provider::Mock.new(capabilities: [], responses: [text_response("FILE lib/widget.rb\nEND",
                                                                           usage: Lain::Usage.new(input_tokens: 8))])
    end

    def arms(**)
      cli.arms_report(fixture_path: File.join(__dir__, "..", "..", "fixtures", "arms", "tasks.yml"), backend:,
                      tools: Lain::Bench::Harness::NO_TOOLS, isolation: "none", **)
    end

    it "is built over the run's journal" do
      allow(backend).to receive(:provider).and_return(uncaching)

      arms(journal:)

      expect(backend).to have_received(:provider).with(journal:)
    end

    it "journals what the arms' context needs and the provider lacks, once" do
      allow(backend).to receive(:provider).and_return(uncaching)

      arms(journal:)

      expect(journal.drain.grep(Lain::Telemetry::CapabilityDegraded).map(&:capability)).to eq([:prompt_caching])
    end
  end

  # Ctrl-C reaching a live arm comparison mid-run: the money already spent on
  # the runs that finished must not be thrown away with the report that would
  # have summarized every arm, so an interrupt answers with the table so far.
  describe "#arms_report, interrupted" do
    let(:journal) { Lain::Channel.new }
    let(:backend) { Lain::CLI::Backend.new({ provider: "anthropic", max_tokens: 64 }, root: Dir.pwd) }

    def arms(**)
      cli.arms_report(fixture_path: File.join(__dir__, "..", "..", "fixtures", "arms", "tasks.yml"), backend:,
                      tools: Lain::Bench::Harness::NO_TOOLS, isolation: "none", journal:, **)
    end

    it "returns the PARTIAL table over the runs graded before the interrupt, instead of raising" do
      provider = InterruptingProvider.new(allow: 2, responses: [text_response("FILE lib/widget.rb\nEND")])
      allow(backend).to receive(:provider).and_return(provider)

      report = arms

      expect(report).to start_with("Arm driver -- PARTIAL, interrupted after 2 graded runs")
      expect(report.lines.count { |line| line.match?(/\A\d+\s/) }).to eq(2)
    end

    # A run graded BEFORE the interrupt still journals its own
    # Telemetry::GradeRecord into the real `--journal` -- the observing wrap
    # {Bench::CLI#arms_report} builds changes nothing about what {Arm::Driver}
    # itself records.
    it "still journals every grade that landed before the interrupt" do
      provider = InterruptingProvider.new(allow: 1, responses: [text_response("FILE lib/widget.rb\nEND")])
      allow(backend).to receive(:provider).and_return(provider)

      arms

      expect(journal.drain.grep(Lain::Telemetry::GradeRecord).size).to eq(1)
    end
  end

  # An agent that loops past its iteration ceiling has FAILED that task; it is
  # not a crash of the comparison, and the money spent on every other run is
  # still owed a report.
  describe "#arms_report, when a task hits the iteration ceiling" do
    let(:journal) { Lain::Channel.new }
    let(:backend) { Lain::CLI::Backend.new({ provider: "anthropic", max_tokens: 64 }, root: Dir.pwd) }
    let(:looping) do
      unresolved = { "type" => "tool_use", "id" => "t1", "name" => "nothing", "input" => {} }
      loop_turn = Lain::Response.new(content: [unresolved], stop_reason: :tool_use,
                                     usage: Lain::Usage.new(input_tokens: 1))
      Lain::Provider::Mock.new(responses: [*[loop_turn] * 30, text_response("FILE lib/widget.rb\nEND")])
    end
    let(:report) do
      allow(backend).to receive(:provider).and_return(looping)
      cli.arms_report(fixture_path: File.join(__dir__, "..", "..", "fixtures", "arms", "tasks.yml"), backend:,
                      tools: Lain::Bench::Harness::NO_TOOLS, isolation: "none", journal:)
    end

    it "still renders the header, every metric table and the cost column" do
      expect(report).to include("Arm driver", "grader score", "total tokens", "cost (USD)")
    end

    it "marks the failed arm's cell with the reason instead of a distribution" do
      expect(report.lines.grep(/single-thread/).first).to include("failed", "ceiling")
    end

    it "journals a failing grade record naming the ceiling" do
      report
      failed = journal.drain.grep(Lain::Telemetry::GradeRecord).reject(&:pass)

      expect(failed.map(&:why)).to include(a_string_matching(/ceiling/))
    end
  end

  # The containing set is ENUMERATED rather than derived, which is only safe if
  # something reddens when the advertised set grows. This is that something.
  describe "which isolation backends contain a write" do
    it "names only backends the resolver actually advertises" do
      expect(Lain::CLI::IsolationBackend::BACKENDS).to include(*described_class::CONTAINING_BACKENDS)
    end

    # THE FAIL-CLOSED HALF. A backend added upstream lands here as UNCONTAINED
    # until somebody rules on it, and this example is where they are told to.
    it "leaves every other advertised backend uncontained, so a new one must be ruled on" do
      unruled = Lain::CLI::IsolationBackend::BACKENDS - described_class::CONTAINING_BACKENDS

      expect(unruled).to eq([Lain::CLI::IsolationBackend::DEFAULT])
    end
  end

  describe "#record" do
    let(:usage) { Lain::Usage.new(input_tokens: 120, output_tokens: 30) }

    # The last mock response repeats once exhausted, so one script drives
    # every run of the sweep.
    let(:provider) do
      Lain::Provider::Mock.new(responses: [text_response("325-650 mg q4h", usage:,
                                                                           model: "claude-sonnet-4-6")])
    end

    # The ONE object record now takes for its provider and its Context, built the
    # way exe/lain and every other Backend spec build it: from the flag hash.
    # `max_tokens` is spelled out because Context requires it (`Integer(nil)`
    # raises) and RECORD_DEFAULTS is where the exe's flag reads its own default
    # from, so this is the same number a run gets.
    def backend(**options)
      Lain::CLI::Backend.new(
        { provider: "anthropic", max_tokens: described_class::RECORD_DEFAULTS.fetch(:max_tokens), **options },
        root: Dir.pwd
      )
    end

    def write_taskfile(dir)
      File.join(dir, "task.txt").tap do |path|
        File.write(path, "what is the aspirin dosing?\n\n  \n")
      end
    end

    # A REAL Agent::PipelineSource, not a double: the claim is that a bench run
    # can now render through a live compaction source and that the source's own
    # per-turn record reaches the session file the sweeps read back.
    def compacting_harness
      lambda do |journal:, recorder:, worker_env:|
        source = Lain::Compaction::Source.new(
          need: Lain::Compaction::Need.new(byte_threshold: 1),
          cold: Lain::Compaction::Cold.new(cache_profile: { ttl: 300 }, journal:),
          hard_cap: 1_048_576, keep_last: 20, journal:
        )
        Lain::Bench::Harness::INSTRUMENTATION.call(journal:, recorder:, worker_env:)
                                             .with(pipeline_source: source)
      end
    end

    it "records n loadable sessions through the injected provider, one numbered file per run" do
      Dir.mktmpdir do |tmp|
        out = File.join(tmp, "sessions")
        paths = cli.record(taskfile: write_taskfile(tmp), runs: 2, out:,
                           backend: backend(model: "claude-sonnet-4-6"), provider:)

        expect(paths).to eq([File.join(out, "1.ndjson"), File.join(out, "2.ndjson")])
        recordings = paths.map { |path| Lain::Bench::Session.load(path) }
        expect(recordings.map { |recording| recording.timeline.to_a.map(&:role) })
          .to all(eq(%w[user assistant]))
      end
    end

    it "asks one prompt per non-blank task file line, per run" do
      Dir.mktmpdir do |tmp|
        cli.record(taskfile: write_taskfile(tmp), runs: 2, out: File.join(tmp, "sessions"),
                   backend: backend(model: "claude-sonnet-4-6"), provider:)
        expect(provider.call_count).to eq(2)
        expect(provider.requests.map { |request| request.messages.size }).to all(eq(1))
      end
    end

    # THE CARD'S SUBJECT. Both bench agent sites passed `Toolset.new([])` and no
    # `instrumentation:`, so no bench run had ever executed with tools, a context
    # strategy or compaction -- every number the bench produced measured the
    # model, against a project whose thesis is that the harness sets the score.
    # `bench record` leases nothing -- no --isolation, no worker env, no
    # checkout of its own -- so the toolless harness is the only one it may
    # default to, and the recorded session is what says which side of that line
    # a number came from.
    it "records a toolless run by default, and the session says so" do
      Dir.mktmpdir do |tmp|
        out = File.join(tmp, "sessions")
        paths = cli.record(taskfile: write_taskfile(tmp), runs: 1, out:, backend:, provider:)

        expect(provider.requests.first.tools).to be_empty
        expect(Lain::Bench::Session.load(paths.first).toolset.to_schema).to be_empty
      end
    end

    # THE HUMAN'S RULING, made unrepresentable rather than documented: a
    # capability set that can act outside the run's own memory, with nothing
    # isolating where it acts, is refused at the door.
    it "refuses a writing toolset, because it has nothing to isolate one with" do
      Dir.mktmpdir do |tmp|
        expect do
          cli.record(taskfile: write_taskfile(tmp), runs: 1, out: File.join(tmp, "sessions"),
                     backend:, provider:, tools: Lain::Bench::Harness::TOOLS)
        end.to raise_error(described_class::Refusal, /can write.*nothing isolates/m)
      end
    end

    it "writes nothing at all when it refuses the pair" do
      Dir.mktmpdir do |tmp|
        out = File.join(tmp, "sessions")
        FileUtils.mkdir_p(out)
        suppress(described_class::Refusal) do
          cli.record(taskfile: write_taskfile(tmp), runs: 1, out:, backend:, provider:,
                     tools: Lain::Bench::Harness::TOOLS)
        end

        expect(Dir.children(out)).to be_empty
      end
    end

    # The recorder can carry the real floor, and a caller has to ASK for it --
    # RunRecorder spawns on WorkerEnv.default, so nothing it is handed is
    # contained and its own default is toolless for that reason.
    it "records a run through the real floor when the recorder is explicitly given one" do
      Dir.mktmpdir do |tmp|
        recorder = described_class::RunRecorder.new(
          provider:, context: backend(model: "claude-sonnet-4-6").context,
          attribution: Lain::Telemetry::SlotFills.from(backend.slots), prompts: ["what is the aspirin dosing?"],
          tools: Lain::Bench::Harness::TOOLS
        )
        recorder.record(File.join(tmp, "1.ndjson"))

        expect(provider.requests.first.tools.map { |tool| tool["name"] })
          .to include("write_file", "read_file", "bash")
      end
    end

    it "records a toolless run when the recorder is built with no tools named" do
      Dir.mktmpdir do |tmp|
        recorder = described_class::RunRecorder.new(
          provider:, context: backend.context,
          attribution: Lain::Telemetry::SlotFills.from(backend.slots), prompts: ["what is the aspirin dosing?"]
        )
        recorder.record(File.join(tmp, "1.ndjson"))

        expect(provider.requests.first.tools).to be_empty
      end
    end

    # The other half of the harness: WHICH Context each turn rendered through.
    # PipelineSource::Null applied everywhere before this, so no bench run had a
    # context strategy at all -- and a strategy that leaves no record is a
    # measurement a comparison cannot attribute.
    it "records which pipeline rendered each request when one is wired" do
      Dir.mktmpdir do |tmp|
        out = File.join(tmp, "sessions")
        paths = cli.record(taskfile: write_taskfile(tmp), runs: 1, out:, backend:, provider:,
                           instrumentation: compacting_harness)

        types = File.readlines(paths.first).map { |line| JSON.parse(line)["type"] }
        expect(types).to include("compaction_decision")
      end
    end

    it "records sessions Variance can report over" do
      Dir.mktmpdir do |tmp|
        out = File.join(tmp, "sessions")
        cli.record(taskfile: write_taskfile(tmp), runs: 2, out:,
                   backend: backend(model: "claude-sonnet-4-6"), provider:)
        expect(cli.variance_report([out])).to include("== Distribution ==")
      end
    end

    # The mirror image of the fixtures' idempotence: fixtures REPLACE because
    # they are scripted and free, but a recorded session cost real money, so
    # an occupied path REFUSES -- Journal.open appends, and a second header in
    # one file would destroy both sweeps' loadability.
    it "refuses to overwrite an existing session file, leaving the recorded bytes untouched" do
      Dir.mktmpdir do |tmp|
        out = File.join(tmp, "sessions")
        record = -> { cli.record(taskfile: write_taskfile(tmp), runs: 2, out:, backend:, provider:) }
        before = record.call.map { |path| File.binread(path) }

        expect { record.call }.to raise_error(described_class::Refusal, /already exists/)
        expect(Dir.children(out).sort.map { |name| File.binread(File.join(out, name)) }).to eq(before)
      end
    end

    # A money-spending command must not read `-n 0` as instant success.
    it "refuses a run count below one" do
      Dir.mktmpdir do |tmp|
        expect { cli.record(taskfile: write_taskfile(tmp), runs: 0, out: tmp, backend:, provider:) }
          .to raise_error(described_class::Refusal, /at least one run/)
      end
    end

    # Integer(2.5) truncates to 2 -- on a money-spending sweep, `-n 2.5` must
    # refuse rather than quietly record fewer runs than typed.
    it "refuses a fractional run count rather than truncating it" do
      Dir.mktmpdir do |tmp|
        expect { cli.record(taskfile: write_taskfile(tmp), runs: 2.5, out: tmp, backend:, provider:) }
          .to raise_error(described_class::Refusal, /whole number/)
      end
    end

    # A name outside the advertised set is a typo on a money-spending command,
    # and reading it as the default would silently measure a different run.
    it "refuses a --memory name that is not a memory source" do
      Dir.mktmpdir do |tmp|
        expect { cli.record(taskfile: write_taskfile(tmp), runs: 1, out: tmp, backend:, provider:, memory: "store") }
          .to raise_error(described_class::Refusal, /empty or project/)
      end
    end

    # The invariant CLI::Wiring#project_memory states, held on the bench too: a
    # sweep run from a subdirectory must measure recall against the memory of
    # the project it is in, not against an empty store nobody ever wrote to.
    it "keys --memory project to the project root, not to the process's cwd" do
      Dir.mktmpdir do |tmp|
        was = ENV.fetch("XDG_STATE_HOME", nil)
        ENV["XDG_STATE_HOME"] = tmp
        root = File.join(tmp, "proj")
        nested = File.join(root, "lib", "deep")
        FileUtils.mkdir_p(File.join(root, ".lain"))
        FileUtils.mkdir_p(nested)
        at_root = Lain::Memory::ProjectStore.new(project_dir: Lain::ProjectDir.new(root:))
        at_root.append(Lain::Memory::Item.new(id: "db-conventions", description: "naming", body: "snake"))

        out = File.join(tmp, "sessions")
        FileUtils.mkdir_p(out)
        path = Dir.chdir(nested) do
          cli.record(taskfile: write_taskfile(tmp), runs: 1, out:, backend:, provider:, memory: "project").first
        end
        records = File.foreach(path).map { |line| JSON.parse(line) }
        loaded = records.find { |record| record["type"] == "memory_loaded" }

        expect(loaded.fetch("version")).to eq(at_root.load.version)
      ensure
        ENV["XDG_STATE_HOME"] = was
      end
    end

    it "refuses a missing task file with a Refusal, not a raw ENOENT" do
      Dir.mktmpdir do |tmp|
        expect { cli.record(taskfile: File.join(tmp, "absent.txt"), runs: 2, out: tmp, backend:, provider:) }
          .to raise_error(described_class::Refusal, /no task file/)
      end
    end

    it "refuses a task file with no prompts" do
      Dir.mktmpdir do |tmp|
        blank = File.join(tmp, "task.txt")
        File.write(blank, "\n \n")
        expect { cli.record(taskfile: blank, runs: 2, out: tmp, backend:, provider:) }
          .to raise_error(described_class::Refusal, /no prompts/)
      end
    end

    # The default wiring builds the REAL provider and spends money, so it is
    # key-gated up front; an injected provider is the caller's own liability
    # (that is how the offline examples above run keyless).
    it "refuses to build the real provider without ANTHROPIC_API_KEY" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return(nil)
      Dir.mktmpdir do |tmp|
        expect { cli.record(taskfile: write_taskfile(tmp), runs: 2, out: tmp, backend:) }
          .to raise_error(described_class::MissingAPIKey, /ANTHROPIC_API_KEY/)
      end
    end

    # Chat and record resolve providers through the SAME Backend, so an
    # unknown --provider name raises the one named Lain error from either path,
    # never Thor::Error out of lib/.
    it "raises Lain::CLI::UnknownProvider on an unknown --provider name" do
      Dir.mktmpdir do |tmp|
        expect { cli.record(taskfile: write_taskfile(tmp), runs: 2, out: tmp, backend: backend(provider: "gemini")) }
          .to raise_error(Lain::CLI::UnknownProvider, /gemini/)
      end
    end

    # The provider `record` builds for itself, over the wire: its own records
    # have to reach the file of the run they happened in.
    describe "the provider the backend builds" do
      def stub_unterminated_stream
        stub_request(:post, "http://localhost:11434/api/chat")
          .to_return(status: 200, headers: { "Content-Type" => "application/x-ndjson" },
                     body: "#{JSON.generate("model" => "qwen3:4b", "done" => false,
                                            "message" => { "role" => "assistant", "content" => "par" })}\n")
      end

      def types_in(path) = File.foreach(path).map { |line| JSON.parse(line)["type"] }

      it "lands a truncated stream in the run file it cut short" do
        stub_unterminated_stream
        Dir.mktmpdir do |tmp|
          paths = cli.record(taskfile: write_taskfile(tmp), runs: 1, out: File.join(tmp, "sessions"),
                             backend: backend(provider: "ollama", model: "qwen3:4b"))

          expect(types_in(paths.first)).to include("truncated_stream", "capability_degraded")
        end
      end

      it "gives every run file its own capability record" do
        stub_unterminated_stream
        Dir.mktmpdir do |tmp|
          paths = cli.record(taskfile: write_taskfile(tmp), runs: 2, out: File.join(tmp, "sessions"),
                             backend: backend(provider: "ollama", model: "qwen3:4b"))

          expect(paths.map { |path| types_in(path).count("capability_degraded") }).to eq([1, 1])
        end
      end
    end

    # A run the provider refuses mid-sweep costs that run, not the sweep.
    describe "a failed run" do
      let(:failing) do
        Class.new(Lain::Provider::Mock) do
          def complete(request, **)
            return super if @refused

            @refused = true
            raise Lain::Provider::Ollama::APIError, "connection refused"
          end
        end
      end

      def record_with_first_failing(tmp, runs:)
        File.join(tmp, "sessions").tap do |out|
          cli.record(taskfile: write_taskfile(tmp), runs:, out:, backend: backend(model: "claude-sonnet-4-6"),
                     provider: failing.new(responses: [text_response("325-650 mg q4h", usage:,
                                                                                       model: "claude-sonnet-4-6")]))
        end
      end

      it "sets run 1 aside, records run 2, and variance names run 1 as failed" do
        Dir.mktmpdir do |tmp|
          out = record_with_first_failing(tmp, runs: 2)

          expect(Dir.children(out).sort).to eq(%w[1.failed.ndjson 2.ndjson])
          expect { cli.variance_report([out]) }
            .to raise_error(described_class::Refusal, /1\.failed\.ndjson: failed.*at least two/m)
        end
      end

      it "reports over the runs that recorded, listing the failed one apart with why it failed" do
        Dir.mktmpdir do |tmp|
          report = cli.variance_report([record_with_first_failing(tmp, runs: 3)])

          expect(report).to start_with("Variance — 2 recordings")
          expect(report).to match(/== Set aside ==\n.*1\.failed\.ndjson: failed recording /)
          expect(report).to include("(Lain::Provider::Ollama::APIError: connection refused)")
        end
      end

      it "says which run was set aside, and why, where it would have named the path" do
        Dir.mktmpdir do |tmp|
          out = File.join(tmp, "sessions")
          said = cli.record(taskfile: write_taskfile(tmp), runs: 2, out:, backend: backend(model: "claude-sonnet-4-6"),
                            provider: failing.new(responses: [text_response("fine", usage:)]))

          expect(said).to eq(["#{File.join(out, "1.failed.ndjson")} " \
                              "(set aside: Lain::Provider::Ollama::APIError: connection refused)",
                              File.join(out, "2.ndjson")])
        end
      end

      # A sweep that recorded nothing is not a success, whatever each run said.
      it "refuses when every run was set aside, naming each" do
        refusing = Class.new(Lain::Provider::Mock) do
          def complete(*) = raise(Lain::Provider::Ollama::APIError, "connection refused")
        end
        Dir.mktmpdir do |tmp|
          out = File.join(tmp, "sessions")

          expect do
            cli.record(taskfile: write_taskfile(tmp), runs: 2, out:, backend: backend(model: "m"),
                       provider: refusing.new)
          end.to raise_error(described_class::Refusal, /\Ano run recorded\n.*1\.failed\.ndjson.*\n.*2\.failed\.ndjson/)
          expect(Dir.children(out).sort).to eq(%w[1.failed.ndjson 2.failed.ndjson])
        end
      end

      it "refuses variance over a sweep that recorded nothing without a bare path prefix" do
        refusing = Class.new(Lain::Provider::Mock) do
          def complete(*) = raise(Lain::Provider::Ollama::APIError, "connection refused")
        end
        Dir.mktmpdir do |tmp|
          out = File.join(tmp, "sessions")
          suppress(described_class::Refusal) do
            cli.record(taskfile: write_taskfile(tmp), runs: 2, out:, backend: backend(model: "m"),
                       provider: refusing.new)
          end

          expect { cli.variance_report([out]) }.to raise_error(described_class::Refusal) { |refusal|
            expect(refusal.message.lines.map(&:strip)).to all(satisfy { |line| !line.start_with?(":") })
            expect(refusal.message.lines.last).to start_with("variance needs at least two recordings")
          }
        end
      end
    end

    # A killed process leaves a run with no header. It is listed, never a
    # reason to refuse every other recording beside it.
    it "lists a session file with no header as set aside rather than refusing the directory" do
      Dir.mktmpdir do |tmp|
        out = File.join(tmp, "sessions")
        cli.record(taskfile: write_taskfile(tmp), runs: 2, out:, backend: backend(model: "claude-sonnet-4-6"),
                   provider:)
        headerless = File.foreach(File.join(out, "2.ndjson")).reject { |line| JSON.parse(line)["type"] == "session" }
        File.write(File.join(out, "3.ndjson"), headerless.join)

        report = cli.variance_report([out])

        expect(report).to start_with("Variance — 2 recordings")
        expect(report).to match(/== Set aside ==\n.*3\.ndjson: no session header/)
      end
    end

    # A copy of a recorded run whose every turn answered with no usage, beside
    # the record a stream that stopped without its `done` line leaves.
    def write_unmeasured(from, to)
      zeroed = { "input_tokens" => 0, "output_tokens" => 0 }
      records = File.foreach(from).map do |line|
        record = JSON.parse(line)
        record["type"] == "turn_usage" ? record.merge("usage" => zeroed) : record
      end
      truncated = { "type" => "truncated_stream", "kind" => "unterminated", "request_digest" => "blake3:ab",
                    "frames" => 1, "accumulated_bytes" => 3, "tool_calls" => 0 }
      File.write(to, [*records, truncated].map { |record| "#{JSON.generate(record)}\n" }.join)
    end

    # A stream cut short answers with no usage at all, and averaged in it reads
    # as a free run.
    it "leaves a zero-usage run beside a truncated stream out of variance, and names it" do
      Dir.mktmpdir do |tmp|
        out = File.join(tmp, "sessions")
        cli.record(taskfile: write_taskfile(tmp), runs: 2, out:, backend: backend(model: "claude-sonnet-4-6"),
                   provider:)
        write_unmeasured(File.join(out, "2.ndjson"), File.join(out, "3.ndjson"))

        report = cli.variance_report([out])

        expect(report).to start_with("Variance — 2 recordings")
        expect(report).to match(/== Set aside ==\n.*3\.ndjson: no usage recorded beside a truncated stream/)
      end
    end

    # The counter-example: a stream cut short on a run that still paid for
    # tokens measured something, and stays in the distribution.
    it "keeps a run with usage beside a truncated stream in variance" do
      Dir.mktmpdir do |tmp|
        out = File.join(tmp, "sessions")
        cli.record(taskfile: write_taskfile(tmp), runs: 2, out:, backend: backend(model: "claude-sonnet-4-6"),
                   provider:)
        File.write(File.join(out, "2.ndjson"),
                   "#{JSON.generate("type" => "truncated_stream", "kind" => "unterminated",
                                    "request_digest" => "blake3:ab", "frames" => 1, "accumulated_bytes" => 3,
                                    "tool_calls" => 0)}\n", mode: "a")

        report = cli.variance_report([out])

        expect(report).to start_with("Variance — 2 recordings")
        expect(report).not_to include("Set aside")
      end
    end

    # An ollama temp-0 arm records. The provider is stubbed (money), but
    # the sampler flags ride the Context into Request#extra, so the recorded
    # session HEADER carries them and the recording still replays dry.
    describe "an ollama temp-0 arm" do
      it "records the sampler extra into the session header and replays dry" do
        Dir.mktmpdir do |tmp|
          out = File.join(tmp, "sessions")
          cli.record(taskfile: write_taskfile(tmp), runs: 1, out:, provider:,
                     backend: backend(provider: "ollama", temperature: 0, seed: 7))

          recording = Lain::Bench::Session.load(File.join(out, "1.ndjson"))
          expect(recording.context.extra).to include("temperature" => 0, "seed" => 7)
          expect { recording.dry_replay }.not_to raise_error
        end
      end
    end

    # The orchestrator amendment: bench record owns slot_fills emission. Each
    # recorded journal carries EXACTLY ONE slot_fills record, built from the
    # slots the Backend's context rendered, and Loader#slot_fills reads it back.
    describe "slot attribution" do
      def slot_fills_count(path)
        File.readlines(path).map { |line| JSON.parse(line) }.count { |record| record["type"] == "slot_fills" }
      end

      it "emits exactly one slot_fills record per recorded session" do
        Dir.mktmpdir do |tmp|
          out = File.join(tmp, "sessions")
          paths = cli.record(taskfile: write_taskfile(tmp), runs: 2, out:,
                             backend: backend(model: "claude-sonnet-4-6"), provider:)

          expect(paths.map { |path| slot_fills_count(path) }).to all(eq(1))
        end
      end

      it "records fills Loader#slot_fills reads back as the session's attribution" do
        Dir.mktmpdir do |tmp|
          out = File.join(tmp, "sessions")
          cli.record(taskfile: write_taskfile(tmp), runs: 1, out:,
                     backend: backend(model: "claude-sonnet-4-6"), provider:)

          loader = Lain::Bench::Session::Loader.new(File.foreach(File.join(out, "1.ndjson")))
          expect(loader.slot_fills.digests).not_to be_empty
        end
      end

      # The attribution's one claim is the JOIN: digests["system"] content-
      # addresses the system bytes the request_sent records journal in full
      # (the join-guard idiom). That must hold under --system too -- an
      # override renders INSTEAD of the slots, so a record still carrying the
      # untouched slots' digests would be a coherent-looking lie.
      def journaled_system_text(records)
        payload_system = records.find { |record| record["type"] == "request_sent" }
                                .fetch("payload").fetch("system")
        return payload_system if payload_system.is_a?(String)

        payload_system.map { |block| block.fetch("text") }.join
      end

      it "attributes a --system override so the digest still joins onto the journaled system bytes" do
        Dir.mktmpdir do |tmp|
          out = File.join(tmp, "sessions")
          cli.record(taskfile: write_taskfile(tmp), runs: 1, out:, system: "Reply with one word.",
                     backend: backend(model: "claude-sonnet-4-6"), provider:)

          records = File.readlines(File.join(out, "1.ndjson")).map { |line| JSON.parse(line) }
          slot_fills = records.find { |record| record["type"] == "slot_fills" }
          expect(slot_fills.fetch("digests").fetch("system"))
            .to eq(Lain::Canonical.digest(journaled_system_text(records)))
          expect(slot_fills.fetch("fills").fetch("system")).to eq("Reply with one word.")
        end
      end

      it "attributes the default slot render so the digest joins onto the journaled system bytes" do
        Dir.mktmpdir do |tmp|
          out = File.join(tmp, "sessions")
          cli.record(taskfile: write_taskfile(tmp), runs: 1, out:,
                     backend: backend(model: "claude-sonnet-4-6"), provider:)

          records = File.readlines(File.join(out, "1.ndjson")).map { |line| JSON.parse(line) }
          expect(records.find { |record| record["type"] == "slot_fills" }.fetch("digests").fetch("system"))
            .to eq(Lain::Canonical.digest(journaled_system_text(records)))
        end
      end
    end
  end
end
