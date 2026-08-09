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
      # rather than of convenience. {Changeset::ChangedFile#status} is a DIFF
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
      class MarkedChangeset
        # The Symbol -> canonical-String projection of {Review::FILE_STATES}.
        # `Marks#states` answers Symbols; every glyph table, every journaled
        # record and every wire form spells the state as a String, and
        # {Review::FILE_STATES} is where that spelling is decided. Derived
        # rather than restated, and read through `fetch`, so a state Marks
        # invents that the vocabulary does not know raises here instead of
        # rendering blank.
        STATES = Review::FILE_STATES.to_h { |name| [name.to_sym, name] }.freeze

        # What a file with NO hunks shows: a binary change, a mode-only change,
        # a pure rename. {Marks#states} never names such a file -- it groups
        # hunks, and there are none -- so this is not a state Marks refused to
        # answer, it is the honest reading of the question it was never asked:
        # no hunk of this file is marked reviewed, because it has none.
        #
        # It can never become `reviewed`, and that is disclosed rather than
        # papered over. It does not wedge an approve: {Verdict::Policy::EveryHunk}
        # judges HUNKS, and a file with none has no unreviewed hunk to block
        # with. The alternative -- calling it `reviewed` -- would claim a review
        # nobody did.
        HUNKLESS = STATES.fetch(:unreviewed)

        # Frozen and shared rather than a fresh `[]` per hunkless file.
        NO_KEYS = [].freeze

        # `path => the review keys of that path's hunks`, by exactly the rule
        # {Marks} applies to the same changeset (`group_by(&:path)`, then
        # `Hunk.keys` over one file's hunks at a time -- the batch is a
        # precondition of the key scheme, not a convenience). This is the ONE
        # place that grouping is written for the session tier: {Session} reads
        # it for its own key guard and for the changeset digest, and passes the
        # result in here so a whole-changeset blake3 pass happens once per
        # render rather than three times.
        #
        # A spec pins these keys equal to the ones {Marks} judges, because a row
        # that handed a marking gesture a differently-derived key would mark
        # something the tri-state never reads.
        #
        # @param changeset [#hunks]
        # @return [Hash{String => Array<String>}]
        def self.keys_by_path(changeset)
          changeset.hunks.group_by(&:path).transform_values { |hunks| Hunk.keys(hunks) }.freeze
        end

        # The commit walk is the DEFAULT strategy rather than the only one, so
        # a caller that has not chosen still gets the grouping the review model
        # has always had. Naming one here is what keeps {Session#marked} a
        # no-argument message until a later card gives the session a scope to
        # resolve.
        WALK = Review::Partition::STRATEGIES.fetch(:commits)

        # @param changeset [Review::Changeset] the whole, unfiltered changeset
        # @param marks [Review::Marks] recorded against the same base
        # @param keys_by_path [Hash{String => Array<String>}] {keys_by_path}'s
        #   answer, passed in when the caller already computed it
        # @param strategy [Review::Partition::Strategy] how the files are grouped
        # @return [MarkedChangeset]
        # @raise [Marks::BaseMismatch] if the marks name another base
        def self.of(changeset, marks, keys_by_path: keys_by_path(changeset), strategy: WALK)
          states = marks.states(changeset)
          # Keyed by the ChangedFile itself, not by its path: a Partition holds
          # the very same value objects, so the lookup is exact and two files
          # that somehow shared a path could not silently collapse into one row.
          rows = changeset.files.to_h { |file| [file, row(file, states, keys_by_path)] }
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

        def self.row(file, states, keys_by_path)
          FileRow.new(file:, state: state_of(file, states),
                      hunk_keys: keys_by_path.fetch(file.path, NO_KEYS))
        end
        private_class_method :row

        # An absent path is the hunkless case ({HUNKLESS} says why); a path
        # {Marks} DID name is looked up in the vocabulary, so a tri-state the
        # vocabulary does not know raises through `STATES.fetch` instead of
        # rendering blank. There is a spec for that raise.
        #
        # The shape this must not take is `STATES.fetch(states[path], HUNKLESS)`,
        # which swallows that second case as a hunkless file -- an unknown
        # tri-state would then render `[ ]` on a file somebody had reviewed. An
        # earlier version of this comment claimed the `key?`/`fetch` PAIR was
        # what preserved the distinction. It is not -- and the form that comment
        # named as equivalent was wrong too, which is worth an extra sentence
        # rather than a third try. A bare `states.fetch(path) { HUNKLESS }` is
        # RED: the block's value falls straight into `STATES.fetch`, `HUNKLESS`
        # is a String, `STATES`' keys are Symbols, and it raises. The form that
        # IS equivalent is `STATES.fetch(states.fetch(file.path) { return
        # HUNKLESS })`, and the `return` is what makes it so -- it leaves the
        # method before the vocabulary lookup can happen. Two lines are kept
        # over that for reading alone, which is a taste and is labelled as one.
        def self.state_of(file, states)
          return HUNKLESS unless states.key?(file.path)

          STATES.fetch(states.fetch(file.path))
        end
        private_class_method :state_of

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
        FileRow = Data.define(:file, :state, :hunk_keys) do
          def path = file.path
          def old_path = file.old_path
          def new_path = file.new_path
          def status = file.status
          def binary? = file.binary?
          def hunks = file.hunks
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
        PartitionRow = Data.define(:partition, :files) do
          def label = partition.label
          def detail = partition.detail
          def added = partition.detail.added(files)
          def deleted = partition.detail.deleted(files)
          def binaries = partition.detail.binaries(files)
        end
      end
    end
  end
end
