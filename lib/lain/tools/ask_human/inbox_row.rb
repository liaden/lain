# frozen_string_literal: true

module Lain
  module Tools
    class AskHuman
      InboxRow = Data.define(:from, :age, :summary)

      # One pending question as a listing row: who is stuck, for how long, and
      # what they asked. Reopened rather than given a `Data.define ... do`
      # block, since a constant declared in that block resolves against the
      # enclosing module instead of this class.
      #
      # ONE ROW, TWO SURFACES. The terminal drain ({Frontend::TTY::Inbox}) and
      # the editor's lain://inbox ({Frontend::Neovim::InboxView::Row}) each held
      # their own copy of this arithmetic, and only the terminal's ran when the
      # terminal drew. An age is derived from a CLOCK, so two implementations of
      # one are two answers waiting to differ about one question.
      #
      # THE CLOCK IS HANDED IN, NEVER READ HERE. {.at} takes the instant its
      # caller measured against, so one listing ages every row against one
      # moment, two surfaces handed one instant cannot disagree, and this object
      # has no clock to race. The age is recomputed on every render from a live
      # read -- never stamped once and re-shown later.
      #
      # Each surface keeps what is genuinely its own: colour ({#drawn}'s
      # painter), and the cut-and-wrap of an over-wide item
      # ({Frontend::Neovim::Fold}).
      class InboxRow
        # A clamp on the LEAD, so a fleet's rows still line up their ages.
        NAME_WIDTH = 19

        # Every character a terminal reads as a line break, which is stronger
        # than "holds no \n": a lone \r redraws the line from column 0, so
        # everything before it is overwritten by whatever the author put after.
        # `\R` is exactly that set, measured character for character, and
        # matching a RUN collapses a CRLF to one space rather than two. The
        # editor needs the same scrub for its own reason: `nvim_buf_set_lines`
        # refuses a line holding a newline, the render rides as a notify, and
        # the buffer then stops taking writes with nothing said.
        BREAKS = /\R+/

        # A terminal INSTRUCTION rather than text, removed whole and ahead of
        # {OBEYED} so nothing of it is left behind: `\e[1A` walks the cursor
        # onto the row above and `\e[2K` erases it, which is how a model-written
        # summary rewrites the line a surface drew before it. Measured off a
        # real pane: a task of `"clean\e[1A\e[2KPWNED"` put its own words on the
        # HUD line. The four families are CSI, OSC, the string escapes
        # (DCS/SOS/PM/APC), and every other two-character escape including a
        # bare ESC.
        SEQUENCES = %r{
          \e\][^\a\e]*(?:\a|\e\\)?     # OSC, terminated by BEL or ST
          | \e[P^_X][^\e]*(?:\e\\)?    # DCS, SOS, PM, APC
          | \e\[[0-?]*[ -/]*[@-~]      # CSI
          | \e[ -/]*[0-~]?             # any other escape, and a bare ESC
        }x

        # Kept as a space rather than dropped, because a tab is the one control
        # character that is SEPARATING two words rather than instructing the
        # terminal: deleting it joins them.
        TABS = /\t+/

        # What a terminal or a bidi renderer OBEYS: the whole Cc block -- C0,
        # DEL, and the 8-bit introducers above U+007F that
        # {Frontend::Completion.printable} argues for -- plus the Cf format
        # characters, where U+202E reorders a row and U+200B hides in it.
        #
        # Cf IS covered here and deliberately is NOT in `Completion.printable`,
        # and the surfaces are why. That one highlights grapheme clusters in a
        # menu and needs the ZWJ inside a family emoji; this one composes ONE
        # row out of several columns of somebody else's text, where a bidi
        # override can reorder the columns around it. A ZWJ sequence degrading
        # into its parts costs a glyph; a reordered row costs the reading.
        OBEYED = /[[:cntrl:]\p{Cf}]/

        # Structural, not decoration: `70_inbox.lua` finds a row by the
        # separators around the age, and `05_records.lua` reads a line OPENING
        # with them as a continuation of the item above.
        GAP = "  "

        class << self
          # @param from [String, nil] the asker, clamped to {NAME_WIDTH}
          # @param summary [String] the one-line question, already bounded by
          #   whoever derived it ({Announcement#summary} for a set)
          # @param asked_at [Time] when the question was observed
          # @param now [Time] the instant to age against, read ONCE per listing
          #   by the caller
          # @return [InboxRow]
          def at(from:, summary:, asked_at:, now:)
            new(from: sender(from), age: aged(asked_at, now), summary: one_line(summary))
          end

          # The sender column alone, for a surface naming an asker outside a row
          # (the terminal's arrival note), so {NAME_WIDTH} keeps one site.
          def sender(from) = one_line(from)[0, NAME_WIDTH]

          # One line a terminal DRAWS rather than obeys. Every caller here
          # composes a row out of text somebody else wrote -- a model's question
          # summary, a spawn's task line -- and at least one of them prints it
          # raw to a terminal, so the rule is the strongest of its surfaces'
          # and not the weakest.
          #
          # THE ORDER IS FORCED. Breaks collapse to a space first, so words
          # either side of a newline stay separate words; tabs become spaces for
          # the same reason; whole escape sequences go before {OBEYED}, or the
          # ESC alone would be stripped and `[1A` left as visible junk. That
          # holds for the 7-bit forms {SEQUENCES} matches. An 8-BIT introducer
          # (U+009B, U+009D) is removed by {OBEYED} instead and does leave its
          # parameters as text -- inert, and not worth a second grammar.
          #
          # THE STRIP IS LOAD-BEARING: the editor's fold compares a summary
          # against the whole item it may have elided, and a question ending in
          # a newline made those differ by one trailing space -- manufacturing a
          # two-line item out of whitespace no human can see.
          def one_line(text)
            text.to_s.gsub(BREAKS, " ").gsub(TABS, " ").gsub(SEQUENCES, "").gsub(OBEYED, "").strip
          end

          # Coarse on purpose: an inbox answers "how stale", not "when exactly".
          #
          # NEGATIVE AGES ARE RENDERED, not clamped. `asked_at` is an
          # observation time and `now` a later read of a clock that is not
          # monotonic, so an NTP step or a suspend gives one -- and
          # `70_inbox.lua` matches a leading `-` precisely so that row stays
          # answerable rather than looking right and resolving nothing.
          def aged(asked_at, now)
            seconds = (now - asked_at).to_i
            return "#{seconds}s" if seconds < 60
            return "#{seconds / 60}m" if seconds < 3600

            "#{seconds / 3600}h"
          end
        end

        def to_s = drawn { |_column, text| text }

        # The row as one line, each column offered to a caller that decorates
        # one. The LAYOUT is never the caller's -- escape codes are the only way
        # two surfaces' lines may differ.
        #
        # The lstrip is not tidying: a record naming NOBODY would otherwise open
        # its row with the very two spaces the editor reads as a continuation,
        # folding a live question into the item above, where the `<CR>` walk
        # would answer that item's set instead.
        #
        # @yieldparam column [Symbol] :from, :age or :summary
        # @yieldparam text [String] that column's drawn text
        # @return [String]
        def drawn(&painter) = to_h.map(&painter).join(GAP).lstrip
      end
    end
  end
end
