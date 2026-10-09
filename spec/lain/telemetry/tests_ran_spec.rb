# frozen_string_literal: true

# What the tip's own suite did on the sha an implementation gate is about to
# name, or why it was not run.
RSpec.describe Lain::Telemetry::TestsRan do
  def run_of(passed: [], failed: [], errors: [])
    Lain::Grader::TestHarness::Run.new(passed:, failed:, errors:, stderr: "")
  end

  it "journals as tests_ran, counting what the run reported against the issue and sha" do
    record = described_class.from(run_of(passed: %w[p1 p2 p3], failed: [], errors: ["NameError"]),
                                  issue_id: "a", sha: "abc123")

    expect(record.to_journal).to eq("type" => "tests_ran", "issue_id" => "a", "sha" => "abc123", "ran" => true,
                                    "passed" => 3, "failed" => 0, "errors" => 1, "why" => nil)
  end

  it "says the tests were not run, and why, with nothing counted" do
    record = described_class.unrun(issue_id: "a", sha: "abc123", why: "the project declares no tests preset")

    expect(record).to have_attributes(ran: false, passed: 0, failed: 0, errors: 0,
                                      why: "the project declares no tests preset")
  end

  it "refuses a record that names no issue or no sha" do
    expect { described_class.unrun(issue_id: "", sha: "abc123", why: "w") }.to raise_error(ArgumentError, /issue_id/)
    expect { described_class.unrun(issue_id: "a", sha: nil, why: "w") }.to raise_error(ArgumentError, /sha/)
  end

  it "refuses a record of tests not run that does not say why" do
    expect { described_class.unrun(issue_id: "a", sha: "abc123", why: " ") }.to raise_error(ArgumentError, /why/)
  end

  it "is deeply frozen, even from unfrozen strings" do
    expect(described_class.unrun(issue_id: +"a", sha: +"abc123", why: +"w")).to be_deeply_frozen
    expect(described_class.from(run_of(passed: ["p"]), issue_id: +"a", sha: +"abc123")).to be_deeply_frozen
  end
end
