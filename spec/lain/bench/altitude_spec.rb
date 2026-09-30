# frozen_string_literal: true

require "bigdecimal"
require "fileutils"
require "tmpdir"
require "yaml"

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).

# The narrowest ledger duck the cache-write metric needs: it ignores the
# timeline and answers a fixed Usage, so a scripted arm can carry a genuinely
# fixed cache-write figure with no Store machinery at all (driver_spec's shape).
class AltitudeSpecLedger
  def initialize(cache_creation_input_tokens:)
    @usage = Lain::Usage.new(input_tokens: 100, output_tokens: 20, cache_creation_input_tokens:)
  end

  def usage(_timeline) = @usage
  def cost(_timeline) = BigDecimal("0.01")
end

# What a linear arm hands back: the four metrics every topology answers, and
# nothing else. It deliberately does NOT answer rework or round-trips -- those
# are an epic's facts, and this is how "unmeasured ones say so" gets a subject.
class AltitudeSpecRun
  def initialize(arm:, score:, tokens:, elapsed:, cache: 0)
    @arm = arm
    @score = score
    @tokens = tokens
    @elapsed = elapsed
    @ledger = AltitudeSpecLedger.new(cache_creation_input_tokens: cache)
  end

  attr_reader :arm, :score, :elapsed, :ledger

  def total_tokens = @tokens
  def timeline = nil
  def cost = BigDecimal("0.01")
  def grade = Lain::Grader::Grade.new(score: @score, pass: @score >= 1.0, why: "scripted")
end

# What an epic arm hands back: everything above, plus the two metrics only a
# gated topology has.
class AltitudeSpecEpicRun < AltitudeSpecRun
  def initialize(rework: 0, round_trips: 0, **rest)
    super(**rest)
    @rework = rework
    @round_trips = round_trips
  end

  def rework_total = @rework
  def round_trips_total = @round_trips
end

# A scripted arm: it records every task it was asked, in order, into a shared
# log, so "the warning preceded the first arm" is an ordering fact rather than
# an assumption.
class AltitudeSpecArm
  def initialize(name, log, epic: false, score: 1.0)
    @name = name
    @log = log
    @epic = epic
    @score = score
  end

  attr_reader :name

  def run(task, **)
    @log << [:ran, @name, task]
    return AltitudeSpecRun.new(arm: @name, score: @score, tokens: 100, elapsed: 1.0) unless @epic

    AltitudeSpecEpicRun.new(arm: @name, score: @score, tokens: 300, elapsed: 2.0, cache: 40,
                            rework: 1, round_trips: 3)
  end
end

# An arm that really leases what it is handed and really grades with the judge
# the bench built for that task -- which is what makes "the subject project
# reaches the arm" an assertion rather than a claim. It stands in for a live
# arm's body: lease, work, grade, release.
class AltitudeSubjectArm
  def initialize(name, seen)
    @name = name
    @seen = seen
  end

  attr_reader :name

  def run(task, grading:, isolation:, **)
    lease = isolation.acquire(@name)
    cwd = lease.worker_env.cwd
    grade = grading.call(lease:, grader: nil).grade(:ignored_trajectory)
    @seen << { id: task[/refund/] ? "order-total" : "invoice-lines", cwd:, grade:,
               holds_subject: File.exist?(File.join(cwd, "Gemfile")) && Dir.exist?(File.join(cwd, "spec/unit")),
               score: grade.score, why: grade.why }
    AltitudeSpecRun.new(arm: @name, score: grade.score, tokens: 100, elapsed: 1.0)
  ensure
    lease&.release
  end
end

# An arm that asks for its judge BEFORE it touches the checkout, which is the
# order a lease holding none has to be refused through: reaching for the cwd
# first would die of NoMethodError on nil instead.
class AltitudeJudgeFirstArm
  def initialize(name) = (@name = name)

  attr_reader :name

  def run(_task, grading:, isolation:, **)
    grading.call(lease: isolation.acquire(@name), grader: nil)
    raise "a lease holding no checkout should have been refused before this"
  end
end

# A sink that records what was said to it, so the cost warning is observable
# without anything reaching $stdout -- only the frontend may touch that.
class AltitudeSpecSink
  def initialize(log) = (@log = log)

  # Each of these records rather than delegating to its sibling: a bare `puts`
  # call inside this class reads to RSpec/Output as a spec writing to stdout,
  # which is the very thing a sink stand-in exists to make impossible.
  def puts(*args)
    record(args.join(" "))
    nil
  end

  def write(*args)
    record(args.join)
    args.sum { |arg| arg.to_s.bytesize }
  end

  def print(*args)
    record(args.join)
    nil
  end

  def <<(obj)
    record(obj.to_s)
    self
  end

  def flush = self

  private

  def record(said) = @log << [:said, said]
