# frozen_string_literal: true

# The Driver runs N arms over a task suite and folds each arm's runs into its
# own per-metric distributions -- grader, tokens, wall-time -- laid side by side.
# It reuses Compare's Distribution + Table (never reshaping Compare's surface)
# and runs entirely over Provider::Mock.
RSpec.describe Lain::Arm::Driver do
  let(:spawn_seam) do
    lambda do |journal:|
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

  let(:arms) { [Lain::Arm::SingleThread.new(name: "single-thread"), Lain::Arm::SingleThread.new(name: "control-b")] }
  let(:tasks) { ["procedural task", "another task"] }

  describe "#report — arms compared distributionally" do
    subject(:report) { described_class.new(arms, tasks:, spawn_seam:, grader:).report }

    it "is a String -- never touches stdout" do
      expect(report).to be_a(String)
    end

    it "reports grader, tokens, and wall-time distributions" do
      expect(report).to include("grader score").and include("total tokens").and include("wall-time")
      expect(report).to include("mean").and include("median")
    end

    it "reports every arm, once per arm" do
      expect(report).to include("single-thread").and include("control-b")
    end

    it "folds each arm's suite into a distribution of n = the number of tasks" do
      # Every metric section carries a per-arm `n` column == the suite size.
      # A metric section is: title, header row, dashed rule, then one row per arm.
      section = report.split("\n\n").find { |block| block.start_with?("total tokens") }
      counts = section.lines.drop(3).map { |line| line.split(/\s{2,}/)[1] }
      expect(counts).to all(eq(tasks.size.to_s))
    end

    it "renders byte-identical reports when the same instance reports twice" do
      driver = described_class.new(arms, tasks:, spawn_seam:, grader:)
      expect(driver.report).to eq(driver.report)
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
