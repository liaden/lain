# frozen_string_literal: true

require "fileutils"
require "open3"

# TmuxSurface -- one object opening windows, popups, and detached
# sessions. Two kinds of examples, mirroring up_spec.rb:
#
# * "against a real tmux server" shells out to an ACTUAL tmux on a scratch
#   socket (`-L tmux-surface-spec-...`), never Joel's real session. It skips
#   outright (never fails) when no tmux binary is on PATH -- the same inline
#   guard up_spec.rb uses for :nvim/:api_integration-style environment gaps.
# * "degrading loudly" / detection-branch examples inject a FAKE
#   shell_out_factory, so the control-mode / old-tmux / no-tmux scenarios run
#   on every machine regardless of what tmux (if any) is actually installed.
#
# A Mixlib::ShellOut double satisfying the one duck TmuxSurface exercises:
# #run_command (a no-op), #exitstatus/#stderr/#stdout. Named distinctly from
# up_spec.rb's FakeShellOut (which has no #stdout) so the two top-level
# constants never collide when the suite loads both files.
FakeTmuxShellOut = Struct.new(:exitstatus, :stdout, :stderr) do
  def run_command = self
end

# tmux's OWN `#{...}` format-string syntax, not Ruby interpolation -- see
# TmuxSurface::COMMAND_LIST_NAME_FORMAT's comment for the identical trap.
WINDOW_NAME_FORMAT = '#{window_name}' # rubocop:disable Lint/InterpolationCheck
SESSION_NAME_FORMAT = '#{session_name}' # rubocop:disable Lint/InterpolationCheck

