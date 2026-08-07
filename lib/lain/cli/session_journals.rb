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
    # disagree about what is parked -- silently, since neither raises. They
    # stated the rule twice for one wave and had already drifted: one reached
    # for `Dir.glob`, the other `Dir.children`. That is the shape that cost this
    # chunk a real bug elsewhere (two hand-written whitespace lists that
    # disagreed), so the rule lives here and the surfaces above it only choose
    # which record types they care about.
    #
    # == The five clauses
    #
    # 1. EVERY `.ndjson` in the directory, ephemeral `.btw` sessions INCLUDED --
    #    unlike {CLI::Sessions}' default listing. A gate decided during a
    #    `--btw` session is still decided, and dropping a record is unsafe in
    #    BOTH directions: a lost terminal decision leaves an answered item
    #    parked, a lost deferral reads as drained. There is no single-file
    #    shortcut ({CLI::SessionFile}'s resolution, which the report commands
    #    read through) and no newest-file one for the same reason -- either would
    #    silently drop last week's deferrals.
    # 2. `Dir.children`, never `Dir.glob`. A directory NAME carrying glob
    #    metacharacters is a name, not a pattern: `Dir.glob` finds nothing under
    #    a `$XDG_STATE_HOME` containing `[`, and finds it silently. (The
    #    {CLI::Sessions} / {Resume::Selector} idiom, and a spec pins the case.)
    # 3. Parsed through {Journal.records}, never `JSON.parse` directly, so a
    #    foreign line -- a Rust `tracing` span sharing the fd -- is skipped
    #    rather than raised on.
    # 4. Ordered by the `ts` field ASCENDING, compared as a String, with a
    #    STABLE tiebreak. See {#ordered} for why a String compare is safe and
    #    what it depends on.
    # 5. A file that cannot be READ is named ({Unreadable}), never skipped. A
    #    journal nothing could open may hold this epic's records, and walking
    #    past it reports stale truth as current -- the fold's own never-skip
    #    rule, applied one layer out at the file rather than at the record.
    #
    # Materializing is deliberate and is what the `types:` filter bounds:
    # ordering has to sort, so the kept records become an Array. Without the
    # filter that Array would be every turn of every session this project ever
    # ran, for the sake of a handful of epic records.
    class SessionJournals
      include Enumerable

      # A file the directory listed cannot be read as a journal. The session
      # directory belongs to the user, so a stray `weird.ndjson/` subdirectory
      # (EISDIR) or a mode-000 file (EACCES) is reachable with nothing wrong at
      # this tier -- and a raw `Errno::EISDIR: Is a directory @ io_fillbuf`
      # escapes `exe/lain`'s `rescue Lain::Error` and prints a backtrace at
      # someone who asked for a status report.
      class Unreadable < Error
        def initialize(path, cause)
          super("cannot read the session journal #{path}: #{cause.message}")
        end
      end

      # What was read versus what was understood.
      #
      # It exists because "folded 2 journals" counts FILES, and a count of files
      # cannot tell "read two journals and understood them" from "read two
      # journals and understood none of them". On a surface whose entire job is
      # to justify the sentence "nothing is outstanding", that difference is the
      # whole answer: a truncated or garbled line could BE the deferral, and a
      # lost deferral reads as drained.
      #
      # `unreadable` counts lines {Journal.parse} could make nothing of -- not
      # foreign records. A Rust tracing span is valid JSON and simply is not
      # ours; counting it here would cry wolf on every session that shared its
      # fd.
      Tally = Data.define(:files, :lines, :records, :unreadable)

      # @param dir [String] the project's session directory, already resolved --
      #   this object does no `Paths` arithmetic, which is what lets one caller
      #   scope by `Dir.pwd` and another by an explicit root
      # @param types [Array<String>] the journal discriminators to keep.
      #   REQUIRED, and deliberately so: every caller knows which records it is
      #   about, and a "keep everything" default would quietly make the
      #   materialization above unbounded.
      def initialize(dir:, types:)
        @dir = dir
        @types = types
      end

      # WHICH directory this walk folded. Public because a report that prints a
      # fold has to be able to say where the fold came from -- the epic tier
      # keys its container on the project root and its journals on the working
      # directory, so "which epic" and "whose records" are two answers and a
      # reader cannot infer the second from the first.
      attr_reader :dir

      def each(&block)
        return to_enum(:each) unless block

        ordered.each(&block)
        self
      end

      # @return [Tally]
      def tally
        @tally ||= readings.inject(Tally.new(files: files.size, lines: 0, records: 0, unreadable: 0)) do |sum, read|
          sum.with(lines: sum.lines + read.lines, records: sum.records + read.records.size,
                   unreadable: sum.unreadable + read.unreadable)
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

      # One file's worth of answer: the records we keep, and the counts that say
      # what it cost to find them.
      Reading = Data.define(:records, :lines, :unreadable)
      private_constant :Reading

      def readings = @readings ||= files.map { |path| reading_of(path) }

      # Ordered by `ts` ascending with the position in the concatenation
      # breaking ties, because `sort_by` is NOT stable and this walk must be a
      # function of the bytes on disk rather than of the sort's internals.
      #
      # The String compare is safe ONLY because {Journal#record} stamps every
      # line with `Time.now.utc.iso8601(6)` -- fixed width, zero padded, always
      # UTC, always `Z`. That makes lexicographic order chronological order. A
      # `ts` written by anything else -- bearing an offset like `+02:00`, or no
      # zone at all -- would sort wrong and sort SILENTLY, so a second writer
      # into this directory owes that format. Named here because the dependency
      # is invisible at the call site.
      #
      # What the tiebreak means, precisely: WITHIN a file it is write order,
      # since a journal is appended. ACROSS files it is filename order, which is
      # not write order and does not pretend to be -- two sessions can stamp the
      # same microsecond. It is deterministic, which is the property a
      # projection needs; it is not a claim about which happened first.
      #
      # It is DEFENSIVE, and honestly so: dropping `index` here changes no
      # observable behaviour on MRI 4.0.5, measured up to 5000 records with
      # interleaved and shuffled ties. Ruby does not SPECIFY `Array#sort` as
      # stable, so that is a fact about this interpreter rather than a promise
      # of the language, and a projection that reorders itself on an upgrade is
      # exactly the kind of silent drift this walk exists to prevent. Kept, and
      # a mutation of it is expected to survive the specs.
      def ordered
        @ordered ||= readings.flat_map(&:records)
                             .each_with_index.sort_by { |record, index| [record["ts"].to_s, index] }
                                             .map(&:first)
      end

      # One pass, and only the kept records survive it: the counts are taken as
      # the lines go by rather than from a materialized parse of the whole file,
      # so peak memory is what we keep and not what we read.
      #
      # The rescue wraps the whole enumeration, not just the open: `File.foreach`
      # without a block is lazy, so EISDIR and EACCES both surface on the first
      # iteration here rather than at the call.
      def reading_of(path)
        counted = File.foreach(path).each_with_object({ records: [], lines: 0, unreadable: 0 }) do |line, acc|
          acc[:lines] += 1
          record = Journal.parse(line)
          acc[:unreadable] += 1 if record.nil?
          acc[:records] << record if record && @types.include?(record["type"].to_s)
        end
        Reading.new(**counted)
      rescue SystemCallError => e
        raise Unreadable.new(path, e)
      end
    end
  end
end
