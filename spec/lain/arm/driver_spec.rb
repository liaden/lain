# frozen_string_literal: true

require "bigdecimal"

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module DriverSpecSupport
  FakeGrade = Struct.new(:score)

  # The narrowest ledger duck #value_of needs (`#usage(timeline)`,
  # `#cost(timeline)`) -- ignores the timeline entirely and answers a FIXED
  # value, so a {FixedCacheArm} can give a genuinely fixed cache-write figure
  # with no Timeline/Store machinery at all.
  class FixedLedger
    def initialize(cache_creation_input_tokens:)
      @usage = Lain::Usage.new(input_tokens: 100, output_tokens: 20, cache_creation_input_tokens:)
    end

    def usage(_timeline) = @usage
    def cost(_timeline) = BigDecimal("0.01")
  end

  # A concrete Arm whose #run returns a Run carrying a FIXED cache-write
  # figure, bypassing spawn_seam entirely -- the only way to give ONE arm in
  # a Driver comparison a genuinely different cache-write value than a
  # SIBLING arm, since the Driver threads one shared spawn_seam into every
  # arm it compares (`#distributions_for`).
  class FixedCacheArm < Lain::Arm
    def initialize(name:, cache_creation_input_tokens:)
      super(name:)
      @ledger = FixedLedger.new(cache_creation_input_tokens:)
    end

    def run(_task, spawn_seam:, grader:, isolation: NoIsolation) # rubocop:disable Lint/UnusedMethodArgument
      Lain::Arm::Run.new(arm: name, timeline: nil, grade: FakeGrade.new(1.0), elapsed: 0.1, ledger: @ledger)
    end
  end

  # Remembers every subject it was handed on its way to the real grader, so an
  # example can hold the journaled subject digest against the very Timeline
  # that was graded rather than against a shape assertion.
  class RecordingGrader
    attr_reader :subjects

    def initialize(inner)
      @inner = inner
      @subjects = []
    end

    def grade(subject)
      @subjects << subject
      @inner.grade(subject)
    end
  end
end

