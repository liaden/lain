# frozen_string_literal: true

module Lain
  module Compaction
    class DerivationAudit
      # Why two derivations over one source disagree, as a value over the two
      # edges and one registry answer.
      #
      # Its own object because "did these two derivations even ask the same
      # question?" is a different question from "which of them is wrong", and
      # answering the second without the first is how an audit comes to blame a
      # strategy for its own reader's `keep_last`.
      Diagnosis = Data.define(:recorded, :rebuilt, :purity) do
        def name
          return :window_disagrees if window?
          return :window_or_replay if ranges_differ? && purity == :impure
          return :derivation_bug unless recorded.offered?

          VERDICTS.fetch(purity)
        end

        private

        # Certain when the boundary itself moved. Otherwise only a strategy
        # DECLARED pure can carry the inference, and that is the whole of it: a
        # pure strategy is a function of the span it was offered, so if it
        # proposed different ranges over the same source it was offered a
        # different span, and only the window could have moved it.
        #
        # `== :pure`, never `!= :impure`. Registry silence is not a claim -- the
        # reason {DerivationAudit#purity} is three-valued at all -- and putting
        # `:unclaimed` on this side would tell a reader to check a `keep_last`
        # that may have been right, which is the same bug in the other
        # direction.
        def window? = boundary_moved? || (ranges_differ? && purity == :pure)

        # {Boundary}'s own two outputs, computed from the messages and
        # `keep_last` ALONE -- no strategy is consulted -- which is what makes
        # their disagreement proof about the window rather than a guess.
        def boundary_moved? = recorded.cut != rebuilt.cut || recorded.moved != rebuilt.moved

        def ranges_differ? = recorded.spans != rebuilt.spans
      end
      private_constant :Diagnosis
    end
  end
end
