# frozen_string_literal: true

require "open3"

# T20: FleetWindows -- a `#<<` tee sink (StatusFeed's observe pattern) that
# turns :spawn records into tmux windows running `lain watch <digest>`, and
# terminal Message records (an actor's "stopped" farewell, a one-shot's
# result) into a done marker on the window title. The sink ONLY enqueues;
# `tmux` shell-outs happen on a separate pump fiber draining that queue --
# the unit examples prove the enqueue/drain split with a FakeShellOut'd
# TmuxSurface, and one guarded example runs against a real scratch `-L`
# server, exactly tmux_surface_spec.rb's two-kinds split.
FakeFleetShellOut = Struct.new(:exitstatus, :stdout, :stderr) do
  def run_command = self
end

# The spawner-returned task duck FleetWindows consults (#finished?) before
# respawning its pump. The default (live) spawner answers an Async::Task.
FakeFleetPump = Struct.new(:pump, :finished) do
  def finished? = finished
end

RSpec.describe Lain::CLI::FleetWindows do
  let(:recorded) { [] }
  let(:factory) do
    lambda do |*args|
      recorded << args
      FakeFleetShellOut.new(0, "", "")
    end
  end
  let(:surface) { Lain::CLI::TmuxSurface.new(shell_out_factory: factory) }
  let(:pumps) { [] }
  let(:spawner) do
    lambda do |&pump|
      pumps << pump
      FakeFleetPump.new(pump, false)
    end
  end
  let(:notices) { [] }
  let(:fleet) do
    described_class.new(surface:, role_for: ->(_record) { "researcher" }, notice: notices, spawner:)
  end

  let(:parent) { "blake3:9f00111122223333" }
  let(:head) { "blake3:0abc111122223333" }
  let(:spawn_digest) { "blake3:5aaa111122223333" }

  def spawn_record(digest: spawn_digest, lifecycle: "launched")
    Lain::Telemetry::Message.new(
      digest:, kind: :spawn, from: parent, to: nil,
      payload: { "prefix" => "fresh", "posture" => "schema", "only" => nil,
                 "spawned_from" => head, "lifecycle" => lifecycle },
      causal_parents: [head], correlation: parent
    )
  end

  def farewell_record(spawn: spawn_digest)
    Lain::Telemetry::Message.new(
      digest: "blake3:feed111122223333", kind: :message, from: spawn, to: parent,
      payload: { "text" => "actor stopped", "lifecycle" => "stopped" },
      causal_parents: [spawn, "blake3:head2"], correlation: spawn
    )
  end

  def result_record(spawn: spawn_digest)
    Lain::Telemetry::Message.new(
      digest: "blake3:0e50111122223333", kind: :message, from: spawn, to: parent,
      payload: { "result" => "found 3 papers", "final" => "blake3:f1na" },
      causal_parents: [spawn, "blake3:f1na"], correlation: spawn
    )
  end

  def tell_record(spawn: spawn_digest)
    Lain::Telemetry::Message.new(
      digest: "blake3:0add111122223333", kind: :message, from: parent, to: spawn,
      payload: { "text" => "narrow to RCTs" },
      causal_parents: [spawn], correlation: parent
    )
  end

  def usage_record
    Lain::Telemetry::TurnUsage.new(digest: "blake3:0turn", model: "claude-x", stop_reason: :end_turn,
                                   usage: { "input_tokens" => 10, "output_tokens" => 5 })
  end

  def open_argvs = recorded.select { |argv| argv.include?("new-window") }
  def rename_argvs = recorded.select { |argv| argv.include?("rename-window") }

  describe "the sink only enqueues" do
    it "shells nothing out inside the tee fan-out; the window opens only when the queue drains" do
      fleet << spawn_record

      expect(recorded).to be_empty

      fleet.drain_pending
      expect(open_argvs).to eq([["tmux", "new-window", "-n", "researcher-5aaa1111",
                                 "lain watch #{spawn_digest}"]])
    end

    it "starts its pump fiber through the injected spawner, and respawns one that finished" do
      fleet << spawn_record
      expect(pumps.size).to eq(1)

      dead_spawner = ->(&pump) { pumps << pump and FakeFleetPump.new(pump, true) }
      dying = described_class.new(surface:, notice: notices, spawner: dead_spawner)
      dying << spawn_record
      dying << spawn_record(digest: "blake3:6bbb111122223333")
      expect(pumps.size).to eq(3)
    end
  end

  describe "window per actor" do
    it "names the window for its role plus the digest short form, running lain watch on the full digest" do
      fleet << spawn_record
      fleet.drain_pending

      expect(open_argvs).to eq([["tmux", "new-window", "-n", "researcher-5aaa1111",
                                 "lain watch #{spawn_digest}"]])
    end

    it "falls back to the subagent tool's own name when no role seam is wired" do
      nameless = described_class.new(surface:, notice: notices, spawner:)
      nameless << spawn_record
      nameless.drain_pending

      expect(open_argvs.first).to include("subagent-5aaa1111")
    end

    it "marks the window title done on the actor's farewell (lifecycle stopped) and never kills the window" do
      fleet << spawn_record
      fleet << farewell_record
      fleet.drain_pending

      expect(rename_argvs).to eq([["tmux", "rename-window", "-t", "=researcher-5aaa1111",
                                   "researcher-5aaa1111 [done]"]])
      expect(recorded.flatten).not_to include("kill-window")
    end

    it "marks the window done on a one-shot's result message too" do
      fleet << spawn_record
      fleet << result_record
      fleet.drain_pending

      expect(rename_argvs.size).to eq(1)
    end

    it "does not mark on a plain tell -- conversation is not a lifecycle transition" do
      fleet << spawn_record
      fleet << tell_record
      fleet.drain_pending

      expect(rename_argvs).to be_empty
    end

    it "opens one window for a redelivered :spawn (a journal replay), not two" do
      fleet << spawn_record
      fleet << spawn_record
      fleet.drain_pending

      expect(open_argvs.size).to eq(1)
    end

    it "does not re-window a spawn redelivered AFTER its terminal -- an actor once closed stays closed" do
      fleet << spawn_record
      fleet << farewell_record
      fleet << spawn_record
      fleet.drain_pending

      expect(open_argvs.size).to eq(1)
      expect(rename_argvs.size).to eq(1)
    end

    it "swallows the rename when the human already closed the window -- the marker has nowhere to land" do
      failing = lambda do |*args|
        recorded << args
        FakeFleetShellOut.new(args.include?("rename-window") ? 1 : 0, "", "can't find window")
      end
      fleet = described_class.new(surface: Lain::CLI::TmuxSurface.new(shell_out_factory: failing),
                                  notice: notices, spawner:)
      fleet << spawn_record
      fleet << farewell_record

      expect { fleet.drain_pending }.not_to raise_error
    end

    it "is inert for records answering none of #kind, #usage, #head" do
      fleet << Lain::Telemetry::StreamStarted.new(digest: "blake3:5aaa")
      fleet.drain_pending

      expect(recorded).to be_empty
    end
  end

  describe "the per-turn cap" do
    def burst(count)
      count.times { |i| fleet << spawn_record(digest: format("blake3:%04x111122223333", i)) }
    end

    it "opens at most CAP_PER_TURN windows for one turn's burst" do
      burst(6)
      fleet.drain_pending

      expect(open_argvs.size).to eq(described_class::CAP_PER_TURN)
    end

    it "emits ONE notice at the turn boundary naming every un-windowed actor and its lain watch command" do
      burst(6)
      fleet << usage_record
      fleet.drain_pending

      expect(notices.size).to eq(1)
      record = notices.first
      expect(record.to_journal["type"]).to eq("windows_capped")
      expect(record.actors.size).to eq(2)
      expect(record.actors.map { |actor| actor["watch"] })
        .to eq(["lain watch blake3:0004111122223333", "lain watch blake3:0005111122223333"])
      expect(record.actors.map { |actor| actor["role"] }).to all(eq("researcher"))
    end

    it "emits no notice when the burst stayed under the cap" do
      burst(3)
      fleet << usage_record
      fleet.drain_pending

      expect(notices).to be_empty
    end

    it "resets the budget at the turn boundary -- the cap is per turn, not per session" do
      burst(4)
      fleet << usage_record
      fleet << spawn_record(digest: "blake3:aaaa111122223333")
      fleet.drain_pending

      expect(open_argvs.size).to eq(5)
      expect(notices).to be_empty
    end

    # The failure paths never journal a TurnUsage -- the panel's F-notice-loss
    # probe: a burst followed by Ctrl-C (RunInterrupted) or a close
    # (SessionClosed) stranded the held WindowsCapped forever, AC3's own
    # prohibition. Both closers are boundaries now, and the teardown drain is
    # the last-resort release when NO boundary record ever reached this sink.
    describe "boundaries on the failure paths" do
      it "releases the held notice at a RunInterrupted boundary, exactly once" do
        burst(6)
        fleet << Lain::Telemetry::RunInterrupted.new(head: nil)
        fleet.drain_pending

        expect(notices.size).to eq(1)
        expect(notices.first.actors.size).to eq(2)
      end

      it "releases the held notice at a SessionClosed boundary" do
        burst(6)
        fleet << Lain::Telemetry::SessionClosed.new(head: nil, reason: :interrupted)
        fleet.drain_pending

        expect(notices.size).to eq(1)
      end

      it "resets the window budget at a closer boundary too, like any turn end" do
        burst(4)
        fleet << Lain::Telemetry::RunInterrupted.new(head: nil)
        fleet << spawn_record(digest: "blake3:aaaa111122223333")
        fleet.drain_pending

        expect(open_argvs.size).to eq(5)
      end

      it "releases the held notice on the teardown drain when no boundary record ever arrived" do
        burst(6)
        fleet.drain_pending

        expect(notices.size).to eq(1)
        expect(notices.first.actors.map { |actor| actor["watch"] })
          .to eq(["lain watch blake3:0004111122223333", "lain watch blake3:0005111122223333"])
      end
    end
  end

  describe "hostile role names" do
    # tmux format-expands `new-window -n` names (a role "#{pane_pid}" renders
    # as a PID) and `.`/`:` are separators inside a `=name` rename target --
    # the panel's naming probe. The role contributes only conservative bytes.
    def fleet_for(role)
      described_class.new(surface:, role_for: ->(_record) { role }, notice: notices, spawner:)
    end

    it "neutralizes tmux format expansion in the window name" do
      # tmux's OWN format syntax, not Ruby interpolation (the pinned trap).
      hostile = fleet_for('#{pane_pid}') # rubocop:disable Lint/InterpolationCheck
      hostile << spawn_record
      hostile.drain_pending

      expect(open_argvs.first).to include("--pane_pid--5aaa1111")
    end

    it "keeps the rename target exact-matchable: no '.' or ':' survives into the name" do
      hostile = fleet_for("deep:v2.researcher")
      hostile << spawn_record
      hostile << farewell_record
      hostile.drain_pending

      expect(open_argvs.first).to include("deep-v2-researcher-5aaa1111")
      expect(rename_argvs).to eq([["tmux", "rename-window", "-t", "=deep-v2-researcher-5aaa1111",
                                   "deep-v2-researcher-5aaa1111 [done]"]])
    end

    it "keeps spaces, letters, digits, underscore, and dash as-is" do
      benign = fleet_for("deep researcher_2")
      benign << spawn_record
      benign.drain_pending

      expect(open_argvs.first).to include("deep researcher_2-5aaa1111")
    end
  end

  describe ".for" do
    it "answers the Null sink outside tmux -- no window machinery constructs" do
      expect(described_class.for({ windows: true }, env: {})).to be_a(described_class::Null)
    end

    it "answers the Null sink without the flag, even inside tmux" do
      expect(described_class.for({}, env: { "TMUX" => "/tmp/tmux-1000/default,42,0" }))
        .to be_a(described_class::Null)
    end

    it "answers a live sink only with the flag AND $TMUX" do
      expect(described_class.for({ windows: true }, env: { "TMUX" => "/tmp/tmux-1000/default,42,0" }))
        .to be_a(described_class)
    end

    it "gives the Null the same duck: <<, notice=, drain_pending" do
      null = described_class::Null.new
      null.notice = notices

      expect(null << spawn_record).to eq(null)
      expect(null.drain_pending).to eq(null)
    end
  end

  describe "the pump under a real reactor (default spawner)" do
    it "performs queued commands on its own fiber at the next scheduler tick, never on the caller's stack" do
      Sync do
        live = described_class.new(surface:, role_for: ->(_record) { "researcher" }, notice: notices)
        live << spawn_record
        expect(recorded).to be_empty

        sleep(0)
        expect(open_argvs.size).to eq(1)
      end
    end
  end

  describe "against a real tmux server" do
    def tmux_present? = system("tmux", "-V", out: File::NULL, err: File::NULL)

    before { skip("tmux not found on PATH") unless tmux_present? }

    let(:socket) { "fleet-windows-spec-#{Process.pid}-#{object_id}" }
    let(:real_surface) { Lain::CLI::TmuxSurface.new(socket:) }

    around do |example|
      system("tmux", "-L", socket, "new-session", "-d", "-s", "lain", out: File::NULL, err: File::NULL)
      example.run
    ensure
      system("tmux", "-L", socket, "kill-server", out: File::NULL, err: File::NULL)
    end

    # tmux's OWN format syntax, not Ruby interpolation (the pinned trap).
    let(:name_format) { '#{window_name}' } # rubocop:disable Lint/InterpolationCheck

    def window_names
      Open3.capture2("tmux", "-L", socket, "list-windows", "-t", "lain", "-F", name_format)
           .first.lines.map(&:strip)
    end

    it "opens a role-named window on spawn and retitles it done on the farewell, leaving it open" do
      # `sleep 60 #` comments the digest out of the shell command, so the pane
      # outlives both assertions without needing a lain exe on this PATH.
      fleet = described_class.new(surface: real_surface, watch_command: "sleep 60 #",
                                  role_for: ->(_record) { "researcher" }, notice: notices,
                                  spawner:, session: "lain")
      fleet << spawn_record
      fleet.drain_pending
      expect(window_names).to include("researcher-5aaa1111")

      fleet << farewell_record
      fleet.drain_pending
      expect(window_names).to include("researcher-5aaa1111 [done]")
    end
  end
end
