# frozen_string_literal: true

require "stringio"
require "tmpdir"

RSpec.describe Lain::CLI::Command::Mode do
  subject(:command) { described_class.new }

  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }

  def switch_for(approval, *layers)
    Lain::Mode::Switch.new(Lain::Mode.new(approval:, layers:), journal:)
  end

  def env_for(switch, dispatching: false)
    instance_double(Lain::CLI::Command::Env, mode_switch: switch,
                                             agent: instance_double(Lain::Agent, dispatching?: dispatching))
  end

  def flips = Lain::Journal.records(journal_io.string.lines, type: "mode_switch").to_a

  it "registers as /mode with a one-line usage naming the reset" do
    expect(command.name).to eq("mode")
    expect(command.usage).to include("/mode").and include("!")
  end

  describe "bare /mode" do
    it "reports the scope, the approval and every active layer" do
      switch = switch_for(:ask, :goal)

      expect(command.call("", env_for(switch))).to eq("checkout ask: goal (GOAL)")
    end

    it "reports without switching or journaling" do
      switch = switch_for(:ask, :goal)
      command.call("  ", env_for(switch))

      expect(switch.current).to eq(Lain::Mode.new(layers: [:goal]))
      expect(flips).to be_empty
    end
  end

  describe "/mode <approval> and /mode <scope>" do
    it "switches the approval level the session runs under" do
      switch = switch_for(:ask)
      command.call("auto", env_for(switch))

      expect(switch.approval.name).to eq(:auto)
    end

    it "journals the change attributed to the tty" do
      switch = switch_for(:auto)
      command.call("ask", env_for(switch))

      expect(flips).to contain_exactly(
        a_hash_including("from_approval" => "auto", "to_approval" => "ask", "surface" => "tty")
      )
    end

    it "keeps the layers already enabled -- an axis is one slot, not the whole mode" do
      switch = switch_for(:ask, :goal)
      command.call("auto", env_for(switch))

      expect(switch.layers.names).to eq([:goal])
    end

    it "takes a token for each axis in one invocation" do
      switch = switch_for(:ask)
      command.call("checkout auto", env_for(switch))

      expect(switch.current).to eq(Lain::Mode.new(scope: :checkout, approval: :auto))
    end

    it "returns rendered text naming both the old and the new mode, never printing" do
      switch = switch_for(:ask)
      text = nil

      expect { text = command.call("auto", env_for(switch)) }.not_to output.to_stdout
      expect(text).to be_a(String).and include("ask").and include("auto")
    end

    # Mode#describe carries its own colon, so a "mode: " prefix stutters.
    it "renders the transition without restating the subject" do
      switch = switch_for(:ask, :goal)

      expect(command.call("auto", env_for(switch)))
        .to eq("checkout ask: goal (GOAL) -> checkout auto (AUTO): goal (GOAL)")
    end

    it "writes nothing for a token naming the value already in force" do
      switch = switch_for(:auto)
      command.call("auto", env_for(switch))

      expect(flips).to be_empty
    end
  end

  describe "/mode +layer and /mode -layer" do
    it "enables one layer without touching either axis" do
      switch = switch_for(:ask)
      command.call("+auto_approve", env_for(switch))

      expect(switch.approval.name).to eq(:ask)
      expect(switch.layers).to include(:auto_approve)
    end

    it "disables one layer without touching either axis -- the other half of the toggle" do
      switch = switch_for(:auto, :auto_approve, :goal)
      command.call("-auto_approve", env_for(switch))

      expect(switch.approval.name).to eq(:auto)
      expect(switch.layers.names).to eq([:goal])
    end

    it "disabling a layer that was never enabled is a no-op, not a refusal" do
      switch = switch_for(:ask)

      expect { command.call("-goal", env_for(switch)) }.not_to raise_error
      expect(switch.layers).to be_empty
    end

    it "applies an axis and a layer in one invocation, journaling one flip" do
      switch = switch_for(:ask, :goal)
      command.call("auto +notify -goal", env_for(switch))

      expect(switch.current).to eq(Lain::Mode.new(approval: :auto, layers: [:notify]))
      expect(flips.size).to eq(1)
    end
  end

  describe "tokens from one axis" do
    # Scenario: contradictory tokens refuse
    it "refuses two approval tokens, naming both, and leaves the mode unchanged" do
      switch = switch_for(:ask)

      expect { command.call("ask auto", env_for(switch)) }
        .to raise_error(Lain::Error, /\bask\b.*\bauto\b/)
      expect(switch.current).to eq(Lain::Mode.new(approval: :ask))
      expect(flips).to be_empty
    end

    it "refuses even when the second token repeats the first" do
      switch = switch_for(:ask)

      expect { command.call("auto auto", env_for(switch)) }.to raise_error(Lain::Error, /approval twice/)
    end
  end

  describe "a retired name" do
    # Scenario: retired names refuse
    it "refuses manual by name, listing the tokens /mode takes" do
      switch = switch_for(:ask)

      expect { command.call("manual", env_for(switch)) }
        .to raise_error(Lain::Error) { |error| expect(error.message).to include("manual", "ask", "auto", "checkout") }
      expect(flips).to be_empty
    end

    it "refuses accept_edits by name, saying what it became" do
      expect { command.call("accept_edits", env_for(switch_for(:auto))) }
        .to raise_error(Lain::Error, /accept_edits is retired: it is ask now/)
    end

    it "moves the scope to plan, keeping the approval level" do
      switch = switch_for(:auto)
      command.call("plan", env_for(switch))

      expect([switch.scope.name, switch.approval.name]).to eq(%i[plan auto])
      expect(flips).to contain_exactly(a_hash_including("from_scope" => "checkout", "to_scope" => "plan"))
    end

    it "refuses checkout and plan together, naming both" do
      switch = switch_for(:ask)

      expect { command.call("checkout plan", env_for(switch)) }.to raise_error(Lain::Error, /checkout plan.*scope/)
      expect(flips).to be_empty
    end

    it "refuses a retired name among other tokens, applying none of them" do
      switch = switch_for(:ask)

      expect { command.call("auto +vi manual", env_for(switch)) }.to raise_error(Lain::Error, /manual/)
      expect(switch.current).to eq(Lain::Mode.new)
    end
  end

  describe "the reset" do
    # The most confined mode there is: nothing written reaches the checkout,
    # and nothing is decided without asking.
    it "lands in plan scope and ask approval from any mode" do
      switch = switch_for(:auto, :auto_approve, :goal, :notify)
      command.call("!", env_for(switch))

      expect([switch.scope.name, switch.approval.name]).to eq(%i[plan ask])
    end

    it "clears every layer too -- a reset that leaves auto_approve on has not reset anything" do
      switch = switch_for(:auto, :auto_approve, :goal, :notify)
      command.call("!", env_for(switch))

      expect(switch.layers).to be_empty
    end

    # The reset is reachable as `/mode !` and NOT as `/mode!`: the invocation
    # grammar's identifier is `[\w-]+`, so the trailing bang leaves the line
    # matching nothing and it falls through to the skill middleware as prose.
    # Pinned here rather than fixed: the grammar is shared, and widening it is
    # a deferred design decision (chunk-compaction-tiers-pins-isolation.md).
    # This example going red is the signal that whoever widens it must also
    # decide how the modifier reaches a command.
    # The reset is a safety step first. A spike that cannot be cut -- an empty
    # repository, a git failure, a board with nothing to cut from -- must not
    # leave `auto` and its layers in force.
    describe "when plan scope cannot be entered" do
      let(:chronicle) { instance_double(Lain::CLI::Chronicle, record_journal: journal) }
      let(:board) do
        Lain::CLI::Switchboard.for(chronicle:, options: { auto_approve: true }, model: "m",
                                   toolset: Lain::Toolset.new([Lain::Tools::Bash.new]),
                                   test_layout: Lain::Middleware::GuardTestLayout::Run.undeclared)
                              .bind_session(Lain::Session.new)
      end

      it "still lowers approval to ask and drops every layer, staying in the checkout" do
        command.call("auto", env_for(board.mode_switch))
        command.call("!", env_for(board.mode_switch))

        expect(board.mode_switch.current).to eq(Lain::Mode.new)
        expect(board.policy_switch.current).to be(board.ladder)
      end

      it "says in words that plan scope could not be entered, and why" do
        told = command.call("!", env_for(board.mode_switch))

        expect(told).to include("checkout ask: no layers active", "plan scope could not be entered",
                                "needs a project")
      end
    end

    it "arrives as an argument, because the invocation grammar rejects a trailing bang" do
      expect(Lain::Skill::Invocation.parse("/mode!")).to be_nil
      expect(Lain::Skill::Invocation.parse("/mode !").args).to eq("!")
    end
  end

  # Moving a scope moves where every tool resolves and runs, and gives a spike
  # back that a call still running may be writing in.
  describe "a scope flip while the agent is dispatching" do
    it "refuses entering plan, in words, and moves nothing" do
      switch = switch_for(:ask)

      expect { command.call("plan", env_for(switch, dispatching: true)) }
        .to raise_error(Lain::Error, /cannot move the scope while a turn is in flight/)
      expect([switch.current, flips]).to eq([Lain::Mode.new, []])
    end

    it "refuses leaving plan too" do
      switch = Lain::Mode::Switch.new(Lain::Mode.new(scope: :plan), journal:)

      expect { command.call("checkout", env_for(switch, dispatching: true)) }
        .to raise_error(Lain::Error, /cannot move the scope/)
    end

    # The reset is the safety step, and a turn in flight is exactly when a
    # human reaches for it: the approval and the layers drop at once, and only
    # the move to plan scope waits.
    describe "the reset" do
      let(:chronicle) { instance_double(Lain::CLI::Chronicle, record_journal: journal) }
      let(:board) do
        Lain::CLI::Switchboard.for(chronicle:, options: { auto_approve: true }, model: "m",
                                   toolset: Lain::Toolset.new([Lain::Tools::Bash.new]),
                                   test_layout: Lain::Middleware::GuardTestLayout::Run.undeclared)
                              .bind_session(Lain::Session.new)
      end

      it "lowers approval to ask and drops every layer in the scope it is in" do
        command.call("auto", env_for(board.mode_switch))
        command.call("!", env_for(board.mode_switch, dispatching: true))

        expect(board.mode_switch.current).to eq(Lain::Mode.new)
        expect(board.policy_switch.current).to be(board.ladder)
      end

      it "says the move to plan scope waits until the turn ends" do
        told = command.call("!", env_for(board.mode_switch, dispatching: true))

        expect(told).to include("checkout ask: no layers active", "plan scope waits until the turn in flight ends")
      end
    end

    it "lets a flip that keeps the scope through" do
      switch = switch_for(:ask)
      command.call("auto +vi", env_for(switch, dispatching: true))

      expect(switch.approval.name).to eq(:auto)
    end
  end

  describe "an unknown name" do
    it "raises a recoverable Lain::Error naming every scope and approval token" do
      switch = switch_for(:ask)

      expect { command.call("turbo", env_for(switch)) }
        .to raise_error(Lain::Error, /turbo/) { |error| expect(error.message).to include(*axis_names) }
    end

    it "leaves the mode in force and journals nothing, so the repl loops on the same mode" do
      switch = switch_for(:auto)
      suppress(Lain::Error) { command.call("auto turbo", env_for(switch)) }

      expect(switch.approval.name).to eq(:auto)
      expect(flips).to be_empty
    end

    it "raises a recoverable Lain::Error naming every declared layer" do
      switch = switch_for(:ask)

      expect { command.call("+nonsense", env_for(switch)) }
        .to raise_error(Lain::Error) { |error| expect(error.message).to include(*layer_names) }
    end

    it "refuses a bare sigil rather than enabling nothing quietly" do
      switch = switch_for(:ask)

      expect { command.call("+", env_for(switch)) }.to raise_error(Lain::Error)
    end
  end

  # The bare-token/sigil-token split is unambiguous only while no declared name
  # opens with a sigil or with the reset token, and nothing in lib/ enforces
  # that. Asserted here so the day someone declares a layer `:"-x"` -- which
  # this command would route as "disable x", silently unreachable -- is the day
  # an example goes red rather than the day a toggle stops working.
  it "holds: no declared scope, approval or layer name opens with a sigil" do
    names = axis_names + Lain::Mode::Layer::NAMES.map(&:to_s)

    expect(names).to all(satisfy { |name| !name.start_with?("+", "-", described_class::RESET) })
  end

  # A bare token is looked up by which roster holds it, so one name on both
  # rosters would be unreachable on one of them.
  it "holds: no name is both a scope and an approval level" do
    expect(Lain::Mode::Scope::NAMES & Lain::Mode::Approval::NAMES).to be_empty
  end

  describe "case" do
    it "accepts the upper-case approval the prompt's own lighter teaches" do
      switch = switch_for(:ask)
      command.call("AUTO", env_for(switch))

      expect(switch.approval.name).to eq(:auto)
    end

    it "accepts an upper-case layer token too, sigil and all" do
      switch = switch_for(:ask)
      command.call("+GOAL", env_for(switch))

      expect(switch.layers).to include(:goal)
    end
  end

  # The same command over the switch a real chat hands it -- a board's
  # BoundSwitch -- read back through the predicate the automatic approval
  # surface asks on every sweep, so a toggle here is the toggle that surface
  # sees.
  describe "the auto_approve layer, over a real board" do
    let(:chronicle) { instance_double(Lain::CLI::Chronicle, record_journal: journal) }
    let(:tools) { Lain::Toolset.new(ToolRegistry.names.map { |name| ToolRegistry.build(name) }) }

    # The reset enters plan scope, so the board can lease a scratch directory
    # and holds a session to confine there.
    around do |example|
      Dir.mktmpdir("lain-mode-reset") do |dir|
        @scratch = dir
        example.run
      end
    end

    def board_for(**options)
      Lain::CLI::Switchboard.for(chronicle:, options:, model: "claude-opus-4-8", toolset: tools,
                                 spike: Lain::Isolation::Scratch.new(root: @scratch),
                                 test_layout: Lain::Middleware::GuardTestLayout::Run.undeclared)
                            .bind_session(Lain::Session.new)
    end

    def engaged?(board) = Lain::CLI::Wiring::ToolsetBuild::AutoApproveLayer.new(board: -> { board }).call

    it "engages the automatic approver on +auto_approve and withdraws it on -auto_approve" do
      board = board_for
      readings = [engaged?(board)]
      command.call("+auto_approve", env_for(board.mode_switch))
      readings << engaged?(board)
      command.call("-auto_approve", env_for(board.mode_switch))

      expect(readings << engaged?(board)).to eq([false, true, false])
    end

    it "withdraws a layer the launch flag turned on, and the reset withdraws it too" do
      %w[-auto_approve !].each do |args|
        board = board_for(auto_approve: true)
        launched = engaged?(board)
        command.call(args, env_for(board.mode_switch))

        expect([launched, engaged?(board)]).to eq([true, false]), "#{args} did not withdraw the launch flag's layer"
      end
    end

    it "lists the layer the launch flag turned on, before any /mode has run" do
      board = board_for(auto_approve: true)

      expect(command.call("", env_for(board.mode_switch))).to eq("checkout ask: auto_approve (AA)")
      expect(flips.map { |flip| flip["surface"] }).to eq([Lain::CLI::Switchboard::LAUNCH_SURFACE])
    end
  end

  # The goal layer belongs to the standing-goal driver: the switch a chat hands
  # this command is the driver's guard over the board's, so the layer can only
  # show a goal that stands, and lowering it ends that goal.
  describe "the goal layer, over a real board and a real driver" do
    let(:chronicle) { instance_double(Lain::CLI::Chronicle, record_journal: journal) }
    let(:tools) { Lain::Toolset.new(ToolRegistry.names.map { |name| ToolRegistry.build(name) }) }
    let(:board) do
      Lain::CLI::Switchboard.for(chronicle:, options: {}, model: "claude-opus-4-8", toolset: tools,
                                 spike: Lain::Isolation::Scratch.new(root: @scratch),
                                 test_layout: Lain::Middleware::GuardTestLayout::Run.undeclared)
                            .bind_session(Lain::Session.new)
    end
    let(:driver) do
      Lain::CLI::GoalDriver.new(journal:, layer: Lain::CLI::GoalDriver::Layer.new(-> { board.mode_switch }))
    end
    let(:env) { env_for(driver.guarding(board.mode_switch)) }

    # The reset enters plan scope; see the auto_approve layer's examples.
    around do |example|
      Dir.mktmpdir("lain-mode-reset") do |dir|
        @scratch = dir
        example.run
      end
    end

    it "refuses +goal with no standing goal, naming /goal <objective>, and switches nothing" do
      expect { command.call("auto +goal", env) }.to raise_error(Lain::Error, %r{/goal <objective>})
      expect(board.mode_switch.current).to eq(Lain::Mode.new)
      expect(flips).to be_empty
    end

    it "takes +goal while a goal stands, since the layer is already the driver's" do
      driver.start("ship the parser")

      expect(command.call("+goal", env)).to end_with("goal (GOAL)")
    end

    it "stops the standing goal on -goal, and on the reset" do
      %w[-goal !].each do |args|
        driver.start("ship the parser")
        command.call(args, env)

        expect(driver).not_to be_active, "#{args} left the goal standing"
        expect(board.mode_switch.layers).not_to include(:goal)
      end
    end

    # A lowering flip whose record landed is committed, so the goal stops even
    # when a live view fails after the record.
    it "stops the standing goal on -goal when a live sink fails after the record landed" do
      sink = Object.new
      def sink.<<(_event) = raise(IOError, "state file write failed")
      teed = Lain::CLI::Switchboard.new(journal: Lain::CLI::JournalTee.new(journal, sink), model: "m", toolset: tools)
      goals = Lain::CLI::GoalDriver.new(journal:, layer: Lain::CLI::GoalDriver::Layer.new(-> { teed.mode_switch }))
      suppress(IOError) { goals.start("ship the parser") }

      expect { command.call("-goal", env_for(goals.guarding(teed.mode_switch))) }.to raise_error(IOError)
      expect([goals.active?, teed.mode_switch.layers.include?(:goal)]).to eq([false, false])
    end

    it "leaves a standing goal alone when a flip keeps its layer" do
      driver.start("ship the parser")
      command.call("auto +notify", env)

      expect(driver).to be_active
      expect(board.mode_switch.layers.names).to eq(%i[goal notify])
    end
  end

  def axis_names = (Lain::Mode::Scope::NAMES + Lain::Mode::Approval::NAMES).map(&:to_s)

  def layer_names = Lain::Mode::Layer::NAMES.map(&:to_s)

  def suppress(error_class)
    yield
  rescue error_class
    nil
  end
end
