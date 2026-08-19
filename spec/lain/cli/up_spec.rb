# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "shellwords"
require "tempfile"
require "time"

# The PATH/`--` argv split and the `--root`/`--cwd` flags are Thor's work, so
# the examples at the foot of this file drive the REAL command parser. exe/lain
# is a script, not a lib file: it ends in `LainCLI.start(ARGV)` guarded by
# `$PROGRAM_NAME == __FILE__`, so this `load` defines the class without parsing
# rspec's ARGV -- the same seam spec/lain/cli_spec.rb and chat_flags_spec use.
load File.expand_path("../../../exe/lain", __dir__)

# I2: `lain up` -- create/attach the "lain" tmux session, session-scoped so the
# global theme is untouched, with a status-right HUD (warmth/fleet/inbox) read
# from I1's `.lain/state.json` (see lib/lain/status_feed.rb for the exact
# keys). Two kinds of examples:
#
# * "against a real tmux server" shells out to an ACTUAL tmux on a scratch
#   socket (`-L lain-spec-...`), never Joel's real session. It skips outright
#   (never fails) when no tmux binary is on PATH -- an environment gap, not a
#   lain regression, the same idiom spec/support/tags.rb uses for :nvim.
# * "degrading loudly" injects a FAKE shell_out_factory, so the no-tmux /
#   broken-tmux / no-jq scenarios run on every machine regardless of what is
#   actually installed there.
#
# A Mixlib::ShellOut double satisfying the one duck #run exercises:
# #run_command (a no-op -- the real one blocks until the child exits; this
# object is already "done" the instant it's built) and #exitstatus/#stderr/
# #stdout (nil-safe: most examples never set it). Defined at the top level
# (not inside RSpec.describe) so it is a plain constant, not one assigned
# inside a block.
FakeShellOut = Struct.new(:exitstatus, :stderr, :stdout) do
  def run_command = self
  def stdout = self[:stdout] || ""
end

