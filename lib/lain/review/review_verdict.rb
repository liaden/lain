# frozen_string_literal: true

module Lain
  module Review
    # The judgement, against the changeset it judged.
    #
    # `changeset_digest` is required rather than implied by position in the
    # journal: a verdict read back without it is a judgement of nothing, and the
    # journal is shared by every review this session ran.
    #
    # Admissibility -- whether an approve may stand over unreviewed hunks -- is
    # NOT decided here. {Review::Verdict::Policy} owns it, because a rule you
    # cannot swap is a rule you cannot experiment with on a bench. This record
    # judges the vocabulary only.
    ReviewVerdict = Data.define(:verdict, :changeset_digest) do
      include Telemetry::Journalable
      include Declarative

      declare do
        attribute :verdict
        attribute :changeset_digest
        # The message names the DECISION rather than the set, because the two
        # call for opposite responses. An agent reading "must be one of approve"
        # concludes the set is too short and widens it; the correct move is to
        # stop, because choosing the vocabulary is not this chunk's to do.
        validates :verdict,
                  inclusion: { in: VERDICTS,
                               message: Wire.refusal(
                                 "must be #{VERDICTS.join("/")} -- the verdict vocabulary is research open " \
                                 "question 3 and unsettled, so this chunk journals only " \
                                 "#{VERDICTS.join("/")}; a second value is a decision taken in " \
                                 "Review::VERDICTS with that question settled, not here"
                               ) }
        validates :changeset_digest, presence: { message: Wire.refusal("must address the changeset it judged") }
      end

      def initialize(verdict:, changeset_digest:)
        values = { verdict: Wire.token(verdict), changeset_digest: Wire.token(changeset_digest) }
        self.class.check!(**values)

        super(**values)
      end
    end

    class ReviewVerdict
      # See {ChangesetOpened::JOURNAL_TYPE}.
      JOURNAL_TYPE = "review_verdict"
    end
  end
end
