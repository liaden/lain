# frozen_string_literal: true

module Lain
  module Review
    class Session
      MarkedChangeset = Data.define(:files, :partitions, :base_ref, :head_ref, :sides)

      # A changeset's STRUCTURE joined to its marks' TRI-STATE -- the one object
      # that can answer both, and the argument every {Review::Surface} means by
      # `present`'s `changeset` (see {Surface}'s class doc for that duck).
      #
      # Neither half can answer it alone, and that is ownership rather than
      # convenience. {Source::ChangedFile#status} is a DIFF fact and deliberately
      # does not answer `#state`; {Marks} derives a REVIEW fact per path and has
      # no notion of files, commits or hunk order. Putting both meanings on one
      # message name is how a table renders the wrong glyph with nothing failing.
      #
      #   #files       -> Array<FileRow>       every file, in the diff's own order
      #   #partitions  -> Array<PartitionRow>  the groups, files partitioned
      #   #base_ref / #head_ref                the refs every anchor rests on
      #   #sides                               which of them the round presents
      #
      # {#sides} is forwarded, never derived, and rides here because THIS is what
      # a {Review::Surface} is handed. It is the round's own fact and not any
      # file's: rows carry no side, and a {FileRow} whose old path is nil is an
      # addition inside a two-sided round.
      #
      # It does NOT answer `#hunks`. {Marks#reconcile} reads `#base_ref` and
      # `#hunks` together and must only ever be handed the whole, unfiltered
      # {Changeset}, so a view can never be mistaken for the thing the pruner
      # takes. {Review::Partition} withholds the same pair for the same reason.
      #
      # Rows are built ONCE and shared: the {FileRow} under a partition is the
      # same object as the one at whole scope, so a re-render cannot show two
      # different states for one file.
      #
      # IT COSTS ONLY WHAT HAS BEEN READ. The derivation is per PATH, and a file
      # that has not been chunked is never asked about, which is what makes a
      # survey affordable to present. The hazard that buys is this class's own
      # warning turned on itself: "not read yet" and "read, and it has no hunk"
      # both render {HUNKLESS} and are both ABSENT from the key table. So the
      # FILE answers the first (`#chunked?`) and a read file missing from the
      # table is refused rather than drawn ({.keys_of}).
      class MarkedChangeset
        # The Symbol -> canonical-String projection of {Review::FILE_STATES}.
        # `Marks#state_of` answers Symbols; every glyph table, every journaled
        # record and every wire form spells the state as a String, and
        # {Review::FILE_STATES} is where that spelling is decided. Derived
        # rather than restated, and read through `fetch`, so a state Marks
        # invents that the vocabulary does not know raises here instead of
        # rendering blank.
        STATES = Review::FILE_STATES.to_h { |name| [name.to_sym, name] }.freeze

        # What a file with NO hunks shows: a binary change, a mode-only change, a
        # pure rename -- and, since the survey arm, a file nothing has read yet.
        # {Marks} never derives such a file from a mark, because it has no key to
        # derive one from, so this is not a state Marks refused to answer: it is
        # the honest reading of a question it was never asked.
        #
        # The two cases stay TOLD APART where it matters even though they render
        # alike -- {.keys_of} refuses a read file the key table does not name.
        #
        # It can never become `reviewed`, and that is disclosed rather than
        # papered over. It does not wedge an approve: {Verdict::Policy::EveryHunk}
        # judges HUNKS, and a file with none has no unreviewed hunk to block
        # with. Calling it `reviewed` would claim a review nobody did.
        HUNKLESS = STATES.fetch(:unreviewed)

        # Frozen and shared rather than a fresh `[]` per hunkless file.
        NO_KEYS = [].freeze

        # `path => the review keys of that path's hunks`, over the files that
        # have been READ, by exactly the rule {Marks} applies to the same hunks
        # (`group_by(&:path)`, then `Hunk.keys` over one file's hunks at a time
        # -- the batch is a precondition of the key scheme, not a convenience).
        # This is the ONE place that grouping is written for the session tier.
        #
        # It names what has been READ, not what exists. A {LazyFile} nobody has
        # chunked has no keys to name, and asking it for some is the whole cost a
        # survey defers. For a DIFF nothing moves: every {Source::ChangedFile} is
        # read the moment the parser produces it. The select goes over FILES
        # rather than the changeset's hunks because `Changeset#hunks` is
        # `files.flat_map(&:hunks)` -- reading it to find out what has been read
        # would chunk everything to answer.
        #
        # A spec pins these keys equal to the ones {Marks} judges, because a row
        # that handed a marking gesture a differently-derived key would mark
        # something the tri-state never reads.
        #
        # @param changeset [#files]
        # @return [Hash{String => Array<String>}]
        def self.keys_by_path(changeset)
          changeset.files.select(&:chunked?).flat_map(&:hunks)
                   .group_by(&:path).transform_values { |hunks| Hunk.keys(hunks) }.freeze
        end

        # The commit walk is the DEFAULT strategy rather than the only one, so
        # a caller that has not chosen still gets the grouping the review model
        # has always had. Naming one here is what keeps {Session#marked} a
        # no-argument message until a later card gives the session a scope to
        # resolve.
        WALK = Review::Partition::STRATEGIES.fetch(:commits)

        # The join, derived one path at a time, so a presentation costs only what
        # has been read. Each file answers whether it has been chunked; only the
        # ones that have reach {Marks}, through {Marks#state_of}, which takes
        # that path's keys and reads nothing else. A survey that has chunked
        # nothing therefore derives nothing and opens no file, at the one place
        # every render passes through.
        #
        # An unread file is {HUNKLESS} for exactly the reason a binary one is: no
        # hunk of it is marked reviewed, because none of it is here yet -- and it
        # is the only state it can be, since a mark names a hunk key and this
        # file has produced none.
        #
        # This replaced an all-or-nothing shortcut on the table's emptiness, and
        # the measurement is worth keeping: 0 keys chunked 0 of 50 files, 1 key
        # chunked 50 of 50 -- which is the partial table every corpus session
        # actually hands over.
        #
        # The base check is asked HERE, once. It used to be made on
        # {Marks#states}' way past; per-path derivation never passes the
        # changeset to marks at all, and this is the object that holds the pair.
        #
        # @param changeset [Review::Changeset] the whole, unfiltered changeset
        # @param marks [Review::Marks] recorded against the same base
        # @param keys_by_path [Hash{String => Array<String>}] {keys_by_path}'s
        #   answer, passed in when the caller already computed it
        # @param strategy [Review::Partition::Strategy] how the files are grouped
        # @return [MarkedChangeset]
        # @raise [Marks::BaseMismatch] if the marks name another base
        # @raise [KeyError] for a table that omits a file with hunks -- see {.keys_of}
        def self.of(changeset, marks, keys_by_path: keys_by_path(changeset), strategy: WALK)
          marks.assert_same_base!(changeset)
          # Keyed by the ChangedFile itself, not by its path: a Partition holds
          # the very same value objects, so the lookup is exact and two files
          # that somehow shared a path could not silently collapse into one row.
          rows = changeset.files.to_h { |file| [file, row(file, marks, keys_by_path)] }
          new(files: rows.values.freeze, partitions: grouped(changeset, rows, strategy),
              base_ref: changeset.base_ref, head_ref: changeset.head_ref, sides: changeset.sides)
        end

        # `fetch` without a default: a partition names only files the changeset
        # named, so a miss is a broken grouping and must say so.
        def self.grouped(changeset, rows, strategy)
          changeset.partitions(strategy).map do |partition|
            PartitionRow.new(partition:, files: partition.files.map { |file| rows.fetch(file) }.freeze)
          end.freeze
        end
        private_class_method :grouped

        # A file nobody has read is {HUNKLESS} and carries no key, and it says so
        # from the FILE rather than from the table's silence -- which is what
        # keeps "not asked yet" and "asked, and there is nothing" two facts. A
        # file that HAS been read reaches the vocabulary through `STATES.fetch`,
        # so a tri-state {Marks} invents that the vocabulary does not know raises
        # instead of rendering blank. There is a spec for that raise.
        def self.row(file, marks, keys_by_path)
          return FileRow.new(file:, state: HUNKLESS, hunk_keys: NO_KEYS) unless file.chunked?

          keys = keys_of(file, keys_by_path)
          FileRow.new(file:, state: STATES.fetch(marks.state_of(keys)), hunk_keys: keys)
        end
        private_class_method :row

        # `fetch` with no fallback for a file that HAS hunks, and that refusal is
        # the whole of what makes a partial table safe. `.of(changeset, marks,
        # keys_by_path: {})` used to render every file of a fully-reviewed diff
        # as `unreviewed` in silence, because an absent entry and an unread file
        # asked the same question of the same table. The FILE answers the second
        # question now, so an absent entry can only mean one thing.
        #
        # A read file with NO hunks is legitimately absent, for {HUNKLESS}'
        # original reason. Reading `#hunks` to tell the two apart is free here
        # and only here -- the file has already been chunked, or the guard above
        # returned.
        def self.keys_of(file, keys_by_path)
          return NO_KEYS if file.hunks.empty?

          keys_by_path.fetch(file.path) do
            raise KeyError, "#{file.path.inspect} has hunks, and the key table handed to this join does not " \
                            "name it -- deriving its state from an empty batch would show a file somebody " \
                            "reviewed as unreviewed, with nothing failing"
          end
        end
        private_class_method :keys_of

        # One file's row: the diff's own facts, forwarded unchanged, plus the one
        # fact the diff cannot know.
        #
        #   #path #old_path #new_path #status #binary?   the diff's, from ChangedFile
        #   #hunks                                       the diff's, in diff order
        #   #state                                       the review's, from Marks
        #   #hunk_keys                                   what a marking gesture names
        #
        # `#state` is the file's WHOLE-CHANGESET tri-state, and it is the same
        # under a partition as at whole scope. That is structural rather than a
        # coincidence relied on quietly: a strategy PARTITIONS files rather than
        # replicating them, so every hunk of a file sits under exactly one group.
        # Were attribution ever to become per-hunk, this row would have to stop
        # implying a per-group reading.
        #
        # `#chunked?` and `#rendered_lines` are forwarded so a renderer deciding
        # what a heading may claim never has to ask `#hunks` to find out whether
        # asking `#hunks` is affordable.
        FileRow = Data.define(:file, :state, :hunk_keys) do
          def path = file.path
          def old_path = file.old_path
          def new_path = file.new_path
          def status = file.status
          def binary? = file.binary?
          def hunks = file.hunks
          def chunked? = file.chunked?
          def rendered_lines = file.rendered_lines
        end

        # One group's row: what heads it, its share of the files as {FileRow}s,
        # and its line accounting.
        #
        # `#added`/`#deleted` are SCALARS and the accounting is asked of the
        # partition's DETAIL. That is a correction, not a style choice:
        # {Partition::ByCommit::Commit#numstat} is a frozen
        # `Array<Source::FileStat>` and answers neither, so a row that shadowed
        # the name with an aggregate would satisfy a test double and raise
        # `NoMethodError` on the real object. The detail is asked rather than the
        # hunks counted here because only the strategy knows whether it has an
        # accounting of its own.
        #
        # For a commit the figures are the commit's OWN numstat, summed -- not
        # its share of the cumulative diff, which is what `#files` is. Under
        # `--diff-merges=first-parent` a merge's figure is the entire side
        # branch, so a merge row legitimately outranks the commit that wrote the
        # code; {Partition::ByCommit}'s own doc records why that cannot be fixed
        # from inside these objects.
        #
        # It does NOT forward `#sha`, `#subject`, `#body` or `#numstat`: those are
        # a COMMIT's facts and a directory has none of them, so they live on
        # {#detail} where only the rows that have them answer.
        #
        # `#binaries` is forwarded and DRAWN BY NOBODY, so an all-binary group
        # still shows `+0 -0` and reads as "nothing changed" -- the misreading the
        # count exists to prevent. Said out loud rather than left implied.
        #
        # {#counted?} exists because {Partition::Undetailed} reads EVERY HUNK of
        # every file it is given: arithmetic over a diff, and a whole-group chunk
        # over a corpus, which is the cost the survey arm defers. So the row says
        # whether its figures are real, and a renderer asks that before asking
        # for them. The question is put to the FILES rather than to the detail,
        # the conservative direction on purpose: a detail with an accounting of
        # its own could answer over unread files, and this declines to. It costs
        # nothing today and means no renderer has to know which details are free.
        #
        # The hazard it leaves: `#added` still answers when `#counted?` is false,
        # by chunking. Nothing in `lib/` asks it that way, and making it raise
        # would put two meanings on one message for a caller that does not exist.
        #
        # {#rendered_lines} is what a heading claims INSTEAD: {Bounds::Size}' own
        # unit, summed off files that answer it without being chunked. An UPPER
        # BOUND over a corpus and exact over a diff, so whatever draws it must
        # not spell it as a count.
        PartitionRow = Data.define(:partition, :files) do
          def label = partition.label
          def detail = partition.detail
          def added = partition.detail.added(files)
          def deleted = partition.detail.deleted(files)
          def binaries = partition.detail.binaries(files)
          def counted? = files.all?(&:chunked?)
          def rendered_lines = files.sum(&:rendered_lines)
        end
      end
    end
  end
end
