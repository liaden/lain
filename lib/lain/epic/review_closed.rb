# frozen_string_literal: true

module Lain
  module Epic
    # The human handed the document back, journaled by {Review#settle} before the
    # baton is released and before any fiber is woken, so a reader woken by the
    # delta can trust the record is already there.
    #
    # It carries what {Intake::Delta} reports, in the delta's own two registers.
    # The BYTE register is `written_digest` and `disk_digest`: equal means the
    # bytes never moved. The MEANING register is `changes`, the account's changed
    # kinds and their ids, exact and unhedged -- an id under `removed` LEFT.
    #
    # `lossy` is neither register and must not be read as one. It says only that
    # the disk came back at less than half the bytes lain wrote -- a suspicion of
    # truncation that a legitimate mass edit trips too. It is emphatically NOT
    # "issues were deleted"; that is `changes["removed"]`.
    #
    # `error` and `error_kind` are what stop an empty `changes` from meaning two
    # different things: with an error present, nothing was COMPARED, which is a
    # different fact from "the two sides agreed". An `error_kind` of
    # `Lain::Epic::Review::Unrecoverable` changes how the rest of the line reads
    # and a reader joining these records has no other way to know it -- lain
    # restarted while the human held the document, so the bytes it wrote are gone
    # and NOTHING was compared. The file is not corrupt and a surface must not
    # say it is; `lossy` is `false` there because the ratio was never MEASURED,
    # not because truncation was ruled out.
    #
    # The summary is string-keyed because it round-trips through JSON and a
    # record read back has to equal the one written -- {Account#changes} answers
    # Symbol keys, and Symbol and String keys are two spellings of one field.
    ReviewClosed = Data.define(:epic_slug, :path, :generation, :written_digest, :disk_digest, :changes,
                               :lossy, :error, :error_kind) do
      include Telemetry::Journalable

      def initialize(epic_slug:, path:, generation:, written_digest:, disk_digest:, changes:, lossy:,
                     error: nil, error_kind: nil)
        claim = ReviewClaim.interned(epic_slug:, path:, generation:, written_digest:)
        disk_digest = -disk_digest.to_s
        # `&&=`, so an absent error stays absent rather than interning to "" --
        # {Intake::Delta} reads a present error as "nothing was compared", and a
        # blank one would say that about every settlement that went fine.
        error &&= -error.to_s
        error_kind &&= -error_kind.to_s
        Contracts::ReviewClosed.check!(**claim, disk_digest:, changes:, lossy:, error:, error_kind:)

        # `changes` is normalized AFTER its contract, the one departure from
        # {ReviewClaim}'s order and a forced one: the contract asks whether the
        # summary is a Hash at all, and the normalization cannot run on a value
        # that is not one. It preserves every key, so the contract still judges
        # what gets stored.
        super(**claim, disk_digest:, changes: summarized(changes), lossy:, error:, error_kind:)
      end

      private

      # Every level frozen: `Data` freezes the instance and nothing else, so a
      # nested Array left mutable would cost this value `Ractor.shareable?` --
      # the mechanical statement that a record holds no reachable mutable state.
      def summarized(changes)
        changes.to_h { |kind, ids| [-kind.to_s, ids.map { |id| -id.to_s }.freeze] }.freeze
      end
    end

    class ReviewClosed
      # See {IssueTransition::JOURNAL_TYPE}.
      JOURNAL_TYPE = "review_closed"
    end
  end
end
