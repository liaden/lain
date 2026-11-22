# frozen_string_literal: true

# How an issue's acceptance is judged: by tests the red step writes and runs,
# or, for a script, a manifest or a spike, by a human at the implementation
# gate against the commands the scenarios name.
RSpec.describe Lain::CLI::EpicDriver::Acceptance do
  def scenarios(*texts)
    texts.map do |text|
      Lain::Gherkin::Scenario.new(name: "s", clauses: [Lain::Gherkin::Clause.new(keyword: "Then", text:)])
    end
  end

  def scenario(*clauses)
    clauses = clauses.map { |keyword, text| Lain::Gherkin::Clause.new(keyword:, text:) }
    [Lain::Gherkin::Scenario.new(name: "s", clauses:)]
  end

  describe ".of" do
    it "reads the manual level as Manual, carrying the commands its scenarios name in backticks" do
      found = described_class.of("manual", scenarios: scenarios("`scripts/fetch-models.sh --check` exits 0",
                                                                "`cargo build` and `scripts/fetch-models.sh --check`"))

      expect(found).to be_a(described_class::Manual)
      expect(found.commands).to eq(["scripts/fetch-models.sh --check", "cargo build"])
    end

    it "takes the backticked spans of When and Then clauses, And or But following either, and never a Given's" do
      found = described_class.of("manual", scenarios: scenario(["Given", "a checkout with `rm -rf build` run"],
                                                               ["And", "a `setup` step"],
                                                               ["When", "I run `make check`"],
                                                               ["And", "then `make lint`"],
                                                               ["Then", "`./bin/verify` exits 0"],
                                                               ["But", "`./bin/verify --strict` also exits 0"]))

      expect(found.commands).to eq(["make check", "make lint", "./bin/verify", "./bin/verify --strict"])
    end

    it "reads a manual issue whose scenarios name no command as Manual with none" do
      expect(described_class.of("manual", scenarios: scenarios("a human looks at it")).commands).to eq([])
    end

    it "reads any other level as Tested at that level" do
      expect(described_class.of("seam", scenarios: [])).to eq(described_class::Tested.new(level: "seam"))
    end

    it "reads no level as Tested at the layout's default" do
      expect(described_class.of(nil, scenarios: [])).to eq(described_class::Tested.new(level: nil))
    end

    it "is deeply frozen" do
      expect(Ractor.shareable?(described_class.of("manual", scenarios: scenarios("`make`")))).to be(true)
    end
  end

  describe ".procedure" do
    it "carries the whole When and Then steps, prose included, and never a Given" do
      steps = scenario(["Given", "a built checkout"], ["When", "the human opens the battery doc"],
                       ["And", "runs `make check` from the root"], ["Then", "every row reads green"])

      expect(described_class.procedure(steps))
        .to eq(["the human opens the battery doc", "runs `make check` from the root", "every row reads green"])
    end
  end

  describe ".of_issue" do
    it "reads the level and the criteria off the issue itself" do
      criteria = "```gherkin\nScenario: it fetches\n  Then `scripts/fetch-models.sh --check` exits 0\n```"
      issue = Lain::Epic::Issue.new(id: "a", title: "A", level: "manual", criteria:)

      expect(described_class.of_issue(issue).commands).to eq(["scripts/fetch-models.sh --check"])
    end

    it "reads an issue with no criteria at its level" do
      expect(described_class.of_issue(Lain::Epic::Issue.new(id: "a", title: "A", level: "seam")))
        .to eq(described_class::Tested.new(level: "seam"))
    end
  end

  describe "the red step each takes" do
    let(:tests) { Object.new }

    it "is the test step for Tested" do
      expect(described_class::Tested.new(level: "unit").red_step(tests)).to equal(tests)
    end

    it "is the unscripted stand-in for Manual" do
      expect(described_class::Manual.new(commands: []).red_step(tests)).to equal(Lain::CLI::EpicDriver::IssueTests::Unscripted)
    end
  end

  describe "whether the project's layout places its tests" do
    it "is so for Tested and not for Manual" do
      expect([described_class::Tested.new(level: nil),
              described_class::Manual.new(commands: [])].map(&:placed_by_layout?))
        .to eq([true, false])
    end
  end
end
