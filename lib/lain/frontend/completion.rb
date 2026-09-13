# frozen_string_literal: true

require "tty-cursor"

module Lain
  module Frontend
    class Completion # rubocop:disable Style/Documentation -- doc lives on the reopen below; see .rubocop.yml's note
      # The one key lain claims for completion. `C-g` is the only other control
      # key free in ALL THREE keymaps lain binds -- emacs, vi_command and
      # vi_insert -- and it is spoken for; see {LineEditor::Registry::KEYMAPS}
      # for why the free space is exactly two keys wide. vi_insert is in that
      # list, which is what makes this fire for a human whose inputrc says
      # `editing-mode vi`; the cost is that C-x no longer self-inserts there.
      KEY = "C-x"

      # How many candidates a menu shows. Also the `limit:` handed to
      # {Lain::Ext::Fuzzy#match}, which is the point: without one, matching
      # against a repo of a hundred thousand paths materializes a hundred
      # thousand Hashes across the FFI boundary to show eight of them.
      DEFAULT_LIMIT = 8

      # Draws nowhere -- the Null Object that keeps {#draw} from growing a nil
      # check.
      NOWHERE = ->(_bytes) {}

      # Strip Cc -- C0 (U+0000-U+001F), DEL, and C1 (U+0080-U+009F, whose
      # members are 8-bit CSI introducers on some terminals). A filename is
      # attacker-controlled in any cloned repo: a file named "ev\e[2Jil.rb" put
      # a live erase-display sequence on the screen AND into the accepted
      # buffer, and a newline in a filename broke the row accounting {#clear}
      # relies on. Ext::Prompt's `sanitize` is the same rule for branch names.
      #
      # STRIPPED, not rejected, on the same precedent: rejecting hands an
      # availability failure to whoever controls a filename, while stripping
      # leaves the printable remainder visible -- `\e[2J` reads as the obvious
      # junk `[2J` instead of being silently deleted or silently obeyed.
      #
      # Cf is deliberately NOT covered. U+202E RIGHT-TO-LEFT OVERRIDE survives
      # and can still reorder a candidate visually; that is confusion, not
      # execution, and stripping Cf would take the ZWJ sequences the
      # grapheme-cluster highlighting is built to keep whole.
      def self.printable(text) = text.gsub(/\p{Cc}/, "")

      class << self
        # The completion the key action answers with. One line editor per
        # process means one live completion per process, so the binding points
        # at a SLOT rather than closing over whichever {TTY} happened to be
        # built first.
        attr_reader :current

        # The key can fail to become ours in several ways, and NONE may cost the
        # human their prompt -- completion is a convenience, the TTY is not.
        #
        # A second install in one process (a spec suite, a reconnect) is
        # GUARDED, because {LineEditor.bind} is deliberately not idempotent and
        # `unbind_all` would take another card's key down with it.
        #
        # Everything else is RESCUED and REPORTED, never swallowed:
        # {LineEditor::KeyTaken} covers two unrelated causes -- someone else
        # already owns the key, and the key was written but does not route -- so
        # the message forwards Reline's own words, and both leave the human
        # pressing a key that does nothing.
        #
        # Takes an already-built completion rather than building one: {.new} is
        # pure and this is the process-global act, which is what lets a caller
        # construct a {TTY} without silently rebinding the human's C-x. {TTY}
        # installs when it TAKES the terminal, never when it is built.
        #
        # @param completion [Completion] the built instance to make {.current} and bind the key to
        # @param notify [#call] renders a warning line ({TTY#render_warning})
        def install(completion, notify: SILENT)
          @current = completion
          claim_key(notify) unless LineEditor.bound?(KEY)
          completion
        end

        private

        def claim_key(notify)
          LineEditor.bind(KEY) { |buffer| @current&.call(buffer) }
        rescue LineEditor::KeyTaken => e
          notify.call("warning: completion is off -- #{e.message}")
        end
      end

      # @param sources [Completion::Sources] sigil -> candidate matcher
      # @param theme [Frontend::Theme] paints the menu and its highlights
      # @param screen [#call] receives the menu's bytes -- {TTY::Countdown#draw},
      #   which is the existing owner of writing to the screen while the prompt
      #   is live. Injected rather than reached for, so this class writes to no
      #   stream of its own and invents no second lock.
      # @param limit [Integer] candidates per menu
      def initialize(sources:, theme:, screen: NOWHERE, limit: DEFAULT_LIMIT)
        @sources = sources
        @menu = Menu.new(theme:)
        @screen = screen
        @limit = limit
        @drawn = false
      end

      # @param buffer [String] every line typed so far, joined with "\n"
      # @return [String, nil] the buffer with its trailing token completed, or
      #   nil to leave the buffer exactly as the human typed it
      def call(buffer)
        token = Token.in_progress(buffer, @sources)
        token && complete(token)
      end

      # Called once the prompt has been answered: Reline has printed its closing
      # newline by then, so the cursor sits on the row the menu started on and a
      # single clear-to-bottom takes the whole thing with it.
      def clear
        @screen.call(::TTY::Cursor.clear_screen_down) if @drawn
        @drawn = false
        nil
      end

      private

      def complete(token)
        matches = @sources.for(token.sigil).match(token.query, limit: @limit)
        return draw(@menu.notice(token)) if matches.empty?

        draw(@menu.offer(token.sigil, matches))
        token.replace(matches.first.fetch("candidate"))
      end

      # Returns nil so the nothing-matched path reads as "drew a notice, left
      # the buffer alone" in one expression.
      def draw(bytes)
        @screen.call(bytes)
        @drawn = true
        nil
      end
    end

    # Fuzzy completion for the `/command` and `@path` token at the end of the
    # prompt's buffer, drawn as lain's own menu and reached through
    # {LineEditor}'s key-action seam.
    #
    # Reline's own completion cannot do this. `filter_normalize_candidates`
    # applies `item.start_with?(target)` to everything a `completion_proc`
    # returns (reline 0.6.3, line_editor.rb:802-814), so a fuzzy candidate --
    # which by definition need not start with what was typed -- is silently
    # dropped. Not overridable from outside; hence a menu of our own.
    #
    # SYNCHRONOUS AND NON-BLOCKING, and that is not a style preference. The
    # handler runs ON Reline's input loop, where Reline's INT trap only sets a
    # flag that the same loop reads, so anything that waits here wedges the
    # editor with nothing left to interrupt it. There is therefore no
    # interactive pick loop: one keypress draws the alternatives and completes
    # to the best of them, in one pass, and returns.
    #
    # The menu is drawn BELOW the line the editor is on -- save cursor, step
    # down, clear from there to the bottom, print, restore cursor -- so Reline
    # never sees the write and lain never has to model where Reline's cursor
    # is. {#clear} erases the same region once the prompt has been answered,
    # which is what keeps a menu from outliving the prompt it belongs to.
    class Completion
      # Reopened rather than nested above -- the tty.rb idiom, which keeps each
      # body inside Metrics/ClassLength instead of loosening it.

      # What is being completed: the run of non-space characters the buffer ends
      # in. The seam hands over a buffer and never a cursor, so "where the human
      # is typing" can only be the end of what they have typed.
      #
      # The sigil is part of the token because `/` and `@` are not word-break
      # characters, and making them so means setting
      # `Reline.completer_word_break_characters` -- process-global, so it would
      # change what `/ruby`'s IRB does too.
      Token = Data.define(:prefix, :sigil, :query) do
        def self.in_progress(buffer, sources)
          text = buffer.to_s[/\S*\z/]
          return nil if text.empty? || !sources.sigil?(text[0])

          new(prefix: buffer[0, buffer.length - text.length], sigil: text[0], query: text[1..])
        end

        # Only the token is rewritten; every earlier line of a multiline buffer
        # and every word before it comes through untouched.
        def replace(candidate) = "#{prefix}#{sigil}#{candidate}"

        def typed = "#{sigil}#{query}"
      end
    end

    class Completion
      # The menu's bytes: the candidate lines, their highlights, and the cursor
      # discipline that lets them be drawn under a line editor that does not
      # know they exist.
      class Menu
        # Save, step to the start of the next row, clear everything below,
        # draw, put the cursor back. "\r\n" rather than "\n" because Reline
        # holds the terminal in raw mode, where a bare linefeed moves down a
        # row without returning to column one.
        NEWLINE = "\r\n"

        def initialize(theme:)
          @theme = theme
        end

        def offer(sigil, matches)
          framed(matches.map { |match| line(sigil, match) })
        end

        def notice(token)
          framed([@theme.paint(:label, "(nothing matches #{token.typed})")])
        end

        private

        def framed(lines)
          [::TTY::Cursor.save, NEWLINE, ::TTY::Cursor.clear_screen_down,
           lines.join(NEWLINE), ::TTY::Cursor.restore].join
        end

        # Scrubbed again even though {Sources} already scrubbed: this is the
        # last gate before the screen, so no source added later can put a
        # control byte on the terminal by forgetting.
        #
        # On an already-scrubbed candidate it is a NO-OP, which is what keeps
        # the matcher's positions indexing the very string being drawn. If it
        # ever actually fires it shortens the candidate underneath positions
        # computed against the longer one, and every highlight past the first
        # control byte lands on the wrong character. The trade is deliberate: a
        # misplaced highlight is cosmetic, a live escape sequence is not. A
        # source that makes this fire is the defect; fix it there.
        def line(sigil, match)
          candidate = Completion.printable(match.fetch("candidate"))
          "#{sigil}#{highlight(candidate, match.fetch("positions"))}"
        end

        # `positions` are GRAPHEME-CLUSTER indices, which is why the candidate
        # is split with #grapheme_clusters and not #chars or bytes -- the
        # matcher reports them that way on purpose, so a highlight lands on the
        # character a human sees rather than half of one.
        #
        # Chunked into runs before painting: a per-character paint would emit
        # an escape pair per character, which is both unreadable in a spec's
        # failure output and a lot of bytes for a menu redrawn per keystroke.
        def highlight(candidate, positions)
          candidate.grapheme_clusters.each_with_index
                   .chunk { |_cluster, index| positions.include?(index) }
                   .map { |matched, pairs| @theme.paint(matched ? :match : :plain, pairs.map(&:first).join) }
                   .join
        end
      end
    end
  end
end

require_relative "completion/sources"
