# frozen_string_literal: true

require "tmpdir"
require "json"
require "open3"
require "shellwords"

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
# object is already "done" the instant it's built) and #exitstatus/#stderr.
# Defined at the top level (not inside RSpec.describe) so it is a plain
# constant, not one assigned inside a block.
FakeShellOut = Struct.new(:exitstatus, :stderr) do
  def run_command = self
end

RSpec.describe Lain::CLI::Up do
  def tmux_present? = system("tmux", "-V", out: File::NULL, err: File::NULL)

  # Strips tmux's `#(job)` status-right wrapper and runs the job directly
  # through a real shell -- proves what the HUD would render WITHOUT relying
  # on tmux's own async status-bar refresh timing (a real render was verified
  # once, by hand, against a PTY-attached tmux 3.8; asserting on that timing
  # in the suite would be flaky where this is not).
  def eval_status_job(raw_value)
    job = raw_value.strip.sub(/\A#\(/, "").sub(/\)\z/, "")
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
    let(:up) { described_class.new(session:, socket:, state_path:) }

    after { system("tmux", "-L", socket, "kill-server", out: File::NULL, err: File::NULL) }

    def write_state(cache_deadline:, fleet:, inbox_count:)
      File.write(state_path, JSON.generate({ "cache_deadline" => cache_deadline, "fleet" => fleet,
                                             "inbox_count" => inbox_count }))
    end

    def tmux(*args) = Open3.capture2("tmux", "-L", socket, *args).first.strip

    def session_count
      Open3.capture2("tmux", "-L", socket, "list-sessions").first.lines.size
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

    it "threads -- chat args into the spawned window's command, each argument shell-escaped" do
      write_state(cache_deadline: nil, fleet: [], inbox_count: 0)
      chat_args = ["--model", "claude-fable-5", "--no-journal"]

      described_class.new(session:, socket:, state_path:, chat_args:).call

      # `#{pane_start_command}` is tmux's OWN format-string syntax, not Ruby
      # interpolation -- single-quoted so it reaches tmux byte-for-byte.
      # rubocop:disable Lint/InterpolationCheck
      pane_command = tmux("list-panes", "-t", "#{session}:chat", "-F", '#{pane_start_command}')
      # rubocop:enable Lint/InterpolationCheck
      expect(pane_command).to include("chat --model claude-fable-5 --no-journal")
    end

    it "attaches instead of duplicating on a second call" do
      write_state(cache_deadline: nil, fleet: [], inbox_count: 0)

      first = up.call
      second = described_class.new(session:, socket:, state_path:).call

      expect(first.created).to be true
      expect(second.created).to be false
      expect(session_count).to eq(1)
    end

    it "leaves the global theme untouched -- only the lain session/window carry the options" do
      write_state(cache_deadline: nil, fleet: [], inbox_count: 0)
      # A control session started on the SAME server, never touched by Up, is
      # the honest baseline: if global options had changed, this sibling
      # would inherit the change too.
      system("tmux", "-L", socket, "new-session", "-d", "-s", "control", "-x", "80", "-y", "24")
      before_status_right = tmux("show-options", "-g", "status-right")
      before_bell = tmux("show-window-options", "-g", "monitor-bell")

      up.call

      expect(tmux("show-options", "-g", "status-right")).to eq(before_status_right)
      expect(tmux("show-window-options", "-g", "monitor-bell")).to eq(before_bell)
      expect(tmux("show-options", "-v", "-t", "control", "status-right")).to eq("")
      expect(tmux("show-window-options", "-t", "control:1", "monitor-bell")).to eq("")
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

  # T11: `lain up -- ARGS` threads the trailing chat flags into the spawned
  # window's command. `chat` validates its own flags -- Up never parses
  # `chat_args`, only Shellwords-escapes each element, so these examples
  # assert on the composed STRING, never on flag semantics.
  describe "-- chat args pass-through" do
    let(:state_path) { "/tmp/irrelevant-for-these-examples/state.json" }

    def capture_new_session_command(chat_args:)
      calls = []
      spy = lambda do |*args|
        calls << args
        FakeShellOut.new(args[1] == "has-session" ? 1 : 0, "")
      end

      described_class.new(session: "lain", state_path:, chat_args:, shell_out_factory: spy).call

      calls.find { |args| args.include?("new-session") }.last
    end

    it "shell-escapes every chat arg onto the default chat command" do
      command = capture_new_session_command(chat_args: ["--model", "claude-fable-5", "--no-journal"])

      expect(command).to eq(
        "export PATH=\"$HOME/.rubies/ruby-4.0.5/bin:$PATH\"; exec #{$PROGRAM_NAME} chat " \
        "--model claude-fable-5 --no-journal"
      )
    end

    it "leaves the chat command untouched when no chat args are given" do
      command = capture_new_session_command(chat_args: [])

      expect(command).to eq("export PATH=\"$HOME/.rubies/ruby-4.0.5/bin:$PATH\"; exec #{$PROGRAM_NAME} chat")
    end

    it "keeps a hostile chat arg inert -- it reaches chat as one literal argument, never shell syntax" do
      Dir.mktmpdir do |marker|
        hostile = "; touch #{marker}/pwned $(touch #{marker}/pwned2)"

        command = capture_new_session_command(chat_args: [hostile])
        Open3.capture3("sh", "-c", command)

        expect(Dir.children(marker)).to be_empty
      end
    end

    it "shell-escapes a hostile arg as a single Shellwords-escaped token" do
      hostile = "; rm -rf /"

      command = capture_new_session_command(chat_args: [hostile])

      expect(command).to end_with(Shellwords.escape(hostile))
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
