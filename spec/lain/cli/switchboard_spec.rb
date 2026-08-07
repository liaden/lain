# frozen_string_literal: true

require "stringio"

RSpec.describe Lain::CLI::Switchboard do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }

  # A REAL Toolset, for the reason resolution_spec and posture_spec both record:
  # a verifying double's `#only` accepts any argument list at all, so a posture
  # naming a tool no live set holds would satisfy every example here and raise
  # at the first `/mode plan` of a real session instead.
  let(:base) { Lain::Toolset.new(ToolRegistry.names.map { |name| ToolRegistry.build(name) }) }

  def switchboard(yolo: false, toolset: base)
    described_class.new(journal:, yolo:, model: "claude-opus-4-8", toolset:)
  end

  def mode(posture) = Lain::Mode.new(posture:)

  def gated_call = Struct.new(:name, :input, :tool_use_id).new("bash", { "command" => "ls" }, "tu_1")

  def mode_records = Lain::Journal.records(journal_io.string.lines, type: "mode_switch").to_a

  def policy_records = Lain::Journal.records(journal_io.string.lines, type: "policy_switch").to_a

  describe "the approval side" do
    # T21: the queue is still the parked list, but what the gate holds is the
    # LADDER over it -- the deterministic rungs answer first, and the queue is
    # where a call lands when they abstain.
    it "wires the queue as the parked list and the ladder over it as the gate's starting policy" do
      board = switchboard

      expect(board.approvals).to be_a(Lain::Approval::Queue)
      expect(board.ladder).to be_a(Lain::Approval::Escalation)
      expect(board.policy_switch.current).to be(board.ladder)
    end

    it "wires the deterministic rungs below the surfaces, journaling to the session journal" do
      board = switchboard

      expect(board.ladder.map(&:name)).to eq(%w[triage rules surfaces])

      Sync do |task|
        parked = task.async { board.policy_switch.call(gated_call, nil) }
        task.with_timeout(1) { board.approvals.dequeue }

        expect(Lain::Journal.records(journal_io.string.lines, type: "escalation")
                            .map { |record| record["rung"] }.to_a).to eq(%w[triage rules])
      ensure
        parked&.stop
      end
    end

    it "wires NO queue under --yolo, starting the switch on ApproveAll" do
      board = switchboard(yolo: true)

      expect(board.approvals).to be_nil
      expect(board.policy_switch.call("effect", nil)).to be(true)
    end
  end

  # The card that built the ledger owns this: T15 (masking) reads it and T16 (the
  # prompt) writes it, through different files in different waves, so two
  # half-wirings would give the run two ledgers and a release control that
  # silently releases nothing. One board, one ledger, and it is exposed for that
  # reason alone.
  #
  # `switchboard` here is the HELPER METHOD at the top of this file, not a `let`,
  # so every call builds a fresh board. That is what makes "the SAME one every
  # time" and "not shared between two boards" agree rather than contradict --
  # the first pins one board, the second pins two. Memoize the helper into a
  # `let` and the second example goes red for a reason that is not about the
  # subject.
  describe "the region ledger" do
    it "holds one" do
      expect(switchboard.ledger).to be_a(Lain::Sensitivity::Ledger)
    end

    it "answers the SAME one every time, so a late reader cannot get a second" do
      board = switchboard

      expect(board.ledger).to be(board.ledger)
    end

    # The posture decides who is asked, not whether the run has somewhere to
    # record an answer -- and --yolo wires no queue, so this is the arm most
    # likely to be skipped by accident.
    it "holds one under --yolo too, where there is no queue" do
      expect(switchboard(yolo: true).ledger).to be_a(Lain::Sensitivity::Ledger)
    end

    it "does not share one between two boards, which is what a run-scoped ledger means" do
      expect(switchboard.ledger).not_to be(switchboard.ledger)
    end
  end

  describe "the model side" do
    let(:store) { Lain::Store.new }
    let(:timeline) do
      Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
    end

    it "grafts the live model slot onto a context, read at render time" do
      board = switchboard
      grafted = board.graft(Lain::Context.new(model: "claude-opus-4-8", max_tokens: 64))

      board.model_switch.switch("claude-haiku-4-5", surface: "tty")

      expect(grafted.render(timeline:, toolset: Lain::Toolset.new).model).to eq("claude-haiku-4-5")
    end
  end

  # T10. T5 established WHERE the live mode lives; these are the examples that
  # say a flip DOES something -- it re-binds the gate policy the construction-
  # fixed Gate reads and the capability set the construction-fixed Agent renders.
  describe "the mode side, bound to the live gate and the live toolset" do
    let(:store) { Lain::Store.new }
    let(:timeline) do
      Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
    end
    let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 64) }

    def rendered_tools(board) = context.render(timeline:, toolset: board.toolset).tools.map { |tool| tool["name"] }

    describe "--yolo, which is the auto posture said on the other axis" do
      it "starts in auto and approves a tier-3 call with no queue to park it on" do
        board = switchboard(yolo: true)

        expect(board.mode_switch.posture.name).to eq(:auto)
        expect(board.approvals).to be_nil
        expect(board.policy_switch.call(gated_call, nil)).to be(true)
      end

      # The ladder is what chooses the starting policy now, so --yolo says
      # ApproveAll exactly once. Construction still journals nothing: the
      # initial policy is the wiring's choice and is already in the flags.
      it "journals no flip for the mode it was constructed in" do
        switchboard(yolo: true)

        expect(mode_records).to be_empty
        expect(policy_records).to be_empty
      end
    end

    describe "a posture flip at runtime" do
      it "approves a tier-3 call without parking it once the posture switches to auto" do
        board = switchboard
        board.mode_switch.switch(mode(:manual), surface: "tty")

        Sync do |task|
          parked = task.async { board.policy_switch.call(gated_call, nil) }
          task.with_timeout(1) { board.approvals.dequeue }
          expect(board.approvals.each.count).to eq(1)

          board.mode_switch.switch(mode(:auto), surface: "tty")

          # Bounded, and not as belt-and-braces: a break that leaves the policy
          # switch untouched parks this call on the queue FOREVER, and an
          # unbounded example then hangs the whole suite instead of failing --
          # which is how a mutation run lost a five-minute batch to it.
          expect(task.with_timeout(1) { board.policy_switch.call(gated_call, nil) }).to be(true)
          expect(board.approvals.each.count).to eq(1)
        ensure
          parked&.stop
        end
      end

      it "restores the queue when the posture switches back to an asking rung" do
        board = switchboard

        board.mode_switch.switch(mode(:auto), surface: "tty")
        # The board STARTS on the ladder, so asserting only the destination is
        # vacuous -- "never moved" and "moved back" are the same reading. This
        # is the leg that tells them apart.
        expect(board.policy_switch.current).not_to be(board.ladder)

        board.mode_switch.switch(mode(:manual), surface: "tty")

        expect(board.policy_switch.current).to be(board.ladder)
      end

      # The gate flip rides the SAME journal /yolo's does, so a transcript shows
      # one policy history rather than two half-histories to be joined by hand.
      it "journals the gate flip through the one policy switch, attributed to the surface" do
        board = switchboard

        board.mode_switch.switch(mode(:auto), surface: "editor")

        expect(policy_records.last).to include("to" => "approve_all", "surface" => "editor")
      end
    end

    describe "plan, which takes the capability away rather than gating it" do
      it "drops edit_file from a subsequent render" do
        board = switchboard
        board.mode_switch.switch(mode(:manual), surface: "tty")
        expect(rendered_tools(board)).to include("edit_file")

        board.mode_switch.switch(mode(:plan), surface: "tty")

        expect(rendered_tools(board)).not_to include("edit_file")
      end

      # The whole reason this card did not have to rebuild the Agent: the
      # capability set is a SLOT the Agent and its executor already hold, so the
      # object identity wiring_spec pins across a session survives the flip.
      it "re-binds the slot in place, so the Agent still holds the object it was built with" do
        board = switchboard
        live = board.toolset

        board.mode_switch.switch(mode(:plan), surface: "tty")

        expect(board.toolset).to equal(live)
        expect(live.names).not_to include("edit_file", "write_file", "bash")
        expect(live.fetch("read_file")).to be_a(Lain::Tools::ReadFile)
      end

      # The slot is the possession, and possession IS authorization here -- so
      # the reader the Agent hands around must not offer a way to disarm a live
      # session with no journal line and no mode change behind it. The board is
      # the only writer.
      it "hands out a read-only face: no writer, and frozen" do
        live = switchboard.toolset

        expect(live).to be_frozen
        expect(live).not_to respond_to(:bind)
        expect(live).not_to respond_to(:only)
      end

      # A slot is not a value. Said out loud because Toolset#== exists and the
      # asymmetry would otherwise read as an oversight.
      it "is not == to the set it holds, in either direction" do
        live = switchboard.toolset

        expect(live == live.current).to be(false)
        expect(live.current == live).to be(false)
      end

      it "restores the full set on the way back out, because it re-resolves from the base" do
        board = switchboard
        board.mode_switch.switch(mode(:plan), surface: "tty")

        board.mode_switch.switch(mode(:manual), surface: "tty")

        expect(board.toolset.names).to eq(base.names)
      end
    end

    # The doctrine /yolo off already states, one rung up: a session that wired
    # no queue cannot enter a posture that parks on one, and inventing a policy
    # would journal the run as `manual` while approving everything.
    describe "a posture that needs a queue this session never wired" do
      it "refuses the flip loudly" do
        board = switchboard(yolo: true)

        expect { board.mode_switch.switch(mode(:manual), surface: "tty") }
          .to raise_error(Lain::Error, /no approval queue/)
      end

      # The run is otherwise partitioned into {auto, plan} for its whole life,
      # so the refusal has to name the only way out rather than leave the
      # operator guessing at a command that cannot exist.
      it "names the remedy, which is a restart and not a command" do
        board = switchboard(yolo: true)

        expect { board.mode_switch.switch(mode(:accept_edits), surface: "tty") }
          .to raise_error(Lain::Error, /restart without --yolo/)
      end

      it "leaves the mode where it was, and journals nothing" do
        board = switchboard(yolo: true)

        expect { board.mode_switch.switch(mode(:manual), surface: "tty") }.to raise_error(Lain::Error)

        expect(board.mode_switch.posture.name).to eq(:auto)
        expect(mode_records).to be_empty
      end

      it "still refuses /yolo off, because there is no prior policy to restore either" do
        board = switchboard(yolo: true)
        env = build_command_env(policy_switch: board.policy_switch)

        expect { Lain::CLI::Command::Yolo.new.call("off", env) }
          .to raise_error(Lain::Error, /nothing to restore/)
        expect(board.policy_switch.call(gated_call, nil)).to be(true)
      end
    end
  end

  it "hands /approve a tty-signing drain prompt whose reads route through the conductor" do
    conductor = instance_double(Lain::CLI::Conductor)
    tty = instance_double(Lain::Frontend::TTY)
    prompt = switchboard.surface_kwargs(conductor:, tty:).fetch(:approval_prompt)
    pending = Lain::Approval::Queue::Pending.new(
      effect: Struct.new(:name, :input, :tool_use_id).new("bash", { "command" => "ls" }, "tu_1"),
      requester: "agent", clock: -> { 0.0 }
    )
    allow(conductor).to receive(:read_reply).with(tty, /bash/).and_return("y")

    prompt.decide(pending)

    expect(pending.surface).to eq("tty")
    expect(pending).to be_approved
  end
end
