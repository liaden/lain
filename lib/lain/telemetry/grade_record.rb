# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # A grade attestation must name the grader that produced it, the subject
      # it judged, say whether it passed as a real boolean (the same
      # `presence:`-cannot-reject-`false` reasoning as {Verdict}'s `survived`),
      # and explain itself.
      class GradeRecord < Declarative::Carrier
        attribute :grader, :lain_interned
        attribute :score
        attribute :pass
        attribute :why, :lain_interned
        attribute :subject_digest
        attribute :criteria_digest, default: nil
        attribute :arm, default: nil
        attribute :grader_digest, default: nil
        validates :grader, presence: { message: "must name the grader class, got nil" }
        validates :subject_digest, presence: { message: "must name the subject graded, got nil" }
        validates :pass, inclusion: { in: [true, false], message: "must be true or false, got %<value>s" }
        validates :why, presence: { message: "must explain the grade, got nil" }
      end
    end

    # The grader's attestation for the ORDINARY `#grade` every grader answers
    # with -- {Verdict} above is {Grader::Verified}'s second-pass verdict, which
    # is a different question.
    #
    # `grader` is the producing class's NAME, not the object: a self-describing
    # value, never a live reference. `subject_digest` addresses whatever was
    # graded, resolved by {Grader::Journaling#digest_for} in a pinned order that
    # never guesses -- and where nothing in that order applies, it raises
    # rather than silently addressing the subject's
    # `Object#inspect` identity. It is an attribution key, not a claim that two
    # equal digests graded byte-identical subjects across runs.
    #
    # `criteria_digest` is nil by default, since not every grader judges against
    # a parsed criteria doc. Its presence is what lets a later replay recover
    # "which criteria was this run graded against" from the record alone.
    # `arm` names the {Arm} a bench run was graded under; nil for a grade made
    # outside a comparison, and for journals written before the field existed.
    # `grader_digest` addresses the grader's `#identity` -- what changes its
    # verdict, which a class name alone cannot say; nil where the grader gives none.
    GradeRecord = Data.define(:grader, :score, :pass, :why, :subject_digest, :criteria_digest, :arm,
                              :grader_digest) do
      include Journalable

      # Built from a live {Grader::Grade} plus the attribution
      # {Grader::Journaling} supplies -- the grade's own fields ride straight
      # through unchanged.
      def self.from(grade, grader:, subject_digest:, criteria_digest: nil, grader_digest: nil)
        new(grader:, score: grade.score, pass: grade.pass?, why: grade.why, subject_digest:, criteria_digest:,
            grader_digest:)
      end

      def initialize(grader:, score:, pass:, why:, subject_digest:, criteria_digest: nil, arm: nil, grader_digest: nil)
        super(**Carriers::GradeRecord.settle!(grader:, score: score.to_f.clamp(0.0, 1.0), pass:, why:,
                                              subject_digest:, criteria_digest:, grader_digest:,
                                              arm: arm&.then { -_1.to_s }))
      end
    end
  end
end
