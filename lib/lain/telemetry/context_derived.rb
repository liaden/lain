# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # `strategy` is required because "journal the edge, re-derive on resume"
      # is only exact if the edge names WHICH function was applied.
      #
      # Neither head digest is required, and both are legitimately nil: deriving
      # an empty timeline is a no-op that still records the edge, and a strategy
      # that drops every span answers the empty chain.
      class ContextDerived < Declarative::Carrier
        attribute :strategy
        attribute :spans
        attribute :cut
        validates :strategy, presence: { message: "must name the strategy that derived the chain, got nil" }
        validates :cut, inclusion: { in: %i[empty declined offered],
                                     message: "must be one of empty/declined/offered, got %<value>s" }
        validate :spans_name_their_endpoints

        private

        def spans_name_their_endpoints
          return if Array(spans).all? { |span| span.is_a?(Array) && span.size == 2 }

          errors.add(:spans, "must each be the [first, last] source digest of one collapsed range")
        end
      end
    end

    # One derivation edge: the source head a derived chain was computed from,
    # the derived head it produced, the strategy that produced it, and the
    # source-digest span of every range that collapsed.
    #
    # The DERIVED EVENTS are deliberately not here: "journal the edge,
    # re-derive the chain" is exact rather than approximate, because a
    # deterministic strategy is a pure function of the source and a model-backed
    # one answers through the already-journalled {Oracle::Recorded}. So this
    # record is what an audit needs to REBUILD the chain, not a copy of it.
    #
    # `spans` carries each collapsed range's ENDPOINTS rather than its whole
    # preimage: the interior is recoverable from the source chain `source_head`
    # already names, and a long range would otherwise write hundreds of digests
    # into one NDJSON line. The preimage itself is not lost -- it is on the
    # derived replacement event's `causal_parents`, where the fibre of the
    # collapse belongs.
    #
    # `cut` is the DIAGNOSIS, and it is the field that makes an empty `spans`
    # readable. A derivation that collapsed nothing has three causes and they
    # are not interchangeable:
    #
    #   `:empty`    -- the request was vacuous; `keep_last` covered the whole
    #     history, so nothing was ever droppable.
    #   `:declined` -- {Compaction::Boundary} found no legal cut but 0. Under
    #     the shipped cut rule this is unreachable through a DERIVATION: every
    #     declining shape is one {Context::Conversation} refuses before an edge
    #     is journalled. Kept because {Compaction::Boundary} can still answer it
    #     and a future cut rule may reach it again.
    #   `:offered`  -- a real span was handed to the strategy, so an empty
    #     `spans` is the STRATEGY's answer and nobody else's.
    #
    # All three journal the same empty spans and the same derived length;
    # without this field an audit cannot tell a boundary that never offered a
    # span from a strategy that declined one.
    #
    # `moved` is how far {Compaction::Boundary}'s backward search walked from
    # the naive `size - keep_last` split. READ IT ONLY ALONGSIDE `cut`. It is a
    # DISTANCE, and what a given distance MEANS depends on which of the three
    # cuts it sits beside:
    #
    #   `:offered`  -- the cut landed, and the distance says which neighbouring
    #     message forced it to land where it did. This is the only reading in
    #     which a small number is reassuring.
    #   `:declined` -- no cut landed at all, and the distance is merely how far
    #     the search got before giving up. It says nothing about a landing.
    #   `:empty`    -- no search was ever run, so it is 0 by vacancy.
    #
    # So a reader must never reconstruct the verdict from this number, and no
    # bound on it (whatever a given {Boundary} rule happens to make typical) is
    # a property of THIS record. `cut` is the verdict; this is the detail
    # underneath one.
    #
    # `keep_last` is here because RE-DERIVATION IS NOT REPRODUCIBLE WITHOUT IT:
    # the trailing window fixes where {Compaction::Boundary} cuts and therefore
    # which turns a strategy is ever offered, and it is not recoverable from
    # `spans`, whose endpoints say nothing about how many messages were retained
    # after a range. A reader re-deriving from this record has no other way to
    # learn it -- guessing wrong reads as drift, a confident, wrong "the chain
    # disagrees" from noise.
    #
    # Emitted by {Compaction::Derivation}. Nothing re-derives against it today
    # -- this subsystem's own drift-checking reader was unreachable and has
    # been deleted -- which makes the record write-only in practice, exactly
    # the default failure mode a field nobody consumes drifts into silently.
    ContextDerived = Data.define(:source_head, :derived_head, :strategy, :spans, :cut, :moved, :keep_last) do
      include Journalable

      def initialize(source_head:, derived_head:, strategy:, spans:, cut:, moved: 0, keep_last: nil)
        strategy = named(strategy)
        spans = Canonical.normalize(spans)
        cut = cut.to_sym
        Carriers::ContextDerived.check!(strategy:, spans:, cut:)

        super(source_head: source_head&.dup&.freeze, derived_head: derived_head&.dup&.freeze,
              strategy:, spans:, cut:, moved: Integer(moved), keep_last: keep_last&.then { |n| Integer(n) })
      end

      private

      # An anonymous class renders as `#<Class:0x00007f...>`, and that address
      # is fresh in every process. A reader resolving these records back to a
      # strategy by NAME would see a different address every run and call
      # that drift. Anonymous strategies are unauditable by name anyway, so
      # they collapse to one honest token rather than to a lie that looks
      # specific.
      def named(strategy)
        name = strategy.to_s

        -(name.match?(/\A#<Class:0x\h+>\z/) ? "(anonymous strategy)" : name)
      end
    end
  end
end
