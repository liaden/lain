# frozen_string_literal: true

module Lain
  module Review
    # What joined a survey already open, and the address the corpus has now.
    #
    # A survey ACCRETES: the human points at a subtree and then adds the file
    # they are reading to the round in progress. This is the only record other
    # than {ChangesetOpened} that puts a digest on the journal, and that is what
    # {Session#regenerated?} reads -- a widening is a deliberate act, so the
    # address it establishes must not read afterwards as the ground shifting
    # underneath the human.
    #
    # `paths` is what a resume rebuilds the wider corpus from, and nothing else
    # could: a mark carries a hunk key and nothing more ({HunkMarked}), and a key
    # is a digest no path reads back out of ({Hunk#key}).
    CorpusExtended = Data.define(:paths, :digest) do
      include Telemetry::Journalable
      include Guardable

      guard do
        attribute :paths
        attribute :digest
        validates :paths, presence: { message: Wire.refusal("must name what joined the corpus") }
        validates :digest, presence: { message: Wire.refusal("must address the widened corpus") }
        # `presence:` judges the LIST, so `[nil]` and `[""]` are both present
        # lists of nothing -- and this record is a WIRE boundary in both
        # directions: {Session::Replay} reads `paths` straight off a JSON line
        # and rebuilds through this constructor, so a null inside the list
        # replays into a path a resume would then walk. Hand-rolled for
        # {Telemetry::Guards::Switches}' reason: neither declarative validator
        # can say "no blank member" about a list.
        #
        # It reports the LIST rather than the offending member, because the
        # caller passed a list and a message naming `nil` alone reads as though
        # the whole argument were missing.
        validates_each :paths do |record, attribute, value|
          blank = value.to_a.any? { |path| path.nil? || path.to_s.empty? }
          record.errors.add(attribute, "must name only real paths, got #{value.inspect}") if blank
        end
      end

      # `Array()` rather than a type test: one path is the ordinary case the
      # add-to-survey gesture produces, and a record that made its caller wrap a
      # value it can read perfectly well is a refusal nobody learns anything
      # from. It also folds nil to the empty set the guard already refuses by
      # name, instead of a `NoMethodError` naming neither the class nor the
      # field.
      def initialize(paths:, digest:)
        values = { paths: Array(paths).map { |path| Wire.token(path) }.freeze, digest: Wire.token(digest) }
        self.class.check!(**values)

        super(**values)
      end
    end

    class CorpusExtended
      # See {ChangesetOpened::JOURNAL_TYPE}.
      JOURNAL_TYPE = "corpus_extended"
    end
  end
end
