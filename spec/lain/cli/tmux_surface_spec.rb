# frozen_string_literal: true

require "open3"

# T2: TmuxSurface -- one object opening windows, popups, and detached
# sessions. Two kinds of examples, mirroring up_spec.rb:
#
# * "against a real tmux server" shells out to an ACTUAL tmux on a scratch
#   socket (`-L tmux-surface-spec-...`), never Joel's real session. It skips
#   outright (never fails) when no tmux binary is on PATH -- the same inline
#   guard up_spec.rb uses for :nvim/:integration-style environment gaps.
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
    end

    def tmux_windows
      Open3.capture2("tmux", "-L", socket, "list-windows", "-t", "lain", "-F",
                     WINDOW_NAME_FORMAT).first.lines.map(&:strip)
    end

    it "opens a real window" do
      placement = surface.window(command: "sleep 60", name: "probe", target_session: "lain")

      expect(placement).to eq(described_class::Placement.new(kind: :window, target: "probe", degraded: false,
                                                             reason: nil))
      expect(tmux_windows).to include("probe")
    end

    it "renames a real window in place through an exact-match target (T20's done marker)" do
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
  end

  # T16 F3: /fork's child must resolve the SAME project regardless of the
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

  # T17 F1/F2: /btw's popup runs a `lain chat` REPL whose child may exit with a
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
