# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # `survived` is checked by inclusion rather than `presence:`, which would
      # silently reject `false` -- the same reasoning as {RequestSent}'s
      # `stream`.
      class Verdict < Declarative::Carrier
        attribute :digest
        attribute :survived
        attribute :why
        validates :digest, presence: { message: "must name the finding it judged, got nil" }
        validates :survived, inclusion: { in: [true, false], message: "must be true or false, got %<value>s" }
        validates :why, presence: { message: "must explain the verdict, got nil" }
      end
    end

    # A finding's refutation verdict ({Grader::Verified}'s second pass).
    # `digest` is the finding's OWN content address rather than an id it does
    # not carry the way a tool call carries a `tool_use_id` -- it is the join
    # key {Grader::Refuter::Recorded.from_journal} looks the verdict back up by.
    # `survived` is the refuter's thresholded pass/fail, since a continuous
    # Rubric score alone is not a verdict; `score` keeps the raw 0..1
    # confidence alongside.
    # `scale` names the {Grader::Rubric::Scale} the judge answered on; nil in a record made before
    # scales existed, which {Bench::JudgeScale::Source} reads as unattributed rather than as unit.
    # `refuter` is the 1-based index of the refuter that judged, set when several judge one finding; nil
    # in a record made by a lone refuter or before indexes existed.
    Verdict = Data.define(:digest, :survived, :score, :why, :scale, :refuter) do
      include Journalable

      def initialize(digest:, survived:, score:, why:, scale: nil, refuter: nil)
        Carriers::Verdict.check!(digest:, survived:, why:)

        super(digest: digest.dup.freeze, survived:, score: score.to_f.clamp(0.0, 1.0), why: -why.to_s,
              scale: scale&.to_s&.freeze, refuter:)
      end
    end
  end
end
