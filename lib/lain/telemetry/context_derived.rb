# frozen_string_literal: true

module Lain
  module Telemetry
    module Guards
      # A derivation record must name the strategy that derived the chain --
      # "journal the edge, re-derive on resume" is only exact if the edge names
      # WHICH function was applied -- must land on one of the three answers to
      # "what span was the strategy offered", and must carry each collapsed
      # range as the pair of source digests it spans.
      #
      # Neither head digest is required. Both are legitimately nil: deriving an
      # empty timeline is a no-op that still records the edge, and a strategy
      # that drops every span answers the empty chain. A `presence:` on either
      # would refuse an honest record.
      class ContextDerived < Guard
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
    # The DERIVED EVENTS are deliberately not here. The ruling is "journal the
    # edge, re-derive the chain", which is exact rather than approximate: a
    # deterministic strategy is a pure function of the source, and a model-backed
    # one answers through {Oracle::Recorded}, whose `oracle_answer` records are
    # already journalled and replayed by `(oracle_digest, question)`. So this
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
    #     the cut rule T4 shipped this is nearly unreachable, and through a
    #     DERIVATION it is unreachable outright: every declining shape carries
    #     either a `tool_use` at index 0 or one message holding both a
    #     `tool_result` and a `tool_use`, and {Context::Conversation} refuses
    #     both, so the chain is refused before an edge is journalled. Kept
    #     because {Compaction::Boundary} can still answer it, and because a
    #     future cut rule may reach it again -- a reader must handle it. No
    #     journal anywhere carries one: this record type ships with this chunk
    #     and nothing has ever written it.
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
    # `keep_last` is here because RE-DERIVATION IS NOT REPRODUCIBLE WITHOUT IT.
    # This record's whole contract is that an audit can rebuild the chain rather
    # than read a copy of it, and the trailing window is part of what determines
    # that chain -- it fixes where {Compaction::Boundary} cuts, and therefore
    # which turns a strategy is ever offered. It is not recoverable from `spans`
    # either: a collapsed range's endpoints say nothing about how many messages
    # were retained after it. Without the field {Compaction::DerivationAudit}
    # has to be TOLD the parameter, and a wrong one reads as drift -- a
    # confident, wrong "the chain disagrees" from the one object whose whole job
    # is to tell real drift from noise.
    #
    # Held in canonical wire form (String keys, deeply frozen) so the record
    # stays `Ractor.shareable?`, the same idiom {TurnUsage}'s `usage` uses.
    #
    # Emitted by {Compaction::Derivation}, and READ BACK by
    # {Compaction::DerivationAudit} -- which matters, because nothing reads a
    # `compaction` record back today and a write-only trace is this subsystem's
    # default failure mode.
    ContextDerived = Data.define(:source_head, :derived_head, :strategy, :spans, :cut, :moved, :keep_last) do
      include Journalable

      def initialize(source_head:, derived_head:, strategy:, spans:, cut:, moved: 0, keep_last: nil)
        strategy = named(strategy)
        spans = Canonical.normalize(spans)
        cut = cut.to_sym
        Guards::ContextDerived.check!(strategy:, spans:, cut:)

        super(source_head: source_head&.dup&.freeze, derived_head: derived_head&.dup&.freeze,
              strategy:, spans:, cut:, moved: Integer(moved), keep_last: keep_last&.then { |n| Integer(n) })
      end

      private

      # An anonymous class renders as `#<Class:0x00007f...>`, and that address
      # is fresh in every process. T8 replays these records by strategy name, so
      # an address would read as drift on the next run -- and would leak a heap
      # address into the experiment record for nothing. Anonymous strategies are
      # unauditable by name anyway (spec doubles, mostly), so they collapse to
      # one honest token rather than to a lie that looks specific.
      def named(strategy)
        name = strategy.to_s

        -(name.match?(/\A#<Class:0x\h+>\z/) ? "(anonymous strategy)" : name)
      end
    end
  end
end
