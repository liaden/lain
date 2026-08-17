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

  # Passes as soon as an assistant turn exists. It scores the Run and nothing
  # else: the grader is no longer a control signal, so this arm takes the same
  # number of steps whether it passes or never does.
  let(:passing_grader) do
    Lain::Grader::Fixture.new("settled") do |f|
      f.check("committed an assistant turn") { |timeline| timeline.to_a.map(&:role).include?("assistant") }
    end
  end

  # Never passes -- a task no grader can score, which is where reading the
  # grader as a control signal used to cost the whole ceiling in model calls.
  let(:never_grader) do
    Lain::Grader::Fixture.new("open") { |f| f.check("never") { |_timeline| false } }
  end

  # What the default config costs on a model that repeats itself, which
  # `spawn_seam` does: step 1 records the first note (the ledger advances),
  # steps 2-4 repeat it (stalls 1, 2, 3 -- K tops out and the arm replans), and
  # step 5 stalls again, which is the ledger settling the loop. K + 2, and the
  # relation holds for every (stall_limit, max_steps) the constructor accepts.
  def default_steps = 5

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

  # The orchestration transitions a run journaled, in order -- the record a
  # bench reads to answer "what did this arm DO, and why did it stop?".
  def transition_events(journaled)
    journaled.grep(Lain::Arm::DualLedger::LedgerTransition).map(&:event)
  end

  describe "#run — the graded dual-ledger run" do
    subject(:run) { described_class.new.run("summarize the paper", spawn_seam:, grader: passing_grader) }

    it "returns an Arm::Run graded over one linear, fully-reachable Timeline" do
      expect(run).to be_a(Lain::Arm::Run)
      expect(run.timeline.to_a.map(&:role)).to eq(%w[user assistant] * default_steps)
      expect(run.grade).to be_pass
    end

    it "prices the run off its journal (single linear Timeline reaches every paid turn)" do
      expect(run.total_tokens).to eq(72 * default_steps) # (60 + 12) per step
      expect(run.compare_run.cost).to be > 0
    end

    # T24: the outer loop's whole drive is timed by the SAME injected instrument
    # the other arms use -- and the block's value (the settled Loop) comes back
    # from it, so no mutable capture is needed to reach it.
    #
    # The READ COUNT is what pins the span to the drive: `0.25` alone is the
    # delta of any single timed region, so a per-step span would report it too
    # -- and would read this clock twice per step instead of twice per run.
    it "takes elapsed off the injected instrument's clock, over the whole drive" do
      reads = 0
      arm = described_class.new(instrument: Lain::Arm::Instrument.new(clock: -> { (reads += 1) * 0.25 }))

      run = arm.run("summarize the paper", spawn_seam:, grader: passing_grader)

      expect(run.elapsed).to eq(0.25)
      expect(reads).to eq(2)
    end
  end

  # T8: the outer loop reads the LEDGER, never the grader. Consulting the
  # scoring function as a control signal was oracle leakage the control arms do
  # not get -- it confounds a cross-arm score comparison with protocol rather
  # than strategy -- and it spent the ceiling in model calls on any task the
  # grader could not pass.
  describe "the outer loop settles from the ledger's own progress reading" do
    # ONE provider across every step, so `call_count` IS the number of model
    # calls the outer loop spent. Mock repeats its last response once exhausted,
    # which is the canonical Magentic-One stall: the note never changes, so the
    # ledger signature never moves.
    let(:repeating_provider) do
      usage = Lain::Usage.new(input_tokens: 60, output_tokens: 12)
      Lain::Provider::Mock.new(responses: [text_response("still analysing; no edits yet",
                                                         model: "claude-sonnet-4", usage:)])
    end

    def repeating_seam(provider)
      lambda do |journal:, workspace: Lain::Workspace.empty, timeline: nil, **|
        Lain::Agent.new(provider:, toolset: Lain::Toolset.new([]),
                        context: Lain::Context.new(model: "claude-opus-4-8", max_tokens: 128),
                        journal:, workspace:, timeline:)
      end
    end

    # A Grader::Fixture is deeply frozen, so it cannot be spied on directly --
    # the double stands in for it and answers the same failing Grade every time.
    it "asks the grader exactly once -- for the Run's grade, never as a control signal" do
      grader = instance_double(Lain::Grader::Fixture,
                               grade: never_grader.grade(Lain::Timeline.empty(store: Lain::Store.new)))

      described_class.new.run("ungradeable", spawn_seam: repeating_seam(repeating_provider), grader:)

      expect(grader).to have_received(:grade).once
    end

    it "terminates before max_steps once the ledger stops advancing, ungradeable or not" do
      provider = repeating_provider

      described_class.new.run("ungradeable", spawn_seam: repeating_seam(provider), grader: never_grader)

      expect(provider.call_count).to be < described_class::DEFAULT_MAX_STEPS
    end

    # The other half of settling on a crude structural detector: a run that IS
    # working must not be cut short by it. Nothing here can judge a task
    # complete -- only whether it moved -- so a ledger that keeps advancing is
    # bounded by `max_steps` and by nothing else.
    it "never settles a run whose ledger keeps advancing -- max_steps is its only bound" do
      arm = described_class.new(stall_limit: 1, max_steps: 3)

      run = arm.run("healthy", spawn_seam: scripted_seam(["read intro", "read methods", "wrote summary"]),
                               grader: never_grader)

      expect(run.timeline.to_a.map(&:role)).to eq(%w[user assistant] * 3)
    end
  end

  # BLOCKER 2 (panel): a run has to be able to END without being labelled stuck.
  # Settling used to be reachable only THROUGH a replan, so "this run stopped
  # early" and "this run stalled" were the same journal record, and the
  # replans/stalls count -- a bench metric -- doubled as the termination reason.
  # The machine's own terminal moves say it instead: `stall -> :stalled` with no
  # replan behind it for a ledger that terminally dried up, `end_turn -> :done`
  # for every other exit.
  #
  # `:done` therefore asserts "the ceiling bound this run before its ledger
  # terminally dried up" and nothing stronger -- a run that stalled on its last
  # step and bought a rewrite it never got to try ends `:done` too. The example
  # below happens to have no stall behind it because its model advances every
  # step; that is the fixture, not the state's meaning.
  describe "how a run ENDED is journaled, not inferred" do
    it "journals a run the ceiling bound as a terminal `done`" do
      journaled = []
      arm = described_class.new(stall_limit: 1, max_steps: 3,
                                journal_factory: -> { recording_journal(journaled).new })

      arm.run("healthy", spawn_seam: scripted_seam(["read intro", "read methods", "wrote summary"]),
                         grader: never_grader)

      expect(transition_events(journaled)).to eq(%i[dispatch dispatch dispatch end_turn])
      expect(journaled.grep(Lain::Arm::DualLedger::LedgerTransition).last.to_journal)
        .to eq({ "type" => "ledger_transition", "from" => :awaiting_model, "to" => :done, "event" => :end_turn })
    end

    it "journals a ledger that dried up as a terminal `stall`, the rewrite already spent" do
      journaled = []
      arm = described_class.new(journal_factory: -> { recording_journal(journaled).new })

      arm.run("stuck", spawn_seam:, grader: never_grader)

      # K + 2 steps: one that advances, K that do not (the last buying the
      # rewrite), and one more proving the rewrite did not take.
      expect(transition_events(journaled))
        .to eq(%i[dispatch dispatch dispatch dispatch stall replan dispatch stall])
    end

    it "does not call a dried-up run done -- the two terminal moves never both appear" do
      journaled = []
      arm = described_class.new(journal_factory: -> { recording_journal(journaled).new })

      arm.run("stuck", spawn_seam:, grader: never_grader)

      expect(transition_events(journaled)).not_to include(:end_turn)
    end
  end

  # SHOULD-FIX (panel): both are public constructor keywords on a class built to
  # be parameter-swept, and both had degenerate values that produced a run
  # nobody would recognise, silently. `stall_limit: 0` replanned before any step
  # had failed to progress; a `max_steps` below `stall_limit + 2` left the loop
  # unable to reach its settling step at all, so it burned the ceiling for a
  # reason no reader could guess from the constructor.
  describe "a config that could not settle is refused at construction" do
    it "refuses a stall_limit below 1 -- K is a count of no-progress steps" do
      expect { described_class.new(stall_limit: 0) }.to raise_error(ArgumentError, /stall_limit/)
    end

    it "refuses a max_steps the settling step cannot be reached within, naming the relation" do
      expect { described_class.new(stall_limit: 4, max_steps: 5) }
        .to raise_error(ArgumentError, /max_steps/)
    end

    it "accepts the tightest config that can still settle: max_steps == stall_limit + 2" do
      expect { described_class.new(stall_limit: 4, max_steps: 6) }.not_to raise_error
      expect(described_class.new(stall_limit: 4, max_steps: 6)).to be_a(described_class)
    end
  end

  # AC1: The ledger rides the Workspace, sent-not-stored.
  describe "the Task/Progress ledger rides the Workspace, never the Timeline" do
    subject(:run) do
      described_class.new.run("summarize the paper", spawn_seam: spawn_seam(captured), grader: passing_grader)
    end

    let(:captured) { [] }

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

      transitions = journaled.grep(Lain::Arm::DualLedger::LedgerTransition).map(&:to_journal)
      expect(transitions).to include({ "type" => "ledger_transition", "from" => :awaiting_model,
                                       "to" => :stalled, "event" => :stall })
      expect(transitions).to include({ "type" => "ledger_transition", "from" => :stalled,
                                       "to" => :awaiting_model, "event" => :replan })
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

      single = Lain::Arm::SingleThread.new.run("t", spawn_seam: seam, grader: passing_grader)
      dual = described_class.new.run("t", spawn_seam: seam, grader: passing_grader)

      expect(single).to be_a(Lain::Arm::Run)
      expect(dual).to be_a(Lain::Arm::Run)
    end
  end

  describe "the injected isolation seam" do
    # See single_thread_spec: the real Lease, because reclaim-then-surrender
    # relies on its idempotent-loud release to reclaim exactly once.
    it "acquires a lease and releases it exactly once, even though the ledger arm ignores its env" do
      released = []
      lease = Lain::Isolation::Lease.new(worker_env: Lain::WorkerEnv.default, on_release: -> { released << :once })
      isolation = instance_double(Lain::Isolation::Null, acquire: lease)

      described_class.new.run("t", spawn_seam:, grader: passing_grader, isolation:)

      expect(isolation).to have_received(:acquire)
      expect(lease).to be_released
      expect(released).to eq([:once])
    end
  end
end
