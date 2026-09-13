# frozen_string_literal: true

require "shellwords"

module Lain
  module CLI
    class Up
      # The status-right HUD's string composition. Everything here is a STRING
      # for tmux's own `$SHELL -c` at the `#(...)` job boundary {Up}'s class
      # comment explains, so state_path is escaped for THAT shell, not ours.
      class Hud
        # The HUD arrives ALREADY RENDERED, in {Lain::StatusFeed}'s `hud` field
        # -- glyph, counts, the clamped context percentage, the run's token
        # spend and the composed mode lighter, all of it composed once by
        # {Lain::StatusFeed::Reading}. So this job's whole work is picking one
        # field out of one line, and the seven-line jq program it replaces (plus
        # its byte-for-byte twin in `plugin/tmux/scripts/lain-status`, plus a
        # named warning for a missing `jq`) is gone with it.
        #
        # NO `$` ANYWHERE, and that is the one rule shaping this. tmux 3.4
        # escapes a `$` in an option value to a backslash-dollar and stores it
        # escaped (3.8 does not), so the job tmux later hands the shell is a
        # syntax error -- swallowed by the `2>/dev/null` below, leaving a
        # permanent "lain: no state yet" on every tmux 3.4, which is Ubuntu
        # 24.04's and every GitHub runner's. That is why this reads the field
        # with `sed` rather than with the parameter expansion the shipped script
        # uses: a script FILE has no such rule and can be free of PATH entirely,
        # while an option value may not name a shell variable at all.
        #
        # Ending the field at the first `"` is sound rather than lucky:
        # {Lain::StatusFeed::Reading} strips `"`, `\` and `#` out of the one
        # segment that is free-form, and every other segment is a count or a
        # clamped percentage.
        EXTRACT = %q{sed -n 's/.*"hud":"\([^"]*\)".*/\1/p'}

        # How often tmux re-runs the `#(...)` job. A fact about this renderer --
        # what a redraw costs, how stale its numbers may get -- not about
        # sessions, windows or attaching, so it does not live on {Up}.
        DEFAULT_INTERVAL = 5

        # @param state_path [String] the state file the job reads, resolved by
        #   {Lain::ProjectDir#state_path} -- which today lives under
        #   `$XDG_STATE_HOME/lain`, not in the project
        # @param interval [Integer] seconds between re-renders; tmux's
        #   `status-interval`, which {Up} writes as a session option
        def initialize(state_path:, interval: DEFAULT_INTERVAL)
          @state_path = state_path
          @interval = interval
        end

        # `state_path` is public because the file sits in a directory named by
        # twelve hex characters of a hash, so {Up::Report#hud_line} has to tell
        # the operator where it is. Reading it hands out a name, not authority.
        attr_reader :interval, :state_path

        # `grep .` is the never-blank guard, and it is not decoration: an
        # ordinary fresh `up` window, before StatusFeed's first publish writes
        # `state.json`, leaves the extractor with nothing to print and rendered a
        # LITERALLY BLANK status-right (reproduced through an attached PTY
        # capture). Empty stdout fails `grep`, and `|| echo` then says so in
        # words -- which a state file from a lain too old to publish the field
        # reaches by the same route.
        #
        # @return [String] the status-right value
        def status_right
          "#(#{EXTRACT} #{Shellwords.escape(state_path)} 2>/dev/null | grep . || echo 'lain: no state yet')"
        end
      end
    end
  end
end
