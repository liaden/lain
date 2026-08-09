# frozen_string_literal: true

module Lain
  module Review
    class Session
      MarkedChangeset = Data.define(:files, :partitions, :base_ref, :head_ref)

      # A changeset's STRUCTURE joined to its marks' TRI-STATE -- the one object
      # that can answer both, and the argument every {Review::Surface} means by
      # `present`'s `changeset` (see {Surface}'s class doc for that duck).
      #
      # Neither half can answer it alone, and that is a matter of ownership
      # rather than of convenience. {Source::ChangedFile#status} is a DIFF
      # fact (added/deleted/modified/renamed) and deliberately does not answer
      # `#state`; {Marks} derives a REVIEW fact per path and has no notion of
      # files, commits or hunk order. Putting both meanings on one message name
      # is how a table renders the wrong glyph with nothing failing, so the join
      # is made HERE, once, by the session that holds both.
      #
      # == What it answers
      #
      #   #files       -> Array<FileRow>       every file, in the diff's own order
      #   #partitions  -> Array<PartitionRow>  the groups, files partitioned
      #   #base_ref / #head_ref                the refs every anchor rests on
      #
      # It does NOT answer `#hunks`. {Marks#reconcile} reads `#base_ref` and
      # `#hunks` together, and it must only ever be handed the whole, unfiltered
      # {Changeset} -- the session keeps that one and hands this one to
      # renderers, so a view can never be mistaken for the thing the pruner
      # takes. {Review::Partition} withholds the same pair for the same
      # reason, and {PartitionRow} does not restore it.
      #
      # Rows are built ONCE and shared: the {FileRow} under a partition is the
      # same object as the one at whole scope, so a re-render cannot show two
      # different states for one file.
      #
      # == It costs only what has been read
      #
      # The derivation is per PATH, and a file that has not been chunked is
      # never asked about ({.of}). That is what makes a survey affordable to
      # present: a corpus of fifty files nobody has opened draws its whole table
      # having read none of them, where the previous all-or-nothing shortcut
      # read all fifty as soon as one mark existed.
      #
      # The hazard that buys is worth naming, because it is this class's own
      # warning turned on itself: "not read yet" and "read, and it has no hunk"
      # both render {HUNKLESS}, and both are ABSENT from the key table. Letting
      # the table answer both would put two meanings on one lookup -- so the
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

        # What a file with NO hunks shows: a binary change, a mode-only change,
        # a pure rename -- and, since the survey arm, a file nothing has read
        # yet. {Marks} never derives such a file from a mark, because it has no
        # key to derive one from, so this is not a state Marks refused to
        # answer: it is the honest reading of the question it was never asked.
        # No hunk of this file is marked reviewed, because it has none here.
        #
        # The two cases stay TOLD APART where it matters even though they render
        # alike -- {.keys_of} refuses a read file the key table does not name,
        # rather than letting an absent entry mean either thing.
        #
        # It can never become `reviewed`, and that is disclosed rather than
        # papered over. It does not wedge an approve: {Verdict::Policy::EveryHunk}
        # judges HUNKS, and a file with none has no unreviewed hunk to block
        # with. The alternative -- calling it `reviewed` -- would claim a review
        # nobody did.
        HUNKLESS = STATES.fetch(:unreviewed)

        # Frozen and shared rather than a fresh `[]` per hunkless file.
        NO_KEYS = [].freeze

        # `path => the review keys of that path's hunks`, over the files that
        # have been READ, by exactly the rule {Marks} applies to the same hunks
        # (`group_by(&:path)`, then `Hunk.keys` over one file's hunks at a
        # time -- the batch is a precondition of the key scheme, not a
        # convenience). This is the ONE place that grouping is written for the
        # session tier.
        #
        # == It names what has been read, not what exists
        #
        # A {LazyFile} nobody has chunked has no keys to name, and asking it for
        # some is the whole cost a survey exists to defer -- so the table grows
        # with what a session has actually looked at. For a DIFF nothing moves:
        # every {Source::ChangedFile} is read the moment the parser produces it,
        # so `files.select(&:chunked?).flat_map(&:hunks)` is `changeset.hunks`
        # exactly and the table is the one it has always been.
        #
        # The select goes over FILES rather than the changeset's hunks because
        # `Changeset#hunks` is `files.flat_map(&:hunks)` -- reading it to find
        # out what has been read would chunk everything to answer.
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

        # The join, derived one path at a time, so a presentation costs only
        # what has been read.
        #
        # Each file answers whether it has been chunked; only the ones that have
        # reach {Marks}, and they reach it through {Marks#state_of}, which takes
        # that path's keys and reads nothing else. A survey that has chunked
        # nothing therefore derives nothing and opens no file, at the one place
        # every render passes through ({Session#present} rebuilds this on
        # purpose, never memoized).
        #
        # An unread file is {HUNKLESS} for exactly the reason a binary one is:
        # no hunk of it is marked reviewed, because none of it is here yet. That
        # is the honest answer to a question nobody has asked, not a guess -- and
        # the only state it can be, since a mark names a hunk key and this file
        # has produced none.
        #
        # This replaced an all-or-nothing shortcut on the table's emptiness, and
        # the measurement is worth keeping: an EMPTY table skipped the
        # derivation, a table naming one path of fifty took it, and
        # {Marks#states} then walked all fifty. 0 keys chunked 0 of 50 files, 1
        # key chunked 50 of 50 -- which is the partial table every corpus
        # session actually hands over.
        #
        # A diff's files are all read, so this is the same derivation it has
        # always been, arrived at the same way.
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
              base_ref: changeset.base_ref, head_ref: changeset.head_ref)
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
        # question now, so an absent entry can only mean one thing -- and a read
        # file with hunks that the table does not name is a table disagreeing
        # with the changeset, which is a wrong glyph waiting to be drawn.
        #
        # A read file with NO hunks is legitimately absent, for {HUNKLESS}'
        # original reason: a binary change, a mode-only change, a pure rename.
        # Reading `#hunks` to tell the two apart is free here and only here --
        # the file has already been chunked, or the guard above returned.
        def self.keys_of(file, keys_by_path)
          return NO_KEYS if file.hunks.empty?

          keys_by_path.fetch(file.path) do
            raise KeyError, "#{file.path.inspect} has hunks, and the key table handed to this join does not " \
                            "name it -- deriving its state from an empty batch would show a file somebody " \
                            "reviewed as unreviewed, with nothing failing"
          end
        end
        private_class_method :keys_of

        # One file's row: the diff's own facts, forwarded unchanged, plus the
        # one fact the diff cannot know.
        #
        #   #path #old_path #new_path #status #binary?   the diff's, from ChangedFile
        #   #hunks                                       the diff's, in diff order
        #   #state                                       the review's, from Marks
        #   #hunk_keys                                   what a marking gesture names
        #
        # `#state` is the file's WHOLE-CHANGESET tri-state, and it is the same
        # number under a partition as at whole scope. That is structural, not a
        # coincidence to be relied on quietly: a {Review::Partition::Strategy}
        # PARTITIONS files rather than replicating them, so every hunk of a file
        # sits under exactly one group and the two derivations cannot differ.
        # Were attribution ever to become per-hunk, this row would have to stop
        # implying a per-group reading.
        # `#chunked?` and `#rendered_lines` are forwarded so that a renderer
        # deciding what a heading may claim never has to reach past the row to
        # the file -- and, more to the point, never has to ask `#hunks` to find
        # out whether asking `#hunks` is affordable.
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
        # `NoMethodError` on the real object. The detail is asked rather than
        # the hunks counted here because only the strategy knows whether it has
        # an accounting of its own -- {Partition::Undetailed} reads the hunks,
        # which is the honest answer when it does not.
        #
        # == What these figures may and may not be read as
        #
        # For a commit they are the commit's OWN numstat, summed -- not its
        # share of the cumulative diff, which is what `#files` is. Under
        # `--diff-merges=first-parent` a merge's figure is the entire side
        # branch, so a merge row legitimately outranks the commit that actually
        # wrote the code; {Partition::ByCommit}'s own doc records why that
        # cannot be fixed from inside these objects (it needs a parent count
        # {Source::Commit} does not carry). Forwarding the commit's own numbers
        # unchanged is the option that does not make it worse.
        #
        # It does NOT forward `#sha`, `#subject`, `#body` or `#numstat`. Those
        # are a COMMIT's facts and a directory has none of them, so they live on
        # {#detail} where only the rows that have them answer -- which is the
        # whole reason the partition axis stopped being the commit axis.
        #
        # `#binaries` is forwarded and DRAWN BY NOBODY -- neither surface
        # renders it, so an all-binary group still shows `+0 -0` and reads as
        # "nothing changed", which is the misreading the count exists to
        # prevent. Said out loud rather than left implied by a comment claiming
        # the defect is closed; rendering it is a card nobody has written.
        #
        # == What {#counted?} exists for, and the one hazard it leaves
        #
        # {Partition::Undetailed} -- the accounting of every strategy that has
        # none of its own, which is every strategy a survey can be grouped by --
        # reads EVERY HUNK of every file it is given. Over a diff that is
        # arithmetic on hunks a parser already produced; over a corpus it chunks
        # the whole group, which is the cost the survey arm exists to defer. So
        # the row says whether its figures are real, and a renderer asks that
        # before it asks for them.
        #
        # The question is put to the FILES rather than to the detail, and that
        # is the conservative direction on purpose: a detail with an accounting
        # of its own ({Partition::ByCommit}, whose figures are git's numstat)
        # could answer over unread files, and this declines to. It costs
        # nothing today -- {Partition::ByCommit} refuses a source with no walk,
        # so a corpus is never grouped by it, and every file of a diff is read
        # -- and it means no renderer has to know which details are free.
        #
        # The hazard is that `#added` still answers when `#counted?` is false,
        # by chunking. Nothing in `lib/` asks it that way, and making it raise
        # would put two meanings on one message for the sake of a caller that
        # does not exist; the guard is one `#counted?` away and named here.
        #
        # {#rendered_lines} is what a heading claims INSTEAD: {Bounds::Size}'
        # own unit, summed off files that answer it without being chunked. It
        # is an UPPER BOUND over a corpus ({Source::Corpus}'s own docstring says
        # why it must over-measure) and exact over a diff, so whatever draws it
        # must not spell it as a count.
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
