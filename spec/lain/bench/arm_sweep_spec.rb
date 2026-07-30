# frozen_string_literal: true

# B12 (chunk-orchestration-arms-isolation): the arms bench sweep. Runs the
# three orchestration arms -- single-thread (the control), orchestrator-worker,
# and dual-ledger -- over B0's ArmTasks suite, driven by committed recorded
# trajectories through Provider::Mock (deterministic, offline, zero network),
# and reports grader, tokens, wall-time, context-loss, and replans/stalls as
# distributions PER ARM, per category, with single-thread present as the
# control every arm is measured against.
RSpec.describe Lain::Bench::ArmSweep do
  def tasks_path = File.join(__dir__, "..", "..", "fixtures", "arms", "tasks.yml")
  def recordings_path(name) = File.join(__dir__, "..", "..", "fixtures", "bench", "arm_sweep", "#{name}.yml")

  subject(:sweep) { described_class.new(tasks_path:, recordings_path: recordings_path("recordings")) }

  # A measurement is one (arm, task) cell: the metrics the sweep folds into
  # distributions. Asserting on these directly is the decider-sweep precedent
  # (`#timelines`) -- a numeric invariant checked without re-parsing the bytes.
  def by_arm(measurements) = measurements.group_by(&:arm)

  describe "#measurements — one graded, priced, process-metric'd cell per (arm, task)" do
    let(:measurements) { sweep.measurements }
    let(:grouped) { by_arm(measurements) }

    it "measures every arm over every recorded task" do
      expect(grouped.keys).to contain_exactly("single-thread", "orchestrator-worker", "dual-ledger")
      grouped.each_value { |cells| expect(cells.map(&:task_id).uniq.size).to eq(cells.size) }
    end

    it "carries the pre-registered category on every cell" do
      expect(measurements.map(&:category))
        .to all(satisfy("a pre-registered category") { |category| %i[procedural parallel].include?(category) })
    end

    it "prices real tokens off each run's journal -- never zero for a run that spent" do
      grouped.fetch("single-thread").each { |m| expect(m.tokens).to be > 0 }
    end

    it "reproduces the boundary: orchestrator-worker loses on a coupled procedural task, " \
       "where its uncoordinated decomposition diverges from the control" do
      orchestrator = grouped.fetch("orchestrator-worker")
      procedural = orchestrator.select { |m| m.category == :procedural }
      # At least one coupled procedural task scores below the single-thread control.
      expect(procedural.map(&:score).min).to be < 1.0
    end

    it "does NOT lose the parallel side: orchestrator-worker grades every genuinely-" \
       "independent task as well as the control" do
      orchestrator = grouped.fetch("orchestrator-worker").select { |m| m.category == :parallel }
      single = grouped.fetch("single-thread").select { |m| m.category == :parallel }
      expect(orchestrator.map(&:score)).to eq(single.map(&:score))
    end

    it "counts context-loss as control-divergence: the control never diverges from itself" do
      grouped.fetch("single-thread").each { |m| expect(m.context_loss).to eq(0) }
    end

    it "surfaces a context-loss event on the coupled procedural task for the decomposing arm" do
      orchestrator = grouped.fetch("orchestrator-worker").select { |m| m.category == :procedural }
      expect(orchestrator.map(&:context_loss).max).to be >= 1
    end
  end

  # The report's titled metric tables, in rendered order. A section is
  # "<title>\n<header>\n<rule>\n<row>…", so a block whose SECOND line is the
  # shared arm-column header is a metric table and nothing else is (the NOTE
  # prose and the "== category ==" banners are not).
  def metric_sections(report)
    report.split("\n\n").select { |block| block.lines[1].to_s.start_with?("arm ") }
  end

  def section_title(section) = section.lines.first.chomp

  def arm_rows(section) = section.lines.drop(3).map { |line| line.split(/\s{2,}/).first }

  # Every titled table's rows, in order, control-marked as the report renders it.
  def row_order = ["single-thread (control)", "orchestrator-worker", "dual-ledger"]

  # METRICS' declaration order plus the ABSENT wall-time section, which rides
  # last in every category block.
  def section_order = ["grader score", "total tokens", "context-loss events", "replans/stalls", "wall-time (s)"]

  describe "#report — the arm comparison, distributions per arm" do
    let(:report) { sweep.report }

    it "names single-thread as the control in its header" do
      expect(report).to include("control: single-thread")
    end

    # Anchored at the start of a line and followed by the newline the table
    # begins on, so a metric that survives only inside the NOTE prose (or as a
    # substring of another title) cannot satisfy this.
    it "reports all five metrics as their own titled sections" do
      section_order.each { |title| expect(report).to match(/^#{Regexp.escape(title)}\n/) }
    end

    # The two orderings a shared fold could silently reverse, and which no
    # "includes the label" assertion would notice: the metric sections inside a
    # category block, and the arm rows inside a section. Both are the reading
    # order of the experiment record.
    it "renders the metric sections in declaration order, wall-time last, in every category block" do
      expect(metric_sections(report).map { |section| section_title(section) })
        .to eq(section_order * 3)
    end

    it "orders the arm rows identically in every metric section, the control first" do
      orders = metric_sections(report).map { |section| arm_rows(section) }
      expect(orders.size).to eq(section_order.size * 3)
      expect(orders.uniq).to eq([row_order])
    end

    it "breaks the boundary out per category rather than averaging it away" do
      expect(report).to include("== procedural ==")
      expect(report).to include("== parallel ==")
    end

    it "discloses the linear-arms tie so a reader does not mistake it for a finding" do
      expect(report).to include("single-thread and dual-ledger produce IDENTICAL")
      expect(report).to match(/artifact of the offline harness/i)
      expect(report).to match(/coordination overhead, visible only in the replans/i)
    end

    it "discloses that context-loss UNDER-counts -- omitted/added files versus the control are not counted" do
      expect(report).to include("UNDER-counts")
      expect(report).to match(/omitted or added\s+versus the control is not/m)
    end

    it "marks the single-thread row (control) in the tables themselves, not only the header" do
      expect(report).to match(/^single-thread \(control\)/)
    end

    it "marks wall-time ABSENT under offline mock replay rather than fabricating it" do
      # "wall-time (s)" is the table header; the NOTE prose says "wall-time is
      # ABSENT", so the "(s)" is what pins the match to the table, not the note.
      wall = report[/wall-time \(s\).*?(?=\n\n|\z)/m]
      expect(wall).to include("ABSENT")
      %w[single-thread orchestrator-worker dual-ledger].each { |arm| expect(wall).to include(arm) }
    end
  end

  describe "determinism (byte-identical reports, the sweep discipline)" do
    it "renders byte-identical reports across two independent instances" do
      first = described_class.new(tasks_path:, recordings_path: recordings_path("recordings")).report
      second = described_class.new(tasks_path:, recordings_path: recordings_path("recordings")).report
      expect(first).to eq(second)
    end

    it "renders byte-identical reports when the same instance reports twice" do
      expect(sweep.report).to eq(sweep.report)
    end
  end

  describe "replans/stalls are sourced by TEE-ing the dual-ledger journal" do
    subject(:stall_sweep) { described_class.new(tasks_path:, recordings_path: recordings_path("stall")) }

    it "counts a dual-ledger replan when the run never settles and progress stalls" do
      dual = stall_sweep.measurements.select { |m| m.arm == "dual-ledger" }
      expect(dual.map(&:replans).max).to be >= 1
    end

    it "leaves the linear control at zero replans -- single-thread has no ledger to replan" do
      single = stall_sweep.measurements.select { |m| m.arm == "single-thread" }
      expect(single.map(&:replans)).to all(eq(0))
    end

    it "pluralizes the header count -- a one-task fixture reads '1 task', never '1 tasks'" do
      expect(stall_sweep.report).to include("1 task (")
      expect(stall_sweep.report).not_to include("1 tasks")
    end
  end

  describe "a missing recordings fixture refuses namedly" do
    it "raises a Lain::Error naming the missing path, not Errno::ENOENT" do
      missing = recordings_path("does-not-exist")

      expect { described_class.new(tasks_path:, recordings_path: missing).report }
        .to raise_error(described_class::MissingFixture, /#{Regexp.escape(missing)}/)
    end
  end

  describe "a recorded task with no matching prompt refuses namedly rather than mis-scoring" do
    it "raises MalformedRecording when the mock is asked a prompt it has no recording for" do
      expect { described_class.new(tasks_path:, recordings_path: recordings_path("unknown_prompt")).report }
        .to raise_error(described_class::MalformedRecording)
    end
  end
end
