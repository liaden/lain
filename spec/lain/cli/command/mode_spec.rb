# frozen_string_literal: true

require "stringio"

RSpec.describe Lain::CLI::Command::Mode do
  subject(:command) { described_class.new }

  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }

  def switch_for(posture, *layers)
    Lain::Mode::Switch.new(Lain::Mode.new(posture:, layers:), journal:)
  end

  def env_for(switch) = instance_double(Lain::CLI::Command::Env, mode_switch: switch)

  def flips = Lain::Journal.records(journal_io.string.lines, type: "mode_switch").to_a

  it "registers as /mode with a one-line usage naming the reset" do
    expect(command.name).to eq("mode")
    expect(command.usage).to include("/mode").and include("!")
  end

  describe "bare /mode" do
    it "reports the current posture and every active layer" do
      switch = switch_for(:accept_edits, :goal)

      expect(command.call("", env_for(switch))).to include("accept_edits").and include("goal")
    end

    it "reports without switching or journaling" do
      switch = switch_for(:accept_edits, :goal)
      command.call("  ", env_for(switch))

      expect(switch.current).to eq(Lain::Mode.new(posture: :accept_edits, layers: [:goal]))
      expect(flips).to be_empty
    end
  end

  describe "/mode <posture>" do
    it "switches the posture the session runs under" do
      switch = switch_for(:auto)
      command.call("plan", env_for(switch))

      expect(switch.posture.name).to eq(:plan)
    end

    it "journals the change attributed to the tty" do
      switch = switch_for(:auto)
      command.call("plan", env_for(switch))

      expect(flips).to contain_exactly(
        a_hash_including("from" => "auto", "to" => "plan", "surface" => "tty")
      )
    end

    it "keeps the layers already enabled -- a posture is one slot, not the whole mode" do
      switch = switch_for(:manual, :goal)
      command.call("auto", env_for(switch))

      expect(switch.layers.names).to eq([:goal])
    end

    it "returns rendered text naming both the old and the new mode, never printing" do
      switch = switch_for(:auto)
      text = nil

      expect { text = command.call("plan", env_for(switch)) }.not_to output.to_stdout
      expect(text).to be_a(String).and include("auto").and include("plan")
    end

    # Mode#describe carries its own colon, so a "mode: " prefix stutters.
    it "renders the transition without restating the subject" do
      switch = switch_for(:auto, :goal)

      expect(command.call("plan", env_for(switch)))
        .to eq("auto (AUTO): goal (GOAL) -> plan (PLAN): goal (GOAL)")
    end
  end

  describe "/mode +layer and /mode -layer" do
    it "enables one layer without touching the posture" do
      switch = switch_for(:manual)
      command.call("+auto_approve", env_for(switch))

      expect(switch.posture.name).to eq(:manual)
      expect(switch.layers).to include(:auto_approve)
    end

    it "disables one layer without touching the posture -- the other half of the toggle" do
      switch = switch_for(:manual, :auto_approve, :goal)
      command.call("-auto_approve", env_for(switch))

      expect(switch.posture.name).to eq(:manual)
      expect(switch.layers.names).to eq([:goal])
    end

    it "disabling a layer that was never enabled is a no-op, not a refusal" do
      switch = switch_for(:manual)

      expect { command.call("-goal", env_for(switch)) }.not_to raise_error
      expect(switch.layers).to be_empty
    end

    it "applies a posture and a layer in one invocation, journaling one flip" do
      switch = switch_for(:auto, :goal)
      command.call("plan +notify -goal", env_for(switch))

      expect(switch.current).to eq(Lain::Mode.new(posture: :plan, layers: [:notify]))
      expect(flips.size).to eq(1)
    end
  end

  describe "the reset" do
    it "lands in the most restrictive posture from any posture" do
      switch = switch_for(:auto, :auto_approve, :goal, :notify)
      command.call("!", env_for(switch))

      expect(switch.posture.name).to eq(:plan)
    end

    it "clears every layer too -- a reset that leaves auto_approve on has not reset anything" do
      switch = switch_for(:auto, :auto_approve, :goal, :notify)
      command.call("!", env_for(switch))

      expect(switch.layers).to be_empty
    end

    it "targets the most restrictive rung the posture ladder declares" do
      expect(described_class::FLOOR).to eq(Lain::Mode::Posture::NAMES.first)
    end

    # The reset is reachable as `/mode !` and NOT as `/mode!`: the invocation
    # grammar's identifier is `[\w-]+`, so the trailing bang leaves the line
    # matching nothing and it falls through to the skill middleware as prose.
    # Pinned here rather than fixed: the grammar is shared, and widening it is
    # a deferred design decision (chunk-compaction-tiers-pins-isolation.md).
    # This example going red is the signal that whoever widens it must also
    # decide how the modifier reaches a command.
    it "arrives as an argument, because the invocation grammar rejects a trailing bang" do
      expect(Lain::Skill::Invocation.parse("/mode!")).to be_nil
      expect(Lain::Skill::Invocation.parse("/mode !").args).to eq("!")
    end
  end

  describe "an unknown name" do
    it "raises a recoverable Lain::Error naming every valid posture" do
      switch = switch_for(:manual)

      expect { command.call("turbo", env_for(switch)) }
        .to raise_error(Lain::Error, /turbo/) { |error| expect(error.message).to include(*posture_names) }
    end

    it "leaves the mode in force and journals nothing, so the repl loops on the same posture" do
      switch = switch_for(:manual)
      suppress(Lain::Error) { command.call("turbo", env_for(switch)) }

      expect(switch.posture.name).to eq(:manual)
      expect(flips).to be_empty
    end

    it "raises a recoverable Lain::Error naming every declared layer" do
      switch = switch_for(:manual)

      expect { command.call("+nonsense", env_for(switch)) }
        .to raise_error(Lain::Error) { |error| expect(error.message).to include(*layer_names) }
    end

    it "refuses a bare sigil rather than enabling nothing quietly" do
      switch = switch_for(:manual)

      expect { command.call("+", env_for(switch)) }.to raise_error(Lain::Error)
    end
  end

  # The bare-token/sigil-token split is unambiguous only while no declared name
  # opens with a sigil or with the reset token, and nothing in lib/ enforces
  # that. Asserted here so the day someone declares a layer `:"-x"` -- which
  # this command would route as "disable x", silently unreachable -- is the day
  # an example goes red rather than the day a toggle stops working.
  it "holds: no declared posture or layer name opens with a sigil" do
    names = (Lain::Mode::Posture::NAMES + Lain::Mode::Layer::NAMES).map(&:to_s)

    expect(names).to all(satisfy { |name| !name.start_with?("+", "-", described_class::RESET) })
  end

  describe "case" do
    it "accepts the upper-case posture the prompt's own lighter teaches" do
      switch = switch_for(:auto)
      command.call("PLAN", env_for(switch))

      expect(switch.posture.name).to eq(:plan)
    end

    it "accepts an upper-case layer token too, sigil and all" do
      switch = switch_for(:manual)
      command.call("+GOAL", env_for(switch))

      expect(switch.layers).to include(:goal)
    end
  end

  def posture_names = Lain::Mode::Posture::NAMES.map(&:to_s)

  def layer_names = Lain::Mode::Layer::NAMES.map(&:to_s)

  def suppress(error_class)
    yield
  rescue error_class
    nil
  end
end
