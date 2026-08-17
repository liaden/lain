# frozen_string_literal: true

module Lain
  module CLI
    # `lain sessions`: an honest listing of this project's recorded sessions,
    # newest first -- basename, started-at, turn count, open/closed (plus
    # `chained` for a resumed file), and the short head digest. Derivation
    # only reads the records; it never re-verifies the Merkle chain, which is
    # the Loader's job at resume time. Returns a String; only the frontend
    # renders (output discipline).
    class Sessions
      def initialize(paths: Paths.new)
        @paths = paths
      end

      # @param all [Boolean] include ephemeral (`.btw.ndjson`) sessions; the
      #   default view is the durable record only (T3) -- promotion is a
      #   rename, so a kept session simply starts matching
      # @return [String] one line per session, newest first; or the honest
      #   empty state naming the directory searched
      def listing(all: false)
        names = session_names(all:)
        return "no sessions recorded under #{dir}" if names.empty?

        names.reverse.map { |name| Row.for(name:, path: File.join(dir, name)).to_s }.join("\n")
      end

      private

      def dir = @dir ||= @paths.sessions_dir

      # Bench::CLI's discovery idiom: Dir.children (never glob-parsed), sorted
      # -- the filenames are UTC-timestamped, so lexicographic IS chronological.
      def session_names(all:)
        Dir.children(dir).select { |name| name.end_with?(".ndjson") && (all || !Paths.ephemeral?(name)) }.sort
      end

      # Counts the entries {Journal.records} already walks, so the number of
      # lines a session file held is knowable without a second read of it --
      # no extra `File.foreach`, no extra `Journal.parse`. `Journal.records`
      # stays untouched: this wraps the enumerable handed TO it, not the
      # lazy chain it returns, so `Row.for`'s single pass over the file is
      # exactly as lazy as it was before this existed.
      class LineCount
        include Enumerable

        attr_reader :lines_read

        def initialize(entries)
          @entries = entries
          @lines_read = 0
        end

        def each
          return enum_for(:each) unless block_given?

          # Reset, not accumulate: `include Enumerable` promises #each is
          # safe to drive more than once, and `lines_read` is only ever
          # meaningful as "what the MOST RECENT walk saw" -- an accumulating
          # counter would silently misreport a healthy, twice-read file as
          # damaged.
          @lines_read = 0
          @entries.each do |entry|
            @lines_read += 1
            yield entry
          end
        end
      end

      # One file's derived line. A separate object because deriving a row --
      # classifying open/closed/chained, counting turns, picking the head --
      # is its own responsibility, and the listing above stays a pure map.
      class Row
        # The digest prefix the inspect idiom shows (see Event#inspect).
        SHORT = 19

        def self.for(name:, path:)
          entries = LineCount.new(File.foreach(path))
          records = Journal.records(entries).to_a
          new(name:, records:, empty: Journal.empty?(path), skipped: entries.lines_read - records.size)
        end

        # `empty:` is required, not defaulted: a default exists only to let a
        # caller omit it, and the sole thing omitting it could produce is a
        # zero-byte file silently mislabelled "unreadable" -- the exact
        # confusion this row was split to end. `skipped:` is required for the
        # same reason -- a default would let a caller forget it and reintroduce
        # F6's silence.
        def initialize(name:, records:, empty:, skipped:)
          @name = name
          @records = records
          @empty = empty
          @skipped = skipped
        end

        # A file with no session header is not a loadable session (a pre-scribe
        # --nvim-era journal, or not ours at all); listed honestly rather than
        # skipped, so the directory's contents and the listing never disagree.
        # `#{damage}` on BOTH branches: the headerless one can misfire in the
        # expensive direction -- a torn header followed by a surviving `turn`
        # record reads as "turn, not a chat", a POSITIVE claim about a `lain
        # review`-style journal that is actually a damaged session -- and
        # leaving the skip unreported there would send a reader away from the
        # exact damage {#unloadable}'s own third case exists to surface.
        def to_s
          return "#{@name}  ?  0 turns  #{unloadable}  -#{damage}" if header.nil?

          "#{@name}  #{started}  #{turns.size} turns  #{status}  #{head_short}#{damage}"
        end

        private

        # F6: Journal.records' skip-foreign-bytes contract (journal.rb:131-136)
        # is sound -- the fd can be shared with Rust tracing spans -- but applied
        # to lain's OWN torn record it left a damaged session looking intact:
        # same header, same status, one turn short under an unmoved head digest.
        # This reports the skip instead of preventing it, so the row stops lying
        # by omission. Blank when nothing was skipped, so an intact session
        # carries no damage indication at all. "unparsed", not "torn": the row
        # states exactly what {Journal.parse} measured -- a line that did not
        # parse -- not a cause ("torn") it has no way to know. A stray blank
        # line in an otherwise-perfect session is unparsed; calling it torn
        # would be a claim the code cannot back.
        def damage
          return "" unless @skipped.positive?

          "  #{@skipped} #{@skipped == 1 ? "line" : "lines"} unparsed"
        end

        # THREE headerless causes, and only the middle one is damage. A
        # zero-byte file is what {Journal.open} left when a chat died before its
        # header; an unreadable one holds bytes nothing can load; and a file
        # whose records load PERFECTLY and simply are not a chat's is neither --
        # `lain review` writes one of those per run, opening with
        # `changeset_opened` and no session header at all.
        #
        # Naming that third case by its first record rather than calling it
        # unreadable is the same correction the empty/unreadable split already
        # made once: "unreadable" sends a reader hunting corruption that is not
        # there, and after a crash that is exactly the hunt they cannot afford
        # to waste. {Bench}'s variance driver already words it this way -- "no
        # session header record to rebuild a context from" -- so this is the
        # listing catching up with a distinction the tree had drawn elsewhere.
        def unloadable
          return "empty" if @empty
          return "unreadable" if @records.empty?

          "#{@records.first["type"]}, not a chat"
        end

        def header = @records.find { |record| record["type"] == SessionRecord::HEADER_TYPE }
        def turns = @records.select { |record| record["type"] == SessionRecord::TURN_TYPE }
        def closed = @records.find { |record| record["type"] == "session_closed" }

        def started
          timestamp = header["ts"]
          timestamp ? timestamp[0, SHORT] : "?"
        end

        def status
          state = closed ? "closed" : "open"
          header["resumed_from"] ? "#{state}, chained" : state
        end

        # The last turn record is the most recent head this file knows; a
        # turnless file falls back to its recorded anchors (a closed file's
        # own, then the chained-from head), "-" for a header-only session.
        def head_short
          digest = turns.last&.fetch("digest") || closed&.fetch("head", nil) ||
                   header.dig("resumed_from", "head")
          digest ? digest[0, SHORT] : "-"
        end
      end
    end
  end
end
