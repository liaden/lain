# frozen_string_literal: true

# The Driver runs N arms over a task suite and folds each arm's runs into its
# own per-metric distributions -- grader, tokens, wall-time -- laid side by side.
# It reuses Compare's Distribution + Table (never reshaping Compare's surface)
# and runs entirely over Provider::Mock.
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
    # The data row for one arm inside one metric's table, read off the rendered
    # bytes the same way the sibling examples above match them.
    def row_for(report, metric, arm)
      section = report.split("\n\n").find { |block| block.start_with?("#{metric}\n") }
      section.lines.map(&:chomp).find { |line| line.start_with?("#{arm} ") }
    end

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
