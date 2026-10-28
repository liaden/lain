# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # `survived` is checked by inclusion rather than `presence:`, which would
      # silently reject `false` -- the same reasoning as {RequestSent}'s
      # `stream`.
      class Verdict < Declarative::Carrier
        NAMED = {
          why: "must explain the verdict"
        }.freeze

        attribute :digest
        attribute :survived
        attribute :score
        attribute :why, :lain_interned
        attribute :scale, default: nil
        attribute :refuter, default: nil
        validates :digest, presence: { message: "must name the finding it judged, got nil" }
        validates :survived, inclusion: { in: [true, false], message: "must be true or false, got %<value>s" }
        validates :why, presence: { message: "must explain the verdict, got nil" }

        validate :names_are_not_blank

        private

        # The interning cast turns false, [] and {} into present Strings, so blankness is judged on the raw value.
        def names_are_not_blank
          NAMED.each do |name, text|
            raw = @attributes[name.to_s].value_before_type_cast
            errors.add(name, "#{text}, got #{raw.inspect}") if raw.blank? && !errors.include?(name)
          end
        end
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
        super(**Carriers::Verdict.settle!(digest:, survived:, score: score.to_f.clamp(0.0, 1.0), why:,
                                          scale: scale&.to_s, refuter:))
      end
    end
  end
end
