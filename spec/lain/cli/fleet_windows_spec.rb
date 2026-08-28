# frozen_string_literal: true

require "fileutils"
require "open3"

# FleetWindows -- a `#<<` tee sink (StatusFeed's observe pattern) that
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
      expect(open_argvs.first).to eq(["tmux", "new-window", "-P", "-n", "researcher-5aaa1111",
                                      "lain watch #{spawn_digest}", ";", "set-window-option", "-t",
                                      "=researcher-5aaa1111", "remain-on-exit", "failed"])
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

      expect(open_argvs.first).to eq(["tmux", "new-window", "-P", "-n", "researcher-5aaa1111",
                                      "lain watch #{spawn_digest}", ";", "set-window-option", "-t",
                                      "=researcher-5aaa1111", "remain-on-exit", "failed"])
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

  # `new-window` exits 0 as soon as the tmux SERVER accepts the request, so
  # whether the pane lived is invisible to the client that opened it -- which
  # is how a `lain` missing from a non-interactive `$SHELL -c` PATH stayed
  # unreported for the life of the feature. The pump asks the server once,
  # behind the open, and says so when the answer is "gone".
  describe "a window that did not survive" do
    def dead_pane_factory(status: "127")
      pane_factory("1:#{status}\n")
    end

    def live_pane_factory = pane_factory("0:\n")

    def pane_factory(answer)
      lambda do |*args|
        recorded << args
        FakeFleetShellOut.new(0, args.include?("list-panes") ? answer : "", "")
      end
    end

    def fleet_over(factory)
      described_class.new(surface: Lain::CLI::TmuxSurface.new(shell_out_factory: factory),
                          role_for: ->(_record) { "researcher" }, notice: notices, spawner:)
    end

    def check_argvs = recorded.select { |argv| argv.include?("list-panes") }
    def deaths = notices.select { |record| record.to_journal["type"] == "window_died" }

    it "reports the spawn whose window did not survive" do
      fleet = fleet_over(dead_pane_factory)
      fleet << spawn_record
      fleet << usage_record
      fleet.drain_pending

      expect(deaths.map(&:digest)).to eq([spawn_digest])
    end

    it "writes no such record for a window whose command keeps running" do
      fleet = fleet_over(live_pane_factory)
      fleet << spawn_record
      fleet << usage_record
      fleet.drain_pending

      expect(deaths).to be_empty
      expect(check_argvs.size).to eq(1)
    end

    it "carries the command that was attempted and the status the pane died with" do
      fleet = fleet_over(dead_pane_factory(status: "42"))
      fleet << spawn_record
      fleet << usage_record
      fleet.drain_pending

      record = deaths.first
      expect(record.command).to eq("lain watch #{spawn_digest}")
      expect(record.status).to eq(42)
      expect(record.window).to eq("researcher-5aaa1111")
    end

    # A pane held by `remain-on-exit failed` ALWAYS leaves a status behind, so
    # "gone" never means "died" -- it means a clean exit or a human who closed
    # the window. Journalling that as a death would put a lie in the
    # experiment record, which is worse than putting nothing there.
    it "writes nothing for a window merely gone -- a corpse's status is the only evidence of a death" do
      vanished = lambda do |*args|
        recorded << args
        FakeFleetShellOut.new(args.include?("list-panes") ? 1 : 0, "", "can't find window")
      end
      fleet = fleet_over(vanished)
      fleet << spawn_record
      fleet << usage_record

      expect { fleet.drain_pending }.not_to raise_error
      expect(deaths).to be_empty
    end

    it "writes nothing when the window is there and healthy" do
      fleet = fleet_over(live_pane_factory)
      fleet << spawn_record
      fleet << usage_record
      fleet.drain_pending

      expect(deaths).to be_empty
    end

    # Chained into the open, not sent after it: tmux destroys a pane whose
    # command could not start before a second client can connect, so the tail
    # has to ride the same invocation to leave anything to ask about.
    it "asks tmux to hold the failed pane in the very request that opens the window" do
      fleet << spawn_record
      fleet.drain_pending

      expect(open_argvs).to eq([["tmux", "new-window", "-P", "-n", "researcher-5aaa1111",
                                 "lain watch #{spawn_digest}", ";", "set-window-option", "-t",
                                 "=researcher-5aaa1111", "remain-on-exit", "failed"]])
    end

    it "does the asking on the pump, never inside the tee fan-out" do
      dying = fleet_over(dead_pane_factory)
      dying << spawn_record
      dying << usage_record

      expect(recorded).to be_empty
      expect(notices).to be_empty
    end

    # The server reaps a pane asynchronously to the client that opened it, so
    # a check issued behind the open reads a pane that has not died yet. The
    # wait is a turn, not a timer -- and on a real reactor that is a whole
    # model round trip of slack for nothing but a queue.
    it "does not let the check ride the open: the pump opens the window and asks nothing yet" do
      Sync do
        live = described_class.new(surface: Lain::CLI::TmuxSurface.new(shell_out_factory: dead_pane_factory),
                                   role_for: ->(_record) { "researcher" }, notice: notices)
        live << spawn_record
        sleep(0)
        expect(open_argvs.size).to eq(1)
        expect(check_argvs).to be_empty

        live << usage_record
        sleep(0)
        expect(check_argvs.size).to eq(1)
      end
    end

    it "checks a window once, not once per record the sink sees afterwards" do
      fleet = fleet_over(dead_pane_factory)
      fleet << spawn_record
      fleet << spawn_record
      fleet << tell_record
      fleet << usage_record
      fleet << usage_record
      fleet.drain_pending

      expect(check_argvs.size).to eq(1)
      expect(deaths.size).to eq(1)
    end

    # A done-marked window can still be holding a corpse: an actor whose watch
    # command never started can have its lineage close before the turn ends,
    # and the pane sits there reading `[done]` over a status nobody was told
    # about. The status is unambiguous evidence, so a closed lineage is no
    # reason to stop asking.
    it "still reports a window that is holding a corpse, even once its actor is done-marked" do
      fleet = fleet_over(dead_pane_factory)
      fleet << spawn_record
      fleet << farewell_record
      fleet << usage_record
      fleet.drain_pending

      expect(check_argvs.size).to eq(1)
      expect(deaths.map(&:digest)).to eq([spawn_digest])
    end

    it "writes nothing for a done-marked window whose watch simply finished and closed" do
      vanished = lambda do |*args|
        recorded << args
        FakeFleetShellOut.new(args.include?("list-panes") ? 1 : 0, "", "can't find window")
      end
      fleet = fleet_over(vanished)
      fleet << spawn_record
      fleet << farewell_record
      fleet << usage_record
      fleet.drain_pending

      expect(deaths).to be_empty
    end

    # A session can end without any boundary record ever reaching this sink,
    # and what is lost then is everything: no record, and an operator whose
    # only signal is a corpse pane they may never look at.
    it "releases a held check on the teardown drain when no boundary ever arrived" do
      fleet = fleet_over(dead_pane_factory)
      fleet << spawn_record
      fleet.drain_pending

      expect(deaths.map(&:digest)).to eq([spawn_digest])
    end

    # {Pump::Mark}'s sanctioned swallow, for the same reason: a check that
    # cannot ask tmux anything has no evidence, which is the same as no
    # record. Unrescued it escapes `drain_pending` -- performed on the
    # CALLER's stack -- and replaces whatever exception was already unwinding
    # ChatLaunch's teardown.
    it "swallows a tmux that has gone away rather than raising out of the teardown drain" do
      # Only the QUESTION loses its tmux; the window opened normally, which is
      # what puts the raise on the check rather than on the open.
      no_tmux = lambda do |*args|
        raise Errno::ENOENT, "no such file or directory - tmux" if args.include?("list-panes")

        FakeFleetShellOut.new(0, "", "")
      end
      fleet = described_class.new(surface: Lain::CLI::TmuxSurface.new(shell_out_factory: no_tmux),
                                  notice: notices, spawner:)
      fleet << spawn_record

      expect { fleet.drain_pending }.not_to raise_error
      expect(deaths).to be_empty
    end

    it "checks nothing for a capped actor -- no window was opened to survive" do
      6.times { |i| fleet << spawn_record(digest: format("blake3:%04x111122223333", i)) }
      fleet << usage_record
      fleet.drain_pending

      expect(check_argvs.size).to eq(described_class::CAP_PER_TURN)
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
    # (SessionClosed) stranded the held WindowsCapped forever, and a held
    # notice must always be released. Both closers are boundaries now, and the
    # teardown drain is the last-resort release when NO boundary record ever
    # reached this sink.
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

  # The lifecycle vocabulary's five acceptance criteria, restated here as a
  # direct record of each scenario. The first three restate coverage that
  # already exists above under other names (farewell, one-shot result,
  # tell-is-not-terminal). The fourth and fifth are the ones this substitution
  # actually adds: a completion can carry both vocabularies at once, and the
  # predicate itself must have exactly one definition in the tree.
  describe "the lifecycle vocabulary FleetWindows asks" do
    it "closes the window on an actor farewell" do
      fleet << spawn_record
      fleet << farewell_record
      fleet.drain_pending

      expect(rename_argvs.size).to eq(1)
    end

    it "closes the window on a one-shot result" do
      fleet << spawn_record
      fleet << result_record
      fleet.drain_pending

      expect(rename_argvs.size).to eq(1)
    end

    it "closes nothing on an ordinary tell" do
      fleet << spawn_record
      fleet << tell_record
      fleet.drain_pending

      expect(rename_argvs).to be_empty
    end

    it "closes its window exactly once for a completion carrying both a result and a lifecycle mark" do
      both = Lain::Telemetry::Message.new(
        digest: "blake3:b0b0111122223333", kind: :message, from: spawn_digest, to: parent,
        payload: { "result" => "found 3 papers", "lifecycle" => "stopped", "final" => "blake3:f1na" },
        causal_parents: [spawn_digest, "blake3:f1na"], correlation: spawn_digest
      )
      fleet << spawn_record
      fleet << both
      fleet << both
      fleet.drain_pending

      expect(rename_argvs.size).to eq(1)
    end

    it "defines no terminal predicate of its own -- FleetWindows asks Telemetry::SpawnLifecycle instead" do
      path, = described_class.instance_method(:observe_close).source_location
      expect(File.read(path)).not_to include("def terminal?")
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
    # tmux's OWN format syntax, not Ruby interpolation (the pinned trap).
    let(:name_format) { '#{window_name}' } # rubocop:disable Lint/InterpolationCheck

    around do |example|
      system("tmux", "-L", socket, "new-session", "-d", "-s", "lain", out: File::NULL, err: File::NULL)
      example.run
    ensure
      system("tmux", "-L", socket, "kill-server", out: File::NULL, err: File::NULL)
      sweep_sockets
    end

    # `kill-server` stops the server and leaves its socket inode behind, so a
    # scratch `-L` name is one more file per example in a directory shared with
    # every other spec and every real session on the box -- 13,668 of them had
    # accumulated there when this was noticed. Swept by GLOB rather than by the
    # one name this example used: the client returns as soon as the server is
    # told to exit, so a socket can outlive the example that made it and a
    # later example is the only thing left to clear it. Scoped to this
    # process's pid, so it can never touch a concurrent run's server or a real
    # session.
    def sweep_sockets
      FileUtils.rm_f(Dir.glob(File.join(ENV.fetch("TMUX_TMPDIR", "/tmp"), "tmux-#{Process.uid}",
                                        "fleet-windows-spec-#{Process.pid}-*")))
    end

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

    # On the PRODUCTION spawner, so the turn of slack between the open and the
    # check is the real thing rather than a spec's two calls in a row: the pump
    # fiber opens the window, the server reaps the pane at its own pace, and
    # only the next turn boundary releases the question.
    it "reports the window whose command a real tmux pane could not run" do
      # No `#` comment this time: the digest rides along and the whole line is
      # what a real pane's non-interactive `$SHELL -c` cannot find -- exactly
      # the 127 a `lain` off that PATH produces.
      Sync do
        fleet = described_class.new(surface: real_surface, watch_command: "no-such-command-on-this-path",
                                    role_for: ->(_record) { "researcher" }, notice: notices, session: "lain")
        fleet << spawn_record
        sleep(0.3)

        fleet << usage_record
        sleep(0.3)

        death = notices.find { |record| record.to_journal["type"] == "window_died" }
        expect(death).to have_attributes(digest: spawn_digest, status: 127,
                                         command: "no-such-command-on-this-path #{spawn_digest}")
      end
    end

    it "stays silent about a real window whose command is still running" do
      fleet = described_class.new(surface: real_surface, watch_command: "sleep 60 #",
                                  role_for: ->(_record) { "researcher" }, notice: notices,
                                  spawner:, session: "lain")
      fleet << spawn_record
      fleet.drain_pending
      fleet << usage_record
      fleet.drain_pending

      expect(notices).to be_empty
      expect(window_names).to include("researcher-5aaa1111")
    end
  end
end
