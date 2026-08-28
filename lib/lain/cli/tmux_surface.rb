# frozen_string_literal: true

require "mixlib/shellout"

module Lain
  module CLI
    # One object for every tmux surface a command reaches for: a `window`
    # (a new tab in an existing session), a `popup` (a transient floating
    # pane -- `display-popup`), and a detached `session` (a wholly separate
    # tmux session, e.g. forking the whole lain session rather than adding a
    # window to one). Callers (/fork, /btw, fleet windows) never
    # shell out to tmux directly; they ask this object for a Placement.
    #
    # `display-popup` does not render everywhere: under `tmux -CC` (iTerm2's
    # control mode) the popup never appears (verified live against a PTY --
    # see planning/interface-integration.md), and it does not exist at all on
    # a tmux built before 3.2. `#popup` detects BOTH before touching the
    # server and, when either holds, opens a window instead -- never a
    # half-open dialog the human can't see. The returned Placement always
    # names whether (and why) that happened, so a caller can say so.
    #
    # Detection is capability-based, not version-string parsing (a "next-3.8"
    # dev build, or a distro's patched tag, would defeat a `tmux -V` regex):
    # `list-commands` for `display-popup` support, `list-clients` for any
    # attached client's `#{client_control_mode}` -- both are one read-only
    # shell-out apiece, never a side effect. Ambiguous cases (no attached
    # client at all, e.g. this object driven from a script rather than an
    # interactive pane) resolve to "not control mode": there is no client to
    # have degraded FOR, so the ordinary popup path is the honest default.
    #
    # Opening is only half of what a caller needs to know. tmux answers the
    # client the moment its SERVER accepts a request, so #window's success
    # says nothing about whether the pane it made ever ran the command.
    # `keep_failed:` and {#window_state} are the pair that closes that gap:
    # the first leaves a corpse where there would otherwise be nothing, the
    # second reads it.
    #
    # Every tmux invocation goes through Mixlib::ShellOut with an ARGV array
    # -- the same discipline as {Up} -- so `command:` (a single opaque shell
    # string tmux hands to ITS OWN `$SHELL -c` inside the new pane, exactly
    # {Up}'s `chat_command`) never needs quoting against a shell on our side.
    class TmuxSurface
      # Reused verbatim, not redefined: one exception name for "no tmux" no
      # matter which CLI object hit it, so rescuing {Up::TmuxUnavailable} or
      # {TmuxSurface::TmuxUnavailable} means the same thing -- they ARE the
      # same class.
      TmuxUnavailable = Up::TmuxUnavailable

      # The surface actually opened, and the name the caller asked for.
      # `degraded` says the caller did not get everything it asked for, and
      # `reason` says which check forced it: "control_mode" / "old_tmux" when
      # #popup fell back to a window, "no_pane_hold" when a window opened but
      # the server refused to hold a failed pane.
      Placement = Data.define(:kind, :target, :degraded, :reason)

      # What the server says about a window somebody opened earlier. Both
      # halves are part of the answer even where a caller reads only one:
      # {FleetWindows} keys on `status` because a corpse's exit code is the
      # only unambiguous evidence of a death, while `survived` is what a
      # caller asking the plainer question -- is this window still working --
      # would read, and neither is derivable from the other.
      # `survived` is false both for a pane `keep_failed:` held after a
      # non-zero exit -- `status` is then what it died with -- and for a
      # window tmux can no longer find at all, where there is nothing left to
      # ask and `status` is nil.
      WindowState = Data.define(:target, :survived, :status) do
        def initialize(target:, survived:, status:) = super(target: -target, survived:, status:)
      end

      # tmux's OWN `#{...}` format-string syntax (`man tmux` FORMATS), not
      # Ruby interpolation -- the identical trap {Up::Hud::JQ_FILTER}'s comment
      # documents for jq's `\(...)`. Named constants (rather than inline
      # literals) so the `rubocop:disable` covers exactly these two strings,
      # nowhere else.
      COMMAND_LIST_NAME_FORMAT = '#{command_list_name}' # rubocop:disable Lint/InterpolationCheck
      CLIENT_CONTROL_MODE_FORMAT = '#{client_control_mode}' # rubocop:disable Lint/InterpolationCheck
      PANE_DEATH_FORMAT = '#{pane_dead}:#{pane_dead_status}' # rubocop:disable Lint/InterpolationCheck

      def initialize(socket: nil, shell_out_factory: Mixlib::ShellOut.public_method(:new))
        @socket = socket
        @shell_out_factory = shell_out_factory
      end

      # tmux's `=` target syntax pins an exact window-name match; prefix
      # matching would let "researcher-5aaa" name "researcher-5aaa1111"
      # instead. One spelling for every caller that has to name a window
      # again after opening it -- a rename, a liveness check, and this
      # class's own pane-holding tail.
      #
      # @param name [String] the window name to match exactly
      # @param session [String, nil] session to scope the match to
      # @return [String] a tmux target-window
      def self.exact_window(name, session: nil) = [session, "=#{name}"].compact.join(":")

      # @param command [String] shell command tmux runs in the new window
      # @param name [String, nil] window name (`-n`)
      # @param target_session [String, nil] session to add the window to;
      #   nil lets tmux pick (the current session, from inside a pane)
      # @param cwd [String, nil] the new pane's start directory (`-c`) --
      #   /fork pins the parent's project root here so the child resolves
      #   the SAME project regardless of the session's pane-cwd conventions;
      #   nil leaves tmux's own default-path rules in charge
      # @param keep_failed [Boolean] hold the pane when its command exits
      #   non-zero, so a window that could not start leaves something for
      #   {#window_state} to read instead of blinking out. Needs a `name` --
      #   the request that does it names the window back -- and is ignored
      #   without one.
      # @return [Placement]
      def window(command:, name: nil, target_session: nil, cwd: nil, keep_failed: false)
        hold = keep_failed && name ? self.class.exact_window(name, session: target_session) : nil
        args = new_window_argv(command:, name:, target_session:, cwd:, printing: !hold.nil?)
        reason = hold.nil? ? open_plain(args) : open_holding(args, hold)
        Placement.new(kind: :window, target: name, degraded: !reason.nil?, reason:)
      end

      # Whether the command a window was opened for is still there. {#window}
      # cannot answer this: `new-window` exits 0 the moment the SERVER accepts
      # the request, so a command that never ran looks exactly like one that
      # did.
      #
      # `list-panes`, NOT `display-message -p`: verified against tmux 3.7, an
      # unfindable target makes display-message answer for the CURRENT pane
      # and still exit 0, so a window that is gone would report a healthy
      # one's state. list-panes refuses the target instead, and that refusal
      # is itself the answer -- a window nobody can find did not survive, and
      # there is no status left to report for it.
      #
      # The first line only. A window the human splits by hand grows panes
      # after the fact; the pane tmux made for the command is the first.
      #
      # Fails CLOSED, twice over. `survived` is true only for a pane that
      # positively read alive, so an answer this cannot parse is never
      # mistaken for a healthy window; and `exitstatus` is asked with `&.`
      # because Mixlib::ShellOut answers nil for a client killed by a signal,
      # where `.zero?` would raise out of whatever queued work is asking.
      #
      # @param target [String] a tmux target-window
      # @return [WindowState]
      def window_state(target:)
        reply = run("list-panes", "-t", target, "-F", PANE_DEATH_FORMAT)
        return WindowState.new(target:, survived: false, status: nil) unless reply.exitstatus&.zero?

        dead, status = reply.stdout.lines.first.to_s.strip.split(":", 2)
        WindowState.new(target:, survived: dead == "0", status: Integer(status.to_s, exception: false))
      end

      # `-EE`, not `-E`: the popup runs a `lain chat` REPL that can exit
      # non-zero (a crash), and `-EE` keeps the popup up on a non-zero exit
      # until a key -- so the human READS the failure instead of watching it
      # vanish. A clean exit (the reap path) still closes on its own.
      #
      # @param command [String] shell command tmux runs in the popup
      # @param title [String, nil] popup title (`-T`); doubles as the window
      #   name if this degrades
      # @param width [String, Integer, nil] `-w` value (tmux accepts `50%`
      #   forms too, hence String)
      # @param height [String, Integer, nil] `-h` value
      # @param target_session [String, nil] see {#window}
      # @param cwd [String, nil] the popup's start directory (`-d`), forwarded
      #   to the degrade window's `-c` too -- /btw pins the parent's project
      #   root so the child resolves the SAME project, exactly as {#window}
      #   does for /fork; nil leaves tmux's own default-path rules in charge
      # @return [Placement]
      def popup(command:, title: nil, width: nil, height: nil, target_session: nil, cwd: nil)
        reason = degrade_reason
        return window(command:, name: title, target_session:, cwd:).with(degraded: true, reason:) if reason

        args = ["display-popup", "-EE"]
        args += ["-d", cwd] if cwd
        args += ["-T", title] if title
        args += ["-w", width.to_s] if width
        args += ["-h", height.to_s] if height
        args << command
        act(*args)
        Placement.new(kind: :popup, target: title, degraded: false, reason: nil)
      end

      # Retitle an existing window -- the done marker on a fleet window. Not a
      # Placement: nothing opens. Same {#act} discipline, so a target that no
      # longer exists (the human already closed the window) raises
      # {TmuxUnavailable} and the CALLER decides whether that is fatal --
      # {FleetWindows} treats it as already-done.
      #
      # @param target [String] a tmux target-window; "=name" pins an exact
      #   window-name match (tmux's own `=` syntax, else it prefix-matches)
      # @param name [String] the window's new name
      # @return [self]
      def rename_window(target:, name:)
        act("rename-window", "-t", target, name)
        self
      end

      # @param name [String] the new session's name
      # @param command [String, nil] shell command for its initial window
      # @return [Placement]
      def session(name:, command: nil)
        args = ["new-session", "-d", "-s", name]
        args << command if command
        act(*args)
        Placement.new(kind: :session, target: name, degraded: false, reason: nil)
      end

      private

      def new_window_argv(command:, name:, target_session:, cwd:, printing:)
        args = ["new-window"]
        args << "-P" if printing
        args += ["-t", target_session] if target_session
        args += ["-c", cwd] if cwd
        args += ["-n", name] if name
        args << command
      end

      # ONE invocation, not two. tmux answers `new-window` as soon as its
      # SERVER accepts the request and then destroys a dead pane before a
      # second client can even connect, so a `set-window-option` SENT AFTER
      # loses the race about one time in ten (measured here against tmux 3.7
      # through Mixlib::ShellOut). Chained into the same command list it
      # cannot: tmux runs a list to completion before it processes the pane's
      # death.
      #
      # `failed` and not `on`, exactly as {Up}'s chat pane: a command that
      # exits cleanly still closes its own window, so this only holds the
      # screen when there is something to read.
      #
      # `-P` is what makes a PARTIAL failure readable. tmux prints the new
      # window's target only when `new-window` itself ran, so an empty stdout
      # beside a non-zero exit means the open failed and must be loud, while a
      # printed target means only the tail was refused -- a tmux older than
      # the `failed` value, which is a diagnostic worth losing rather than a
      # reason to refuse the window. The Placement says so ("no_pane_hold"),
      # because a caller running a death detector off a pane-hold it did not
      # get is running it blind and had better know.
      # @return [String, nil] the reason the window is degraded, or nil
      def open_holding(args, target)
        reply = run(*args, ";", "set-window-option", "-t", target, "remain-on-exit", "failed")
        raise TmuxUnavailable, "tmux new-window failed: #{reply.stderr.strip}" if refused_open?(reply)

        reply.exitstatus&.zero? ? nil : "no_pane_hold"
      end

      # An ordinary window has no half that can fail on its own: #act is loud,
      # or the window opened with everything asked for.
      def open_plain(args)
        act(*args)
        nil
      end

      def refused_open?(reply) = !reply.exitstatus&.zero? && reply.stdout.strip.empty?

      # nil (no degrade), or the reason #popup falls back to a window.
      # Unsupported tmux is checked first: an old server has no
      # `client_control_mode` format variable either, so probing control
      # mode first on such a build risks a confusing empty/garbage read
      # instead of the more honest "this tmux is too old" answer.
      def degrade_reason
        return "old_tmux" unless popup_supported?
        return "control_mode" if control_mode?

        nil
      end

      def popup_supported? = run("list-commands", "-F", COMMAND_LIST_NAME_FORMAT).stdout.include?("display-popup")

      # True when ANY attached client reports control mode. This object has
      # no notion of "the" client that will end up looking at a given popup
      # -- scoping to one would need a target-client this API never asks
      # for -- so it is conservative: one -CC client anywhere on the session
      # is enough to avoid a popup no one there could see.
      def control_mode?
        run("list-clients", "-F", CLIENT_CONTROL_MODE_FORMAT).stdout.each_line.any? { |line| line.strip == "1" }
      end

      # Every mutating tmux call goes through here so a real failure (a
      # broken tmux that cannot spawn a server at all) fails loudly instead
      # of silently doing nothing.
      def act(*args)
        shell_out = run(*args)
        raise TmuxUnavailable, "tmux #{args.first} failed: #{shell_out.stderr.strip}" unless shell_out.exitstatus.zero?

        shell_out
      end

      def run(*)
        @shell_out_factory.call("tmux", *socket_flag, *).tap(&:run_command)
      rescue Errno::ENOENT
        raise TmuxUnavailable, "tmux not found on PATH -- install it (or fix PATH) before using TmuxSurface"
      end

      def socket_flag = @socket ? ["-L", @socket] : []
    end
  end
end
