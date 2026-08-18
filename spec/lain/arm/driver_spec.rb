# frozen_string_literal: true

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

  # T12 / CE-6.2. The bench's headline metric, and until now the one metric the
  # arm comparison did not carry -- `Arm::Run` folded usage and left cost to
  # `#compare_run`, which the Driver never calls.
  describe "#report — the cost column" do
    # Scenario: the arm report carries a cost column.
    #
    # Asserted against the PriceBook rather than a literal: the claim is "the
    # number in the report is the number this run's own Ledger produced", not
    # "sonnet costs $3/MTok" -- the table is meant to be edited (T1 edits it),
    # and a literal here would fail on a correct price change.
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

  # T12. `chunk-bench-arms-subcommand.md` recorded that this header names none
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

  describe "distribution validation" do
    it "refuses a single-task suite -- one run is not a distribution" do
      expect { described_class.new(arms, tasks: ["only one"], spawn_seam:, grader:) }
        .to raise_error(ArgumentError, /distribution|two/i)
    end

    it "refuses an empty arm list" do
      expect { described_class.new([], tasks:, spawn_seam:, grader:) }
        .to raise_error(ArgumentError, /arm/i)
    end
  end
end
