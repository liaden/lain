# frozen_string_literal: true

module Lain
  module Compaction
    module Strategy
      # The Null strategy: it collapses nothing, so a derivation over it
      # produces a chain that renders byte-identically to its source. That is
      # the monoid unit law rather than an arbitrary check, and it is what makes
      # this the control arm every comparison of compaction policies needs.
      #
      # It is a strategy and not a `nil` the derivation branches on -- the same
      # role {Sink::Null} and {Context::Identity} play. Nobody writes
      # `if strategy`.
      #
      # Purity is declared on {#propose_ranges} and not on `#blocks`, because
      # those are different claims and this object only makes one of them: it
      # proposes no ranges, so it is never asked to collapse one, and inheriting
      # the loud refusal is the honest answer to a question it cannot be asked in
      # the first place.
      class Identity < Base
        # It holds nothing, so the whole of its construction is the freeze every
        # value object repeats (see {Lain::Freezable}). Not on {Base}, for the
        # reason {Elide} states.
        prepend Freezable

        include Algebra::Pure

        NO_RANGES = [].freeze

        # Anonymous keywords rather than `span:`: this answers the same thing
        # whatever span it is offered, and naming an argument it does not read
        # would be the only place in the file suggesting otherwise.
        def propose_ranges(_messages, **) = NO_RANGES

        pure on: :propose_ranges
      end
    end
  end
end
