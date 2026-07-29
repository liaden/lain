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
        #
        # The two later segments are CONDITIONAL, and both conditions are
        # written to survive a key that is simply absent: a state published by
        # an older `lain`, or the ordinary pre-first-turn window where
        # occupancy is genuinely unknown, must render the line it always did
        # rather than "approve:0 ctx:--". A status bar that says something on
        # every quiet chat is noise; these two speak only when there is
        # something to say. (`.foo` on a missing key is null in jq, never an
        # error, which is what makes the guards one comparison each. A zero
        # occupancy is truthy in jq -- only null and false are not -- so a
        # genuinely empty context still renders `ctx:0%`, and only ABSENCE is
        # silent, which is the distinction the field exists to carry.)
        #
        # The percentage is CLAMPED, and this is not defensive padding.
        # {Lain::StatusFeed} publishes `used / window`, and
        # {Lain::ContextWindow.default} answers an unmatched model with its
        # 8,192-token conservative fallback rather than raising -- which is
        # every Ollama id and most Bedrock ids. A real 32k local window then
        # publishes 4.0, and an unclamped filter renders `ctx:400%`. The
        # published number stays honest about what the book was asked (a bench
        # reading it wants the truth); the status bar is where nonsense gets
        # trimmed, because a pegged 100% reads as "full", which is the one
        # thing a human can act on.
        # ⚠️ NO jq VARIABLES, and no `if ... end as $x`. Both are deliberate,
        # and each was a live bug this filter shipped with:
        #
        # * `$` cannot appear here at all. tmux 3.4 ESCAPES a `$` in an option
        #   value to `\$` and stores it escaped (tmux 3.8 does not), so the job
        #   tmux later hands the shell contained `\$warmth` -- a jq syntax
        #   error, swallowed by {#jq_status_right}'s own `2>/dev/null`, leaving
        #   a permanent "lain: no state yet" on every tmux 3.4 (Ubuntu 24.04's,
        #   and every GitHub runner). Concatenating with `+` says the same thing
        #   with nothing for tmux to escape.
        # * The bare `if ... end as $warmth` it used before ALSO needed jq 1.8's
        #   relaxed grammar; jq 1.7 rejects it outright ("unexpected as"), for
        #   the same silent result. Ubuntu 24.04 ships jq 1.7.
        #
        # So it renders identically under jq 1.7 and 1.8, and survives a tmux
        # 3.4 round trip. Verified against both, warm and cold, with and
        # without the optional keys, including the clamp and a zero occupancy.
        JQ_FILTER = <<~'JQ'.strip
          (if .cache_deadline and (.cache_deadline | fromdateiso8601) > now then "🔥" else "❄" end)
          + " fleet:\(.fleet | length) inbox:\(.inbox_count)"
          + (if (.approvals_pending // 0) > 0 then " approve:\(.approvals_pending)" else "" end)
          + (if .occupancy then " ctx:\([(.occupancy * 100 | floor), 100] | min)%" else "" end)
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
