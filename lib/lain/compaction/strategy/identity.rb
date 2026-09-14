# frozen_string_literal: true

module Lain
  module Compaction
    module Strategy
      # The Null strategy: it collapses nothing, so a derivation over it
      # produces a chain that renders byte-identically to its source. That is
      # the monoid unit law rather than an arbitrary check, and it is what makes
      # this the control arm every comparison of compaction policies needs.
      #
      # A strategy and not a `nil` the derivation branches on -- the same role
      # {Sink::Null} and {Context::Identity} play.
      #
      # Its spec holds {#propose_ranges} to the purity laws and not `#blocks`,
      # because those are different claims and this object makes only one: it
      # proposes no ranges, so it is never asked to collapse one, and inheriting
      # the loud refusal is the honest answer to a question it cannot be asked.
      class Identity < Base
        # It holds nothing, so the whole of its construction is the freeze. Not
        # on {Base}, for the reason {Elide} states.
        prepend Freezable

        NO_RANGES = [].freeze

        # Anonymous keywords rather than `span:`: this answers the same thing
        # whatever span it is offered, and naming an argument it does not read
        # would be the only place in the file suggesting otherwise.
        def propose_ranges(_messages, **) = NO_RANGES
      end
    end
  end
end