end

# `lain bench altitude` compares the four decomposition arms over a suite whose
# tasks sit on a SIZE axis, and reports each arm's distribution PER SIZE -- which
# is the whole question: where on that axis does entering higher up the ladder
# start paying for itself?
#
# It spends real money in production (four arms x every task, against a real
# provider), so every example here drives scripted arms and never resolves one.
RSpec.describe Lain::Bench::Altitude do
  let(:log) { [] }
  let(:sink) { AltitudeSpecSink.new(log) }

  let(:arms) do
    [AltitudeSpecArm.new("one-shot", log, score: 0.5),
     AltitudeSpecArm.new("plan-only", log, score: 0.75),
     AltitudeSpecArm.new("epic-progressive", log, epic: true, score: 1.0),
     AltitudeSpecArm.new("epic-hands-off", log, epic: true, score: 1.0)]
  end

  let(:grader) { Lain::Grader::Fixture.new("scripted") { |f| f.check("ran") { true } } }
  let(:spawn_seam) { ->(**) { raise "a scripted arm spawns nothing" } }

  def fixture_path = File.expand_path("../../fixtures/altitude/tasks.yml", __dir__)

  def altitude(**) = described_class.new(fixture_path:, arms:, spawn_seam:, grader:, sink:, **)

  # One titled, blank-line-separated block of the rendered report.
  def section_for(report, title) = report.split("\n\n").find { |block| block.start_with?("#{title}\n") }

  # The size banner's own block, and everything rendered under it up to the next
  # banner -- which is what "per task size" has to be read out of.
  def under_size(report, size)
    blocks = report.split("\n\n")
    start = blocks.index { |block| block.start_with?("== #{size} ==") }
    blocks.drop(start + 1).take_while { |block| !block.start_with?("== ") }
  end

  def row_in(block, arm) = block.lines.map(&:chomp).find { |line| line.start_with?("#{arm} ") }

  describe "#report — one row per arm, per task size" do
    # Scenario: the altitude report compares arms per task size and warns first.
    it "renders a section per size the fixture declares, in fixture order" do
      report = altitude.report

      expect(report).to include("== small ==").and include("== large ==")
      expect(report.index("== small ==")).to be < report.index("== large ==")
    end

    it "gives every arm a row under every size" do
      report = altitude.report

      %w[small large].each do |size|
        scores = under_size(report, size).find { |block| block.start_with?("grader score\n") }
        expect(arms.map(&:name)).to all(satisfy("a row under #{size}") { |arm| row_in(scores, arm) })
      end
    end

    it "runs every arm over every task in its own size, and no other" do
      altitude.report

      small = log.select { |entry| entry.first == :ran }.map(&:last).uniq
      expect(small.size).to eq(4)
      expect(log.count { |entry| entry.first == :ran }).to eq(arms.size * 4)
    end

    it "reports every metric the card names, as its own titled table" do
      report = altitude.report

      ["grader score", "total tokens", "cache write tokens", "wall-time (s)", "rework", "round-trips"]
        .each { |title| expect(report).to match(/^#{Regexp.escape(title)}\n/) }
    end

    it "returns a String and writes nothing to stdout or stderr" do
      report = nil

      expect { report = altitude.report }.to output("").to_stdout.and output("").to_stderr
      expect(report).to be_a(String)
    end

    it "renders byte-identical reports when the same instance reports twice" do
      bench = altitude

      expect(bench.report).to eq(bench.report)
    end
  end

  # "Mark absent, never fabricate": rework and round-trips are an epic's facts,
  # and a 0 in a linear arm's cell would read as "measured, and it was none"
  # rather than "this topology has no such number".
  describe "a metric a topology does not have" do
    it "says so in the linear arms' cells, and reports the epic arms' real figures" do
      report = altitude.report
      rework = under_size(report, "small").find { |block| block.start_with?("rework\n") }

      expect(row_in(rework, "one-shot")).to include("not measured")
      expect(row_in(rework, "plan-only")).to include("not measured")
      expect(row_in(rework, "epic-hands-off")).not_to include("not measured")
    end

    it "keeps the n column real for an unmeasured cell, so the row still says how many runs there were" do
      report = altitude.report
      rework = under_size(report, "small").find { |block| block.start_with?("rework\n") }

      expect(row_in(rework, "one-shot")).to match(/one-shot\s+2\s/)
    end
  end

  # Scenario (the first clause): the cost warning precedes the first arm.
  describe "it says what it is about to spend, before it spends it" do
    it "warns through the sink before any arm has run" do
      altitude.report

      expect(log.first.first).to eq(:said)
      expect(log.first.last).to match(/money|spend/i)
    end

    it "names all four arms and the task count it is about to run" do
      altitude.report

      expect(log.first.last).to include("4").and match(/task/i)
    end

    # The warning is the operator's, not the record's: a bench report is pasted
    # into an issue, and a spend warning inside it would read as a property of
    # the experiment rather than of the command that ran it.
    it "keeps the warning out of the returned report" do
      expect(altitude.report).not_to match(/spends real/i)
    end
  end

  # THE CARD'S FIRST GHERKIN, on an assembled path rather than in the grader's
  # own spec: an arm is graded by the SUBJECT'S own suite, in a checkout holding
  # that subject, narrowed to the task's level root.
  #
  # Without this the bench measures nothing it claims to: an arm with no lease
  # works in lain's own tree, and a transcript grader scores the words rather
  # than the code.
  describe "the subject project an arm actually works in", :seam do
    def committed(name) = File.expand_path("../../fixtures/altitude/subjects/#{name}", __dir__)

    # Two tasks at one size, pointing at the COMMITTED subject projects by
    # absolute path, so the suite is real without copying fixtures around.
    def with_subjects
      Dir.mktmpdir("lain-altitude-subjects") do |dir|
        path = File.join(dir, "tasks.yml")
        File.write(path, YAML.dump("tasks" => two_small_tasks))
        yield path
      end
    end

    def two_small_tasks
      [{ "id" => "order-total", "size" => "small", "subject" => committed("order-total"),
         "level" => "unit", "prompt" => "add a refund" },
       { "id" => "invoice-lines", "size" => "small", "subject" => committed("invoice-lines"),
         "level" => "unit", "prompt" => "net the invoice" }]
    end

    let(:seen) { [] }
    let(:arms) { [AltitudeSubjectArm.new("one-shot", seen)] }

    def bench_over(path) = described_class.new(fixture_path: path, arms:, spawn_seam:, grader:, sink:)

    # A lease's copy is deleted on release, so a refusal naming it would send
    # the human to a path that is gone -- and by then an arm has been paid for.
    it "refuses an untrusted subject before any arm runs, naming the committed project" do
      Dir.mktmpdir("lain-altitude-untrusted") do |state|
        with_env("XDG_STATE_HOME" => state) do
          expect { with_subjects { |path| bench_over(path).report } }
            .to raise_error(Lain::Project::Trust::Untrusted) { |error|
              expect(error.message).to include("lain trust #{committed("order-total")}",
                                               "lain trust #{committed("invoice-lines")}")
            }
        end
      end

      expect([seen, log]).to eq([[], []])
    end

    it "leases each arm a checkout holding that task's own subject project" do
      with_subjects { |path| bench_over(path).report }

      expect(seen.map { |run| run.fetch(:id) }).to contain_exactly("order-total", "invoice-lines")
      expect(seen.map { |run| run.fetch(:holds_subject) }).to all(be(true))
      # And it is a COPY: the arm must never be handed the committed fixture to
      # edit, or one run's work would leak into the next.
      expect(seen.map { |run| run.fetch(:cwd) }).to all(satisfy("outside the committed fixture") do |cwd|
        !cwd.start_with?(File.expand_path("../../fixtures", __dir__))
      end)
    end

    # order-total's unit root is 2 of 3 and its whole suite is 3 of 4, so the
    # score proves BOTH that the subject's own suite ran and that it was
    # narrowed to the task's level.
    it "grades the arm by that subject's own suite, narrowed to the task's level root" do
      with_subjects { |path| bench_over(path).report }

      graded = seen.find { |run| run.fetch(:id) == "order-total" }
      expect(graded.fetch(:score)).to eq(2.0 / 3)
      expect(graded.fetch(:why)).to include("refunds a line")
    end

    # Both small subjects grade 2 of 3 at their unit root, so the arm's row is
    # the mean of two real suite results -- 0.667, not a transcript's 1.000.
    it "puts that same score in the report rather than a transcript's" do
      report = with_subjects { |path| bench_over(path).report }

      expect(report).to match(/^one-shot\s+2\s+0\.667/)
    end
  end

  # The committed fixtures are DATA, and data rots quietly: a subject project
  # whose `[tests]` table was dropped, or an epic whose plans lost their
  # `Subject:` line, would leave the bench measuring nothing while every example
  # here still passed. Each of these pins a coupling that nothing else holds.
  describe "the committed fixtures" do
    def fixtures = File.expand_path("../../fixtures/altitude", __dir__)

    def committed_tasks = YAML.safe_load_file(File.join(fixtures, "tasks.yml")).fetch("tasks")

    def demo_epic
      Lain::Epic::Document.parse_markdown(File.read(File.join(fixtures, "epic/demo/epic.md")))
    end

    # The task suite and the subject projects are coupled by path and by level
    # name, and neither end knows about the other.
    it "gives every task a subject project declaring a layout with the level that task names" do
      committed_tasks.each do |task|
        layout = Lain::Config.test_layout(root: File.join(fixtures, task.fetch("subject")))

        expect(layout).to be_in_force
        expect(layout.mapping.level(task.fetch("level")).root).to eq("spec/unit")
      end
    end

    # Parsed through the real Document, because that grammar is what the driver
    # reads an epic back with -- and a hand-written heading that parses wrong
    # does so silently.
    it "carries an epic whose issues declare criteria and a blocking edge" do
      graph = demo_epic

      expect(graph.ids).to eq(%w[ledger report])
      expect(graph.blocked_by("report")).to eq(["ledger"])
      graph.each do |issue|
        expect(Lain::Gherkin::Criteria.parse(issue.criteria).scenarios).not_to be_empty
      end
    end

    # An issue actor places its failing tests by mirroring the subject its PLAN
    # declares. Without that line the epic arms refuse before they start, which
    # is the gap this fixture was built to close.
    it "gives every issue a plan declaring the subject its tests mirror" do
      artifact = Struct.new(:read, :path)

      declared = demo_epic.ids.to_h do |id|
        plan = File.join(fixtures, "epic/demo/plans/#{id}.md")
        [id, Lain::CLI::EpicDriver::PlanSubject.read(artifact.new(File.read(plan), plan),
                                                     layout: Lain::TestLayout::None)]
      end

      expect(declared.transform_values(&:subject)).to eq("ledger" => "lib/ledger.rb", "report" => "lib/report.rb")
      expect(declared.values.map(&:level).uniq).to eq(["unit"])
    end
  end

  describe "a suite it refuses" do
    def with_fixture(tasks, &block)
      Dir.mktmpdir("lain-altitude-fixture") do |dir|
        path = File.join(dir, "tasks.yml")
        File.write(path, YAML.dump("tasks" => tasks))
        yield path
      end
    end

    # A REAL subject project. These examples are about the fixture's SHAPE, and
    # subject paths are resolved in the same pre-flight, so an invented path
    # would refuse first and mask what each of them is actually pinning.
    def task(id, size)
      { "id" => id, "size" => size, "level" => "unit", "prompt" => "do #{id}",
        "subject" => File.expand_path("../../fixtures/altitude/subjects/order-total", __dir__) }
    end

    # A distribution needs n >= 2, the rule Arm::Driver states for the same
    # reason: one run is not a distribution, and reporting it as one invites a
    # comparison the sample cannot support.
    it "refuses a size carrying only one task, naming the size" do
      with_fixture([task("a", "small"), task("b", "small"), task("c", "large")]) do |path|
        bench = described_class.new(fixture_path: path, arms:, spawn_seam:, grader:, sink:)

        expect { bench.report }.to raise_error(Lain::Error, /"large" size carries 1 task/)
      end
    end

    it "refuses a task declaring no size, naming the task" do
      with_fixture([task("a", "small").tap { |entry| entry.delete("size") }, task("b", "small")]) do |path|
        bench = described_class.new(fixture_path: path, arms:, spawn_seam:, grader:, sink:)

        expect { bench.report }.to raise_error(described_class::MalformedTask, /"a"|size/)
      end
    end

    it "refuses a fixture that is not there, naming the path" do
      bench = described_class.new(fixture_path: "/nowhere/tasks.yml", arms:, spawn_seam:, grader:, sink:)

      expect { bench.report }.to raise_error(described_class::MissingFixture, %r{/nowhere/tasks\.yml})
    end

    # Ids are how a run is matched back to the task it was given, so a duplicate
    # would make one of the two unreachable rather than loud.
    it "refuses duplicate task ids" do
      with_fixture([task("a", "small"), task("a", "small")]) do |path|
        bench = described_class.new(fixture_path: path, arms:, spawn_seam:, grader:, sink:)

        expect { bench.report }.to raise_error(described_class::MalformedTask, /a/)
      end
    end

    # A fixture whose root is a SEQUENCE has no `tasks:` key to fetch at all,
    # and `[].fetch("tasks")` is a TypeError naming neither the file nor what it
    # wanted -- so it is refused like every other malformed fixture.
    it "refuses a fixture whose root is a sequence rather than a mapping" do
      Dir.mktmpdir("lain-altitude-fixture") do |dir|
        path = File.join(dir, "tasks.yml")
        File.write(path, YAML.dump([{ "id" => "a" }]))
        bench = described_class.new(fixture_path: path, arms:, spawn_seam:, grader:, sink:)

        expect { bench.report }.to raise_error(described_class::MalformedTask, /#{Regexp.escape(path)}/)
      end
    end

    # An empty suite is a fixture mistake, not a comparison of nothing. Left to
    # fall through it would be reported as a SIZE being too thin, which tells
    # the operator about a size when the problem is the file.
    it "refuses a fixture declaring no tasks at all, naming the file" do
      with_fixture([]) do |path|
        bench = described_class.new(fixture_path: path, arms:, spawn_seam:, grader:, sink:)

        expect { bench.report }.to raise_error(described_class::MalformedTask, /#{Regexp.escape(path)}/)
      end
    end

    # A REFUSAL MUST NOT FIRE MID-RUN. Resolving a subject lazily, inside the
    # run, meant a suite whose SECOND task named a missing project took the
    # whole report down with the first task's arms already spent -- while the
    # class promised a malformed suite costs nothing. Subject paths are pure
    # path work, so they are resolved in the pre-flight with everything else.
    it "refuses a missing subject project before the warning and before any arm has run" do
      Dir.mktmpdir("lain-altitude-missing") do |dir|
        path = File.join(dir, "tasks.yml")
        present = File.expand_path("../../fixtures/altitude/subjects/order-total", __dir__)
        File.write(path, YAML.dump("tasks" => [
                                     { "id" => "a", "size" => "small", "subject" => present,
                                       "level" => "unit", "prompt" => "do a" },
                                     { "id" => "b", "size" => "small", "subject" => "#{present}-is-not-there",
                                       "level" => "unit", "prompt" => "do b" }
                                   ]))
        bench = described_class.new(fixture_path: path, arms:, spawn_seam:, grader:, sink:)

        expect { bench.report }.to raise_error(Lain::Error, /altitude task "b" names the subject project/)
        # The shared log carries both the cost warning and every arm run, so an
        # empty one is the whole claim: nothing was said and nothing was spent.
        expect(log).to be_empty
      end
    end
  end

  # An injected isolation that leases no checkout is a wiring mistake, not a
  # reason to lose the report: the arm reads "not measured" like any other
  # unmeasurable cell, and its siblings still render.
  describe "an injected isolation that leases nothing" do
    it "reads not measured rather than taking the whole render down" do
      bench = described_class.new(fixture_path:, spawn_seam:, grader:, sink:,
                                  arms: [AltitudeJudgeFirstArm.new("one-shot")],
                                  isolation: Lain::Arm::NoIsolation)

      expect(bench.report).to match(/^one-shot\s+2\s+not measured/)
    end
  end

  # A count of one has to read as one. "1 sizes" is the seam that makes a report
  # look generated rather than written, and this report is an experiment record.
  describe "the header's counts" do
    it "says one size when every task shares one, and two when they do not" do
      one_size = with_one_size do |path|
        described_class.new(fixture_path: path, arms:, spawn_seam:, grader:, sink:).report
      end

      expect(one_size).to include("2 tasks over 1 size,")
      expect(one_size).not_to include("1 sizes")
      expect(altitude.report).to include("4 tasks over 2 sizes,")
    end

    def with_one_size(&block)
      Dir.mktmpdir("lain-altitude-header") do |dir|
        path = File.join(dir, "tasks.yml")
        File.write(path, YAML.dump("tasks" => one_size_tasks))
        yield path
      end
    end

    def one_size_tasks
      subject = File.expand_path("../../fixtures/altitude/subjects/order-total", __dir__)
      %w[a b].map do |id|
        { "id" => id, "size" => "small", "subject" => subject, "level" => "unit", "prompt" => "do #{id}" }
      end
    end
  end
end
