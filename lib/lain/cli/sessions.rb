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

      # One file's derived line. A separate object because deriving a row --
      # classifying open/closed/chained, counting turns, picking the head --
      # is its own responsibility, and the listing above stays a pure map.
      class Row
        # The digest prefix the inspect idiom shows (see Event#inspect).
        SHORT = 19

        def self.for(name:, path:)
          new(name:, records: Journal.records(File.foreach(path)).to_a)
        end

        def initialize(name:, records:)
          @name = name
          @records = records
        end

        # A file with no session header is not a loadable session (a pre-scribe
        # --nvim-era journal, or not ours at all); listed honestly rather than
        # skipped, so the directory's contents and the listing never disagree.
        def to_s
          return "#{@name}  ?  0 turns  unreadable  -" if header.nil?

          "#{@name}  #{started}  #{turns.size} turns  #{status}  #{head_short}"
        end

        private

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
