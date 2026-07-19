# frozen_string_literal: true

# The dual-ledger arm maps Magentic-One's dual loop onto Lain: a structured
# Task/Progress {LedgerState} carried sent-not-stored in the Workspace, an outer
# loop that drives the task step by step over ONE linear Timeline, and a stall
# detector that fires a journaled REPLAN on the shared LoopMachine when progress
# dries up for K steps. Driven over Provider::Mock -- no tokens spent.
RSpec.describe Lain::Arm::DualLedger do
  # A fresh agent per step (Provider::Mock is stateful), journaling into the
  # arm's channel so the run is priced, carrying the arm's per-step Workspace,
  # and threading the arm's Timeline so the conversation stays one linear head.
  # The base Arm spawn_seam duck: `call(journal:, **spawn_opts)`. `workspace:`
  # and `timeline:` are OPTIONAL with defaults and there is a `**` tail, so the
  # SAME seam drives DualLedger (which passes workspace:/timeline:) AND
  # SingleThread (which passes only journal:) -- the one-driver-over-both shape
  # B12 needs.
  def spawn_seam(captured_workspaces = [])
    lambda do |journal:, workspace: Lain::Workspace.empty, timeline: nil, **|
      captured_workspaces << workspace
      Lain::Agent.new(provider: step_provider, toolset: Lain::Toolset.new([]),
                      context: Lain::Context.new(model: "claude-opus-4-8", max_tokens: 128),
                      journal:, workspace:, timeline:)
    end
  end

  # One scripted step, priced so the run's Ledger is non-zero.
  def step_provider(text = "did a step")
    usage = Lain::Usage.new(input_tokens: 60, output_tokens: 12)
    response = text_response(text, model: "claude-sonnet-4", usage:)
    Lain::Provider::Mock.new(responses: [response])
  end

  # A seam whose model emits `texts` in order (repeating the last once
  # exhausted, matching Provider::Mock). Identical texts model a stalled run;
  # distinct texts model genuine progress. Base-duck shaped like #spawn_seam.
  def scripted_seam(texts)
    step = -1
    lambda do |journal:, workspace: Lain::Workspace.empty, timeline: nil, **|
      step += 1
      Lain::Agent.new(provider: step_provider(texts[step] || texts.last), toolset: Lain::Toolset.new([]),
                      context: Lain::Context.new(model: "claude-opus-4-8", max_tokens: 128),
                      journal:, workspace:, timeline:)
    end
  end

  # Passes as soon as an assistant turn exists -- so a healthy run settles after
  # one step and the outer loop does not spin to its ceiling.
  let(:settling_grader) do
    Lain::Grader::Fixture.new("settled") do |f|
      f.check("committed an assistant turn") { |timeline| timeline.to_a.map(&:role).include?("assistant") }
    end
  end

  # Never passes -- keeps the outer loop running so a stall can accumulate.
  let(:never_grader) do
    Lain::Grader::Fixture.new("open") { |f| f.check("never") { |_timeline| false } }
  end

  describe "#run — the graded dual-ledger run" do
    subject(:run) { described_class.new.run("summarize the paper", spawn_seam:, grader: settling_grader) }

    it "returns an Arm::Run graded over one linear, fully-reachable Timeline" do
      expect(run).to be_a(Lain::Arm::Run)
      expect(run.timeline.to_a.map(&:role)).to eq(%w[user assistant])
      expect(run.grade).to be_pass
    end

    it "prices the run off its journal (single linear Timeline reaches every paid turn)" do
      expect(run.total_tokens).to eq(72) # 60 + 12, the one step's usage
      expect(run.compare_run.cost).to be > 0
    end

    it "records a non-negative wall-clock elapsed" do
      expect(run.elapsed).to be_a(Float).and be >= 0
    end
  end

  # AC1: The ledger rides the Workspace, sent-not-stored.
  describe "the Task/Progress ledger rides the Workspace, never the Timeline" do
    let(:captured) { [] }

    subject(:run) do
      described_class.new.run("summarize the paper", spawn_seam: spawn_seam(captured), grader: settling_grader)
    end

    it "carries the ledger into the child Workspace each step" do
      run
      ledger_text = captured.first.to_blocks.map { |b| b["text"] }.join

      expect(ledger_text).to include("Task/Progress ledger")
      expect(ledger_text).to include("Task: summarize the paper")
    end

    it "renders the ledger at the request tail and NEVER appends it to the Timeline" do
      run
      # Render at the LIVE turn the arm actually renders on: the last turn is the
      # user turn (the model has not answered yet), which is where the Workspace
      # Reminder injects. `rewind(1)` reproduces that moment off the settled head.
      live = run.timeline.rewind(1)
      request = Lain::Context.new(model: "claude-opus-4-8", max_tokens: 128)
                             .render(timeline: live, toolset: Lain::Toolset.new([]),
                                     workspace: captured.first)

      tail_text = request.messages.last["content"].map { |b| b["text"] }.join
      expect(tail_text).to include("Task/Progress ledger") # sent, at the request tail

      stored = run.timeline.to_a.flat_map(&:content).join
      expect(stored).not_to include("Task/Progress ledger") # never stored in the Timeline
    end
  end

  # AC2: A stall fires a journaled replan transition.
  describe "a stall fires a journaled replan on the LoopMachine" do
    # A progress detector that hands the ledger straight back -- no signature
    # change, so every step reads as no-progress and the stall counter climbs.
    let(:no_progress) { ->(ledger:, **) { ledger } }

    # A tee Channel that mirrors every pushed event into a test-visible array
    # BEFORE the run drains its journal for pricing. This is how a spec observes
    # what was journaled through the before_transition hook.
    def recording_journal(sink)
      Class.new(Lain::Channel) do
        define_method(:push) do |event|
          sink << event
          super(event)
        end
        # Channel's `alias << push` early-binds to the PARENT push, so `<<`
        # (which the arm's Journaling listener uses) would bypass this override
        # -- re-alias here so the tee sees `<<` writes too.
        alias_method :<<, :push
      end
    end

    it "journals a replan LedgerTransition once progress stalls for K steps" do
      journaled = []
      tee = recording_journal(journaled)
      arm = described_class.new(stall_limit: 2, max_steps: 4, progress: no_progress,
                                journal_factory: -> { tee.new })

      arm.run("stuck task", spawn_seam:, grader: never_grader)

      replans = journaled.select do |event|
        event.is_a?(Lain::Arm::DualLedger::LedgerTransition) && event.event == :replan
      end
      expect(replans).not_to be_empty
      expect(replans.first.to_journal)
        .to eq({ "type" => "ledger_transition", "from" => :stalled, "to" => :awaiting_model, "event" => :replan })
    end

    # The headline feature must work WITHOUT an injected detector (panel probe:
    # the old default counted progress.size, which grew every step, so a stall
    # was unreachable in the default config).
    it "fires a replan under the DEFAULT config when the model loops on identical output" do
      journaled = []
      tee = recording_journal(journaled)
      arm = described_class.new(stall_limit: 1, max_steps: 4, journal_factory: -> { tee.new })

      arm.run("stuck", spawn_seam: scripted_seam(["same output, no progress"]), grader: never_grader)

      replans = journaled.select { |e| e.is_a?(Lain::Arm::DualLedger::LedgerTransition) && e.event == :replan }
      expect(replans).not_to be_empty
    end

    it "does NOT stall under the DEFAULT config when the run genuinely progresses" do
      journaled = []
      tee = recording_journal(journaled)
      arm = described_class.new(stall_limit: 2, max_steps: 4, journal_factory: -> { tee.new })

      arm.run("healthy", spawn_seam: scripted_seam(["read intro", "read methods", "read results", "wrote summary"]),
                         grader: never_grader)

      expect(journaled.select { |e| e.respond_to?(:event) && e.event == :replan }).to be_empty
    end
  end

  # Fix 2 (panel): one base-duck seam drives BOTH arms -- B12 needs one driver
  # over SingleThread and DualLedger.
  describe "the base-duck spawn seam drives both arms" do
    it "runs SingleThread and DualLedger from the same seam object" do
      seam = spawn_seam

      single = Lain::Arm::SingleThread.new.run("t", spawn_seam: seam, grader: settling_grader)
      dual = described_class.new.run("t", spawn_seam: seam, grader: settling_grader)

      expect(single).to be_a(Lain::Arm::Run)
      expect(dual).to be_a(Lain::Arm::Run)
    end
  end

  describe "the injected isolation seam" do
    it "acquires a lease and releases it, even though the ledger arm ignores its env" do
      lease = instance_double("lease", release: nil)
      isolation = instance_double("isolation", acquire: lease)

      described_class.new.run("t", spawn_seam:, grader: settling_grader, isolation:)

      expect(isolation).to have_received(:acquire)
      expect(lease).to have_received(:release)
    end
  end
end
