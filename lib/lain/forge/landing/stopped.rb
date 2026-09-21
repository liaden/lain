# frozen_string_literal: true

module Lain
  module Forge
    class Landing
      # The fold, refused -- the second of the two shapes {Running} names.
      #
      # A Stopped run answers every later step with itself, so the sequence
      # short-circuits by polymorphism: `inject` walks the whole plan and the
      # steps after a refusal simply do nothing. That is what keeps the fold
      # free of a `break` and free of a return threaded back through two
      # methods -- {Gh::Poll#take}'s inject, same shape and same reason.
      #
      # Carries the answer that refused it, unchanged, so the reason a human
      # reads is the one the step actually produced.
      Stopped = Data.define(:answer) do
        def advance(_step, _evidence) = self
      end
    end
  end
end