# The Driver runs N arms over a task suite and folds each arm's runs into its
# own per-metric distributions -- grader, tokens, wall-time, dollars -- laid side
# by side under a header naming what produced them. It reuses Compare's
# Distribution + Table (never reshaping Compare's surface) and runs entirely over
# Provider::Mock.
RSpec.describe Lain::Arm::Driver do
  # The seam the DRIVER threads into every arm, so it has to answer the widened
  # duck {Arm} documents (`call(journal:, **spawn_opts) -> Agent`) rather than
  # the narrowest arm's slice of it. A `journal:`-only lambda takes the control
  # arm and nothing else: {Arm::OrchestratorWorker} passes `base_timeline:`,
  # `worker_env:` and `spawned_from:`, {Arm::DualLedger} passes `workspace:` and
  # `timeline:`, and every one of those is an ArgumentError against fixed arity
  # -- so a Driver spec built on one could never drive an isolated arm at all.
  let(:spawn_seam) do
    lambda do |journal:, timeline: nil, base_timeline: nil, workspace: Lain::Workspace.empty, **|
      Lain::Agent.new(
        provider: Lain::Provider::Mock.new(
          responses: [text_response("done", model: "claude-sonnet-4",
                                            usage: Lain::Usage.new(input_tokens: 100, output_tokens: 20))]
        ),
        toolset: Lain::Toolset.new([]),
        context: Lain::Context.new(model: "claude-opus-4-8", max_tokens: 256),
        timeline: base_timeline || timeline, workspace:, journal:
      )
    end
  end

  let(:grader) do
    Lain::Grader::Fixture.new("settled") do |f|
      f.check("committed an assistant turn") { |timeline| timeline.to_a.map(&:role).include?("assistant") }
    end
  end

  let(:arms) { [Lain::Arm::SingleThread.new(name: "single-thread"), Lain::Arm::SingleThread.new(name: "control-b")] }
  let(:tasks) { ["procedural task", "another task"] }

  # The data row for one arm inside one metric's table, read off the rendered
  # bytes. Out here rather than inside one describe because the cost examples
  # and the spend examples read a row the same way, and a second copy is a
  # second thing to drift.
  def row_for(report, metric, arm)
    section_for(report, metric).lines.map(&:chomp).find { |line| line.start_with?("#{arm} ") }
  end

  # One titled, blank-line-separated block of the rendered report.
  def section_for(report, metric) = report.split("\n\n").find { |block| block.start_with?("#{metric}\n") }

  # A seam whose Context asks `model` and whose scripted response records
  # `response_model` -- the two are the SAME string in production and differ
  # under a mock, which is exactly what separates "what the header attributes"
  # from "what the cost column prices".
  def seam_for(model:, response_model: model)
    lambda do |journal:, timeline: nil, base_timeline: nil, workspace: Lain::Workspace.empty, **|
      usage = Lain::Usage.new(input_tokens: 100, output_tokens: 20)
      Lain::Agent.new(
        # `model: nil` and an omitted model are the same Response (it coerces
        # with `model&.to_s`), so the bare-mock case needs no branch here.
        provider: Lain::Provider::Mock.new(responses: [text_response("done", model: response_model, usage:)]),
        toolset: Lain::Toolset.new([]),
        context: Lain::Context.new(model:, max_tokens: 256),
        timeline: base_timeline || timeline, workspace:, journal:
      )
    end
  end

  describe "#report — arms compared distributionally" do
    subject(:report) { described_class.new(arms, tasks:, spawn_seam:, grader:).report }

    # No "is a String -- never touches stdout" example: it asserted only the
    # String half and left stdout unwatched. `bench/arms_report_spec.rb` makes
    # the real claim, with `output("").to_stdout` around the render.
    it "reports grader, tokens, and wall-time distributions" do
      expect(report).to include("grader score").and include("total tokens").and include("wall-time")
      expect(report).to include("mean").and include("median")
    end

    it "reports every arm, once per arm" do
      expect(report).to include("single-thread").and include("control-b")
    end

    it "folds each arm's suite into a distribution of n = the number of tasks" do
      # `n` is the suite size, and it sits beside the arm's own name on that
      # arm's row. Matched as a regex NEXT TO the name rather than by column
      # index, so this pins the number the Driver folded rather than
      # {Compare::Table}'s current column layout.
      expect(report).to match(/^single-thread\s+#{tasks.size}\s/)
      expect(report).to match(/^control-b\s+#{tasks.size}\s/)
    end

    it "renders byte-identical reports when the same instance reports twice" do
      driver = described_class.new(arms, tasks:, spawn_seam:, grader:)
      expect(driver.report).to eq(driver.report)
    end
  end

  # The bench's headline metric, and until now the one metric the arm
  # comparison did not carry -- `Arm::Run` folded usage and left cost to
  # `#compare_run`, which the Driver never calls.
  describe "#report — the cost column" do
    # Scenario: the arm report carries a cost column.
    #
    # Asserted against the PriceBook rather than a literal: the claim is "the
    # number in the report is the number this run's own Ledger produced", not
    # "sonnet costs $3/MTok" -- the table is meant to be edited, and a literal
    # here would fail on a correct price change.
    it "reports a cost column carrying the runs' own ledger cost" do
      report = described_class.new(arms, tasks:, spawn_seam:, grader:).report
      priced = Lain::PriceBook.default.cost("claude-sonnet-4",
                                            Lain::Usage.new(input_tokens: 100, output_tokens: 20))

      expect(report).to include("cost (USD)")
      expect(row_for(report, "cost (USD)", "single-thread")).to include(format("%.6f", priced))
    end

    # Scenario: cost is reported per arm.
    #
    # Three arms whose runs are byte-identical except for the price book their
    # own Instrument carries, so the ONLY way the rows can differ is the Driver
    # folding each arm's own Ledger. Equal usage on every arm is the point: a
    # driver reading one shared ledger, or pricing off the first arm's, still
    # produces three rows and would pass a "three rows exist" assertion.
    it "prices each arm through its own ledger rather than one shared figure" do
      dear = Lain::PriceBook.new(
        prices: { "sonnet" => Lain::Price.per_mtok(input: 30, output: 150, cache_creation: 37.5, cache_read: 3) }
      )
      priced = [Lain::Arm::SingleThread.new(name: "list-price"),
                Lain::Arm::SingleThread.new(name: "ten-x",
                                            instrument: Lain::Arm::Instrument.new(price_book: dear)),
                Lain::Arm::SingleThread.new(name: "list-price-b")]

      report = described_class.new(priced, tasks:, spawn_seam:, grader:).report
      cheap = Lain::PriceBook.default.cost("claude-sonnet-4", Lain::Usage.new(input_tokens: 100, output_tokens: 20))

      expect(row_for(report, "cost (USD)", "list-price")).to include(format("%.6f", cheap))
      expect(row_for(report, "cost (USD)", "list-price-b")).to include(format("%.6f", cheap))
      expect(row_for(report, "cost (USD)", "ten-x")).to include(format("%.6f", cheap * 10))
    end
  end

  # Arm::Driver::METRICS gains cache write tokens, the arm's own token-
  # accounting answer to the same "what did this cost" question `total
  # tokens` asks -- priced not in dollars but in the prefix a stage's
  # compaction had to rewrite. Labeled to match Compare::METRICS'
  # `cache_write_tokens` row (`compare.rb`'s own `"cache write tokens"`).
  describe "#report — the cache write tokens column" do
    def cache_seam_for(cache_creation_input_tokens:)
      lambda do |journal:, timeline: nil, base_timeline: nil, workspace: Lain::Workspace.empty, **|
        usage = Lain::Usage.new(input_tokens: 100, output_tokens: 20, cache_creation_input_tokens:)
        Lain::Agent.new(
          provider: Lain::Provider::Mock.new(responses: [text_response("done", model: "claude-sonnet-4", usage:)]),
          toolset: Lain::Toolset.new([]),
          context: Lain::Context.new(model: "claude-opus-4-8", max_tokens: 256),
          timeline: base_timeline || timeline, workspace:, journal:
        )
      end
    end

    it "reports cache write tokens carrying the runs' own usage" do
      report = described_class.new(arms, tasks:, spawn_seam: cache_seam_for(cache_creation_input_tokens: 40),
                                         grader:).report

      expect(report).to include("cache write tokens")
      expect(row_for(report, "cache write tokens", "single-thread")).to match(/\s40\.0(\s|$)/)
    end

    # Scenario: an unmeasured cache-write is absent, not zero.
    #
    # `spawn_seam` (the suite default) scripts `Usage.new(input_tokens:,
    # output_tokens:)` with no cache fields at all -- exactly "offline
    # recordings carrying only input and output usage". {Lain::Usage}
    # normalizes an absent cache field to 0, which is INDISTINGUISHABLE from a
    # real zero at that layer, so reporting "0.0" here would claim a
    # measurement nobody made. The column says so instead.
    it "marks the column not measured, rather than reporting a false 0.0, when no run's usage ever carried one" do
      report = described_class.new(arms, tasks:, spawn_seam:, grader:).report

      section = section_for(report, "cache write tokens")
      expect(section).not_to be_nil
      expect(section).to include("not measured")
      expect(section).not_to match(/\b0\.0\b/)
    end

    it "renders normally once even one run's usage carries a real cache write" do
      mixed = lambda do |journal:, timeline: nil, base_timeline: nil, workspace: Lain::Workspace.empty, **|
        @cache_calls ||= 0
        @cache_calls += 1
        usage = Lain::Usage.new(input_tokens: 100, output_tokens: 20,
                                cache_creation_input_tokens: @cache_calls.odd? ? 0 : 12)
        Lain::Agent.new(
          provider: Lain::Provider::Mock.new(responses: [text_response("done", model: "claude-sonnet-4", usage:)]),
          toolset: Lain::Toolset.new([]),
          context: Lain::Context.new(model: "claude-opus-4-8", max_tokens: 256),
          timeline: base_timeline || timeline, workspace:, journal:
        )
      end

      report = described_class.new(arms, tasks:, spawn_seam: mixed, grader:).report

      expect(section_for(report, "cache write tokens")).not_to include("not measured")
    end

    # Unmeasured is decided PER ARM inside #fold, and #section must not widen
    # that to the whole column: a one-shot arm that genuinely never writes to
    # cache must not hide an epic arm's real, measured 500-token distribution
    # in the SAME report. This exercises the cross-arm case the `mixed` seam
    # above never can -- there, every arm shares one seam and one call
    # sequence, so every arm's OWN fold ends up mixed too.
    describe "an unmeasured arm does not hide a sibling arm's measured numbers" do
      it "renders the epic arm's real cache-write distribution while the one-shot arm's cell alone says not measured" do
        one_shot = DriverSpecSupport::FixedCacheArm.new(name: "one-shot-never-caches", cache_creation_input_tokens: 0)
        epic = DriverSpecSupport::FixedCacheArm.new(name: "epic-real-cache-writes", cache_creation_input_tokens: 500)

        report = described_class.new([one_shot, epic], tasks:, spawn_seam:, grader:).report

        section = section_for(report, "cache write tokens")
        expect(section).not_to be_nil
        expect(row_for(report, "cache write tokens", "epic-real-cache-writes")).to match(/\s500\.0(\s|$)/)
        expect(row_for(report, "cache write tokens", "one-shot-never-caches")).to include("not measured")
      end

      # Every OTHER metric must still render normally for both arms -- the
      # degradation is scoped to the one column that is actually unmeasured.
      it "leaves every other metric's section untouched by the one-shot arm's unmeasured cache-write" do
        one_shot = DriverSpecSupport::FixedCacheArm.new(name: "one-shot-never-caches", cache_creation_input_tokens: 0)
        epic = DriverSpecSupport::FixedCacheArm.new(name: "epic-real-cache-writes", cache_creation_input_tokens: 500)

        report = described_class.new([one_shot, epic], tasks:, spawn_seam:, grader:).report

        expect(row_for(report, "grader score", "one-shot-never-caches")).to match(/\s1\.000(\s|$)/)
        expect(row_for(report, "grader score", "epic-real-cache-writes")).to match(/\s1\.000(\s|$)/)
        expect(section_for(report, "cost (USD)")).not_to include("not priced")
      end
    end
  end

  # The degradation this column forces a decision about, pinned so it stays a
  # decision. `Ledger#cost_of` raises {PriceBook::UnknownModel} for a payment
  # whose model has no price, and METRICS is folded for EVERY run -- so an
  # unpriceable model would take the whole report down with it, including the
  # three metrics that never needed a model at all.
  #
  # A ZERO IS STILL NOT THE ANSWER (that is the lie PriceBook and
  # Ledger#initialize each refuse in writing), but REFUSING TO NAME A PRICE IS
  # NOT THE SAME AS DESTROYING THE REPORT. The cost SECTION degrades to a
  # one-line refusal carrying the Ledger's own message -- which already names
  # the fix -- and every other section renders.
  #
  # This is not a hypothetical: `lain bench arms FIXTURE --provider ollama`,
  # with no further flags, resolves `qwen3:4b`, which `PriceBook::DEFAULTS`
  # (opus/sonnet/haiku only) cannot price. `--model claude-fable-5` is the same
  # shape, and this chunk's own Open decision 7 leaves that model unpriced on
  # purpose.
  describe "a run this price book cannot price" do
    # The message the section must carry: the Ledger's, not one this renderer
    # invents, so there is one authority on how to make the run priceable.
    def refusal_line(report) = section_for(report, "cost (USD)").lines[1].to_s

    context "when the payments name a model with no price" do
      let(:spawn_seam) { seam_for(model: "qwen3:4b") }

      it "still reports score, tokens and wall-time -- the metrics that never needed a model" do
        report = described_class.new(arms, tasks:, spawn_seam:, grader:).report

        expect(row_for(report, "total tokens", "single-thread")).to match(/\s120\.0(\s|$)/)
        expect(row_for(report, "grader score", "single-thread")).to match(/\s1\.000(\s|$)/)
        expect(row_for(report, "wall-time (s)", "single-thread")).not_to be_nil
      end

      it "renders the cost section as a refusal carrying the ledger's own message, not a zero" do
        report = described_class.new(arms, tasks:, spawn_seam:, grader:).report

        expect(section_for(report, "cost (USD)")).not_to be_nil
        expect(refusal_line(report)).to include("qwen3:4b").and include("fallback")
        expect(section_for(report, "cost (USD)")).not_to include("0.000000")
      end

      # A refused section that still renders an arm row would invite the reader
      # to compare a priced arm against an unpriced one down the same column.
      it "names no arm in the refused section, so nothing reads as a comparable figure" do
        report = described_class.new(arms, tasks:, spawn_seam:, grader:).report

        expect(section_for(report, "cost (USD)")).not_to include("single-thread")
        expect(section_for(report, "cost (USD)")).not_to include("control-b")
      end
    end

    context "when the payments record no model at all" do
      let(:spawn_seam) { seam_for(model: "claude-opus-4-8", response_model: nil) }

      it "degrades the same way, carrying the ledger's bare-mock message" do
        report = described_class.new(arms, tasks:, spawn_seam:, grader:).report

        expect(row_for(report, "total tokens", "single-thread")).to match(/\s120\.0(\s|$)/)
        expect(refusal_line(report)).to include("recorded no model").and include("fallback")
      end
    end

    # The escape stays reachable for a LIBRARY caller, which is what makes the
    # refusal a degradation rather than a dead end -- `bench arms` has no argv
    # for it (exe/lain:494), which is why the refusal above had to exist.
    it "prices normally once a fallback is injected through the arm's own instrument" do
      free = Lain::PriceBook.new(
        fallback: Lain::Price.per_mtok(input: 0, output: 0, cache_creation: 0, cache_read: 0)
      )
      degraded = [Lain::Arm::SingleThread.new(name: "bare-mock",
                                              instrument: Lain::Arm::Instrument.new(price_book: free))]

      report = described_class.new(degraded, tasks:, spawn_seam: seam_for(model: "qwen3:4b"), grader:).report

      expect(row_for(report, "total tokens", "bare-mock")).to match(/\s120\.0(\s|$)/)
      expect(row_for(report, "cost (USD)", "bare-mock")).to match(/\s0\.000000(\s|$)/)
    end

    # The runs are already PAID FOR by the time METRICS folds, and
    # `@report ||=` never memoises on a raise -- so a raising fold made a retry
    # re-run and re-pay the whole suite for nothing. Memoisation surviving the
    # unpriceable case is the mechanical statement that it no longer can.
    it "memoises the degraded report, so a second read re-runs no arm and re-pays nothing" do
      driver = described_class.new(arms, tasks:, spawn_seam: seam_for(model: "qwen3:4b"), grader:)

      expect(driver.report).to equal(driver.report)
    end
  end

  # `chunk-bench-arms-subcommand.md` recorded that this header names none
  # of what produced the report, and a dollar figure on a report that names no
  # model is exactly the lie PriceBook refuses to tell -- so the column and the
  # attribution land together.
  describe "#report — the header attributes the run" do
    # Scenario: the report header names what produced it.
    # The shape a WIRED run actually holds. `Bench::CLI#lease_options` requires a
    # journal whenever `--isolation` is set, so `IsolationBackend#journalled`
    # always wraps the concrete backend -- an example built on a bare
    # `Isolation::Null` exercises a shape `.resolve` never returns, which is how
    # the misattribution below survived a first red-first cycle.
    def wrapped(backend) = Lain::Isolation::Journal.new(backend:, journal: Lain::Channel.new)

    it "names the fixture, the model and the isolation backend" do
      report = described_class.new(arms, tasks:, spawn_seam:, grader:,
                                         fixture: "spec/fixtures/arms/tasks.yml", model: "claude-opus-4-8",
                                         isolation: wrapped(Lain::Isolation::Null.new), isolation_name: "none").report

      expect(report).to include("spec/fixtures/arms/tasks.yml").and include("claude-opus-4-8")
      expect(report).to match(/isolation:\s+none\b/)
    end

    # THE OPERATOR'S OWN WORD BEATS ANY CLASS NAME. Every backend `bench arms`
    # can resolve arrives wrapped in the SAME decorator, so a class name renders
    # `--isolation none` and `--isolation worktree` identically -- it cannot
    # answer the one question this field is asked. Two drivers over ONE decorator
    # object is the mechanical statement of that.
    it "distinguishes two backends that render as the same decorator class" do
      backend = wrapped(Lain::Isolation::Null.new)
      labels = %w[none worktree].map do |name|
        described_class.new(arms, tasks:, spawn_seam:, grader:, isolation: backend, isolation_name: name)
                       .report.lines.find { |line| line.include?("isolation:") }
      end

      expect(labels.uniq.size).to eq(2)
      expect(labels.first).to include("none")
      expect(labels.last).to include("worktree")
    end

    # A library caller injects a backend OBJECT and has no flag name to give, so
    # the class name is what is left -- weaker than the operator's word, and only
    # ever the fallback.
    it "falls back to the backend's class name when constructed with an object and no name" do
      report = described_class.new(arms, tasks:, spawn_seam:, grader:,
                                         isolation: Lain::Isolation::Null.new).report

      expect(report).to match(/isolation:\s+#{Regexp.escape(Lain::Isolation::Null.name)}/)
    end

    # Scenario: an unset isolation backend is named as unset, not omitted.
    #
    # `Arm::NoIsolation` is a bare module leasing nothing, and a blank field
    # reads as "the report forgot" rather than as "nothing was leased". Matched
    # with a word after the colon, so a rendered empty value fails.
    it "says an unset isolation backend is unset rather than leaving the field blank" do
      report = described_class.new(arms, tasks:, spawn_seam:, grader:).report

      expect(report).to match(/isolation:\s+unset\b/)
    end

    # An unsupplied fixture or model is the same claim one field over: the
    # header must say the record does not know, which is weaker than and
    # different from "there was none".
    it "names an unsupplied fixture and model as unrecorded rather than blank" do
      report = described_class.new(arms, tasks:, spawn_seam:, grader:).report

      expect(report).to match(/fixture:\s+\S/).and match(/model:\s+\S/)
      expect(report.lines).to include(a_string_matching(/fixture:\s+unrecorded/))
    end

    # A truthiness guard leaves a blank field one empty String away, and an empty
    # String is exactly what a flag parser hands over for `--model ''` -- the
    # same "blank is unset, not an answer" rule {Bench::SpawnSeam} already
    # applies to `--system`, and for the same reason: a U+00A0 is not an
    # attribution either.
    it "treats a blank fixture or model as unrecorded rather than rendering an empty field" do
      report = described_class.new(arms, tasks:, spawn_seam:, grader:, fixture: "", model: " ").report

      expect(report).to match(/fixture:\s+unrecorded/).and match(/model:\s+unrecorded/)
    end

    it "falls back to the backend's class name when the isolation name is blank" do
      report = described_class.new(arms, tasks:, spawn_seam:, grader:,
                                         isolation: Lain::Isolation::Null.new, isolation_name: "").report

      expect(report).to match(/isolation:\s+#{Regexp.escape(Lain::Isolation::Null.name)}/)
    end
  end

  # The Driver threads ONE seam into every arm it was handed, so the arms it can
  # compare are exactly the arms that seam can spawn for. Driving the topology
  # with the widest spawn tail is what makes that real: {Arm::OrchestratorWorker}
  # passes `base_timeline:`, `worker_env:` and `spawned_from:`, none of which a
  # `journal:`-only lambda accepts.
  #
  # It has to be asserted on the TOKENS, and on nothing else: the arm's
  # `#settle` rescues StandardError and folds a failed worker into the synthesis
  # as a named input, and ArgumentError is a StandardError -- so a seam of the
  # wrong arity still produces a full report with a row per arm. What collapses
  # is the spend: every worker dies before its provider is asked, and the row
  # reads 0.0 tokens.
  #
  # The GRADER row will not do it, and that is worth knowing rather than
  # discovering twice. Dumped under the narrow seam, orchestrator-worker still
  # scores 1.000: the grade is computed over the arm's own timeline, which
  # carries the synthesis assistant turn whether or not a single worker ever
  # ran. An `expect(...).to match(/1\.000/)` here would be exactly the
  # cannot-fail shape this prune exists to remove -- and, separately, it says
  # something about the bench that belongs in `lib/`: the headline grader metric
  # cannot tell total worker collapse from success. Only the spend can.
  describe "an arm whose spawn tail is wider than the control's" do
    it "spends real worker tokens through the one seam, not a rescued zero" do
      mixed = [Lain::Arm::SingleThread.new(name: "single-thread"),
               Lain::Arm::OrchestratorWorker.new(name: "orchestrator-worker")]

      report = described_class.new(mixed, tasks:, spawn_seam:, grader:).report

      expect(row_for(report, "total tokens", "orchestrator-worker")).to match(/\s120\.0(\s|$)/)
      expect(row_for(report, "total tokens", "single-thread")).to match(/\s120\.0(\s|$)/)
    end
  end

  # THE BENCH'S HEADLINE METRIC ON THE EXPERIMENT RECORD. Every other column
  # the Driver folds is recoverable from the journal already -- usage and
  # payments ride the arms' own records -- while the GRADE, the one number the
  # comparison is for, reached the rendered report and nothing else.
  # {Grader::Journaling} is the decorator that fixes it, and the Driver is
  # where it goes: the grader is threaded verbatim into every arm's `#run`, so
  # decorating it once at construction journals every arm's every run.
  describe "#report — the grade on the experiment record" do
    let(:journal) { Lain::Channel.new }

    def grade_records(channel) = channel.drain.grep(Lain::Telemetry::GradeRecord)

    # Scenario: a graded arm run writes its score to the journal.
    it "journals one grade record per run, carrying the score" do
      described_class.new(arms, tasks:, spawn_seam:, grader:, journal:).report
      records = grade_records(journal)

      expect(records.size).to eq(arms.size * tasks.size)
      expect(records.map(&:score)).to all(eq(1.0))
    end

    # Scenario: the grade record names its grader.
    #
    # The INNER grader's class, not the decorator's: an attestation naming
    # `Grader::Journaling` would attribute every verdict in the tree to the
    # wrapper and tell a reader nothing about what judged.
    it "names the grader that produced the verdict" do
      described_class.new(arms, tasks:, spawn_seam:, grader:, journal:).report

      expect(grade_records(journal).map(&:grader).uniq).to eq([Lain::Grader::Fixture.name])
    end

    # Scenario: the grade record names its subject.
    #
    # A Timeline answers no `#digest` of its own, so the Driver must inject the
    # resolution rather than let the decorator's duck-typed fallback guess --
    # held here against the head digest of the very Timeline that was graded.
    it "addresses the trajectory it graded" do
      spy = DriverSpecSupport::RecordingGrader.new(grader)
      described_class.new([Lain::Arm::SingleThread.new(name: "single-thread")], tasks:, spawn_seam:,
                                                                                grader: spy, journal:).report

      expect(grade_records(journal).map(&:subject_digest)).to eq(spy.subjects.map(&:head_digest))
    end

    # Scenario: an ungraded run writes no grade record.
    #
    # An arm that never consults the grader it was handed must leave no
    # attestation behind, because the decorator can only honestly journal a
    # verdict it was asked for. NO ARM IN THE TREE REACHES THIS DRIVER AND
    # BEHAVES THAT WAY -- `Arm::Epic` does ignore its `grader:`, but it is
    # rostered only by `LiveArms.altitude` and `Bench::Altitude` folds its own
    # report rather than driving the Driver at all. So this is a forward
    # contract for the arms a project will author, and it discriminates a real
    # alternative design: a decorator that attested once per RUN rather than
    # once per `#grade` would journal four empty verdicts here.
    it "writes no grade record for an arm that never consults its grader" do
      ungraded = [DriverSpecSupport::FixedCacheArm.new(name: "ungraded", cache_creation_input_tokens: 40),
                  DriverSpecSupport::FixedCacheArm.new(name: "ungraded-b", cache_creation_input_tokens: 40)]
      described_class.new(ungraded, tasks:, spawn_seam:, grader:, journal:).report

      expect(grade_records(journal)).to be_empty
    end

    # Scenario: the reported score is unchanged by journaling.
    #
    # {Grader::Journaling} passes the Grade through verbatim, so the attestation
    # is a side record and never a second opinion -- the two reports' score
    # sections must be byte-identical.
    it "reports the same scores journaled and unjournaled" do
      journaled = described_class.new(arms, tasks:, spawn_seam:, grader:, journal:).report
      plain = described_class.new(arms, tasks:, spawn_seam:, grader:).report

      expect(section_for(journaled, "grader score")).to eq(section_for(plain, "grader score"))
    end
  end

  describe "distribution validation" do
    it "refuses a single-task suite -- one run is not a distribution" do
      expect { described_class.new(arms, tasks: ["only one"], spawn_seam:, grader:) }
        .to raise_error(ArgumentError, /distribution|two/i)
    end

    it "refuses an empty arm list" do
      expect { described_class.new([], tasks:, spawn_seam:, grader:) }
        .to raise_error(ArgumentError, /arm/i)
    end

    # `isolation_name:`, `fixture:` and `model:` all read nil as UNSET, so a
    # caller reasonably expects `journal:` to as well -- and it is the one that
    # cannot, because the decorator pushes onto it and a nil answers no `<<`.
    # Left to detonate it does so from inside the run loop, AFTER every arm has
    # asked a real provider and the money is spent, and `@report ||=` never
    # memoises on a raise path, so the retry re-pays the suite.
    it "refuses a nil journal at construction rather than dying mid-suite, after the spend" do
      expect { described_class.new(arms, tasks:, spawn_seam:, grader:, journal: nil) }
        .to raise_error(ArgumentError, /journal/i)
    end
  end
end