RSpec.describe Lain::CLI::TmuxSurface do
  def tmux_present? = system("tmux", "-V", out: File::NULL, err: File::NULL)

  describe "against a real tmux server" do
    before { skip("tmux not found on PATH") unless tmux_present? }

    let(:socket) { "tmux-surface-spec-#{Process.pid}-#{object_id}" }
    let(:surface) { described_class.new(socket:) }

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
                                        "tmux-surface-spec-#{Process.pid}-*")))
    end

    def tmux_windows
      Open3.capture2("tmux", "-L", socket, "list-windows", "-t", "lain", "-F",
                     WINDOW_NAME_FORMAT).first.lines.map(&:strip)
    end

    # The server reaps a pane asynchronously to the client that opened the
    # window, so what a pane exited with is something to wait for rather than
    # to read the instant #window returns -- measured here at roughly one
    # premature read in ten. That asymmetry is why the pair of methods below
    # exists at all, and why {FleetWindows} holds its check for a whole turn
    # instead of issuing it behind the open.
    def settle = sleep(0.25)

    it "opens a real window" do
      placement = surface.window(command: "sleep 60", name: "probe", target_session: "lain")

      expect(placement).to eq(described_class::Placement.new(kind: :window, target: "probe", degraded: false,
                                                             reason: nil))
      expect(tmux_windows).to include("probe")
    end

    it "renames a real window in place through an exact-match target" do
      surface.window(command: "sleep 60", name: "probe", target_session: "lain")

      surface.rename_window(target: "lain:=probe", name: "probe [done]")

      expect(tmux_windows).to include("probe [done]")
      expect(tmux_windows).not_to include("probe")
    end

    it "raises TmuxUnavailable from #rename_window when the target window no longer exists" do
      expect { surface.rename_window(target: "lain:=never-opened", name: "gone [done]") }
        .to raise_error(described_class::TmuxUnavailable, /rename-window failed/)
    end

    it "opens a real detached session" do
      placement = surface.session(name: "forked", command: "sleep 60")

      expect(placement).to eq(described_class::Placement.new(kind: :session, target: "forked", degraded: false,
                                                             reason: nil))
      sessions = Open3.capture2("tmux", "-L", socket, "list-sessions", "-F",
                                SESSION_NAME_FORMAT).first.lines.map(&:strip)
      expect(sessions).to include("forked")
    end

    it "does NOT degrade a popup on this real (modern, no client attached) tmux -- it genuinely " \
       "attempts display-popup and hits tmux's own client-less refusal, proving the non-degraded " \
       "path really talks to display-popup rather than silently falling back to a window" do
      # No client is ever attached in this spec (no PTY here) -- ambiguous
      # "no client at all" resolves to "not control mode" (the class
      # comment's documented default), and this tmux build ships
      # display-popup, so #popup must NOT degrade. Without an attached
      # client, real tmux then refuses the popup itself ("no current
      # client") -- a DIFFERENT failure than a degrade would produce (a
      # degrade never touches display-popup at all, so it could not surface
      # this message).
      expect { surface.popup(command: "sleep 60", title: "probe", target_session: "lain") }
        .to raise_error(described_class::TmuxUnavailable, /no current client/)
    end

    it "raises TmuxUnavailable with a remedy, and executes nothing, when tmux itself cannot spawn a server" do
      broken_socket_surface = described_class.new(
        shell_out_factory: lambda do |*args|
          FakeTmuxShellOut.new(args.include?("new-window") ? 1 : 0, "", "error connecting to socket")
        end
      )

      expect { broken_socket_surface.window(command: "echo hi") }
        .to raise_error(described_class::TmuxUnavailable, /error connecting to socket/)
    end

    # `new-window` exits 0 the moment the SERVER accepts the request, so a
    # command that cannot start leaves a window the client was told nothing
    # about. tmux destroys that pane within milliseconds; `keep_failed:` is
    # the only thing that leaves a corpse to read a status off, and it works
    # only because it rides the SAME invocation -- sending the option after
    # the open lost this race 2 times in 20 when measured here.
    it "holds the corpse of a window whose command exited non-zero, and names the status it died with" do
      surface.window(command: "exit 42", name: "corpse", target_session: "lain", keep_failed: true)
      settle

      state = surface.window_state(target: "lain:=corpse")
      expect(state.survived).to be(false)
      expect(state.status).to eq(42)
    end

    it "wins that race every time over a burst, so a status is never a coin flip" do
      20.times { |i| surface.window(command: "exit 42", name: "burst#{i}", target_session: "lain", keep_failed: true) }
      settle

      statuses = Array.new(20) { |i| surface.window_state(target: "lain:=burst#{i}").status }
      expect(statuses).to all(eq(42))
    end

    it "reports a window whose command keeps running as survived, carrying no status" do
      surface.window(command: "sleep 60", name: "alive", target_session: "lain", keep_failed: true)

      expect(surface.window_state(target: "lain:=alive"))
        .to eq(described_class::WindowState.new(target: "lain:=alive", survived: true, status: nil))
    end

    it "reports a window that is not there as not survived, rather than answering for some other pane" do
      # Verified against this tmux: `display-message -p` resolves an
      # unfindable target to the CURRENT pane and still exits 0, so it would
      # have reported the session's healthy first window as this one's state.
      # `list-panes` refuses the target instead, which is why the query is
      # built on it.
      state = surface.window_state(target: "lain:=never-opened")

      expect(state.survived).to be(false)
      expect(state.status).to be_nil
    end

    it "keeps a cleanly exiting window's pane out of the way -- `failed`, not `on`" do
      surface.window(command: "true", name: "clean", target_session: "lain", keep_failed: true)
      settle

      expect(tmux_windows).not_to include("clean")
    end
  end

  describe "keep_failed: and #window_state (FakeTmuxShellOut)" do
    def factory_for(calls, reply)
      lambda do |*args|
        calls << args
        args.include?("list-panes") ? reply : FakeTmuxShellOut.new(0, "%1\n", "")
      end
    end

    it "chains the pane-holding request into the SAME invocation as the open" do
      calls = []
      surface = described_class.new(shell_out_factory: factory_for(calls, FakeTmuxShellOut.new(0, "", "")))

      surface.window(command: "lain watch abc", name: "researcher-5aaa1111", target_session: "lain",
                     keep_failed: true)

      expect(calls).to eq([["tmux", "new-window", "-P", "-t", "lain", "-n", "researcher-5aaa1111",
                            "lain watch abc", ";", "set-window-option", "-t", "lain:=researcher-5aaa1111",
                            "remain-on-exit", "failed"]])
    end

    it "leaves an ordinary window's request untouched -- no -P, no tail" do
      calls = []
      surface = described_class.new(shell_out_factory: factory_for(calls, FakeTmuxShellOut.new(0, "", "")))

      surface.window(command: "lain chat --fork", name: "fork-abc", target_session: "lain")

      expect(calls).to eq([["tmux", "new-window", "-t", "lain", "-n", "fork-abc", "lain chat --fork"]])
    end

    it "ignores keep_failed: without a name -- the request that holds the pane names the window back" do
      calls = []
      surface = described_class.new(shell_out_factory: factory_for(calls, FakeTmuxShellOut.new(0, "", "")))

      surface.window(command: "echo hi", keep_failed: true)

      expect(calls).to eq([["tmux", "new-window", "echo hi"]])
    end

    it "is best-effort about the tail: a tmux too old for the `failed` value still opens the window" do
      # tmux prints the new window's target from `-P` before it reaches the
      # refused option, so the open is provably the half that succeeded.
      old_tmux = ->(*_args) { FakeTmuxShellOut.new(1, "lain:2.0\n", "unknown value: failed") }
      surface = described_class.new(shell_out_factory: old_tmux)

      expect { surface.window(command: "echo hi", name: "probe", keep_failed: true) }.not_to raise_error
    end

    # A caller that asked for the pane-hold and did not get it now runs a
    # detector with its instrument switched off: every death will read as a
    # status-less "gone". The Placement is where it finds that out.
    it "says the window is degraded, and why, when the pane-hold was refused" do
      old_tmux = ->(*_args) { FakeTmuxShellOut.new(1, "lain:2.0\n", "unknown value: failed") }
      surface = described_class.new(shell_out_factory: old_tmux)

      expect(surface.window(command: "echo hi", name: "probe", keep_failed: true))
        .to eq(described_class::Placement.new(kind: :window, target: "probe", degraded: true,
                                              reason: "no_pane_hold"))
    end

    it "reports an undegraded window when the pane-hold landed" do
      surface = described_class.new(shell_out_factory: factory_for([], FakeTmuxShellOut.new(0, "", "")))

      expect(surface.window(command: "echo hi", name: "probe", keep_failed: true).degraded).to be(false)
    end

    # Mixlib::ShellOut#exitstatus is `@status&.exitstatus`, so a tmux client
    # killed by a signal answers nil rather than a number. Asking `.zero?` of
    # that raises NoMethodError out of a queued pump command.
    it "survives a signalled tmux client rather than raising NoMethodError on a nil exit status" do
      signalled = ->(*_args) { FakeTmuxShellOut.new(nil, "", "") }
      surface = described_class.new(shell_out_factory: signalled)

      expect(surface.window_state(target: "lain:=probe").survived).to be(false)
      expect { surface.window(command: "echo hi", name: "probe", keep_failed: true) }
        .to raise_error(described_class::TmuxUnavailable)
    end

    it "fails CLOSED on an answer it cannot read -- an unreadable pane is not a healthy one" do
      surface = described_class.new(shell_out_factory: factory_for([], FakeTmuxShellOut.new(0, "\n", "")))

      expect(surface.window_state(target: "lain:=probe"))
        .to eq(described_class::WindowState.new(target: "lain:=probe", survived: false, status: nil))
    end

    it "is still loud when the OPEN itself failed -- nothing printed, so nothing opened" do
      broken = ->(*_args) { FakeTmuxShellOut.new(1, "", "error connecting to socket") }
      surface = described_class.new(shell_out_factory: broken)

      expect { surface.window(command: "echo hi", name: "probe", keep_failed: true) }
        .to raise_error(described_class::TmuxUnavailable, /error connecting to socket/)
    end

    it "reads the pane's death flag and status off list-panes" do
      surface = described_class.new(shell_out_factory: factory_for([], FakeTmuxShellOut.new(0, "1:127\n", "")))

      expect(surface.window_state(target: "lain:=probe"))
        .to eq(described_class::WindowState.new(target: "lain:=probe", survived: false, status: 127))
    end

    it "reads a live pane as survived" do
      surface = described_class.new(shell_out_factory: factory_for([], FakeTmuxShellOut.new(0, "0:\n", "")))

      expect(surface.window_state(target: "lain:=probe").survived).to be(true)
    end

    it "reads a refused target as a window that did not survive, with no status to report" do
      gone = ->(*_args) { FakeTmuxShellOut.new(1, "", "can't find window: probe") }
      surface = described_class.new(shell_out_factory: gone)

      state = surface.window_state(target: "lain:=probe")
      expect(state.survived).to be(false)
      expect(state.status).to be_nil
    end

    it "reads only the first pane's line -- a window split by hand still answers for the command's pane" do
      surface = described_class.new(shell_out_factory: factory_for([], FakeTmuxShellOut.new(0, "1:127\n0:\n", "")))

      expect(surface.window_state(target: "lain:=probe").status).to eq(127)
    end
  end

  # /fork's child must resolve the SAME project regardless of the
  # session's pane-cwd conventions, so #window can pin the new pane's start
  # directory with tmux's own `-c`.
  describe "#window cwd: (FakeTmuxShellOut)" do
    def capturing_factory(calls)
      lambda do |*args|
        calls << args
        FakeTmuxShellOut.new(0, "", "")
      end
    end

    it "passes cwd through as new-window's -c flag" do
      calls = []
      surface = described_class.new(shell_out_factory: capturing_factory(calls))

      surface.window(command: "sleep 60", name: "fork-abc", cwd: "/some/project")

      new_window = calls.find { |args| args.include?("new-window") }
      expect(new_window.each_cons(2)).to include(["-c", "/some/project"])
    end

    it "omits -c entirely when no cwd is given -- tmux's own default-path rules stay in charge" do
      calls = []
      surface = described_class.new(shell_out_factory: capturing_factory(calls))

      surface.window(command: "sleep 60", name: "probe")

      expect(calls.find { |args| args.include?("new-window") }).not_to include("-c")
    end
  end

  # /btw's popup runs a `lain chat` REPL whose child may exit with a
  # non-zero status (a crash the human must SEE, not a popup that vanished), and
  # it must resolve the same project the parent is in -- so #popup pins the start
  # dir with `-d` and stays up on failure with `-EE`.
  describe "#popup cwd: and -EE (FakeTmuxShellOut)" do
    # Captures every argv while still answering the two detection probes, so the
    # NON-degraded display-popup path actually runs (an empty list-commands reply
    # would degrade to a window before display-popup is ever reached).
    def capturing_popup_factory(calls)
      lambda do |*args|
        calls << args
        FakeTmuxShellOut.new(0, popup_probe_stdout(args), "")
      end
    end

    def popup_probe_stdout(args)
      return "display-popup\nnew-window\n" if args.include?("list-commands")
      return "0\n0\n" if args.include?("list-clients")

      ""
    end

    it "runs display-popup with -EE, so the popup outlives a non-zero child exit until a key" do
      calls = []
      surface = described_class.new(shell_out_factory: capturing_popup_factory(calls))

      surface.popup(command: "lain chat --btw", title: "btw")

      popup = calls.find { |args| args.include?("display-popup") }
      expect(popup).to include("-EE")
      expect(popup).not_to include("-E")
    end

    it "pins the popup's start directory with tmux's own -d" do
      calls = []
      surface = described_class.new(shell_out_factory: capturing_popup_factory(calls))

      surface.popup(command: "lain chat --btw", title: "btw", cwd: "/some/project")

      popup = calls.find { |args| args.include?("display-popup") }
      expect(popup.each_cons(2)).to include(["-d", "/some/project"])
    end

    it "forwards cwd to the degrade window path as -c when the popup cannot render" do
      calls = []
      degrading = lambda do |*args|
        calls << args
        FakeTmuxShellOut.new(0, args.include?("list-clients") ? "0\n" : "", "")
      end
      surface = described_class.new(shell_out_factory: degrading)

      surface.popup(command: "lain chat --btw", title: "btw", cwd: "/some/project")

      new_window = calls.find { |args| args.include?("new-window") }
      expect(new_window.each_cons(2)).to include(["-c", "/some/project"])
    end
  end

  describe "popup degrade detection (FakeTmuxShellOut)" do
    # Everything TmuxSurface might shell out to for one #popup call, keyed
    # on the ONE command name each branch cares about -- list-commands
    # (popup support), list-clients (control mode), and anything else
    # (display-popup itself, or #popup's degrade path calling #window)
    # which always just succeeds.
    def factory_for(control_mode:, popup_supported:)
      responses = {
        "list-commands" => FakeTmuxShellOut.new(0, popup_supported ? "display-popup\nnew-window\n" : "new-window\n",
                                                ""),
        "list-clients" => FakeTmuxShellOut.new(0, control_mode ? "1\n0\n" : "0\n0\n", "")
      }
      ->(*args) { responses.find { |command, _| args.include?(command) }&.last || FakeTmuxShellOut.new(0, "", "") }
    end

    it "degrades to a window and names control_mode when an attached client reports control mode" do
      surface = described_class.new(shell_out_factory: factory_for(control_mode: true, popup_supported: true))

      placement = surface.popup(command: "lain chat --btw", title: "btw")

      expect(placement.kind).to eq(:window)
      expect(placement.degraded).to be true
      expect(placement.reason).to eq("control_mode")
      expect(placement.target).to eq("btw")
    end

    it "degrades to a window and names old_tmux when the server predates display-popup" do
      surface = described_class.new(shell_out_factory: factory_for(control_mode: false, popup_supported: false))

      placement = surface.popup(command: "lain chat --btw", title: "btw")

      expect(placement.kind).to eq(:window)
      expect(placement.degraded).to be true
      expect(placement.reason).to eq("old_tmux")
    end

    it "does not degrade when popup is supported and no client is in control mode" do
      surface = described_class.new(shell_out_factory: factory_for(control_mode: false, popup_supported: true))

      placement = surface.popup(command: "lain chat --btw", title: "btw")

      expect(placement.kind).to eq(:popup)
      expect(placement.degraded).to be false
      expect(placement.reason).to be_nil
    end
  end

  describe "no tmux, loud degrade" do
    def no_tmux_factory = ->(*_args) { raise Errno::ENOENT, "no such file or directory - tmux" }

    it "raises TmuxUnavailable with the remedy, and executes nothing, for #window" do
      surface = described_class.new(shell_out_factory: no_tmux_factory)

      expect { surface.window(command: "echo hi") }
        .to raise_error(described_class::TmuxUnavailable, /tmux not found on PATH/)
    end

    it "raises TmuxUnavailable with the remedy, and executes nothing, for #popup " \
       "(detection itself is the first shell-out, so nothing downstream ever runs)" do
      surface = described_class.new(shell_out_factory: no_tmux_factory)

      expect { surface.popup(command: "echo hi") }
        .to raise_error(described_class::TmuxUnavailable, /tmux not found on PATH/)
    end

    it "raises TmuxUnavailable with the remedy, and executes nothing, for #session" do
      surface = described_class.new(shell_out_factory: no_tmux_factory)

      expect { surface.session(name: "forked") }
        .to raise_error(described_class::TmuxUnavailable, /tmux not found on PATH/)
    end

    it "is the same exception Up raises, so one rescue clause covers both" do
      expect(described_class::TmuxUnavailable).to equal(Lain::CLI::Up::TmuxUnavailable)
    end
  end
end
