# frozen_string_literal: true

module Lain
  module Compaction
    module Strategy
      # {Elide}'s attestation, narrowed to the tool observations: the contiguous
      # runs of tool-carrying messages collapse to the attested lines their
      # parent renders, and every conversational turn is left for the derivation
      # to retain verbatim, in place.
      #
      # The cheap half of the motivating pair -- elide on tool spans, summarize
      # on conversational ones, ONE derivation -- and the half that costs
      # nothing: no model call, no oracle, no I/O, exactly as its parent.
      #
      # == The predicate is asked, never spelled
      #
      # {ToolMessages.tool_runs} answers the selection and its complement,
      # {ToolMessages.conversational_runs}, is what the summarizing half asks.
      # ONE object owns the predicate because two spellings could agree on every
      # example anyone wrote and still drift on real input, and the moment they
      # did {Composed} would raise `Overlap` at proposal time, mid-turn, in a
      # live chat, for a reason neither strategy alone could see.
      #
      # == What it inherits
      #
      # Only {Base#propose_ranges} is overridden; `#blocks` is the parent's
      # concatenation of a per-message map, inherited byte-for-byte, so this
      # strategy moves the selection and nothing else. It adds no state, and its
      # parent's prepended {Freezable} still freezes it, so it is as pure as its
      # parent -- which its spec holds it to.
      #
      # The byte-identity property survives the narrower claim because the
      # narrowing is on the SELECTION while the homomorphism is a statement
      # about `#blocks`: where a boundary between two collapsed ranges falls
      # still cannot change the bytes answered. Only the span it claims is
      # smaller.
      class ElideToolObservations < Elide
        # The contiguous runs of tool-carrying messages, and nothing else. A
        # span with no tool message proposes nothing, which is how a strategy
        # declines a turn, and the derivation is then a no-op over it.
        def propose_ranges(messages, span:) = ToolMessages.tool_runs(messages, span:, owner: name)
      end
    end
  end
end
