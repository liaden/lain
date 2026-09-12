# frozen_string_literal: true

require "shellwords"

module Lain
  module CLI
    class Up
      # The status-right HUD's string composition. Everything here is a STRING
      # for tmux's own `$SHELL -c` at the `#(...)` job boundary {Up}'s class
      # comment explains, so state_path is escaped for THAT shell, not ours.
      class Hud
        # The whole warm/fleet/inbox derivation in one jq process, on tmux's
        # status-interval. A single-quoted heredoc because jq's OWN string
        # interpolation is `\(...)` and must reach jq's parser byte-for-byte.
        # Verified against a real tmux 3.8 through an attached PTY: tmux's
        # `#()` job-boundary parser counts the nested parens correctly.
        #
        # NO jq VARIABLES here, and no `if ... end as $x`. Each was a live bug
        # this filter shipped with, and both fail SILENTLY:
        #
        # * tmux 3.4 escapes a `$` in an option value to a backslash-dollar and
        #   stores it escaped (3.8 does not), so the job tmux later handed the
        #   shell was a jq syntax error -- swallowed by {#jq_status_right}'s
        #   `2>/dev/null`, leaving a permanent "lain: no state yet" on every
        #   tmux 3.4, which is Ubuntu 24.04's and every GitHub runner's.
        # * `if ... end as $warmth` needs jq 1.8's relaxed grammar; jq 1.7
        #   rejects it outright, and Ubuntu 24.04 ships jq 1.7.
        #
        # Concatenating with `+` says the same thing with nothing for tmux to
        # escape, and renders identically under jq 1.7 and 1.8.
        #
        # The optional segments are guarded so an absent key -- an older
        # `lain`, or the pre-first-turn window -- renders the line it always
        # did rather than "approve:0 ctx:--". `.foo` on a missing key is null
        # in jq, never an error, which is what makes each guard one
        # comparison; a zero is truthy in jq, so a genuinely empty context
        # still renders `ctx:0%` and only ABSENCE is silent.
        #
        # The percentage is CLAMPED because {Lain::ContextWindow.default}
        # answers an unmatched model with a conservative 8,192 -- which is
        # every Ollama id -- so a real 32k local window
        # publishes 4.0 and an unclamped filter renders `ctx:400%`. The
        # published number stays honest for a bench reading it; the bar is
        # where nonsense gets trimmed, because a pegged 100% reads as "full",
        # which is the one thing a human can act on.
        #
        # The mode segment tests an ALREADY COMPOSED string. Rendering
        # `.posture` and `.layers` instead would put a second copy of the
        # lighter table and of the literal "accept_edits" here, alongside the
        # copy in `plugin/tmux/scripts/lain-status`; this renderer only has to
        # know that empty means quiet.
        #
        # The label is `run:` and both halves are load-bearing. "usage:" would
        # read as the plan's consumption, but {Lain::StatusFeed} sums only what
        # THIS process was billed on THIS key. "session:" would read as the
        # whole conversation, but a {Lain::Session} survives a `--resume` where
        # this counter does not, so a resumed chat would render 0 over a record
        # showing half a million. A run is what was measured, and the word
        # {Lain::Agent::Accounting} already uses for the same ledger.
        #
        # The trailing space is the LAST concatenation on purpose, so the line
        # ends with one space whatever the optional segments did. It lives here
        # rather than in the tmux option value, where trailing whitespace is
        # the more fragile of the two places to keep it.
        JQ_FILTER = <<~'JQ'.strip
          (if .cache_deadline and (.cache_deadline | fromdateiso8601) > now then "🔥" else "❄" end)
          + " fleet:\(.fleet | length) inbox:\(.inbox_count)"
          + (if (.approvals_pending // 0) > 0 then " approve:\(.approvals_pending)" else "" end)
          + (if .occupancy then " ctx:\([(.occupancy * 100 | floor), 100] | min)%" else "" end)
          + (if .run_tokens then " run:\(.run_tokens)" else "" end)
          + (if (.mode_lighter // "") != "" then " " + .mode_lighter else "" end)
          + " "
        JQ

        JQ_MISSING_WARNING = "jq not found on PATH -- status-right falls back to raw state.json " \
                             "(install jq for the formatted warmth/fleet/inbox HUD)"

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

        # @return [Array(String, String), Array(String, nil)] the status-right
        #   value, paired with the named warning when jq is absent -- so a
        #   degraded HUD is never a SILENT one ({Up} surfaces it via Report).
        def status_right(jq_present:)
          jq_present ? [jq_status_right, nil] : [fallback_status_right, JQ_MISSING_WARNING]
        end

        private

        # `2>/dev/null` alone swallows every jq failure, not just a missing
        # binary: an ordinary fresh `up` window, before StatusFeed's first
        # publish writes `state.json`, makes jq exit nonzero with empty stdout
        # and rendered a LITERALLY BLANK status-right (reproduced through an
        # attached PTY capture). The `|| echo` gives this branch the same
        # never-silent guarantee the no-jq branch has.
        def jq_status_right
          "#(jq -r '#{JQ_FILTER}' #{escaped_state_path} 2>/dev/null || echo 'lain: no state yet')"
        end

        # jq missing cannot mean a blank HUD: raw `state.json`, or an honest
        # "no state yet" when even that is absent -- never silence.
        def fallback_status_right
          "#(cat #{escaped_state_path} 2>/dev/null || echo 'lain: no state yet')"
        end

        def escaped_state_path = Shellwords.escape(state_path)
      end
    end
  end
end
