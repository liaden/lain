# frozen_string_literal: true

# B11 adds a `:stalled` state and a `stall! -> replan!` pair to the shared
# {Lain::Agent::LoopMachine} for the dual-ledger arm's outer loop. These specs
# pin the two things the card's escalation trigger cares about: the addition is
# purely ADDITIVE (no move that was legal before becomes illegal, and the
# FAILURE_REASONS/StopReason totality is untouched), and firing `replan!`
# announces through the SAME `before_transition` hook the Journal subscribes to.
#
# The companion `agent_state_machine_spec.rb` still passes UNCHANGED -- that
# transparency bar (the existing transition table asserted there is intact) is
# the whole point of the escalation trigger.
RSpec.describe Lain::Agent::LoopMachine do
  # A minimal includer standing in for both the Agent and the arm's Planner:
  # it wires only the announce listener the mixin needs, so these examples pin
  # the MACHINE, not either driver.
  let(:includer_class) do
    Class.new do
      include Lain::Agent::LoopMachine

      def initialize(listener)
        super()
        @transition_listener = listener
      end
    end
  end

  # Records every announced transition, standing in for the Journal the
  # `before_transition` seam exists for.
  let(:recorder) do
    Class.new do
      attr_reader :seen

      def initialize = @seen = []
      def on_transition(from:, to:, event:) = @seen << { from:, to:, event: }
    end
  end

  let(:listener) { recorder.new }
  subject(:machine) { includer_class.new(listener) }

  describe "the addition is additive -- nothing legal before is illegal now" do
    it "declares the new :stalled state without dropping any prior state" do
      expect(Lain::Agent::STATES).to include(:awaiting_user, :awaiting_model, :awaiting_tools,
                                             :awaiting_approval, :done, :failed, :stalled)
    end

    it "keeps every pre-B11 stop_reason event landing exactly where it did" do
      # The gate this pins: adding stall/replan must not perturb the StopReason
      # transition table. Asserted here directly so a regression is loud in the
      # loop-machine spec, not only in the Agent's own totality spec.
      moves = { tool_use: :awaiting_tools, pause_turn: :awaiting_model, end_turn: :done,
                stop_sequence: :done, max_tokens: :failed, refusal: :failed, unknown: :failed }
      moves.each do |event, target|
        m = includer_class.new(listener)
        m.__send__(:dispatch!) # awaiting_user -> awaiting_model
        # `to eq(target)`, not `change().to()`: pause_turn is a legal SELF-loop
        # (awaiting_model -> awaiting_model), so "did the state change" is the
        # wrong question -- "did it land where it always did" is the invariant.
        expect { m.__send__(:"#{event}!") }.not_to raise_error
        expect(m.state).to eq(target)
      end
    end

    it "leaves the failing-event totality intact (stall/replan never reach :failed)" do
      failing = Lain::Agent.state_machine(:state).events.select do |event|
        event.branches
             .flat_map { |branch| branch.state_requirements.map { |req| req[:to].values } }
             .flatten.include?(:failed)
      end
      expect(failing.map(&:name)).to match_array(%i[max_tokens refusal unknown])
    end
  end

  describe "the stall -> replan pair" do
    before { machine.__send__(:dispatch!) } # reach :awaiting_model

    it "parks in :stalled on stall! and resumes :awaiting_model on replan!" do
      expect { machine.__send__(:stall!) }.to change(machine, :state).to(:stalled)
      expect { machine.__send__(:replan!) }.to change(machine, :state).to(:awaiting_model)
    end

    it "raises on replan! from a non-stalled state rather than silently accepting it" do
      expect { machine.__send__(:replan!) }
        .to raise_error(StateMachines::InvalidTransition, /from :awaiting_model/)
    end

    it "announces the replan through before_transition -- the journaling seam" do
      machine.__send__(:stall!)
      machine.__send__(:replan!)

      expect(listener.seen).to include({ from: :stalled, to: :awaiting_model, event: :replan })
    end
  end

  describe "the dual-ledger Planner journals the replan onto the run's Journal" do
    it "turns the before_transition announcement into a LedgerTransition record" do
      journal = Lain::Channel.new
      planner = Lain::Arm::DualLedger::Planner.new(
        transition_listener: Lain::Arm::DualLedger::Journaling.new(journal)
      )

      planner.__send__(:dispatch!)
      planner.__send__(:stall!)
      planner.__send__(:replan!)

      replans = journal.drain.select { |e| e.is_a?(Lain::Arm::DualLedger::LedgerTransition) && e.event == :replan }
      expect(replans.map(&:to_journal))
        .to eq([{ "type" => "ledger_transition", "from" => :stalled, "to" => :awaiting_model, "event" => :replan }])
    end
  end
end
