# frozen_string_literal: true

module Lain
  module CLI
    # Every journal in one project's session directory, ordered by the timestamp
    # each record carries. The journal-discovery contract, owned ONCE.
    #
    # == Why this is an object and not two private methods
    #
    # `lain epic status` and `lain epic queue` both fold an epic that spans days
    # and sessions, so both must read the SAME files in the SAME order or they
    # disagree about what is parked -- silently, since neither raises. Stating
    # the rule twice had already drifted them within one wave: one reached for
    # `Dir.glob`, the other `Dir.children`.
    #
    # == The five clauses
    #
    # 1. EVERY `.ndjson` in the directory, ephemeral `.btw` sessions INCLUDED --
    #    unlike {CLI::Sessions}' default listing. A gate decided during a
    #    `--btw` session is still decided, and dropping a record is unsafe in
    #    BOTH directions: a lost terminal decision leaves an answered item
    #    parked, a lost deferral reads as drained. There is no single-file
    #    shortcut and no newest-file one for the same reason -- either would
    #    silently drop last week's deferrals.
    # 2. `Dir.children`, never `Dir.glob`. A directory NAME carrying glob
    #    metacharacters is a name, not a pattern: `Dir.glob` finds nothing under
    #    a `$XDG_STATE_HOME` containing `[`, and finds it silently.
    # 3. Parsed through {Journal.parse}, never `JSON.parse` directly, so a
    #    foreign line -- a Rust `tracing` span sharing the fd -- is skipped
    #    rather than raised on. A line that parses to nothing is not foreign:
    #    spans are whole JSON lines, so it is DAMAGE, and {Refuse} (the
    #    default) refuses it when a sign-off could rest on it. See {Torn}. So
    #    is a whole record shaped like a sign-off under another type. See
    #    {Misfiled}.
    # 4. Ordered by the `ts` field ASCENDING, compared as a String, with a
    #    STABLE tiebreak. See {#ordered} for what that compare depends on.
    # 5. A file that cannot be READ is named ({Unreadable}), never skipped. A
    #    journal nothing could open may hold this epic's records, and walking
    #    past it reports stale truth as current.
    #
    # Materializing is deliberate and is what the `types:` filter bounds:
    # ordering has to sort, so the kept records become an Array. Without the
    # filter that Array would be every turn of every session this project ever
    # ran, for the sake of a handful of epic records.
    class SessionJournals
      include Enumerable

      # The session directory belongs to the user, so a stray `weird.ndjson/`
      # subdirectory (EISDIR) or a mode-000 file (EACCES) is reachable with
      # nothing wrong at this tier -- and a raw `Errno::EISDIR` escapes
      # `exe/lain`'s `rescue Lain::Error` and prints a backtrace at someone who
      # asked for a status report.
      #
      # A damaged line is refused under the same name: either way this reader
      # cannot say what the directory holds, and the remedy is the human's.
      class Unreadable < Error
        include RefusedBeforeActing
        include JournalUnreadable

        def self.io(path, cause) = new("cannot read the session journal #{path}: #{cause.message}")

        def self.damaged(line) = new("the session journal #{line.path} #{line.where} (#{line.what}) -- #{line.remedy}")
      end

      REMEDY = "move the damaged file aside or repair the line; nothing was decided"
      private_constant :REMEDY

      Torn = Data.define(:path, :line, :type, :within, :tail)

      # One line {Journal.parse} made nothing of, and what can still be read
      # off it.
      #
      # The type comes off the prefix {Journal#record} writes -- `ts`, then the
      # record's own `type` first -- because a torn line cannot be parsed. That
      # order is a convention; spec/journalable_surface_spec.rb pins where it
      # comes from and the two records a sign-off rests on.
      #
      # EVERY prefix in the line is read, not only the leading one: a writer
      # that appends after an unterminated tear fuses its next record onto the
      # torn one, so a torn `turn` can be carrying a whole deferral. JSON
      # escapes a quote inside a string, so a record's text cannot fake one.
      class Torn
        # JSON.generate escapes nothing a timestamp or a snake_case type holds,
        # so neither value can carry a quote.
        RECORD = /\{"ts":"[^"\\]*","type":"([^"\\]*)"/
        LEADING = /\A#{RECORD}/
        private_constant :RECORD, :LEADING

        # @param path [String] the journal the line was read from
        # @param line [Integer] its line number
        # @param text [String] the raw line
        def self.of(path:, line:, text:)
          text = text.to_s.scrub
          type = sniff(text)
          new(path: -path, line:, type: type && -type, within: text.scan(RECORD).flatten.map(&:-@).freeze,
              tail: !text.end_with?("\n"))
        end

        # @param text [String] one raw journal line
        # @return [String, nil] its record type, or nil when the prefix is gone
        def self.sniff(text) = text.to_s.scrub[LEADING, 1]

        # The records a gate or a stage rests on, each named from the unit that
        # declares it, so neither can drift out from under this set.
        def self.decisive_types = [Approval::SignoffQueue::JOURNAL_TYPE, Lain::Epic::StageTransition::JOURNAL_TYPE]

        # A torn line whose type cannot be read could have been anything, so it
        # is treated as the worst thing it could have been.
        def decisive? = type.nil? || within.intersect?(self.class.decisive_types)

        def what
          return "no record type can be read from it" if type.nil?

          fused = (within - [type]) & self.class.decisive_types
          ["a torn #{type} record", *fused.map { |held| "fused with a #{held} record" }].join(" ")
        end

        def where = tail ? "has an incomplete last line at line #{line}" : "is damaged at line #{line}"

        # An unterminated last line is also what a fold sees while a session is
        # still writing, and moving THAT file aside would hide what it writes next.
        def remedy = tail ? "run again if a session is still writing; otherwise #{REMEDY}" : REMEDY
      end

      Misfiled = Data.define(:path, :line, :type)

      # A whole record carrying the three fields only a sign-off carries
      # together, under a type that is not a sign-off's. {Journal.records}
      # skips an unknown type as foreign, so a deferral whose type was damaged
      # would fold as never made -- and a partition missing its deferral reads
      # as drained.
      class Misfiled
        SHAPE = %w[artifact_digest epic_slug policy].freeze

        # @param record [Hash{String=>Object}] one parsed journal record
        def self.shaped?(record)
          SHAPE.all? { |field| record.key?(field) } && record["type"] != Approval::SignoffQueue::JOURNAL_TYPE
        end

        def decisive? = true

        def where = "is damaged at line #{line}"

        def what
          "a record #{type ? "typed #{named}" : "with no type"} carries #{SHAPE.join(", ")}, which only a " \
            "#{Approval::SignoffQueue::JOURNAL_TYPE} carries"
        end

        # @return [String] the type it wears, quoted, or "no type" when it wears none
        def named = type ? -type.inspect : "no type"

        def remedy = REMEDY
      end

      # The default: a torn line a sign-off could rest on refuses the read. A
      # fold that skipped one read a lost deferral as drained, and drained
      # opened the next stage. Strict by default so a fold nobody thought to
      # name is safe without being named.
      module Refuse
        def self.call(damaged)
          raise Unreadable.damaged(damaged) if damaged.decisive?
        end
      end

      # For a reader that renders over damage and SAYS so, from {#tally} --
      # never for one that decides.
      module Tolerate
        def self.call(_torn) = nil
      end

      # What was read versus what was understood. "Folded 2 journals" counts
      # FILES, which cannot tell "read two journals and understood them" from
      # "read two and understood none": on a surface whose job is to justify
      # "nothing is outstanding", a garbled line could BE the deferral.
      #
      # `unreadable` counts lines {Journal.parse} could make nothing of -- not
      # foreign records. A Rust tracing span is valid JSON and simply is not
      # ours; counting it would cry wolf on every session that shared its fd.
      # `misfiled` names, one per record, the type each {Misfiled} record
      # wore: those parsed, so they are not unreadable, and a reader told
      # "could not be parsed" would hunt for torn bytes that are not there.
      Tally = Data.define(:files, :lines, :records, :unreadable, :misfiled)

      # @param dir [String] the project's session directory, already resolved --
      #   this object does no `Paths` arithmetic, which lets one caller scope by
      #   `Dir.pwd` and another by an explicit root
      # @param types [Array<String>] the journal discriminators to keep.
      #   REQUIRED, and deliberately so: every caller knows which records it is
      #   about, and a "keep everything" default would quietly make the
      #   materialization above unbounded.
      # @param damage [#call] handed each {Torn} line and {Misfiled} record;
      #   {Refuse} unless this reader only reports
      def initialize(dir:, types:, damage: Refuse)
        @dir = dir
        @types = types
        @damage = damage
      end

      # Public because a report that prints a fold has to say where the fold
      # came from: the epic tier keys its container on the project root and its
      # journals on the working directory, so "which epic" and "whose records"
      # are two answers and a reader cannot infer the second from the first.
      attr_reader :dir

      def each(&block)
        return to_enum(:each) unless block

        ordered.each(&block)
        self
      end

      # @return [Tally]
      def tally
        @tally ||= readings.inject(Tally.new(files: files.size, lines: 0, records: 0, unreadable: 0,
                                             misfiled: [].freeze)) do |sum, read|
          sum.with(lines: sum.lines + read.lines, records: sum.records + read.records.size,
                   unreadable: sum.unreadable + read.unreadable, misfiled: (sum.misfiled + read.misfiled).freeze)
        end
      end

      # Sorted, so the concatenation order below -- and therefore the tiebreak
      # in {#ordered} -- is a function of the directory rather than of readdir
      # order.
      def files
        @files ||= Dir.children(@dir).select { |name| name.end_with?(".ndjson") }.sort
                      .map { |name| File.join(@dir, name) }
      end

      private

      # The records we keep, and the counts that say what it cost to find them.
      Reading = Data.define(:records, :lines, :unreadable, :misfiled)
      private_constant :Reading

      def readings = @readings ||= files.map { |path| reading_of(path) }

      # Ordered by `ts` ascending with the position in the concatenation
      # breaking ties, because `sort_by` is NOT stable and this walk must be a
      # function of the bytes on disk rather than of the sort's internals.
      #
      # The String compare is safe ONLY because {Journal#record} stamps every
      # line with `Time.now.utc.iso8601(6)` -- fixed width, zero padded, always
      # UTC, always `Z` -- which makes lexicographic order chronological order.
      # A `ts` bearing an offset like `+02:00`, or no zone at all, would sort
      # wrong and sort SILENTLY, so a second writer into this directory owes
      # that format. Named here because the dependency is invisible at the call
      # site.
      #
      # The tiebreak is write order WITHIN a file (a journal is appended) and
      # filename order ACROSS files, which is not write order and does not
      # pretend to be -- two sessions can stamp the same microsecond. It is
      # deterministic, which is the property a projection needs.
      #
      # It is DEFENSIVE, and honestly so: dropping `index` changes no
      # observable behaviour on MRI 4.0.5, measured up to 5000 records with
      # interleaved and shuffled ties. Ruby does not SPECIFY `Array#sort` as
      # stable, so that is a fact about this interpreter rather than a promise
      # of the language, and a projection that reorders itself on an upgrade is
      # the silent drift this walk exists to prevent.
      def ordered
        @ordered ||= readings.flat_map(&:records)
                             .each_with_index.sort_by { |record, index| [record["ts"].to_s, index] }
                             .map(&:first)
      end

      # One pass: the counts are taken as the lines go by rather than from a
      # materialized parse, so peak memory is what we keep and not what we read.
      #
      # The rescue wraps the whole enumeration, not just the open: `File.foreach`
      # without a block is lazy, so EISDIR and EACCES both surface on the first
      # iteration here rather than at the call.
      #
      # An unterminated last line is judged only once the walk is over, against
      # the size the file had when it began: a size that moved means a writer
      # was mid-record, so the file is read ONCE more before anything refuses.
      def reading_of(path, again: true)
        began = File.size(path)
        counted = counted_in(path)
        tails = counted.delete(:tails)
        return reading_of(path, again: false) if again && written_since?(path, began, tails)

        tails.each { |tail| @damage.call(tail) }
        Reading.new(**counted)
      rescue SystemCallError => e
        raise Unreadable.io(path, e)
      end

      def counted_in(path)
        counts = { records: [], lines: 0, unreadable: 0, misfiled: [], tails: [] }
        lines_of(path).each_with_object(counts) do |line, acc|
          acc[:lines] += 1
          read(path, acc, line, Journal.parse(line))
        end
      end

      def read(path, acc, line, record)
        return torn(path, acc, line) if record.nil?
        return misfiled(path, acc, record) if Misfiled.shaped?(record)

        acc[:records] << record if @types.include?(record["type"].to_s)
      end

      def written_since?(path, began, tails) = tails.any?(&:decisive?) && File.size(path) != began

      # `IO#gets` at the end of a file a live writer is mid-`write` on returns
      # the visible part unterminated, and the next call the rest: rejoined
      # here, those two reads are the one line they are, so only a file's LAST
      # line can arrive without its newline.
      def lines_of(path) = File.foreach(path).slice_after { |line| line.end_with?("\n") }.lazy.map(&:join)

      def torn(path, acc, text)
        acc[:unreadable] += 1
        torn = Torn.of(path:, line: acc[:lines], text:)
        torn.tail ? acc[:tails] << torn : @damage.call(torn)
      end

      def misfiled(path, acc, record)
        type = record["type"]
        misfiled = Misfiled.new(path: -path, line: acc[:lines], type: type.nil? ? nil : -type.to_s)
        acc[:misfiled] << misfiled.named
        @damage.call(misfiled)
      end
    end
  end
end
