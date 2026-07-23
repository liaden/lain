# frozen_string_literal: true

require "mixlib/shellout"

module Lain
  module CLI
    # One object for every tmux surface a command reaches for: a `window`
    # (a new tab in an existing session), a `popup` (a transient floating
    # pane -- `display-popup`), and a detached `session` (a wholly separate
    # tmux session, e.g. forking the whole lain session rather than adding a
    # window to one). Callers (T16 /fork, T17 /btw, T20 fleet windows) never
    # shell out to tmux directly; they ask this object for a Placement.
    #
    # `display-popup` does not render everywhere: under `tmux -CC` (iTerm2's
    # control mode) the popup never appears (verified live against a PTY --
    # see planning/interface-integration.md:141-161), and it does not exist
    # at all on a tmux built before 3.2. `#popup` detects BOTH before
    # touching the server and, when either holds, opens a window instead --
    # never a half-open dialog the human can't see. The returned Placement
    # always names whether (and why) that happened, so a caller can say so.
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
    # Every tmux invocation goes through Mixlib::ShellOut with an ARGV array
    # -- the same discipline as {Up} -- so `command:` (a single opaque shell
    # string tmux hands to ITS OWN `$SHELL -c` inside the new pane, exactly
    # {Up}'s `chat_command`) never needs quoting against a shell on our side.
    class TmuxSurface
      # Reused verbatim, not redefined: one exception name for "no tmux" no
      # matter which CLI object hit it, so a caller can rescue either
      # {Up::TmuxUnavailable} or {TmuxSurface::TmuxUnavailable} and mean the
      # same thing -- they ARE the same class.
      TmuxUnavailable = Up::TmuxUnavailable

      # kind: :window / :popup / :session -- the surface actually opened.
      # target: the window/session name the caller asked for (nil if none).
      # degraded: true only when #popup fell back to a window.
      # reason: nil, or why it degraded -- "control_mode" / "old_tmux".
      Placement = Data.define(:kind, :target, :degraded, :reason)

      # tmux's OWN `#{...}` format-string syntax (`man tmux` FORMATS), not
      # Ruby interpolation -- the identical trap {Up::JQ_FILTER}'s comment
      # documents for jq's `\(...)`. Named constants (rather than inline
      # literals) so the `rubocop:disable` covers exactly these two strings,
      # nowhere else.
      COMMAND_LIST_NAME_FORMAT = '#{command_list_name}' # rubocop:disable Lint/InterpolationCheck
      CLIENT_CONTROL_MODE_FORMAT = '#{client_control_mode}' # rubocop:disable Lint/InterpolationCheck

      def initialize(socket: nil, shell_out_factory: Mixlib::ShellOut.public_method(:new))
        @socket = socket
        @shell_out_factory = shell_out_factory
      end

      # @param command [String] shell command tmux runs in the new window
      # @param name [String, nil] window name (`-n`)
      # @param target_session [String, nil] session to add the window to;
      #   nil lets tmux pick (the current session, from inside a pane)
      # @return [Placement]
      def window(command:, name: nil, target_session: nil)
        args = ["new-window"]
        args += ["-t", target_session] if target_session
        args += ["-n", name] if name
        args << command
        act(*args)
        Placement.new(kind: :window, target: name, degraded: false, reason: nil)
      end

      # @param command [String] shell command tmux runs in the popup
      # @param title [String, nil] popup title (`-T`); doubles as the window
      #   name if this degrades
      # @param width [String, Integer, nil] `-w` value (tmux accepts `50%`
      #   forms too, hence String)
      # @param height [String, Integer, nil] `-h` value
      # @param target_session [String, nil] see {#window}
      # @return [Placement]
      def popup(command:, title: nil, width: nil, height: nil, target_session: nil)
        reason = degrade_reason
        return window(command:, name: title, target_session:).with(degraded: true, reason:) if reason

        args = ["display-popup", "-E"]
        args += ["-T", title] if title
        args += ["-w", width.to_s] if width
        args += ["-h", height.to_s] if height
        args << command
        act(*args)
        Placement.new(kind: :popup, target: title, degraded: false, reason: nil)
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
