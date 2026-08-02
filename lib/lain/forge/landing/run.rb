# frozen_string_literal: true

module Lain
  module Forge
    class Landing
      # The fold's state as it moves down the {Plan}, in TWO shapes rather than
      # one carrying a stopped flag.
      #
      # A {Stopped} run answers every later step with itself, so the sequence
      # short-circuits by polymorphism: `inject` walks the whole plan and the
      # steps after a refusal simply do nothing. That is what keeps this file
      # free of a `break` and free of a return threaded back through two
      # methods -- {Gh::Poll#take}'s inject, same shape and same reason.
      Running = Data.define(:number, :performed) do
        # @param number [Integer, nil] the pull request this landing is about,
        #   once a step has one
        # @param performed [Boolean] whether this run has actually CHANGED
        #   anything yet, as opposed to finding it already in place
        def initialize(number: nil, performed: false) = super

        def advance(step, evidence) = step.advance(self, evidence)

        # A step that reached the world reports what it found there: `observed`
        # false means it performed the effect, and that is what flips this run
        # out of its "changed nothing" state for good.
        def after(answer) = with(performed: performed || !answer.observed?)

        # S3: `observed` is the tier's honesty flag -- true means the effect was
        # found ALREADY in place rather than performed ({Intent}'s doc). A resume
        # that performed three effects and then claimed to have observed them was
        # the old code's word for "I did not have to do anything", which is the
        # opposite of what it means.
        def answer = Gh::Answer.new(ok: true, observed: !performed, detail: { "value" => number })
      end

      # The fold, refused. Carries the answer that refused it, unchanged, so the
      # reason a human reads is the one the step actually produced.
      Stopped = Data.define(:answer) do
        def advance(_step, _evidence) = self
      end
    end
  end
end
