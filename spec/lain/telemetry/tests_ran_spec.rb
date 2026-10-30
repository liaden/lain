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

  describe "journal bytes" do
    def ran(**over)
      described_class.new(issue_id: "i1", sha: "abc", ran: true, passed: 5, failed: 1, errors: 2, **over)
    end

    it "journals a run's counts and a null why" do
      expect(JSON.generate(ran.to_journal)).to eq(
        '{"type":"tests_ran","issue_id":"i1","sha":"abc","ran":true,"passed":5,"failed":1,"errors":2,"why":null}'
      )
    end

    it "journals an unrun record with zero counts and its reason" do
      expect(JSON.generate(described_class.unrun(issue_id: "i1", sha: "abc", why: "no harness").to_journal)).to eq(
        '{"type":"tests_ran","issue_id":"i1","sha":"abc","ran":false,"passed":0,"failed":0,"errors":0,' \
        '"why":"no harness"}'
      )
    end

    it "interns the issue, the sha and the reason across equal records" do
      first = described_class.unrun(issue_id: +"i1", sha: +"abc", why: +"no harness")
      second = described_class.unrun(issue_id: +"i1", sha: +"abc", why: +"no harness")
      %i[issue_id sha why].each { |field| expect(first.public_send(field)).to equal(second.public_send(field)) }
    end

    it "refuses a nil count instead of journaling null" do
      expect { ran(passed: nil) }.to raise_error(StandardError)
    end

    it "refuses a keyword it does not declare" do
      expect { ran(stray: 1) }.to raise_error(ArgumentError, /stray/)
    end
  end

  describe "blank names" do
    it "refuses issue_id given as false, an empty Array or an empty Hash, as it did before interning" do
      [false, [], {}].each do |blank|
        expect do
          described_class.unrun(issue_id: "i", sha: "s", why: "w").then do
            described_class.new(issue_id: blank, sha: "s", ran: false,
                                why: "w")
          end
        end.to raise_error(ArgumentError, /issue_id must name the issue, got/)
      end
    end

    it "refuses sha given as false, an empty Array or an empty Hash, as it did before interning" do
      [false, [], {}].each do |blank|
        expect do
          described_class.unrun(issue_id: "i", sha: "s", why: "w").then do
            described_class.new(issue_id: "i", sha: blank, ran: false,
                                why: "w")
          end
        end.to raise_error(ArgumentError, /sha must name the sha tested, got/)
      end
    end
  end

  describe "post-settle conversions" do
    it "journals numeric-string counts as Integers" do
      record = described_class.new(issue_id: "i", sha: "s", ran: true, passed: "7", failed: "8", errors: "9")
      expect([record.passed, record.failed, record.errors]).to eq([7, 8, 9])
    end

    it "refuses a fractional count alike in every one of the three" do
      %i[passed failed errors].each do |count|
        expect { described_class.new(issue_id: "i", sha: "s", ran: true, count => 1.5) }
          .to raise_error(Lain::Declarative::Types::CoercionError, /integral/), "#{count} took 1.5"
      end
    end
  end
end
