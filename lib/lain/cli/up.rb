# frozen_string_literal: true

require "mixlib/shellout"
require "shellwords"

module Lain
  module CLI
    # `lain up`: create (idempotently) or attach to the "lain" tmux session,
    # and give it the session-scoped HUD planning/interface-integration.md §
    # "One state feed, three renderers" designs -- status-right/status-interval
    # reading I1's `.lain/state.json` via jq, `monitor-bell` on the spawned
    # chat window. Session-scoped, never global (`set-option -t SESSION`,
    # never `-g`): tmux's own inheritance rule (session beats global) is what
    # keeps the theme plugin's globals untouched, so this needs zero
    # tmux.conf changes.
    #
    # Idempotent by construction: #call probes `has-session` first and only
    # creates when it is absent, so a second `lain up` re-applies the same
    # (harmless) option writes to the session that is already there instead
    # of spawning a duplicate -- the exe's job from there is just to attach.
    #
    # Every tmux/jq invocation goes through Mixlib::ShellOut with an ARGV
    # array, never a single command string -- no intermediate shell on OUR
    # side, so nothing here needs to worry about quoting `session`/
    # `state_path`/`chat_command` against a shell we control. The ONE place a
    # shell reappears is deliberate: the `#(...)` job tmux embeds in
    # `status-right` is interpreted by tmux's OWN `$SHELL -c` at render time,
    # so THAT string (built in #jq_status_right/#fallback_status_right) is
    # Shellwords-escaped for a POSIX shell, not for ours.
    class Up
      # tmux missing outright, or any tmux invocation that fails for a reason
      # other than "no session yet" (has-session's own expected nonzero) --
      # surfaced by name so the exe's Lain::Error -> Thor::Error mapping shows
      # a clean message, never a raw Errno or Mixlib backtrace on a demo
      # machine.
      class TmuxUnavailable < Error; end

      DEFAULT_SESSION = "lain"
      CHAT_WINDOW = "chat"
      DEFAULT_STATUS_INTERVAL = 5

      # jq does the whole warm/fleet/inbox derivation in one process, matching
      # the approved design's "#(jq …) on a status-interval" (planning/
      # interface-integration.md § 1). A single-quoted heredoc: jq's OWN
      # string interpolation is `\(...)`, which must reach jq's parser
      # byte-for-byte -- Ruby's `\(` means nothing, so an interpolating
      # heredoc would risk a mangled filter for no gain. Verified against a
      # real tmux 3.8 (nested parens and all) via an attached PTY: tmux's own
      # `#()` job-boundary parser counts nesting correctly, so this is not
      # the tmux-3.7-only risk it might look like at a glance.
      JQ_FILTER = <<~'JQ'.strip
        if .cache_deadline and (.cache_deadline | fromdateiso8601) > now
        then "🔥" else "❄" end as $warmth
        | "\($warmth) fleet:\(.fleet | length) inbox:\(.inbox_count)"
      JQ

      # `created` tells the caller whether a fresh session was just built (so
      # it can say so before attaching) or one was already running (so a
      # second `lain up` reads as "reattaching", never "duplicating").
      # `warnings` carries the jq-missing notice, if any -- the exe `say`s it
      # before attaching so a degraded HUD is never a SILENT one.
      Report = Data.define(:session, :created, :warnings) do
        # The created-vs-reattaching line is the Report's OWN knowledge (it
        # already carries exactly the two fields that decide it), not exe
        # glue -- the exe just `say`s whatever this returns, alongside
        # `warnings`, before it execs.
        def announcement
          created ? "created tmux session '#{session}'" : "reattaching to '#{session}'"
        end
      end

      # {#launch_plan}'s return shape: `messages` is everything the exe
      # `say`s, in print order (warnings before the final announcement, so a
      # degraded HUD is explained BEFORE "created"/"reattaching" scrolls
      # past); `argv` is exactly {#attach_command}'s `Kernel.exec` array.
      LaunchPlan = Data.define(:messages, :argv)

      # The one pane-command recipe (T16 F2 made it a public seam): tmux's
      # new pane does not source an interactive shell's chruby (see
      # CLAUDE.md's toolchain note), so every pane a lain window runs
      # re-exports the PATH fix and re-invokes the LAUNCHING binary --
      # composed per call, never a constant, because $PROGRAM_NAME must be
      # read when the exe runs (under rspec it is not the lain binary).
      # Callers: `lain up`'s chat window and /fork's sibling window.
      def self.pane_command(*argv)
        "export PATH=\"$HOME/.rubies/ruby-4.0.5/bin:$PATH\"; exec #{$PROGRAM_NAME} #{Shellwords.join(argv)}"
      end

      def initialize(session: DEFAULT_SESSION, socket: nil, state_path: default_state_path,
                     chat_command: nil, chat_args: [], status_interval: DEFAULT_STATUS_INTERVAL,
                     shell_out_factory: Mixlib::ShellOut.public_method(:new))
        @session = session
        @socket = socket
        @state_path = state_path
        @chat_args = chat_args
        @chat_command = chat_command || default_chat_command
        @status_interval = status_interval
        @shell_out_factory = shell_out_factory
        @warnings = []
      end

      # @return [Report]
      # @raise [TmuxUnavailable] no tmux on PATH, or a real tmux failure --
      #   never a bare Errno/Mixlib exception past this boundary.
      def call
        created = !session_exists?
        create_session if created
        configure_session
        Report.new(session: @session, created:, warnings: @warnings.dup)
      end

      # Everything the exe needs to finish `lain up`, in the order it needs
      # it: what to print, then what to exec. This is the orchestration the
      # exe used to own (build a Report, print its warnings then its
      # announcement, THEN compute the attach argv) -- that sequencing is
      # `Up`'s own domain knowledge, same as `#attach_command`'s verb
      # branching, so it lives here rather than being re-derived call site by
      # call site. `#call`/`#attach_command`/`Report#announcement` all stay
      # public in their own right (existing specs keep exercising each in
      # isolation); this just composes them.
      #
      # @param nested [Boolean] forwarded to {#attach_command} unchanged
      # @return [LaunchPlan]
      def launch_plan(nested:)
        report = call
        LaunchPlan.new(messages: report.warnings + [report.announcement], argv: attach_command(nested:))
      end

      # The argv the exe hands to `Kernel.exec` to reattach: `switch-client`
      # when the CALLING shell is itself an attached tmux client (tmux
      # refuses a nested `attach` -- "sessions should be nested with care" --
      # and the refusal comes out raw past any rescue, because `Kernel.exec`
      # has already replaced the process by the time tmux objects; the
      # branch has to happen BEFORE exec, not be caught after), plain
      # `attach` otherwise. `nested:` is the caller's OWN answer (the exe
      # passes `ENV.key?("TMUX")`) rather than this class reading ENV
      # itself, so a spec exercises the exact same branch a real nested
      # shell would hit, with no environment coupling.
      #
      # Known gap, accepted for now: `switch-client` only reaches a session
      # on the SAME server the caller is already attached to. `lain up
      # --socket other` from inside a DIFFERENT tmux server is still
      # unhandled -- out of scope while `lain up` only ever spawns on one
      # (default) socket; multi-server topology is a later concern if it
      # ever arises.
      #
      # @param nested [Boolean] true when the calling shell is itself an
      #   attached tmux client
      # @return [Array<String>] argv for Kernel.exec
      def attach_command(nested:)
        verb = nested ? "switch-client" : "attach"
        ["tmux", *socket_flag, verb, "-t", @session]
      end

      private

      # The one query that TOLERATES a nonzero exit: "no such session" is the
      # expected, non-error answer that drives #call into #create_session.
      def session_exists? = run("has-session", "-t", @session).exitstatus.zero?

      # {.pane_command} over the `chat` subcommand. `@chat_args` is the exe's
      # `-- ARGS` trailing capture -- already `chat`'s own flags to validate,
      # never Up's, so the recipe only Shellwords-escapes each one before it
      # lands in a string tmux hands to ITS OWN `$SHELL -c` (the class
      # comment's shell-boundary note); Up never parses or knows the flag
      # names.
      def default_chat_command = self.class.pane_command("chat", *@chat_args)

      def create_session = act(*new_session_args)

      def new_session_args
        args = ["new-session", "-d", "-s", @session, "-n", CHAT_WINDOW]
        @chat_command ? args + [@chat_command] : args
      end

      def configure_session
        set_option("status-right", status_right_value)
        set_option("status-interval", @status_interval.to_s)
        act("set-window-option", "-t", "#{@session}:#{CHAT_WINDOW}", "monitor-bell", "on")
      end

      def set_option(name, value) = act("set-option", "-t", @session, name, value)

      # Every MUTATING tmux call (as opposed to #session_exists?'s query)
      # goes through here so a real failure -- a broken or sandboxed tmux
      # that cannot spawn a server at all, not just "no session yet" -- fails
      # this method loudly instead of leaving a half-configured session with
      # no error anywhere.
      def act(*args)
        shell_out = run(*args)
        raise TmuxUnavailable, "tmux #{args.first} failed: #{shell_out.stderr.strip}" unless shell_out.exitstatus.zero?

        shell_out
      end

      def run(*)
        @shell_out_factory.call("tmux", *socket_flag, *).tap(&:run_command)
      rescue Errno::ENOENT
        raise TmuxUnavailable, "tmux not found on PATH -- install it (or fix PATH) before `lain up`"
      end

      def socket_flag = @socket ? ["-L", @socket] : []

      def status_right_value
        jq_present? ? jq_status_right : fallback_status_right
      end

      # `2>/dev/null` alone swallows every jq failure, not just a missing
      # binary -- the ordinary fresh-`up` window (before StatusFeed's first
      # publish, `state.json` not written yet) makes jq exit nonzero with
      # empty stdout, which rendered as a LITERALLY BLANK status-right
      # (reproduced live via an attached PTY capture, the same technique the
      # class comment already used to verify the jq/tmux job parsing). The
      # `|| echo` combinator is the same never-silent fallback
      # #fallback_status_right uses for the no-jq case, mirrored onto the jq
      # job itself so both branches share the one guarantee: the HUD shows
      # something real or an honest "no state yet", never blank.
      def jq_status_right
        "#(jq -r '#{JQ_FILTER}' #{escaped_state_path} 2>/dev/null || echo 'lain: no state yet')"
      end

      # jq missing cannot mean a blank HUD -- a demo machine's whole point is
      # showing the state. So this both warns namedly (the Report the exe
      # `say`s) AND still shows something real: raw `state.json`, or an
      # honest "no state yet" when even that file is absent, never silence.
      def fallback_status_right
        @warnings << "jq not found on PATH -- status-right falls back to raw state.json " \
                     "(install jq for the formatted warmth/fleet/inbox HUD)"
        "#(cat #{escaped_state_path} 2>/dev/null || echo 'lain: no state yet')"
      end

      def escaped_state_path = Shellwords.escape(@state_path)

      def jq_present?
        @shell_out_factory.call("jq", "--version").tap(&:run_command).exitstatus.zero?
      rescue Errno::ENOENT
        false
      end

      # `.lain/` is a project artifact like `.git/`, not an XDG concern --
      # {StatusFeed}'s own default follows the same rule, independently, so
      # I1 and I2 do not need to depend on each other's private path helper.
      def default_state_path = File.join(Dir.pwd, ".lain", "state.json")
    end
  end
end
