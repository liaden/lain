# frozen_string_literal: true

require "json"
require "time"

module Lain
  class StatusFeed
    # The published struct, understood: the one place that turns
    # `cache_deadline` into a warm/cold answer and the whole struct into the one
    # HUD line every surface shows.
    #
    # Both halves are here because they are one subject -- what the state feed
    # MEANS -- and splitting them put the deadline comparison in five places and
    # the HUD's shape in two (a Ruby jq program and a byte-identical copy of it
    # in `plugin/tmux/scripts/lain-status`). {StatusFeed} publishes `#hud` as a
    # field, so a renderer downstream reads a string and carries no derivation
    # at all; that is what lets the shipped shell script drop `jq`.
    #
    # WHAT THE PRE-RENDERED FIELD COSTS is freshness, on every surface that
    # shows it -- the tmux bar, `lain up`'s status-right, and the editor plugin's
    # `lain.hud()`. The glyph is decided when a publish happens, and a publish
    # happens on an EVENT, so an idle session keeps showing the marker its last
    # turn earned however long it sits. Past the cache profile's window that
    # marker is WRONG, and wrong optimistically: it says 🔥 when the truth is ❄,
    # and a human who believes it pays full price for a prefix they thought was
    # cached.
    #
    # The prompt's own ●/○ is no better and never was. {Frontend::TTY} composes
    # the prompt once per input cycle and hands Reline a String, so that marker
    # is stamped at the turn boundary too. What this card removed is the only
    # surface that DID re-evaluate the deadline on a timer -- a jq program tmux
    # re-ran every status-interval -- and keeping it meant keeping two spellings
    # of one HUD. `elapsed`, `idle` and `since_compaction` have always had this
    # property; a periodic republish is the one fix that answers all four, and
    # it is a decision of its own rather than a line here.
    #
    # Absence is never an error. A missing file, bytes that are not JSON, and
    # valid JSON that is not a struct are all "nothing published yet", because
    # every caller is drawing a prompt or a status bar and none of them may
    # raise there.
    class Reading
      # The terminal's markers -- a filled circle for a cache still inside its
      # sliding TTL, a hollow one for a deadline already passed.
      WARM = "●"
      COLD = "○"

      # The status bar's, which is a different surface with a different budget:
      # one cell in a bar a human reads from across a desk, where a glyph that
      # carries its own colour beats one that needs the bar to supply it.
      HUD_WARM = "🔥"
      HUD_COLD = "❄"

      # {StatusFeed::ModeState} publishes `mode_lighter` as the first FREE-FORM
      # string on this struct -- a degradation path can put a foreign journal's
      # raw posture name in it -- so the closed vocabulary every other segment
      # draws on does not cover that one. Three characters are STRIPPED rather
      # than escaped, because each would be lost differently downstream and no
      # one escaping serves both: a `"` or a `\` ends the field early for the
      # shell that reads it back out of the JSON, and a `#` opens tmux's own
      # format syntax. Dropping them costs a character of a name; keeping them
      # costs the whole line.
      UNRENDERABLE = /["\\#]/

      # The bar trims what the published number does not. {ContextWindow.default}
      # answers an unmatched model -- every Ollama id -- with a conservative
      # 8,192, so a real 32k local window publishes 4.0 and an unclamped render
      # says `ctx:400%`. A pegged 100% reads as "full", which is the one thing a
      # human can act on.
      FULL_PERCENT = 100

      GUESS = "~"

      # How many fleet rows a header carries under the HUD line. Two, and the
      # arithmetic is `lain up`'s: the input pane is six rows, and the HUD, the
      # rows, the "+N more" and the prompt all live in them -- with a third row
      # a countdown has nowhere of its own to draw. `lain://status` is where
      # the whole tree is read.
      HEADER_ROWS = 2

      # What the tree is set in from, so the rows read as standing under the
      # HUD rather than beside it. It is handed to the row and clamped with it.
      LEAD = "  "

      # @param path [String] a published state file, absent or unreadable as
      #   often as not
      # @return [Reading] over whatever was there, or over nothing
      def self.at(path) = new(struct_in(path))

      def self.struct_in(path)
        parsed = JSON.parse(File.read(path))
        parsed.is_a?(Hash) ? parsed : {}
      rescue SystemCallError, JSON::ParserError
        {}
      end
      private_class_method :struct_in

      # @param state [Hash] string-keyed, as published -- {StatusFeed#state}'s
      #   own derivation serves a live in-process reader just as well as a
      #   parsed file serves a separate process. BORROWED, not owned: a caller
      #   handing over the live struct keeps writing to it, so this object makes
      #   no immutability promise it could not keep.
      def initialize(state = {})
        @state = state
      end

      # THREE answers, not two. "Nothing has published a deadline" is not a cold
      # cache: a caller rendering cold for it asserts a window went stale when
      # none was ever opened. The prompt draws nothing for it; `/status` says so
      # in words.
      #
      # @param now [Time] the wall clock, injected so a spec never races a real
      #   deadline
      # @return [Symbol] `:warm`, `:cold` or `:unpublished`
      def warmth(now:)
        deadline = cache_deadline
        return :unpublished if deadline.nil?

        deadline > now ? :warm : :cold
      end

      # The whole HUD, in the order the segments have always rendered: marker,
      # the two counts that are always there, then whatever optional segment the
      # struct actually carries. A state written before a field existed renders
      # the line it always did rather than `approve:0 ctx:--`, which is noise
      # rather than information on every quiet chat.
      #
      # @param now [Time] the wall clock the marker is decided against
      # @return [String] ending in exactly one space, so the last segment never
      #   sits hard against the right edge of a bar
      def hud(now:)
        [marker(now:), " fleet:#{fleet_size} inbox:#{inbox_count}", *optional_segments, " "].join
      end

      # The HUD with the fleet tree under it: what a surface with more than one
      # line shows, which today is the input pane's header. The HUD line stays
      # exactly what every one-line surface draws, so the two cannot drift.
      #
      # It takes the TOP of the tree and says what it left rather than growing
      # with the fleet: this is drawn above a prompt a human is typing at, and a
      # header that pushes the prompt off the bottom of the pane is worse than
      # one that says there are more.
      #
      # NOTHING BELOW THE FIRST LINE READS A CLOCK, and that is a constraint
      # rather than an omission. This string IS the frame the chat publishes to
      # the pane, and a pane redraws whenever the frame changes: an age column
      # would make it differ from itself once a second and cost a redraw a
      # second, each printed where the line editor left the cursor. The rows
      # are therefore {Fleet::Row.undated}; `lain://status` shows the age, where
      # a redraw is a buffer rewrite nobody sees. `now:` still decides the HUD's
      # own cache marker, which flips once rather than ticking.
      #
      # @param now [Time] the wall clock the HUD's marker is decided at
      # @return [String] one line, or one line per row beneath it
      def header(now:) = [hud(now:), *fleet_rows].join("\n")

      # @return [Array<String>] the rows as drawn, indented under the HUD
      def fleet_rows
        rows = Array(@state["fleet_tree"])
        drawn = rows.take(HEADER_ROWS).map { |row| Fleet::Row.undated(row).listed("", under: LEAD) }
        rows.size > HEADER_ROWS ? [*drawn, "#{LEAD}+#{rows.size - HEADER_ROWS} more"] : drawn
      end

      def fleet_size = Array(@state["fleet"]).size

      def inbox_count = @state["inbox_count"].to_i

      # Zero for a state written before the field existed, and for a
      # `--no-journal --no-nvim` run where no tee is ever built: absence is
      # healthy, and a reader deciding whether it is a STALL is doing something
      # this object deliberately does not.
      def derivation_refusal_streak = @state["derivation_refusal_streak"].to_i

      # Only an explicit `true` marks a guess: a state written before the field
      # existed has nothing to say about its window, and a mark it never earned
      # would read as a claim.
      def window_guessed? = @state["window_guessed"] == true

      # The mark a percentage carries when its denominator was a guess. A
      # guessed window is a floor somebody picked, so 61% of it can be 15% of
      # the context the server really loaded.
      def guess_mark = window_guessed? ? GUESS : ""

      private

      def cache_deadline
        raw = @state["cache_deadline"]
        raw && Time.iso8601(raw)
      rescue ArgumentError, TypeError
        nil
      end

      def marker(now:) = warmth(now:) == :warm ? HUD_WARM : HUD_COLD

      def optional_segments = [approvals, occupancy, run_tokens, mode_lighter].compact

      def approvals
        pending = @state["approvals_pending"].to_i
        " approve:#{pending}" if pending.positive?
      end

      # A genuinely empty context still renders `ctx:0%`; only ABSENCE is
      # silent, which is what distinguishes a fresh session from a measured one.
      def occupancy
        ratio = @state["occupancy"]
        ratio && " ctx:#{guess_mark}#{[(ratio * FULL_PERCENT).floor, FULL_PERCENT].min}%"
      end

      # `run:` and both halves are load-bearing. "usage:" would read as the
      # plan's consumption, but {StatusFeed} sums only what THIS process was
      # billed on THIS key; "session:" would read as the whole conversation, but
      # a {Session} survives a `--resume` where this counter does not.
      def run_tokens
        spent = @state["run_tokens"]
        spent && " run:#{spent}"
      end

      # ALREADY COMPOSED upstream (the posture's lighter plus every active
      # layer's, empty under the silent default posture), so this renderer
      # carries no copy of the mode ladder and only has to know that empty means
      # quiet.
      def mode_lighter
        lighter = @state["mode_lighter"].to_s.gsub(UNRENDERABLE, "")
        " #{lighter}" unless lighter.empty?
      end
    end
  end
end
