# frozen_string_literal: true

module Lain
  module Review
    # A round let go with no judgement. It carries NO verdict, and that is the
    # point of it being its own record: a close journaled as a verdict would be
    # read by every policy and fold as a decision the human never made. The
    # digest joins it to the round, as {ReviewVerdict}'s does.
    ChangesetClosed = Data.define(:changeset_digest, :closed_by) do
      include Telemetry::Journalable
      include Declarative

      declare do
        attribute :changeset_digest
        attribute :closed_by
        validates :changeset_digest, presence: { message: Wire.refusal("must address the round it closed") }
        validates :closed_by, inclusion: { in: CLOSED_BY,
                                           message: Wire.refusal("must be one of #{CLOSED_BY.join("/")}") }
      end

      def initialize(changeset_digest:, closed_by:)
        values = { changeset_digest: Wire.token(changeset_digest), closed_by: Wire.token(closed_by) }
        self.class.check!(**values)

        super(**values)
      end
    end

    class ChangesetClosed
      # See {ChangesetOpened::JOURNAL_TYPE}.
      JOURNAL_TYPE = "changeset_closed"

      # {Review::CLOSED_BY}'s two members, named where a caller spells one. The
      # record's own guard refuses either spelling drifting out of that set.
      BY_HUMAN = "human"
      BY_REFUSAL = "refusal"
    end
  end
end
