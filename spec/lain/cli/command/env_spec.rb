# frozen_string_literal: true

RSpec.describe Lain::CLI::Command::Env do
  def readers
    { status: instance_double(Lain::StatusFeed), sessions: instance_double(Lain::CLI::Sessions),
      approvals: described_class::NoApprovals, supervisor: Lain::Supervisor::Null,
      replies: instance_double(Lain::CLI::HumanReplies), fork_point: instance_double(Lain::CLI::ForkPoint),
      tmux_surface: instance_double(Lain::CLI::TmuxSurface), agent: instance_double(Lain::Agent),
      model_switch: instance_double(Lain::Context::ModelSwitch),
      mode_switch: instance_double(Lain::Mode::Switch),
      chronicle: Lain::CLI::Chronicle::Null.new, role_spawn: instance_double(Lain::Skill::RoleSpawn),
      snapshots: instance_double(Lain::Agent::SnapshotSlot) }
  end

  it "is a frozen value over the thirteen readers" do
    env = described_class.new(**readers)

    expect(env).to be_frozen
    expect(env.to_h.keys)
      .to eq(%i[status sessions approvals supervisor replies fork_point tmux_surface agent
                model_switch mode_switch chronicle role_spawn snapshots])
  end

  # `/undo` reads the snapshot log and root through this one reader, so a
  # missing slot must be as loud as any other missing collaborator.
  it "refuses a nil snapshot slot by name" do
    expect { described_class.new(**readers, snapshots: nil) }.to raise_error(ArgumentError, /snapshots/)
  end

  # The gate policy is DERIVED from a mode flip, not written by a command:
  # {CLI::Switchboard#apply} sets it as the consequence of the flip `/mode`
  # reaches through `mode_switch`. A command that wrote it directly would be a
  # second writer for one slot -- which is what `/yolo` was, and what `/mode`
  # exists to avoid. So Env carries the intent and never the derivation, and
  # the identity between the live policy and the session's one queue is pinned
  # on the {CLI::Switchboard}, which owns the switch.
  it "carries no policy_switch -- the gate policy is derived from a mode flip, never a command's to write" do
    expect(described_class.members).not_to include(:policy_switch)
    expect(described_class.new(**readers)).not_to respond_to(:policy_switch)
  end

  it "refuses a nil reader loudly, naming it -- Null collaborators, never nil" do
    expect { described_class.new(**readers, fork_point: nil) }
      .to raise_error(ArgumentError, /fork_point/)
  end

  # The mode switch is a REQUIRED live collaborator, not a nilable one and not a
  # Null: `/mode` writes the slot the Gate and the toolset read, so a Null here
  # would fail OPEN in the way surface.rb:29-37 names -- `/mode plan` would
  # report success while the live posture never moved. Nil must be as loud as
  # any other missing reader, and it must say WHICH one.
  it "refuses a nil mode_switch by name, so a half-wired posture cannot start a run" do
    expect { described_class.new(**readers, mode_switch: nil) }
      .to raise_error(ArgumentError, /mode_switch/)
  end

  it "answers the live mode switch the run wired" do
    switch = instance_double(Lain::Mode::Switch)

    expect(described_class.new(**readers, mode_switch: switch).mode_switch).to be(switch)
  end

  it "answers the approval queue's read duck with nothing parked when a run wires none" do
    expect(described_class::NoApprovals.each.to_a).to eq([])
  end

  # The class doc's claim -- "the one value a command reads its collaborators
  # through" -- made true: a command used to write `env.agent.timeline` or
  # `env.chronicle.journal_path`, reaching THROUGH Env to a collaborator's
  # shape. These four readers are the Demeter point instead.
  describe "the collapsed readers" do
    let(:timeline) { instance_double(Lain::Timeline, head_digest: "blake3:abc123") }
    let(:agent) { instance_double(Lain::Agent, timeline:) }
    let(:chronicle) { instance_double(Lain::CLI::Chronicle, journal_path: "/sessions/x.ndjson") }
    let(:env) { build_command_env(agent:, chronicle:) }

    describe "#timeline" do
      it "answers the agent's live timeline" do
        expect(env.timeline).to be(timeline)
      end
    end

    describe "#head_digest" do
      # Asserting against the SAME literal the double happens to be stubbed
      # with (e.g. the outer `timeline` let's "blake3:abc123") would still
      # pass a hardcoded `def head_digest = "blake3:abc123"` -- this proves
      # DELEGATION instead: a digest this example invents, plus the message
      # expectation that `#timeline` was actually asked for it.
      it "delegates to the timeline's own head_digest, not a value of its own" do
        distinctive = instance_double(Lain::Timeline, head_digest: "blake3:distinctive-9f2c")
        env = build_command_env(agent: instance_double(Lain::Agent, timeline: distinctive))

        expect(env.head_digest).to eq("blake3:distinctive-9f2c")
        expect(distinctive).to have_received(:head_digest)
      end
    end

    describe "#journal_path" do
      it "answers the chronicle's journal path" do
        expect(env.journal_path).to eq("/sessions/x.ndjson")
      end
    end

    describe "#checkpoint" do
      it "journals the live timeline through the chronicle's own catch_up" do
        allow(chronicle).to receive(:catch_up).and_return(chronicle)

        expect(env.checkpoint).to be(chronicle)
        expect(chronicle).to have_received(:catch_up).with(timeline)
      end
    end

    # None of the four may be memoized: `agent`'s own `@timeline` is
    # reassigned every commit/rewind ({Lain::Agent#ask}, {Lain::Agent#rewind}),
    # so a caller holding one Env across a turn must see the CURRENT head, not
    # the one in force when Env was first read from.
    it "re-reads the agent on every call, never caching a stale timeline" do
      moved_on = instance_double(Lain::Timeline, head_digest: "blake3:later")
      allow(agent).to receive(:timeline).and_return(timeline, moved_on)

      expect(env.timeline).to be(timeline)
      expect(env.timeline).to be(moved_on)
    end
  end
end
