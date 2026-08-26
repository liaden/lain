# frozen_string_literal: true

module Lain
  # Scoring a run. Every grader answers "how good was this?" in the SAME shape,
  # a {Grade}, so the kinds are interchangeable downstream: {Fixture} is a
  # deterministic bundle of hard assertions with no model, {Rubric} is an LLM
  # judge in a separate context window.
  #
  # {Verified} is the one exception to that rule: it decorates a
  # finding-producing grader and filters findings through an injected refuter,
  # so its subject is a set of findings rather than a single Grade.
  module Grader
    # `score` is a 0.0..1.0 Float, `pass` a boolean, `why` the human-readable
    # reason. Frozen, so two verdicts over the same subject are `==`.
    Grade = Data.define(:score, :pass, :why) do
      include Declarative

      # A judgment nobody can read the reason for is unusable, so `why` is the
      # one field that cannot be left empty.
      #
      # Hand-written over `#strip`, and NOT `presence:`: ActiveModel's `blank?`
      # matches Unicode whitespace, `#strip` does not, and a lone U+00A0 `why`
      # has always been accepted here. Widening that is a new refusal, not a
      # migration -- {Blankness} is where this codebase reaches for the wider
      # rule, deliberately and by name.
      declare do
        attribute :why
        validate :explains_the_grade

        private

        def explains_the_grade
          errors.add(:why, "must explain the grade, got blank") if why.to_s.strip.empty?
        end
      end

      # `score.to_f` stays AHEAD of the check, where it has always been: a
      # `score` that cannot answer `#to_f` raises NoMethodError before `why` is
      # ever judged, and reordering would quietly turn that into an ArgumentError.
      def initialize(score:, why:, pass: nil)
        clamped = score.to_f.clamp(0.0, 1.0)
        self.class.check!(why:)

        super(score: clamped, pass: pass.nil? ? clamped >= 1.0 : pass, why: -why.to_s)
      end

      def pass? = pass
    end
  end
end

require_relative "grader/fixture"
require_relative "grader/recall"
require_relative "grader/rubric"
require_relative "grader/tool_call_index"
require_relative "grader/tool_steering"
require_relative "grader/frustration_repair"
require_relative "grader/refuter"
require_relative "grader/verified"
require_relative "grader/test_harness"
require_relative "grader/journaling"
