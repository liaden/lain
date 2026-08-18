# frozen_string_literal: true

module Lain
  module Compaction
    module Strategy
      # {Elide}'s attestation, narrowed to the tool observations: the contiguous
      # runs of tool-carrying messages collapse to the attested lines their
      # parent renders, and every conversational turn is left for the derivation
      # to retain verbatim, in place.
      #
      # This is the cheap half of the motivating pair -- elide on tool spans,
      # summarize on conversational ones, ONE derivation -- and it is the half
      # that costs nothing: no model call, no oracle, no I/O, exactly as its
      # parent. It was proved out anonymously first, as
      # `ComposedFixtures#elide_on_tools` in
      # spec/lain/compaction/strategy/composed_spec.rb, and this is that
      # prototype promoted to a name.
      #
      # == The predicate is asked, never spelled
      #
      # {ToolMessages.tool_runs} answers the selection, and the complement --
      # {ToolMessages.conversational_runs} -- is what the summarizing half asks.
      # ONE object owns the predicate because two spellings could agree on every
      # example anyone wrote and still drift on real input, and the moment they
      # did, {Composed} would raise `Overlap` at proposal time, mid-turn, in a
      # live chat, for a reason neither strategy alone could see. So the
      # selection here is a call, not a body.
      #
      # == What it inherits, and the one claim it has to say again
      #
      # Only {Base#propose_ranges} is overridden. `#blocks` is the parent's
      # generated per-message map, inherited byte-for-byte, so what a claimed
      # run collapses TO is unchanged -- this strategy moves the selection and
      # nothing else.
      #
      # That splits the parent's two declarations (`elide.rb:97-98`), because
      # the two structures are classified by different mechanisms and only one
      # of them survives inheritance:
      #
      # - **Elementwise is structural and is inherited.** The generated method
      #   IS the concatenation, so `is_a?(Algebra::Elementwise)` is the
      #   classification ({Algebra::Elementwise}'s own doc, and {Base}'s note
      #   that there is "no second declaration to fall out of sync with it").
      #   Re-declaring would regenerate an identical `#blocks` onto this class
      #   for no behavioural difference, so it is left alone.
      # - **Purity is registry-keyed on the EXACT class and is NOT inherited.**
      #   {DerivationAudit#purity} says so in as many words and depends on it:
      #   an undeclared subclass of a pure strategy audits as
      #   `:unclaimed_purity`, so a drift against it "cannot be attributed"
      #   rather than being named the `:derivation_bug` it would be. Losing that
      #   on the control arm is the diagnosis the audit exists to give, so the
      #   claim is restated below. It is honest to restate: this class adds no
      #   state, and its parent's prepended {Freezable} still freezes it, which
      #   is the shareability proxy the purity laws read.
      #
      # == Why the byte-identity property survives the narrower claim
      #
      # Because the narrowing is on the SELECTION and the homomorphism is a
      # statement about `#blocks`. Where the boundary between two collapsed
      # ranges falls still cannot change the bytes answered -- that is a
      # property of the per-message map, which is untouched -- so this remains
      # a control arm, measuring the policy under test and never the cut points.
      # It is only the span it claims that is smaller.
      class ElideToolObservations < Elide
        # The contiguous runs of tool-carrying messages, and nothing else. A
        # span with no tool message proposes nothing, which is how a strategy
        # declines a turn, and the derivation is then a no-op over it.
        def propose_ranges(messages, span:) = ToolMessages.tool_runs(messages, span:, owner: name)

        # Said again rather than inherited: see the class doc. Not accompanied
        # by an elementwise declaration, which would regenerate the parent's
        # `#blocks` onto this class to no effect.
        pure on: :blocks
      end
    end
  end
end
