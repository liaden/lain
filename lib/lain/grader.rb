# frozen_string_literal: true

module Lain
  # Scoring a run. A grader answers one question -- "how good was this?" -- and
  # every grader answers it in the SAME shape, a {Grade}, so the two kinds are
  # interchangeable to everything downstream: {Fixture} is a deterministic bundle
  # of hard assertions (no model), {Rubric} is an LLM judge in a separate context
  # window. Compare folds a Grade's `#score` into its distribution; speculative
  # branching argmaxes over it. The one non-negotiable is `#why`: a judgment you
  # cannot read the reason for is unusable, so both graders populate it.
  #
  # {Verified} is the one documented exception to the "same shape" rule: it
  # decorates a finding-producing grader and filters findings through an injected
  # refuter, so its subject is a set of findings rather than a single Grade.
  module Grader
    # A grader's verdict. `score` is a 0.0..1.0 Float, `pass` a boolean, and
    # `why` the human-readable reason -- always present, never blank. Frozen, so
    # two verdicts over the same subject are `==` and safe to share.
    Grade = Data.define(:score, :pass, :why) do
      def initialize(score:, why:, pass: nil)
        clamped = score.to_f.clamp(0.0, 1.0)
        raise ArgumentError, "a Grade must explain itself: #why is blank" if why.to_s.strip.empty?

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
require_relative "grader/refuter"
require_relative "grader/verified"
