# frozen_string_literal: true

# B0 (chunk-orchestration-arms-isolation): a small suite of graded coding
# tasks spanning the pre-registered "procedural vs genuinely-parallel"
# boundary, feeding the arm sweep (B12) later. Every task grades
# deterministically with a Grader::Fixture -- no model in the loop -- against
# a Trajectory (the files an arm's run produced or touched).
RSpec.describe Lain::Bench::ArmTasks do
  def fixture_path(name) = File.join(__dir__, "..", "..", "fixtures", "arms", "#{name}.yml")

  def trajectory(files) = Lain::Bench::ArmTasks::Trajectory.new(files:)

  subject(:arm_tasks) { described_class.new(fixture_path: fixture_path("tasks")) }

  describe "the suite spans the pre-registered boundary" do
    it "carries a small, honest suite -- between 4 and 8 tasks total" do
      expect(arm_tasks.count).to be_between(4, 8)
    end

    it "has at least one procedural (single-thread-friendly) task" do
      expect(arm_tasks.procedural).not_to be_empty
    end

    it "has at least one parallel (genuinely independent) task" do
      expect(arm_tasks.parallel).not_to be_empty
    end

    it "assigns every task to a pre-registered category" do
      arm_tasks.each { |task| expect(described_class::CATEGORIES).to include(task.category) }
    end
  end

  describe "Grader::Fixture scores a fixture task deterministically" do
    let(:task) { arm_tasks.find { |t| t.id == "rename-method-and-callsite" } }

    it "returns a passing Grade with a populated why when the recorded trajectory matches gold" do
      grade = task.grader.grade(trajectory("lib/widget.rb" => "def normalize\nend\n",
                                           "app/main.rb" => "Widget.new.normalize(42)\n"))

      expect(grade).to be_pass
      expect(grade.why).not_to be_empty
    end

    it "returns a failing Grade with a populated why when the recorded trajectory misses gold" do
      grade = task.grader.grade(trajectory("lib/widget.rb" => "def frobnicate\nend\n"))

      expect(grade).not_to be_pass
      expect(grade.why).to include("lib/widget.rb")
    end

    it "is deterministic: the same trajectory scores the same Grade twice" do
      recorded = trajectory("lib/widget.rb" => "def normalize\nend\n", "app/main.rb" => "normalize(1)\n")

      expect(task.grader.grade(recorded)).to eq(task.grader.grade(recorded))
    end
  end

  describe "every task in the suite grades deterministically" do
    # Builds the Trajectory that SHOULD satisfy every one of a task's own
    # gold checks. A gold_files value is either the bare-String shorthand
    # for "contains" (the whole value IS the satisfying content) or a
    # structured spec (`{"contains" => ..., "excludes" => ...}` etc, see
    # Bench::ArmTasks.positive_content) whose positive assertion's value is
    # the satisfying content.
    def positive_trajectory(task)
      trajectory(task.gold_files.transform_values { |spec| described_class.positive_content(spec) })
    end

    it "each task's grader passes against a trajectory built from its own gold_files" do
      arm_tasks.each do |t|
        grade = t.grader.grade(positive_trajectory(t))
        expect(grade).to be_pass, "#{t.id}: #{grade.why}"
      end
    end

    it "each task's grader fails against an empty trajectory -- it discriminates, not auto-passes" do
      empty = trajectory({})
      arm_tasks.each { |t| expect(t.grader.grade(empty)).not_to be_pass }
    end
  end

  describe "gold is anchored, not substring-anywhere (review panel adversarial probes)" do
    it "fails add-license-headers when the copyright string is buried as noise, not a real header" do
      task = arm_tasks.find { |t| t.id == "add-license-headers" }
      traj = trajectory("lib/x.rb" => "def x; end\n# not a header, just noise containing # Copyright 2026 Lain Labs\n",
                        "lib/y.rb" => "# Copyright 2026 Lain Labs",
                        "lib/z.rb" => "# Copyright 2026 Lain Labs")

      expect(task.grader.grade(traj)).not_to be_pass
    end

    it "fails fix-off-by-one-loop when the buggy substring is still present alongside the fix" do
      task = arm_tasks.find { |t| t.id == "fix-off-by-one-loop" }
      traj = trajectory("lib/calc.rb" => "# old: i <= items.length (kept for reference)\ni < items.length\n")

      expect(task.grader.grade(traj)).not_to be_pass
    end
  end

  describe "a missing fixture refuses namedly" do
    it "raises a Lain::Error naming the missing path, not Errno::ENOENT" do
      missing = fixture_path("does-not-exist")

      expect { described_class.new(fixture_path: missing).to_a }
        .to raise_error(described_class::MissingFixture, /#{Regexp.escape(missing)}/)
    end
  end

  describe "a malformed fixture task refuses namedly rather than being silently skipped" do
    it "raises MalformedTask naming the missing field" do
      expect { described_class.new(fixture_path: fixture_path("malformed")).to_a }
        .to raise_error(described_class::MalformedTask, /prompt/)
    end

    it "raises MalformedTask when a task names an unrecognized category" do
      expect { described_class.new(fixture_path: fixture_path("unknown_category")).to_a }
        .to raise_error(described_class::MalformedTask, /category/)
    end

    it "raises MalformedTask naming the fixture path when the top-level `tasks:` key is absent, " \
       "never a bare KeyError" do
      expect { described_class.new(fixture_path: fixture_path("no_tasks_key")).to_a }
        .to raise_error(described_class::MalformedTask, /tasks/)
    end

    it "raises MalformedTask (not NoMethodError) when a task entry is not a mapping" do
      expect { described_class.new(fixture_path: fixture_path("entry_not_a_mapping")).to_a }
        .to raise_error(described_class::MalformedTask, /not a mapping/)
    end
  end

  describe "duplicate task ids within one fixture refuse namedly" do
    it "raises MalformedTask naming the duplicate id, rather than silently keeping both" do
      expect { described_class.new(fixture_path: fixture_path("duplicate_id")).to_a }
        .to raise_error(described_class::MalformedTask, /same-id/)
    end
  end
end
