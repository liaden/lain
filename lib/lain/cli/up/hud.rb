# frozen_string_literal: true

require "shellwords"

module Lain
  module CLI
    class Up
      # The status-right HUD's string composition, extracted from {Up} so the
      # tmux orchestration and the jq/fallback formatting stay one
      # responsibility each. Everything here is a STRING for tmux's own
      # `$SHELL -c` (the `#(...)` job boundary {Up}'s class comment explains),
      # so state_path is Shellwords-escaped for that shell, not for ours.
      class Hud
        # jq does the whole warm/fleet/inbox derivation in one process,
        # matching the approved design's "#(jq …) on a status-interval"
        # (planning/interface-integration.md § 1). A single-quoted heredoc:
        # jq's OWN string interpolation is `\(...)`, which must reach jq's
        # parser byte-for-byte -- Ruby's `\(` means nothing, so an
        # interpolating heredoc would risk a mangled filter for no gain.
        # Verified against a real tmux 3.8 (nested parens and all) via an
        # attached PTY: tmux's own `#()` job-boundary parser counts nesting
        # correctly, so this is not the tmux-3.7-only risk it might look like
        # at a glance.
        JQ_FILTER = <<~'JQ'.strip
          if .cache_deadline and (.cache_deadline | fromdateiso8601) > now
          then "🔥" else "❄" end as $warmth
          | "\($warmth) fleet:\(.fleet | length) inbox:\(.inbox_count)"
        JQ

        JQ_MISSING_WARNING = "jq not found on PATH -- status-right falls back to raw state.json " \
                             "(install jq for the formatted warmth/fleet/inbox HUD)"

        def initialize(state_path:)
          @state_path = state_path
        end

        # @return [Array(String, String), Array(String, nil)] the status-right
        #   value, paired with the named warning when jq is absent -- so a
        #   degraded HUD is never a SILENT one ({Up} surfaces it via Report).
        def status_right(jq_present:)
          jq_present ? [jq_status_right, nil] : [fallback_status_right, JQ_MISSING_WARNING]
        end

        private

        # `2>/dev/null` alone swallows every jq failure, not just a missing
        # binary -- the ordinary fresh-`up` window (before StatusFeed's first
        # publish, `state.json` not written yet) makes jq exit nonzero with
        # empty stdout, which rendered as a LITERALLY BLANK status-right
        # (reproduced live via an attached PTY capture). The `|| echo`
        # combinator is the same never-silent fallback the no-jq branch uses,
        # mirrored onto the jq job itself so both branches share the one
        # guarantee: the HUD shows something real or an honest "no state yet",
        # never blank.
        def jq_status_right
          "#(jq -r '#{JQ_FILTER}' #{escaped_state_path} 2>/dev/null || echo 'lain: no state yet')"
        end

        # jq missing cannot mean a blank HUD -- a demo machine's whole point
        # is showing the state. So this still shows something real: raw
        # `state.json`, or an honest "no state yet" when even that file is
        # absent, never silence.
        def fallback_status_right
          "#(cat #{escaped_state_path} 2>/dev/null || echo 'lain: no state yet')"
        end

        def escaped_state_path = Shellwords.escape(@state_path)
      end
    end
  end
end
