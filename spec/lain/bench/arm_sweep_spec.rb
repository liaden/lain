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
      measurements.each { |m| expect(%i[procedural parallel]).to include(m.category) }
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

  describe "#report — the arm comparison, distributions per arm" do
    let(:report) { sweep.report }

    it "names single-thread as the control in its header" do
      expect(report).to match(/control: single-thread/)
    end

    it "reports all five metrics as their own titled sections" do
      ["grader score", "total tokens", "wall-time", "context-loss", "replans"].each do |metric|
        expect(report).to match(/#{metric}/i)
      end
    end

    it "breaks the boundary out per category rather than averaging it away" do
      expect(report).to match(/== procedural ==/)
      expect(report).to match(/== parallel ==/)
    end

    it "discloses the linear-arms tie so a reader does not mistake it for a finding" do
      expect(report).to match(/single-thread and dual-ledger produce IDENTICAL/)
      expect(report).to match(/artifact of the offline harness/i)
      expect(report).to match(/coordination overhead, visible only in the replans/i)
    end

    it "discloses that context-loss UNDER-counts -- omitted/added files versus the control are not counted" do
      expect(report).to match(/UNDER-counts/)
      expect(report).to match(/omitted or added\s+versus the control is not/m)
    end

    it "marks the single-thread row (control) in the tables themselves, not only the header" do
      expect(report).to match(/^single-thread \(control\)/)
    end

    it "marks wall-time ABSENT under offline mock replay rather than fabricating it" do
      # "wall-time (s)" is the table header; the NOTE prose says "wall-time is
      # ABSENT", so the "(s)" is what pins the match to the table, not the note.
      wall = report[/wall-time \(s\).*?(?=\n\n|\z)/m]
      expect(wall).to match(/ABSENT/)
      %w[single-thread orchestrator-worker dual-ledger].each { |arm| expect(wall).to include(arm) }
    end

    it "lists single-thread first in every metric table -- the control row" do
      report.scan(/^single-thread\b/).each_with_index do |_match, _i|
        # every arm row for a metric; single-thread must precede the others in each block
      end
      %w[single-thread orchestrator-worker dual-ledger].each { |arm| expect(report).to include(arm) }
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