RSpec.describe Lain::CLI::Up do
  def tmux_present? = system("tmux", "-V", out: File::NULL, err: File::NULL)

  # THIS checkout's executable, for the one example that runs a real `lain
  # chat` child. `$PROGRAM_NAME` is rspec here, which is exactly why the
  # pre-flight takes its binary as an argument.
  def lain_exe = File.expand_path("../../../exe/lain", __dir__)

  # Strips tmux's `#(job)` status-right wrapper and runs the job directly
  # through a real shell -- proves what the HUD would render WITHOUT relying
  # on tmux's own async status-bar refresh timing (a real render was verified
  # once, by hand, against a PTY-attached tmux 3.8; asserting on that timing
  # in the suite would be flaky where this is not).
  def eval_status_job(raw_value)
    job = raw_value.strip.delete_prefix("#(").delete_suffix(")")
    out, = Open3.capture3("sh", "-c", job)
    out.strip
  end

  describe "against a real tmux server" do
    before { skip("tmux not found on PATH") unless tmux_present? }

    around do |example|
      Dir.mktmpdir { |dir| @state_dir = dir and example.run }
    end

    let(:socket) { "lain-spec-#{Process.pid}-#{object_id}" }
    let(:state_path) { File.join(@state_dir, "state.json") }
    let(:session) { "lain" }
    # The real pre-flight SPAWNS the launching binary, which under rspec is
    # rspec -- so every example in this group would read a refusal from that
    # instead of driving tmux. Handed a no-op here on purpose: the seam has its
    # own group below, over a fake factory, where both the call it makes and
    # the verdict it draws are visible.
    let(:no_preflight) { ->(_chat_args) { [] } }
    let(:up) { described_class.new(session:, socket:, state_path:, chat_preflight: no_preflight) }

    after { system("tmux", "-L", socket, "kill-server", out: File::NULL, err: File::NULL) }

    def write_state(cache_deadline:, fleet:, inbox_count:)
      File.write(state_path, JSON.generate({ "cache_deadline" => cache_deadline, "fleet" => fleet,
                                             "inbox_count" => inbox_count }))
    end

    def tmux(*args) = Open3.capture2("tmux", "-L", socket, *args).first.strip

    def session_count
      Open3.capture2("tmux", "-L", socket, "list-sessions").first.lines.size
    end

    # tmux reaps an exited pane on its OWN event loop, so this waits for the
    # fact instead of sleeping a guessed interval -- and answers false rather
    # than hanging when the window (or the whole server) is gone, which is
    # exactly the regression it guards. The deadline is only ever paid on
    # failure.
    def dead_chat_pane?
      # `#{pane_dead}` is tmux's own format syntax, not Ruby interpolation.
      # rubocop:disable Lint/InterpolationCheck
      probe = -> { tmux("list-panes", "-t", "#{session}:chat", "-F", '#{pane_dead}') == "1" }
      # rubocop:enable Lint/InterpolationCheck
      deadline = Time.now + 5
      sleep(0.01) until probe.call || Time.now > deadline
      probe.call
    end

    it "creates the session with a session-scoped status-right derived from state.json" do
      write_state(cache_deadline: (Time.now + 300).utc.iso8601, fleet: %w[a b], inbox_count: 3)

      report = up.call

      expect(report.session).to eq(session)
      expect(report.created).to be true
      expect(session_count).to eq(1)
      status_right = tmux("show-options", "-v", "-t", session, "status-right")
      expect(eval_status_job(status_right)).to eq("🔥 fleet:2 inbox:3")
    end

    it "shows a cold glyph once the cache deadline has passed" do
      write_state(cache_deadline: (Time.now - 300).utc.iso8601, fleet: [], inbox_count: 0)

      up.call

      status_right = tmux("show-options", "-v", "-t", session, "status-right")
      expect(eval_status_job(status_right)).to eq("❄ fleet:0 inbox:0")
    end

    it "never blanks the HUD before StatusFeed's first publish (state.json not written yet)" do
      # No write_state call: this is the ordinary fresh-`up` window, before
      # any turn has run and StatusFeed has ever published. jq fails
      # (nonzero, no such file) -- the assertion on the raw option value is
      # deterministic (no reliance on tmux's async status-bar refresh
      # timing); the live-render check below reuses #eval_status_job for the
      # same reason the other examples do.
      up.call

      status_right = tmux("show-options", "-v", "-t", session, "status-right")
      expect(status_right).to include("|| echo")
      expect(eval_status_job(status_right)).to eq("lain: no state yet")
    end

    it "sets monitor-bell on the spawned chat window" do
      write_state(cache_deadline: nil, fleet: [], inbox_count: 0)

      up.call

      expect(tmux("show-window-options", "-t", "#{session}:chat", "monitor-bell")).to eq("monitor-bell on")
    end

    # How the 2026-08-06 "starts and immediately crashes" report looked from
    # the outside: `chat` refused a missing API key, printed a perfectly clear
    # line, exited 1 -- and because it was the session's ONLY pane, tmux tore
    # down the whole server and took the message with it. The cause was legible
    # only from a probe socket with this option forced on.
    #
    # `failed`, not `on`: a clean exit still closes the pane, so this holds the
    # screen only when there is something left to read.
    it "keeps a FAILED chat pane on screen, so its refusal outlives the process" do
      write_state(cache_deadline: nil, fleet: [], inbox_count: 0)

      up.call

      expect(tmux("show-window-options", "-t", "#{session}:chat", "remain-on-exit"))
        .to eq("remain-on-exit failed")
    end

    # The example above pins the option's VALUE; this one pins WHEN it lands,
    # which is the half that was broken. tmux reads remain-on-exit at
    # pane-DEATH time, and `keep_failed_pane` used to be the last thing
    # #configure_session did -- four tmux invocations after the pane was
    # already running chat -- so a chat that refused instantly died into a
    # window with no option yet and took window, session and the whole SERVER
    # with it, and #call itself then raised TmuxUnavailable ("no server
    # running") instead of leaving a corpse.
    #
    # Forced with `exit 1` rather than waited for. The race is load-sensitive,
    # so the wild version of this only reddens on a busy box (it is the
    # `-- chat args` example's recorded flake); an instant failing exit makes
    # it deterministic -- 9 losses in 20 repeats against the old ordering, 0 in
    # 20 against this one, measured with tmux alone.
    it "survives a chat that dies INSTANTLY, keeping the corpse rather than the server" do
      write_state(cache_deadline: nil, fleet: [], inbox_count: 0)

      report = described_class.new(session:, socket:, state_path:, chat_command: "exit 1",
                                   chat_preflight: no_preflight).call

      expect(report.created).to be true
      expect(dead_chat_pane?).to be(true)
      expect(tmux("show-window-options", "-t", "#{session}:chat", "remain-on-exit"))
        .to eq("remain-on-exit failed")
    end

    # Opening the window before putting the command in it costs the property
    # HEAD had for free: `new-session` carried the command, so it either
    # produced a session already running chat or produced nothing at all, and a
    # failed `lain up` was always safe to retry. Split the two and a failure
    # between them strands a session called `lain` whose `chat` window is a
    # bare login shell -- and because `configure_session` never ran, the retry
    # reports `created=false`, says "reattaching to 'lain'", carries NO
    # warnings, and drops the operator at a shell prompt. So creation stays
    # all-or-nothing on purpose.
    #
    # Real tmux for every call except the one under test: sabotaging
    # `respawn-pane` alone is what makes the half-built state reachable, and
    # nothing else about the run is faked.
    it "leaves NO session behind when the pane command cannot be spawned" do
      write_state(cache_deadline: nil, fleet: [], inbox_count: 0)
      sabotage = lambda do |*args|
        real = Mixlib::ShellOut.new(*args)
        args.include?("respawn-pane") ? FakeShellOut.new(1, "forced respawn-pane failure") : real
      end

      expect do
        described_class.new(session:, socket:, state_path:, shell_out_factory: sabotage,
                            chat_preflight: no_preflight).call
      end
        .to raise_error(described_class::TmuxUnavailable, /respawn-pane/)

      expect(tmux("list-sessions")).not_to include(session)
    end

    # The other half of the same property, and the one the operator actually
    # feels: the retry after a failed `up` must CREATE, never report itself as
    # reattaching to the wreck.
    it "lets the retry after a failed spawn create cleanly, rather than reattaching to a bare shell" do
      write_state(cache_deadline: nil, fleet: [], inbox_count: 0)
      sabotage = lambda do |*args|
        real = Mixlib::ShellOut.new(*args)
        args.include?("respawn-pane") ? FakeShellOut.new(1, "forced respawn-pane failure") : real
      end
      expect do
        described_class.new(session:, socket:, state_path:, shell_out_factory: sabotage,
                            chat_preflight: no_preflight).call
      end
        .to raise_error(described_class::TmuxUnavailable)

      retried = described_class.new(session:, socket:, state_path:, chat_command: "sleep 30",
                                    chat_preflight: no_preflight).call

      expect(retried.created).to be true
      expect(retried.warnings).to be_empty
      expect(session_count).to eq(1)
    end

    it "threads -- chat args into the spawned window's command, each argument shell-escaped" do
      write_state(cache_deadline: nil, fleet: [], inbox_count: 0)
      chat_args = ["--model", "claude-fable-5", "--no-journal"]

      described_class.new(session:, socket:, state_path:, chat_args:, chat_preflight: no_preflight).call

      # `#{pane_start_command}` is tmux's OWN format-string syntax, not Ruby
      # interpolation -- single-quoted so it reaches tmux byte-for-byte.
      # rubocop:disable Lint/InterpolationCheck
      pane_command = tmux("list-panes", "-t", "#{session}:chat", "-F", '#{pane_start_command}')
      # rubocop:enable Lint/InterpolationCheck
      expect(pane_command).to include("chat --model claude-fable-5 --no-journal")
    end

    # The one example that drives the REAL pre-flight -- a genuine `lain chat`
    # child, booted from this checkout's own exe -- against a REAL tmux. Every
    # other example in this file fakes one side or the other, and the blocker
    # the review found lived exactly in the interaction: LAIN_PREFLIGHT is
    # inherited like any variable, a tmux server hands its environment to
    # every pane, and the chat pane pre-flighted itself into a silent exit
    # that took the server down.
    #
    # So the environment carries one, deliberately. What must hold is that the
    # session is still built, nothing is warned about, and the pane's own line
    # neutralises the variable whatever the server it landed on holds. (The
    # pane still dies moments later, as it does in every example here: it
    # re-execs $PROGRAM_NAME, which under rspec is rspec. What the pane's SHELL
    # does with the scrub is pinned separately, against a real `sh`.)
    it "creates for real, with a real pre-flight, even when LAIN_PREFLIGHT is exported", :seam do
      write_state(cache_deadline: nil, fleet: [], inbox_count: 0)
      real_preflight = Lain::CLI::Up::ChatPreflight.new(shell_out_factory: Mixlib::ShellOut.public_method(:new),
                                                        cwd: @state_dir, executable: lain_exe)

      chat_args = ["--provider", "ollama", "--no-journal"]

      report = with_env("LAIN_PREFLIGHT" => "1") do
        described_class.new(session:, socket:, state_path:, chat_preflight: real_preflight, chat_args:,
                            chat_command: "#{pane_command_class.scrubs}exec #{lain_exe} chat " \
                                          "#{chat_args.join(" ")}").call
      end

      expect([report.created, report.warnings]).to eq([true, []])
      expect(session_survives_its_own_launch?).to be true
    end

    # The blocker's signature, and why THIS is the assertion rather than "the
    # pane is alive": a pane that pre-flighted itself exited **0** about a
    # second in, and an exit-0 pane is not what `remain-on-exit failed` holds
    # -- so the window, the session and the whole server went with it. Every
    # OTHER way for a chat to die exits non-zero, which the option does hold.
    # So "the session outlives its own chat pane" is exactly the property the
    # scrub restores, and nothing else about a chat's health disturbs it.
    # Three seconds is twice the boot measured on this box, so the failure has
    # time to happen rather than being outrun.
    def session_survives_its_own_launch?
      deadline = Time.now + 3
      alive = -> { tmux("list-sessions").include?(session) }
      sleep(0.05) while Time.now < deadline && alive.call
      alive.call
    end

    it "attaches instead of duplicating on a second call" do
      write_state(cache_deadline: nil, fleet: [], inbox_count: 0)

      first = up.call
      second = described_class.new(session:, socket:, state_path:, chat_preflight: no_preflight).call

      expect(first.created).to be true
      expect(second.created).to be false
      expect(session_count).to eq(1)
    end

    it "leaves the global theme untouched -- only the lain session/window carry the options" do
      write_state(cache_deadline: nil, fleet: [], inbox_count: 0)
      # A control session started on the SAME server, never touched by Up, is
      # the honest baseline: if global options had changed, this sibling
      # would inherit the change too.
      #
      # `-f File::NULL`, and it has to be THIS command: a scratch `-L` server
      # sources the developer's own tmux.conf, and this box's ends in
      # `run -b '.../tpm/tpm'` -- BACKGROUND. Measured on a fresh scratch
      # server, global `status-right` is rewritten twice while nobody is
      # looking: tmux-continuum prepends its save job at ~300ms and the theme
      # plugin blanks it at ~500ms. `up.call` sits between this example's two
      # samples, so either write lands inside the comparison and reddens it
      # for a reason that has nothing to do with `lain up`. `-f` is read when
      # the SERVER is created, and the control session is what creates it --
      # `start-server` cannot do the job, because a tmux server holding no
      # sessions exits immediately.
      system("tmux", "-L", socket, "-f", File::NULL,
             "new-session", "-d", "-s", "control", "-x", "80", "-y", "24")
      before_status_right = tmux("show-options", "-g", "status-right")
      before_bell = tmux("show-window-options", "-g", "monitor-bell")

      up.call

      expect(tmux("show-options", "-g", "status-right")).to eq(before_status_right)
      expect(tmux("show-window-options", "-g", "monitor-bell")).to eq(before_bell)
      expect(tmux("show-options", "-v", "-t", "control", "status-right")).to eq("")
      # `control:^` (tmux's "first window"), never `control:1`: the developer's
      # conf sets `base-index 1`, the `-f File::NULL` above reverts it to 0, and
      # `show-window-options -t control:1` then exits 1 with `no such window` on
      # STDERR -- which capture2 discards, so `eq("")` would pass because the
      # window is ABSENT rather than because the option is unset. Verified by
      # swapping in `control:99`, which cannot exist and still passed.
      expect(tmux("show-window-options", "-t", "control:^", "monitor-bell")).to eq("")
      expect(tmux("show-options", "-v", "-t", session, "status-right")).not_to eq("")
    end

    describe "#launch_plan" do
      it "performs the up for real (creates the session) and returns messages + exec argv" do
        write_state(cache_deadline: nil, fleet: [], inbox_count: 0)

        plan = up.launch_plan(nested: false)

        expect(session_count).to eq(1)
        expect(plan.messages).to eq(["created tmux session '#{session}'"])
        expect(plan.argv).to eq(["tmux", "-L", socket, "attach", "-t", session])
      end
    end

    # The whole-cockpit AC against a live tmux AND a live nvim (:nvim-gated,
    # LAIN_NVIM=1): two panes, one shared socket string, and -- the escalation
    # trigger's check -- one shared cwd, asserted from tmux's own
    # pane_current_path rather than assumed from default-path behavior.
    describe "--nvim cockpit", :nvim do
      it "splits the chat window into an nvim pane and a chat pane sharing one socket and one cwd" do
        write_state(cache_deadline: nil, fleet: [], inbox_count: 0)
        Dir.mktmpdir do |runtime|
          Dir.mktmpdir do |project|
            paths = Lain::Paths.new(env: { "XDG_RUNTIME_DIR" => runtime })
            expected_socket = File.join(paths.runtime_dir, "nvim-#{paths.project_hash(project)}.sock")
            # The chat pane's command re-execs $PROGRAM_NAME (rspec here) and
            # dies quickly; remain-on-exit pins the dead pane so the two-pane
            # assertion cannot race its collapse. Server-wide (-g) is fine on
            # this scratch -L server, but it needs a session to exist first.
            system("tmux", "-L", socket, "new-session", "-d", "-s", "keeper", "-x", "80", "-y", "24")
            system("tmux", "-L", socket, "set-option", "-g", "remain-on-exit", "on")

            described_class.new(session:, socket:, state_path:, nvim: "", cwd: project, paths:,
                                chat_args: ["--no-journal"], chat_preflight: no_preflight).call

            # `#{...}` here is tmux's format-string syntax, not Ruby
            # interpolation -- single-quoted so it reaches tmux byte-for-byte.
            # rubocop:disable Lint/InterpolationCheck
            panes = tmux("list-panes", "-t", "#{session}:chat", "-F",
                         '#{pane_start_command}@@#{pane_current_path}@@#{pane_dead}').lines.map(&:strip)
            # rubocop:enable Lint/InterpolationCheck
            expect(panes.size).to eq(2)
            # The -1 limit is load-bearing: a dead pane reports an EMPTY
            # pane_current_path, and a default String#split drops that trailing
            # empty field -- which used to hand `.last` the pane's own command
            # string and File.realpath an Errno::ENOENT that read like a defect
            # in `up` rather than a pane that had simply exited.
            fields = panes.map { |pane| pane.split("@@", -1) }
            commands = fields.map(&:first)
            expect(commands.find { |cmd| cmd.include?("--listen") }).to include("nvim --listen #{expected_socket}")
            expect(commands.find { |cmd| cmd.include?("chat") })
              .to include("chat --nvim #{expected_socket} --no-journal")
            # Still tmux's OWN pane_current_path, never what `up` was passed --
            # but only a LIVE pane can answer it. The chat pane re-execs and
            # dies, and tmux then reports it as either an empty path or the
            # SERVER's cwd; both were observed flaking this example. Asserting
            # over the live panes keeps the original check, and the emptiness
            # guard is what stops it passing vacuously if every pane is dead.
            live_cwds = fields.reject { |pane| pane.last == "1" }.map { |pane| pane[1] }
            expect(live_cwds).not_to be_empty
            expect(live_cwds.uniq.map { |dir| File.realpath(dir) }).to eq([File.realpath(project)])
          end
        end
      end
    end
  end

  # Pure argv construction -- no shell-out at all, so unlike the other
  # groups this needs neither a real tmux binary nor a fake shell_out_factory.
  # `nested:` is a plain kwarg (never real ENV), so these never depend on
  # whether THIS process happens to be running inside tmux.
  describe "#attach_command" do
    it "attaches when the caller is not already inside a tmux client" do
      up = described_class.new(session: "lain", socket: nil, state_path: "/irrelevant")

      expect(up.attach_command(nested: false)).to eq(%w[tmux attach -t lain])
    end

    it "switch-clients instead of attaching when the caller is already inside tmux" do
      up = described_class.new(session: "lain", socket: nil, state_path: "/irrelevant")

      expect(up.attach_command(nested: true)).to eq(%w[tmux switch-client -t lain])
    end

    it "threads the socket flag through either verb" do
      up = described_class.new(session: "lain", socket: "lain-socket", state_path: "/irrelevant")

      expect(up.attach_command(nested: false)).to eq(%w[tmux -L lain-socket attach -t lain])
      expect(up.attach_command(nested: true)).to eq(%w[tmux -L lain-socket switch-client -t lain])
    end
  end

  describe "Report#announcement" do
    it "announces a fresh creation" do
      report = described_class::Report.new(session: "lain", created: true, warnings: [])

      expect(report.announcement).to eq("created tmux session 'lain'")
    end

    it "announces reattaching to an already-running session" do
      report = described_class::Report.new(session: "lain", created: false, warnings: [])

      expect(report.announcement).to eq("reattaching to 'lain'")
    end
  end

  # launch_plan's own composition rules (message order, argv branching) --
  # all pure/fake, no real tmux needed, mirroring "degrading loudly"'s style
  # so these run on every machine. Each example builds its OWN Up instance
  # per launch_plan call rather than reusing one across two calls: #call
  # (which launch_plan invokes internally) accumulates @warnings on the
  # instance, so calling it twice on one Up would double-count a warning --
  # a fresh instance per call sidesteps that entirely rather than relying on
  # it.
  describe "#launch_plan composition" do
    let(:state_path) { "/tmp/irrelevant-for-these-examples/state.json" }

    it "orders messages as warnings first, the announcement last" do
      # has-session must miss (nonzero) so #call actually creates -- the
      # announcement under test is "created", not "reattaching".
      no_jq = lambda do |*args|
        raise Errno::ENOENT, "no such file or directory - jq" if args.first == "jq"

        FakeShellOut.new(args[1] == "has-session" ? 1 : 0, "")
      end

      plan = described_class.new(session: "lain", state_path:, shell_out_factory: no_jq).launch_plan(nested: false)

      expect(plan.messages).to eq(
        ["jq not found on PATH -- status-right falls back to raw state.json " \
         "(install jq for the formatted warmth/fleet/inbox HUD)",
         "created tmux session 'lain'"]
      )
    end

    it "branches the exec argv on nested:, independent of the warnings" do
      always_ok = ->(*_args) { FakeShellOut.new(0, "") }

      attach_plan = described_class.new(session: "lain", state_path:,
                                        shell_out_factory: always_ok).launch_plan(nested: false)
      switch_plan = described_class.new(session: "lain", state_path:,
                                        shell_out_factory: always_ok).launch_plan(nested: true)

      expect(attach_plan.argv).to eq(%w[tmux attach -t lain])
      expect(switch_plan.argv).to eq(%w[tmux switch-client -t lain])
    end
  end

  # T29: I1's feed, this HUD and the TTY prompt all default to the project's
  # `.lain/state.json`. Each used to carry its own literal; all three now name
  # the ONE locator, which is a THIRD object none of them owns -- so the
  # deliberate "I1 and I2 do not depend on each other's private path helper"
  # decision this file's comment records still holds.
  describe "the default state path" do
    # The locator is stubbed to answer a path it would never derive from the
    # working directory, so a default composed HERE cannot produce it -- which
    # is what makes this an assertion about delegation rather than about two
    # spellings of the same string.
    it "asks the ONE project locator for the HUD's state file rather than composing one" do
      elsewhere = "/tmp/the-locator-said-here/state.json"
      allow(Lain::ProjectDir).to receive(:new).and_return(instance_double(Lain::ProjectDir, state_path: elsewhere))
      calls = []
      spy = lambda do |*args|
        calls << args
        FakeShellOut.new(args[1] == "has-session" ? 1 : 0, "")
      end

      described_class.new(session: "lain", shell_out_factory: spy).call

      expect(calls.find { |args| args.include?("status-right") }.last).to include(elsewhere)
    end
  end

  # T16 F2: the one pane-command recipe, now a public seam so /fork's window
  # shares it instead of forking the string -- PATH re-export (tmux panes
  # source no interactive chruby) + exec of the LAUNCHING binary, read at
  # call time ($PROGRAM_NAME is not the lain binary under rspec).
  #
  # The recipe itself lives in {Up::PaneCommand}; `Up.pane_command` stays the
  # seam its callers name. Its examples stay in THIS file for the same reason
  # Cockpit's and Hud's do -- they are Up's children, exercised through the
  # surface Up presents.
  def pane_command_class = Lain::CLI::Up::PaneCommand

  describe ".pane_command" do
    # The LAIN_ preamble is delegated rather than spelled out: it reads the
    # REAL environment, and this suite's own runner legitimately sets
    # LAIN_-prefixed variables, so a literal here would pass or fail depending
    # on how the developer invoked rspec. {.lain_exports} has its own examples
    # below, which drive an injected env and pin the bytes.
    it "composes the env re-exports, the launching binary, and the escaped argv" do
      expect(described_class.pane_command("chat", "--fork", "a b"))
        .to eq("#{pane_command_class.scrubs}" \
               "export PATH=#{File.dirname(RbConfig.ruby)}:$PATH; " \
               "export GEM_HOME=#{Gem.paths.home}; " \
               "export GEM_PATH=#{Gem.path.join(File::PATH_SEPARATOR)}; " \
               "#{pane_command_class.lain_exports}exec #{$PROGRAM_NAME} chat --fork a\\ b")
    end

    # The blocker: `lain up` runs its pre-flight by exporting LAIN_PREFLIGHT
    # into a child, and a variable is inherited by everything downstream of
    # wherever it was set. A tmux SERVER carries it to every pane it spawns
    # (measured), so the chat pane pre-flighted instead of chatting, exited 0
    # -- which `remain-on-exit failed` does not hold -- and took the window,
    # the session and the server with it, saying nothing anywhere.
    #
    # Scrubbed HERE rather than on `new-session`, and that is the stronger
    # place: scrubbing the server lain starts protects only servers lain
    # started, while a pane command scrubs its own line whatever server it
    # lands on -- including one already tainted before `lain up` ran. /fork's
    # window and /btw's popup share the recipe, so they are covered too.
    #
    # Driven through a REAL `sh -c` with the variable exported, because what
    # is under test is what the pane's own shell does with the line, not what
    # the line looks like.
    it "unsets a stray LAIN_PREFLIGHT before the pane execs, so no pane ever runs as a pre-flight" do
      out, = Open3.capture3({ "LAIN_PREFLIGHT" => "1" }, "sh", "-c",
                            "#{pane_command_class.scrubs}printenv LAIN_PREFLIGHT; echo status=$?")

      expect(out).to eq("status=1\n")
    end

    it "puts the scrub AHEAD of the exec, where it can still take effect" do
      expect(described_class.pane_command("chat")).to start_with(pane_command_class.scrubs)
    end

    # The regression this pair exists for, and the reason PATH alone was not
    # enough: a tmux SERVER outlives the shell that started it, so a pane can
    # inherit an environment with no GEM_HOME however clean the window that
    # typed `lain up` was. The re-exported PATH then finds the right ruby, and
    # that ruby defaults Gem.dir to the ABI-keyed `~/.gem/ruby/4.0.0` rather
    # than chruby's `4.0.6` -- an empty directory, so `bundler/setup` resolves
    # nothing and the pane dies in Bundler::GemNotFound with every gem named.
    # Observed on macOS 2026-08-05: `lain up` created the session and the chat
    # pane was dead (exit 7) before the frontend drew a frame.
    it "re-exports GEM_HOME and GEM_PATH, which a tmux server started before chruby does not carry" do
      command = described_class.pane_command("chat")

      expect(command).to include("export GEM_HOME=#{Gem.paths.home}; ")
      expect(command).to include("export GEM_PATH=#{Gem.path.join(File::PATH_SEPARATOR)}; ")
    end

    # Same argument as the RbConfig.ruby stub below: the example above cannot
    # tell a live read from a literal that happens to match this box today. A
    # `bundle config path` vendor directory is the case that makes it matter --
    # the pane must land in the bundle its PARENT resolved, not in whatever the
    # spawned ruby would pick for itself.
    it "follows Gem.paths.home when it changes -- proving the gem home is read live" do
      allow(Gem).to receive(:paths)
        .and_return(instance_double(Gem::PathSupport, home: "/opt/vendor/bundle", path: ["/opt/vendor/bundle"]))

      expect(described_class.pane_command("chat")).to include("export GEM_HOME=/opt/vendor/bundle; ")
    end

    # The pane's own `$SHELL -c` reads these, so a directory with a space in it
    # would split into two words and export a truncated GEM_HOME -- silently,
    # into the same Bundler::GemNotFound the whole fix is about.
    it "escapes a gem home containing a space, since tmux hands the line to a shell" do
      allow(Gem).to receive(:paths)
        .and_return(instance_double(Gem::PathSupport, home: "/opt/my bundle", path: ["/opt/my bundle"]))

      expect(described_class.pane_command("chat")).to include('export GEM_HOME=/opt/my\ bundle; ')
    end

    # Not a general /ruby-\d+\.\d+\.\d+/ refusal -- RbConfig.ruby's bindir on
    # a ruby-install layout (this box, and CLAUDE.md's own toolchain note)
    # IS named "ruby-4.0.6", so a correct derivation legitimately contains a
    # version-shaped path segment. What must never reappear is the STALE
    # literal this fix removes.
    it "carries no stale hardcoded ruby-4.0.5 pin -- it re-exports the RUNNING interpreter's bindir" do
      expect(described_class.pane_command("chat")).not_to include("ruby-4.0.5")
      expect(described_class.pane_command("chat")).to include(File.dirname(RbConfig.ruby))
    end

    # The example above can't tell "derived live" from "a second hardcoded
    # literal that happens to match today's interpreter" -- a future
    # regression to a fresh pin (say "ruby-4.0.7") would sail through it
    # unnoticed. Stubbing RbConfig.ruby to an interpreter that could never be
    # this box's real one, and asserting the command follows the stub, is the
    # only way to prove the read is live rather than baked in.
    it "follows RbConfig.ruby when it changes -- proving the bindir is read live, not baked in" do
      allow(RbConfig).to receive(:ruby).and_return("/opt/totally-fake-ruby-9.9.9/bin/ruby")

      expect(described_class.pane_command("chat")).to include("/opt/totally-fake-ruby-9.9.9/bin")
    end
  end

  # The direnv half of the same stale-server story GEM_HOME told, and a worse
  # one: a pane's `$SHELL -c` is NON-interactive, so zsh reads .zshenv and
  # never .zshrc, direnv's hook never fires, and the pane cannot re-derive
  # these for itself. Measured 2026-08-06 -- a pane on a pre-existing server
  # read an EMPTY value even with the variable set on the `tmux new-window`
  # call, because tmux hands a pane the SERVER's environment, not the client's.
  describe ".lain_exports" do
    it "carries the flag defaults direnv pinned, escaped and in a stable order" do
      env = { "LAIN_PROVIDER" => "ollama", "LAIN_MODEL" => "qwen3:4b" }

      expect(pane_command_class.lain_exports(env))
        .to eq("export LAIN_MODEL=qwen3:4b; export LAIN_PROVIDER=ollama; ")
    end

    it "omits a name that is unset or blank, rather than exporting an empty string over it" do
      expect(pane_command_class.lain_exports({ "LAIN_PROVIDER" => "", "LAIN_MODEL" => nil })).to eq("")
    end

    it "escapes a value the pane's shell would otherwise re-interpret" do
      expect(pane_command_class.lain_exports({ "LAIN_MODEL" => "a b; touch /tmp/pwned" }))
        .to eq('export LAIN_MODEL=a\ b\;\ touch\ /tmp/pwned; ')
    end

    # The prefix is shared with this suite's own controls, and those are set on
    # exactly the machines that also run `lain up` -- a sweep would hand a live
    # chat pane the test wiring of whoever launched it.
    it "ignores LAIN_ names that are suite controls, not flag defaults" do
      env = { "LAIN_OLLAMA" => "1", "LAIN_INTEGRATION" => "1", "LAIN_NVIM" => "0", "LAIN_SPEC_BUDGET" => "30" }

      expect(pane_command_class.lain_exports(env)).to eq("")
    end

    # Never a secret: a pane command is readable from `tmux list-panes` and the
    # process table, so an exported key would be legible to every process on
    # the box. This is the example that fails if someone "fixes" a missing-key
    # crash by forwarding the credential.
    it "never carries an API key into a command line the process table can read" do
      env = { "ANTHROPIC_API_KEY" => "sk-ant-secret", "AWS_SECRET_ACCESS_KEY" => "shh" }

      expect(pane_command_class.lain_exports(env)).to eq("")
      expect(pane_command_class::PANE_ENV).to all(start_with("LAIN_"))
    end

    # PANE_ENV is a hand-maintained list against a set that grows in ANOTHER
    # file, and the failure is silent: a new env-backed flag simply stops
    # reaching panes, which looks exactly like the direnv bug this fixes. So
    # re-derive the truth from exe/lain rather than trusting the copy.
    it "lists every name EnvDefaults actually reads -- no drift against exe/lain" do
      declared = File.read(File.expand_path("../../../exe/lain", __dir__))
                     .scan(/EnvDefaults\.(?:string|numeric)\(\s*"(LAIN_[A-Z_]+)"/).flatten.uniq

      expect(declared).not_to be_empty
      expect(pane_command_class::PANE_ENV).to match_array(declared)
    end
  end

  # T11: `lain up -- ARGS` threads the trailing chat flags into the spawned
  # window's command. `chat` validates its own flags -- Up never parses
  # `chat_args`, only Shellwords-escapes each element, so these examples
  # assert on the composed STRING, never on flag semantics.
  describe "-- chat args pass-through" do
    let(:state_path) { "/tmp/irrelevant-for-these-examples/state.json" }

    # `respawn-pane`, not `new-session`: the window is opened bare so
    # remain-on-exit can be pinned before any command runs, and the chat
    # command lands in the pane a beat later. See Up#create_session.
    def capture_chat_pane_command(chat_args:)
      calls = []
      spy = lambda do |*args|
        calls << args
        FakeShellOut.new(args[1] == "has-session" ? 1 : 0, "")
      end

      described_class.new(session: "lain", state_path:, chat_args:, shell_out_factory: spy).call

      calls.find { |args| args.include?("respawn-pane") }.last
    end

    it "shell-escapes every chat arg onto the default chat command" do
      command = capture_chat_pane_command(chat_args: ["--model", "claude-fable-5", "--no-journal"])

      # The env preamble is {.pane_command}'s own subject (it has its own
      # examples above, which pin every export); what THIS pair is about is the
      # argv tail, so the prefix is delegated rather than duplicated -- the same
      # way btw_spec and fork_spec compare against the recipe.
      expect(command).to eq("#{pane_command_class.scrubs}#{pane_command_class.gem_exports}" \
                            "exec #{$PROGRAM_NAME} chat --model claude-fable-5 --no-journal")
    end

    it "leaves the chat command untouched when no chat args are given" do
      command = capture_chat_pane_command(chat_args: [])

      expect(command).to eq("#{pane_command_class.scrubs}#{pane_command_class.gem_exports}" \
                            "exec #{$PROGRAM_NAME} chat")
    end

    it "keeps a hostile chat arg inert -- it reaches chat as one literal argument, never shell syntax" do
      Dir.mktmpdir do |marker|
        hostile = "; touch #{marker}/pwned $(touch #{marker}/pwned2)"

        command = capture_chat_pane_command(chat_args: [hostile])
        Open3.capture3("sh", "-c", command)

        expect(Dir.children(marker)).to be_empty
      end
    end

    it "shell-escapes a hostile arg as a single Shellwords-escaped token" do
      hostile = "; rm -rf /"

      command = capture_chat_pane_command(chat_args: [hostile])

      expect(command).to end_with(Shellwords.escape(hostile))
    end
  end

  # T9: a construction refusal reaches the operator's OWN terminal, before a
  # session exists to hide it. `lain up` asks `chat` whether it would refuse
  # by running it -- in a child process, with the same argv it would have put
  # in the pane -- and reads the exit status and stderr back.
  #
  # Why it cannot be answered any other way: `chat`'s flag surface is Thor's,
  # declared in exe/lain, and Up is forbidden to parse it (`Up
  # #default_chat_command`'s note -- "Up never parses or knows the flag
  # names"). So the check runs the flags' own owner and reports its verdict.
  # These examples therefore assert on the CALL Up makes and on what it does
  # with the answer; what the child then checks is chat_launch_spec's subject.
  describe "the chat pre-flight" do
    let(:state_path) { "/tmp/irrelevant-for-these-examples/state.json" }

    # One fake factory for both callees, told apart the way the subject tells
    # them apart: tmux is invoked as "tmux", the pre-flight as the launching
    # binary. `calls` is the example's own array so it survives a refusal --
    # what did NOT happen afterwards is half of what these examples assert.
    # `session_exists` drives the create-vs-reattach branch.
    def run_up(calls, chat_args: [], preflight: FakeShellOut.new(0, ""), session_exists: false, **keywords)
      spy = lambda do |*args|
        calls << args
        # Only the launching binary gets the example's answer: `jq --version`
        # comes through the same factory, and handing IT a refusal would prove
        # the wrong thing.
        others = FakeShellOut.new(args[1] == "has-session" && !session_exists ? 1 : 0, "")
        args.first == $PROGRAM_NAME ? preflight : others
      end
      described_class.new(session: "lain", state_path:, chat_args:, shell_out_factory: spy, **keywords).call
    end

    # By the BINARY, not by "the call that is not tmux": `jq` and `nvim` are
    # probed through the same factory, and a helper that matched either of
    # those would pass for the wrong reason.
    def preflight_call(calls) = calls.find { |args| args.first == $PROGRAM_NAME }

    # The raised object, for the examples that assert on the message rather
    # than on which call was or was not made.
    def refusal_from(answer, chat_args: [])
      run_up([], chat_args:, preflight: answer)
      raise "expected a ChatRefused"
    rescue Lain::CLI::Up::ChatRefused => e
      e
    end

    it "refuses in chat's own words, and no tmux session is created" do
      refusal = "ANTHROPIC_API_KEY is not set; --provider anthropic needs it to build a client\n"
      calls = []

      expect { run_up(calls, preflight: FakeShellOut.new(1, refusal)) }
        .to raise_error(Lain::CLI::Up::ChatRefused, refusal.strip)
      expect(calls.flatten).not_to include("new-session")
    end

    # The exe maps a Lain::Error to a Thor::Error, which prints the message
    # and nothing else -- so what the message carries IS what the operator
    # reads. A backtrace frame here would reach them verbatim.
    it "carries the refusal verbatim, with no backtrace frames" do
      thor_refusal = "ERROR: \"lain chat\" was called with arguments [\"--nosuchflag\"]\nUsage: \"lain chat\"\n"

      error = refusal_from(FakeShellOut.new(1, thor_refusal), chat_args: ["--nosuchflag"])

      expect(error.message).to eq(thor_refusal.strip)
      expect(error.message).not_to match(/\.rb:\d+:in/)
    end

    # The one message on this path that lain did not write. A refusal is a
    # line; a CRASHING child is a backtrace, and AC1 promises the operator
    # never reads a frame -- so the frames are dropped rather than relayed,
    # and what is left is capped, since this ends up on a terminal.
    it "relays what the child said without its backtrace frames, and caps a runaway stderr" do
      crash = +"/x/y.rb:12:in 'boom': something broke (RuntimeError)\n" \
               "\tfrom /x/y.rb:30:in 'block in <main>'\n" \
               "\tfrom /x/y.rb:9:in 'Kernel#loop'\n" \
               "chat could not start\n"
      crash << ("noise\n" * 1_000_000) # ~6MB, the shape the review measured at 8

      error = refusal_from(FakeShellOut.new(1, crash))

      expect(error.message).not_to match(/:\d+:in /)
      expect(error.message).to include("chat could not start")
      expect(error.message.bytesize).to be <= described_class::ChatPreflight::MAX_BYTES
    end

    # The half that "drop the frames" gets wrong if it drops LINES: Ruby puts
    # the frame and the cause on the same first line
    # (`path:n:in 'method': MESSAGE (Class)`), so a line-wise filter hands the
    # operator "refused these arguments (exit 1)" about a chat that said
    # exactly what went wrong. The frame goes; the sentence stays.
    #
    # Driven off a REAL uncaught exception rather than a hand-typed one --
    # the format is Ruby's to change, and it has (the method label was
    # backtick-quoted before 3.4).
    it "keeps the cause on the line the frame shares with it" do
      _, crashed, = Open3.capture3(RbConfig.ruby, "-e", 'raise "boom from inside chat"')

      error = refusal_from(FakeShellOut.new(1, crashed))

      expect(error.message).to include("boom from inside chat")
      expect(error.message).not_to match(/:\d+:in /)
    end

    it "replaces bytes that are not valid UTF-8 rather than handing them to a terminal" do
      error = refusal_from(FakeShellOut.new(1, (+"bad \xC3\x28 byte").force_encoding(Encoding::BINARY)))

      expect(error.message.encoding).to eq(Encoding::UTF_8)
      expect(error.message).to be_valid_encoding
    end

    it "hands chat the argv it would have put in the pane, one element per argument" do
      hostile = "; rm -rf /"

      calls = []
      run_up(calls, chat_args: ["--model", "claude-fable-5", hostile])

      expect(preflight_call(calls).take(5)).to eq([$PROGRAM_NAME, "chat", "--model", "claude-fable-5", hostile])
    end

    # LAIN_PREFLIGHT is what stops the child opening a conversation, and the
    # timeout is what stops `lain up` hanging on a check.
    it "runs the child in the project's directory, in pre-flight mode, under a bounded wait" do
      calls = []
      run_up(calls, cwd: "/some/project")

      expect(preflight_call(calls).last)
        .to eq(cwd: "/some/project", env: { Lain::CLI::ChatLaunch::PREFLIGHT_ENV => "1" },
               timeout: described_class::ChatPreflight::TIMEOUT)
    end

    it "creates the session and spawns the chat pane as before when chat accepts the argv" do
      calls = []
      report = run_up(calls, chat_args: ["--no-journal"])

      expect(calls.flatten).to include("new-session")
      expect(calls.find { |args| args.include?("respawn-pane") }.last)
        .to eq("#{pane_command_class.scrubs}#{pane_command_class.gem_exports}" \
               "exec #{$PROGRAM_NAME} chat --no-journal")
      expect(report.warnings).to be_empty
    end

    # Reattaching respawns nothing, so there is no launch to pre-empt -- and
    # a check that refused here would lock an operator out of a session that
    # is already running perfectly well.
    it "asks nothing when reattaching, since no chat pane is spawned" do
      calls = []
      run_up(calls, session_exists: true)

      expect(preflight_call(calls)).to be_nil
    end

    # Degraded is never silent, and it is never fatal either: a check that
    # cannot run is not a refusal, so the cockpit still opens.
    it "warns and opens anyway when the check itself cannot run" do
      calls = []
      cannot_run = lambda do |*args|
        calls << args
        raise Errno::ENOENT, "no such file or directory - lain" if args.first == $PROGRAM_NAME

        FakeShellOut.new(args[1] == "has-session" ? 1 : 0, "")
      end

      report = described_class.new(session: "lain", state_path:, shell_out_factory: cannot_run).call

      expect(report.warnings.join).to match(/pre-flight|preflight/i)
      expect(calls.flatten).to include("new-session")
    end

    # A child with NO exit status was signalled, which answers neither
    # question -- so it degrades with the rest rather than reading as a
    # refusal (or dying on `nil.zero?`, which is how it read before).
    it "warns and opens anyway when the child was killed before it could answer" do
      calls = []
      report = run_up(calls, preflight: FakeShellOut.new(nil, ""))

      expect(report.warnings.join).to include("killed before it could answer")
      expect(calls.flatten).to include("new-session")
    end
  end

  # T19: `lain up --nvim` splits the chat window into a cockpit -- one pane
  # `nvim --listen <socket>`, one pane `lain chat --nvim <socket> ...` -- with
  # the socket computed ONCE, in Ruby, and handed to both panes explicitly, so
  # agreement is by construction rather than by each side re-deriving it. All
  # fake-factory: command COMPOSITION runs on every machine; the live cockpit
  # example sits with the real-tmux group, :nvim-gated.
  describe "--nvim cockpit composition" do
    let(:state_path) { "/tmp/irrelevant-for-these-examples/state.json" }
    let(:cwd) { "/some/project" }

    # `binaries` marks non-tmux probes present (0) or absent (ENOENT); tmux
    # itself always answers, with has-session missing so #call creates.
    def cockpit_up(calls, nvim:, binaries: {}, chat_args: [], paths: Lain::Paths.new(env: {}))
      spy = lambda do |*args|
        calls << args
        raise Errno::ENOENT, "no such file - #{args.first}" if binaries.fetch(args.first, true) == false

        FakeShellOut.new(args.first == "tmux" && args[1] == "has-session" ? 1 : 0, "")
      end
      described_class.new(session: "lain", state_path:, nvim:, cwd:, paths:, chat_args:, shell_out_factory: spy)
    end

    def new_session_call(calls) = calls.find { |args| args.include?("new-session") }
    def split_call(calls) = calls.find { |args| args.include?("split-window") }

    # `new-session` opens the window BARE so remain-on-exit can be pinned
    # before anything runs in it (Up#create_session), so the first pane's
    # real command -- nvim's, or chat's when the cockpit degrades -- arrives on
    # the respawn. That is where every command assertion below reads it.
    def first_pane_call(calls) = calls.find { |args| args.include?("respawn-pane") }

    it "derives the plugin's deterministic socket and threads it into both panes" do
      Dir.mktmpdir do |runtime|
        calls = []
        paths = Lain::Paths.new(env: { "XDG_RUNTIME_DIR" => runtime })
        socket = File.join(paths.runtime_dir, "nvim-#{paths.project_hash(cwd)}.sock")

        cockpit_up(calls, nvim: "", paths:).call

        # The `-c` is a ternary, not `if … | … | endif` (nvim 0.12's `-c` takes
        # ONE Ex command and dies on E488 at the first `|`) and not `silent!`
        # (which swallows a real failure inside :LainStart -- how a layout that
        # never opened went unnoticed). Both were measured; see
        # `Up::Cockpit::LAIN_START`.
        expect(first_pane_call(calls).last)
          .to eq(Shellwords.join(["nvim", "--cmd", "set rtp+=#{paths.nvim_plugin_root}", "--listen", socket,
                                  "-c", Lain::CLI::Up::Cockpit::SCRATCH_BUFFER,
                                  "-c", Lain::CLI::Up::Cockpit::LAIN_START]))
        expect(split_call(calls).last).to end_with("chat --nvim #{Shellwords.escape(socket)}")
      end
    end

    # A dashboard plugin (snacks.nvim here, but alpha/dashboard-nvim/
    # mini.starter all do it) draws over exactly the empty unnamed buffer the
    # cockpit's nvim boots into, hiding the cockpit until the first view lands.
    # Naming the buffer is what trips snacks' own guard -- measured against
    # nvim 0.12.4, which bailed with reason "buffer has a name".
    it "names the startup buffer, so a user's dashboard plugin does not cover the cockpit" do
      Dir.mktmpdir do |runtime|
        calls = []

        cockpit_up(calls, nvim: "", paths: Lain::Paths.new(env: { "XDG_RUNTIME_DIR" => runtime })).call

        expect(first_pane_call(calls).last)
          .to include("-c #{Shellwords.escape(Lain::CLI::Up::Cockpit::SCRATCH_BUFFER)}")
      end
    end

    # NOT `lain://`-prefixed: init.lua's fallback scan collects every
    # `^lain://` buffer as layout-eligible, and this one is a placeholder the
    # runtime never created, so a matching name would offer the layout a buffer
    # that is not a view.
    it "keeps the scratch name out of the lain:// namespace the plugin scans" do
      expect(Lain::CLI::Up::Cockpit::SCRATCH_BUFFER).not_to include("lain://")
    end

    # T2: the gem's own plugin/nvim ships the layout sugar this AC is about --
    # putting it on the pane's runtimepath is what makes :LainStart exist with
    # zero user config, and the `exists()` ternary (asserted above) is what
    # keeps a bare `nvim --listen` unharmed either way.
    # There was a refusal here for a socket that was really the swallowed first
    # chat flag: `--nvim` took an OPTIONAL value, so written last before `--`
    # Thor handed it "--provider" and the shared socket the cockpit exists to
    # establish silently was not there. `--nvim` is a valueless boolean now and
    # the socket has its own `--nvim-socket`, so nothing in that argv position
    # can be consumed -- the guard was retired with the ambiguity rather than
    # left inert, and `RSpec.describe LainCLI` below is where the replacement
    # coverage lives: it pins that `lain up --nvim /tmp/repo` keeps the PATH.

    it "puts the gem's plugin/nvim directory on the runtimepath, guarded ahead of --listen" do
      calls = []

      cockpit_up(calls, nvim: "/x/explicit.sock").call

      expect(first_pane_call(calls).last)
        .to include("--cmd #{Shellwords.escape("set rtp+=#{Lain::Paths::NVIM_PLUGIN_ROOT}")} --listen")
    end

    # T2 degrade AC: a shipped plugin directory that cannot be located is a
    # runtimepath-sugar loss, not a cockpit failure -- the split still
    # happens (mirrors the missing-nvim-binary fallback's "never silent"
    # rule, but the fallback itself differs: THAT one drops to a single
    # pane, this one keeps both and just skips --cmd).
    it "still opens the cockpit with a plain nvim pane, warning namedly, when the shipped plugin is missing" do
      calls = []
      missing_root = "/nonexistent/lain-plugin-nvim"
      paths = Lain::Paths.new(env: {}, nvim_plugin_root: missing_root)

      report = cockpit_up(calls, nvim: "", paths:).call

      expect(first_pane_call(calls).last).not_to include("--cmd")
      expect(first_pane_call(calls).last).to include("--listen")
      expect(split_call(calls)).not_to be_nil
      expect(report.warnings.join).to include(missing_root)
    end

    it "creates the derived socket's directory, private to the user, so nvim --listen can bind" do
      Dir.mktmpdir do |runtime|
        calls = []
        paths = Lain::Paths.new(env: { "XDG_RUNTIME_DIR" => runtime })

        cockpit_up(calls, nvim: "", paths:).call

        dir = paths.runtime_dir
        expect(File.directory?(dir)).to be(true)
        expect(File.stat(dir).mode & 0o777).to eq(0o700)
      end
    end

    it "hands an explicit --nvim SOCKET to both panes untouched" do
      calls = []

      cockpit_up(calls, nvim: "/x/explicit.sock").call

      expect(first_pane_call(calls).last).to include("--listen /x/explicit.sock")
      expect(split_call(calls).last).to include("chat --nvim /x/explicit.sock")
    end

    it "orders the chat pane's flags as --nvim SOCKET first, then the -- passthrough args" do
      calls = []

      cockpit_up(calls, nvim: "/x/explicit.sock", chat_args: ["--model", "claude-fable-5"]).call

      expect(split_call(calls).last).to end_with("chat --nvim /x/explicit.sock --model claude-fable-5")
    end

    # The escalation trigger's same-cwd guarantee: both panes are pinned to
    # the SAME directory with tmux's own -c, never left to default-path
    # inheritance -- the socket hash and the panes' cwd cannot diverge.
    it "pins both panes to the same cwd via -c" do
      calls = []

      cockpit_up(calls, nvim: "/x/explicit.sock").call

      # Three calls now carry the directory, not two: the window is opened
      # bare and then respawned into, so the -c has to survive BOTH halves of
      # the first pane's creation or the pane lands in the server's cwd.
      expect(new_session_call(calls).each_cons(2)).to include(["-c", cwd])
      expect(first_pane_call(calls).each_cons(2)).to include(["-c", cwd])
      expect(split_call(calls).each_cons(2)).to include(["-c", cwd])
    end

    it "degrades to the single chat pane, warning namedly, when nvim is missing" do
      calls = []

      report = cockpit_up(calls, nvim: "", binaries: { "nvim" => false }).call

      expect(split_call(calls)).to be_nil
      expect(first_pane_call(calls).last).not_to include("--nvim")
      expect(first_pane_call(calls).last).to include("chat")
      expect(report.warnings.join).to include("nvim not found on PATH")
    end

    # T19 panel fix: reattaching with --nvim cannot build the cockpit (the
    # session is already there), and a still-un-split chat window means the
    # request is being ignored -- degraded is never silent, so it warns
    # namedly. A window already carrying the cockpit's two panes has nothing
    # to warn about.
    def reattaching_up(calls, pane_lines:, paths: Lain::Paths.new(env: {}))
      spy = lambda do |*args|
        calls << args
        # has-session hits (the session already exists); list-panes answers
        # one line per live pane, the probe #call reads on the reattach path.
        FakeShellOut.new(0, "", args[1] == "list-panes" ? pane_lines : "")
      end
      described_class.new(session: "lain", state_path:, nvim: "", cwd:,
                          paths:, shell_out_factory: spy)
    end

    it "leaves an already-running session alone, warning that the un-split window has no cockpit" do
      calls = []

      report = reattaching_up(calls, pane_lines: "0: bash\n").call

      expect(report.created).to be(false)
      expect(new_session_call(calls)).to be_nil
      expect(first_pane_call(calls)).to be_nil
      expect(split_call(calls)).to be_nil
      expect(report.warnings.join).to include("already exists without the nvim pane")
    end

    it "does not warn on reattach when the existing window already carries the cockpit's two panes" do
      calls = []

      report = reattaching_up(calls, pane_lines: "0: nvim\n1: chat\n").call

      expect(report.created).to be(false)
      expect(report.warnings).to be_empty
    end

    # T2 escalation trigger: the plugin-root probe must be create-path only --
    # a reattach that finds the cockpit already there must stay silent even
    # when the shipped plugin cannot be located, because #call never rebuilds
    # the pane commands on that path.
    it "stays silent on reattach even when the shipped plugin is missing" do
      calls = []
      paths = Lain::Paths.new(env: {}, nvim_plugin_root: "/nonexistent/lain-plugin-nvim")

      report = reattaching_up(calls, pane_lines: "0: nvim\n1: chat\n", paths:).call

      expect(report.created).to be(false)
      expect(report.warnings).to be_empty
    end
  end

  # T7: the HUD's own render, driven straight through `sh` rather than through
  # a tmux server, so the new StatusFeed fields are pinned on every machine
  # that has jq -- not only on one that also has tmux. The filter under test is
  # the SAME Up::Hud::JQ_FILTER the tmux plugin script embeds byte-for-byte
  # (spec/plugin/tmux_plugin_spec.rb pins that), so one render is one HUD.
  describe "Hud, rendering the state feed's fields" do
    def jq_present? = system("jq", "--version", out: File::NULL, err: File::NULL)

    before { skip("jq not found on PATH") unless jq_present? }

    around do |example|
      Dir.mktmpdir { |dir| @state_dir = dir and example.run }
    end

    let(:state_path) { File.join(@state_dir, "state.json") }

    def render(state)
      File.write(state_path, JSON.generate(state))
      value, = Lain::CLI::Up::Hud.new(state_path:).status_right(jq_present: true)
      eval_status_job(value)
    end

    def warm_state(**overrides)
      { "cache_deadline" => (Time.now + 300).utc.iso8601, "fleet" => %w[a b], "inbox_count" => 3 }.merge(overrides)
    end

    it "names both a pending approval and the context occupancy" do
      out = render(warm_state("approvals_pending" => 1, "occupancy" => 0.34))

      expect(out).to eq("🔥 fleet:2 inbox:3 approve:1 ctx:34%")
    end

    # A state written before these fields existed (an older `lain`, a
    # hand-written fixture, the pre-first-turn publish where occupancy is
    # genuinely absent) must render the line it always did -- a HUD that says
    # "approve:0 ctx:--" on every quiet chat is noise, not information.
    it "says nothing about either when the state carries neither" do
      expect(render(warm_state)).to eq("🔥 fleet:2 inbox:3")
    end

    it "stays quiet about approvals while none are parked" do
      expect(render(warm_state("approvals_pending" => 0, "occupancy" => nil))).to eq("🔥 fleet:2 inbox:3")
    end

    it "renders a genuinely empty context as 0%, since only ABSENCE is silent" do
      expect(render(warm_state("occupancy" => 0.0))).to eq("🔥 fleet:2 inbox:3 ctx:0%")
    end

    # StatusFeed publishes used/window, and a ratio above 1.0 is a NORMAL
    # published value rather than a defect. Since T10 a live chat divides by the
    # window its provider says it is serving ({CLI::Backend#context_window}), so
    # this is rarer than it was -- but a model no book carries and no server
    # reports on still falls to {ContextWindow::CONSERVATIVE_FALLBACK}'s 8,192,
    # which is deliberately small so compaction fires early rather than never.
    # "ctx:244%" is what an unclamped filter would then put on a status bar.
    it "clamps a ratio above 1.0 rather than rendering a nonsense percentage" do
      expect(render(warm_state("occupancy" => 2.44))).to eq("🔥 fleet:2 inbox:3 ctx:100%")
    end

    # T8: the mode. StatusFeed publishes the lighter already composed, so this
    # filter carries no copy of the posture/layer ladder and no comparison
    # against the default posture's NAME -- "silent under accept_edits" is one
    # rule, declared once, in Mode::Posture.
    it "names the posture and every active layer through the composed lighter" do
      expect(render(warm_state("mode_lighter" => "MAN AA"))).to eq("🔥 fleet:2 inbox:3 MAN AA")
    end

    it "says nothing about the mode under the default posture, whose lighter is empty" do
      expect(render(warm_state("mode_lighter" => ""))).to eq("🔥 fleet:2 inbox:3")
    end

    it "says nothing about the mode before the first switch, when the key is absent" do
      expect(render(warm_state("posture" => nil, "mode_lighter" => nil))).to eq("🔥 fleet:2 inbox:3")
    end
  end

  describe "degrading loudly" do
    let(:state_path) { "/tmp/irrelevant-for-these-examples/state.json" }

    it "fails with a named Lain::Error, not a backtrace, when there is no tmux binary" do
      no_tmux = ->(*_args) { raise Errno::ENOENT, "no such file or directory - tmux" }

      expect { described_class.new(state_path:, shell_out_factory: no_tmux).call }
        .to raise_error(Lain::CLI::Up::TmuxUnavailable, /tmux/)
    end

    it "fails with a named Lain::Error, not a backtrace, when tmux cannot spawn a server" do
      # has-session behaves exactly as it would for a genuinely absent
      # session (nonzero, no error) -- the failure has to come from
      # new-session itself actually failing, not from that expected miss.
      broken = lambda do |*args|
        case args[1]
        when "has-session" then FakeShellOut.new(1, "")
        when "new-session" then FakeShellOut.new(1, "error connecting to /no/such/socket")
        else FakeShellOut.new(0, "")
        end
      end

      expect { described_class.new(state_path:, shell_out_factory: broken).call }
        .to raise_error(Lain::CLI::Up::TmuxUnavailable, %r{no/such/socket})
    end

    it "warns namedly and falls back to a jq-free status formatter when jq is missing" do
      calls = []
      no_jq = lambda do |*args|
        calls << args
        raise Errno::ENOENT, "no such file or directory - jq" if args.first == "jq"

        FakeShellOut.new(0, "")
      end

      report = described_class.new(state_path:, shell_out_factory: no_jq).call

      expect(report.warnings.join).to match(/jq/i)
      status_right_call = calls.find { |args| args.include?("status-right") }
      status_right_value = status_right_call.last
      expect(status_right_value).not_to include("jq")
      expect(status_right_value).to include(state_path)
    end
  end
end

# T6: `lain up [PATH]` opens a project OTHER than the shell's own directory.
#
# The failure these examples exist for is a PARTIAL one, which is what makes it
# hard to see by inspection. `up` names a directory in three places -- both
# panes' tmux `-c`, the nvim socket's hash, and the HUD's `.lain/state.json` --
# and two of them read a value no PATH argument could change. A cockpit sitting
# in the project the user named, beside a status bar reading the shell's, looks
# like a stale HUD rather than like the wrong project.
#
# `.from_options` is the flag -> contract translator, not a constructor a
# caller parameterises, so it has no `shell_out_factory` seam. The spy goes on
# what {Lain::CLI::Up#initialize}'s default reaches for instead:
# `Mixlib::ShellOut.public_method(:new)` is resolved per construction, so a
# stub installed here IS the factory the Up ends up holding. That keeps these
# examples driving the real translation rather than a hand-built Up, which
# would prove nothing about the argument that produced it.
RSpec.describe Lain::CLI::Up, "opening a PATH" do
  # The `up` flags at their exe defaults, so an example varies only its PATH.
  def up_options(**overrides) = { session: "lain", socket: nil, nvim: true, nvim_socket: nil }.merge(overrides)

  def tmux_calls(path:, **overrides)
    calls = []
    allow(Mixlib::ShellOut).to receive(:new) do |*args|
      calls << args
      FakeShellOut.new(args[1] == "has-session" ? 1 : 0, "")
    end
    described_class.from_options(up_options(**overrides), chat_args: [], path:).call
    calls
  end

  def new_session_call(calls) = calls.find { |args| args.include?("new-session") }
  def split_call(calls) = calls.find { |args| args.include?("split-window") }
  def status_right_call(calls) = calls.find { |args| args.include?("status-right") }

  # The first pane's COMMAND arrives on the respawn, not on the new-session
  # that opens the window bare -- see Up#create_session. Its `-c` is asserted
  # through #new_session_call above, which still carries the window's own.
  def first_pane_call(calls) = calls.find { |args| args.include?("respawn-pane") }

  # `-c DIR` reaches tmux as two ADJACENT argv elements, so the pair is what
  # gets asserted -- `include("-c").and include(dir)` would pass on an argv
  # that carried the directory somewhere else entirely.
  def pinned_dirs(call) = call.each_cons(2).filter_map { |flag, dir| dir if flag == "-c" }

  # A temp directory with its symlinks ALREADY resolved, so `File.expand_path`
  # (what the subject does, lexically) and `File.realpath` (what a fixture
  # would otherwise be spelled with) cannot disagree. They agree by accident on
  # a box where `/tmp` is a real directory and stop agreeing wherever `TMPDIR`
  # resolves through a link -- and every example here would then redden for a
  # reason that has nothing to do with the subject.
  def scratch_dir(&block) = Dir.mktmpdir { |dir| yield(File.realpath(dir)) }

  it "pins both cockpit panes to a relative PATH, expanded against the shell's directory" do
    scratch_dir do |dir|
      services = File.join(dir, "repo", "services")
      FileUtils.mkdir_p(services)

      calls = Dir.chdir(dir) { tmux_calls(path: "repo/services") }

      expect(pinned_dirs(new_session_call(calls))).to eq([services])
      expect(pinned_dirs(split_call(calls))).to eq([services])
    end
  end

  # The HUD half of the same value. The chat pane publishes its state file from
  # its OWN cwd (StatusFeed#default_path), so a status bar reading the shell's
  # project shows a file nothing is writing -- which renders as a HUD frozen at
  # its startup values, not as an error.
  it "points the HUD at the PATH's own .lain/state.json, not the shell's" do
    scratch_dir do |dir|
      repo = File.join(dir, "repo")
      FileUtils.mkdir_p(repo)

      calls = tmux_calls(path: repo)

      expect(status_right_call(calls).last).to include(File.join(repo, ".lain", "state.json"))
    end
  end

  # --no-nvim spawns ONE pane through a different tmux invocation, which is why
  # it needs its own example: the cockpit's two `-c`s were already there and
  # this window's was not, so it would have inherited the tmux SERVER's
  # directory -- whatever project happened to start the server.
  it "pins the plain --no-nvim window to the PATH too, rather than inheriting tmux's default-path" do
    scratch_dir do |dir|
      calls = tmux_calls(path: dir, nvim: false)

      expect(split_call(calls)).to be_nil
      expect(pinned_dirs(new_session_call(calls))).to eq([dir])
    end
  end

  it "derives a different nvim socket per PATH, since the socket is keyed on the directory" do
    scratch_dir do |runtime|
      scratch_dir do |one|
        scratch_dir do |two|
          sockets = with_env("XDG_RUNTIME_DIR" => runtime) do
            [one, two].map { |dir| first_pane_call(tmux_calls(path: dir)).last[/--listen (\S+)/, 1] }
          end

          expect(sockets).to all(start_with(runtime))
          expect(sockets.uniq.size).to eq(2)
        end
      end
    end
  end

  # An explicit socket is used verbatim, whichever flag spelled it: Cockpit
  # takes a resolved `option`, so moving the socket off `--nvim` onto
  # `--nvim-socket` changed the exe and nothing below it.
  it "hands --nvim-socket to both panes verbatim, alongside a PATH" do
    scratch_dir do |dir|
      calls = tmux_calls(path: dir, nvim_socket: "/x/explicit.sock")

      expect(first_pane_call(calls).last).to include("--listen /x/explicit.sock")
      expect(split_call(calls).last).to include("chat --nvim /x/explicit.sock")
      expect(pinned_dirs(split_call(calls))).to eq([dir])
    end
  end

  it "keeps two --nvim-socket launches on the sockets they named, not on one derived pair" do
    scratch_dir do |dir|
      sockets = %w[/x/one.sock /x/two.sock].map do |sock|
        first_pane_call(tmux_calls(path: dir, nvim_socket: sock)).last[/--listen (\S+)/, 1]
      end

      expect(sockets).to eq(%w[/x/one.sock /x/two.sock])
    end
  end

  # An EMPTY --nvim-socket is Cockpit's derive sentinel, which was true by
  # accident and is now the stated rule: an empty shell variable expands to
  # nothing, and "an empty flag means no flag" is what `--root` already does.
  it "reads an empty --nvim-socket as no flag, deriving the per-project socket" do
    scratch_dir do |runtime|
      scratch_dir do |dir|
        socket = with_env("XDG_RUNTIME_DIR" => runtime) do
          first_pane_call(tmux_calls(path: dir, nvim_socket: ""))
        end.last[/--listen (\S+)/, 1]

        expect(socket).to start_with(runtime)
      end
    end
  end

  # Thor answers a BARE `--nvim-socket` with the flag's own name, so the socket
  # would be a relative file called `nvim_socket` in whichever pane read it
  # first -- and the editor and chat would never meet. Refused as "not
  # absolute", which is the rule the socket needs anyway rather than a
  # comparison against the flag's name.
  it "refuses a relative --nvim-socket, which is what a bare one degenerates into" do
    scratch_dir do |dir|
      expect { tmux_calls(path: dir, nvim_socket: "nvim_socket") }
        .to raise_error(Lain::CLI::Up::Cockpit::UnusableSocket, /nvim_socket.*absolute/m)
    end
  end

  it "refuses --nvim-socket together with --no-nvim, naming both rather than dropping one" do
    expect { described_class.from_options(up_options(nvim: false, nvim_socket: "/x.sock"), chat_args: []) }
      .to raise_error(Lain::CLI::Up::Flags::SocketWithoutCockpit, /--no-nvim.*--nvim-socket/m)
  end

  it "leaves the shell's own directory in charge when no PATH is given" do
    scratch_dir do |dir|
      calls = Dir.chdir(dir) { tmux_calls(path: nil) }

      expect(pinned_dirs(new_session_call(calls))).to eq([dir])
    end
  end

  # The refusal lands before an Up exists at all, which is the strongest form
  # of "no tmux session is created": there is nothing holding a shell_out
  # factory to make one with.
  it "refuses a PATH that is a regular file, by name, before it builds anything that could reach tmux" do
    Tempfile.create("lain-up-not-a-directory") do |file|
      expect(described_class).not_to receive(:new)

      expect { described_class.from_options(up_options, chat_args: [], path: file.path) }
        .to raise_error(Lain::CLI::Up::Workdir::NotADirectory, /#{Regexp.escape(file.path)}/)
    end
  end

  it "refuses a PATH that does not exist rather than creating it or falling back to the shell" do
    scratch_dir do |dir|
      missing = File.join(dir, "no-such-project")

      expect { described_class.from_options(up_options, chat_args: [], path: missing) }
        .to raise_error(Lain::CLI::Up::Workdir::NotADirectory, /#{Regexp.escape(missing)}/)
    end
  end
end

# The argv half, driven through LainCLI's REAL Thor parsing: what is under test
# IS the split, and Thor is what does the splitting -- calling #up with a
# hand-made list would assert the split against itself.
RSpec.describe LainCLI, "naming a project on the command line" do
  describe "lain up PATH" do
    # Driven for the argv split only: Up is replaced wholesale, so no tmux is
    # touched and #up's Kernel.exec never has a real argv to run.
    #
    # `debug: true` ALWAYS, not only where a refusal is expected. Thor's own
    # `start` rescues Thor::Error into `exit(1)`, and RSpec does not rescue
    # SystemExit inside an example -- so one unexpected refusal here does not
    # fail an example, it TRUNCATES the run and reports what had passed so far
    # as a clean pass. Measured while probing these examples: a mutant that
    # should have reddened one of them stopped the file at 78 of 113 examples
    # with a single failure. `debug: true` makes Thor re-raise instead.
    def run_up(argv, debug: true)
      seen = nil
      allow(Lain::CLI::Up).to receive(:from_options) do |options, chat_args:, path:|
        seen = { path:, chat_args:, session: options[:session], nvim: options[:nvim],
                 nvim_socket: options[:nvim_socket] }
        instance_double(Lain::CLI::Up, launch_plan: Lain::CLI::Up::LaunchPlan.new(messages: [], argv: %w[tmux]))
      end
      allow(Kernel).to receive(:exec)

      described_class.start(argv, debug:)
      seen
    end

    it "binds a lone positional to PATH" do
      expect(run_up(%w[up /tmp])).to include(path: "/tmp", chat_args: [])
    end

    it "leaves PATH unset when none is typed" do
      expect(run_up(%w[up])).to include(path: nil, chat_args: [])
    end

    # THE case that used to break. `--nvim` took an optional value, so Thor
    # handed it the next token: the cockpit listened on a socket called
    # "/tmp" and the session opened in the shell's directory instead. A
    # valueless boolean cannot consume anything.
    it "keeps the PATH after a bare --nvim, with the cockpit still on" do
      expect(run_up(%w[up --nvim /tmp])).to include(path: "/tmp", nvim: true, nvim_socket: nil)
    end

    it "reads --no-nvim as Thor's negation of the boolean, PATH intact" do
      expect(run_up(%w[up --no-nvim /tmp])).to include(path: "/tmp", nvim: false)
    end

    it "takes an explicit socket from --nvim-socket without touching PATH" do
      expect(run_up(%w[up --nvim-socket /x.sock /tmp]))
        .to include(path: "/tmp", nvim: true, nvim_socket: "/x.sock")
    end

    # The documented `--` form. Thor drops the separator before #up is entered
    # and leaves what followed it UNPARSED, so "--provider" arrives in PATH's
    # own slot; only the tokens argv really carried put it back.
    it "forwards every token after `--` as chat flags, with no PATH" do
      expect(run_up(["up", "--", "--provider", "ollama"]))
        .to include(path: nil, chat_args: %w[--provider ollama])
    end

    # ...and a flag `up` itself declares, written after `--`, belongs to CHAT.
    # `session` proves it: it is still up's own default, not "foo".
    it "takes a PATH before `--` and forwards even up's own flag names after it" do
      expect(run_up(["up", "/tmp", "--", "--session", "foo"]))
        .to include(path: "/tmp", chat_args: %w[--session foo], session: Lain::CLI::Up::DEFAULT_SESSION)
    end

    # The FIRST `--` is the separator and every later one is payload, because
    # `chat` may legitimately carry a `--` of its own. Both of these pass a
    # `--` through to the chat pane, and both are what tells `index` from
    # `rindex` -- with `rindex` the tail still reconciles (it is a suffix of
    # itself), so the split silently moves and `up` refuses a stray it invented.
    it "treats only the FIRST `--` as the separator, forwarding any later one as a chat argument" do
      expect(run_up(["up", "--", "--provider", "ollama", "--", "extra"]))
        .to include(path: nil, chat_args: ["--provider", "ollama", "--", "extra"])
    end

    it "forwards a chat value that is literally `--`" do
      expect(run_up(["up", "--", "--model", "--"])).to include(path: nil, chat_args: ["--model", "--"])
    end

    it "still refuses a second bare positional, naming the `--` the user meant" do
      expect { run_up(%w[up /tmp typo]) }
        .to raise_error(Thor::Error, /unexpected arguments.*typo.*pass chat flags after `--`/)
    end

    # ...and refuses it EVEN WHEN a `--` is present, which is the case that got
    # through: the old gate returned early on any separator anywhere, so "typo"
    # rode into the chat pane and died inside tmux after the session existed.
    it "refuses a stray positional that sits before a `--`, not only one without" do
      expect { run_up(["up", "/tmp", "typo", "--", "--provider", "x"]) }
        .to raise_error(Thor::Error, /unexpected arguments.*typo/)
    end

    # A VALUE-TAKING `up` flag written last before `--` skips the separator and
    # eats the first forwarded token, so Thor hands over a tail that is not the
    # tail argv wrote -- and the count still balances, which is why counting
    # alone silently forwarded the PATH to chat and opened the session in the
    # shell's directory. Both spellings of the trap, both refused by name.
    it "refuses a value-taking flag that took its value from past the `--`" do
      expect { run_up(["up", "/tmp", "--nvim-socket", "--", "--provider", "ollama"]) }
        .to raise_error(LainCLI::Argv::SwallowedFlag, /--nvim-socket=SOCKET/)
    end

    it "refuses it for a flag whose value would silently become the session name" do
      expect { run_up(["up", "/tmp", "--session", "--", "--provider", "ollama"]) }
        .to raise_error(LainCLI::Argv::SwallowedFlag, /--session=NAME/)
    end

    # The remedy the refusal teaches has to actually work, or the message sends
    # the user in a circle.
    it "accepts the `=` spelling the refusal names, keeping PATH and both forwarded tokens" do
      expect(run_up(["up", "/tmp", "--nvim-socket=/x.sock", "--", "--provider", "ollama"]))
        .to include(path: "/tmp", chat_args: %w[--provider ollama], nvim_socket: "/x.sock")
    end

    it "presents a PATH that is not a directory as a clean refusal naming it, never a backtrace" do
      Tempfile.create("lain-up-cli-not-a-directory") do |file|
        expect(Lain::CLI::Up).not_to receive(:new)

        expect { described_class.start(["up", file.path], debug: true) }
          .to raise_error(Thor::Error, /#{Regexp.escape(file.path)}/)
      end
    end
  end

  describe "lain chat --root / --cwd" do
    # These examples lodge in up_spec because T6's Files list gives it as the
    # card's one spec file, and both halves are the same translation: an argv
    # answer to "which project", instead of the shell's directory.
    #
    # `debug: true` for the reason {#run_up} records: Thor turns a refusal into
    # `exit(1)`, which RSpec does not rescue, so it would end the run rather
    # than the example.
    def run_chat(argv, debug: true)
      seen = nil
      allow(Lain::CLI::ChatLaunch).to receive(:new) do |_options, **overrides|
        seen = overrides
        instance_double(Lain::CLI::ChatLaunch, call: nil)
      end

      described_class.start(argv, debug:)
      seen
    end

    # A temp directory with its symlinks already resolved, for the reason
    # {Lain::CLI::Up "opening a PATH"}'s own helper records: the exe expands
    # lexically, and a fixture spelled with realpath would only agree with it
    # where TMPDIR happens not to be a link.
    def scratch_dir(&block) = Dir.mktmpdir { |dir| yield(File.realpath(dir)) }

    # EVERY example here CALLS the factory. The lambda is where resolution
    # actually happens, so an example that only inspects the returned Hash
    # asserts that a flag was noticed and nothing about what it does -- which
    # is exactly how `--root` alone shipped raising a bare ArgumentError.
    it "resolves the run's project from --root and --cwd instead of the shell's directory" do
      scratch_dir do |dir|
        services = File.join(dir, "services")
        FileUtils.mkdir_p(services)

        project = run_chat(["chat", "--root", dir, "--cwd", services]).fetch(:project_factory).call

        expect([project.root, project.cwd, project.detected_by]).to eq([dir, services, :flag])
      end
    end

    # `--root` ALONE is the common invocation -- "open that project" -- and the
    # shell is almost never standing inside the root it names. Left to
    # Resolver's own `cwd: Dir.pwd` it built a Project whose cwd lies outside
    # its root, which Project's guard refuses with an ArgumentError: not a
    # Lain::Error, so it reached the terminal as a fourteen-frame backtrace.
    it "defaults --cwd to the root, so naming a project alone opens it" do
      scratch_dir do |dir|
        project = run_chat(["chat", "--root", dir]).fetch(:project_factory).call

        expect([project.root, project.cwd, project.detected_by]).to eq([dir, dir, :flag])
      end
    end

    it "resolves --cwd alone by walking, leaving the root to detection" do
      scratch_dir do |dir|
        project = run_chat(["chat", "--cwd", dir]).fetch(:project_factory).call

        expect(project.cwd).to eq(dir)
      end
    end

    # The default covers the common case; this covers the rest. Any resolver
    # refusal reaching a typed flag has to arrive as a Thor::Error naming both
    # flags, because either one can be the wrong half -- and a cwd outside its
    # root raises an ArgumentError that no `rescue Lain::Error` between here
    # and Thor would have caught.
    it "presents a --cwd outside its --root as a refusal naming both flags, never a backtrace" do
      scratch_dir do |root|
        scratch_dir do |elsewhere|
          factory = run_chat(["chat", "--root", root, "--cwd", elsewhere]).fetch(:project_factory)

          expect { factory.call }
            .to raise_error(Thor::Error, /--root.*#{Regexp.escape(root)}.*--cwd.*#{Regexp.escape(elsewhere)}/m)
        end
      end
    end

    # The ordinary case must keep ChatLaunch's OWN default factory
    # (Project::Resolver.default_project), not a second construction of the
    # same resolver wearing the shell's directory as an explicit flag.
    it "overrides nothing when neither flag is given" do
      expect(run_chat(%w[chat])).to eq({})
    end

    # `--root ""` is a truthy String, so it would reach rung 1 and die inside
    # realpath("") -- which is what an unset shell variable expands to.
    it "reads an empty --root as no flag at all" do
      expect(run_chat(["chat", "--root", ""])).to eq({})
    end

    it "refuses a --root that is a regular file, naming the flag and the path" do
      Tempfile.create("lain-chat-root") do |file|
        expect { run_chat(["chat", "--root", file.path]) }
          .to raise_error(Thor::Error, /--root.*#{Regexp.escape(file.path)}/)
      end
    end

    it "refuses a --cwd that is a regular file, naming that flag rather than --root" do
      Tempfile.create("lain-chat-cwd") do |file|
        expect { run_chat(["chat", "--cwd", file.path]) }
          .to raise_error(Thor::Error, /--cwd.*#{Regexp.escape(file.path)}/)
      end
    end
  end
end
