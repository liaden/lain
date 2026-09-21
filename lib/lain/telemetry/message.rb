# frozen_string_literal: true

module Lain
  module Telemetry
    # A :message or :spawn Event promoted to the session record, its OWN additive
    # type so the turn-chain loader's `of_type` narrowing never sees it (a
    # :message can never survive {Timeline#commit}'s digest re-derivation, so it
    # must not wear the `turn` shape). Field-pinned to what a later re-put into a
    # Store needs -- `payload` is the addressed body, `causal_parents` the
    # backward edges a provenance walk descends -- carried as data here, and
    # reconstructing the Store from it is a separate job this type does not do.
    Message = Data.define(:digest, :kind, :from, :to, :payload, :causal_parents, :correlation) do
      include Journalable

      # The one funnel {Event::ChainWriter} observes hands the scribe an Event;
      # this is where its envelope + body become the flat record. A :turn
      # arriving on that funnel belongs to a SPAWNED chain and wears
      # {ChildTurn} instead -- see there for why the two cannot share a record.
      def self.from_event(event)
        new(digest: event.digest, kind: event.kind, from: event.from, to: event.to,
            payload: event.body, causal_parents: event.causal_parents, correlation: event.correlation)
      end

      def initialize(digest:, kind:, from:, to:, payload:, causal_parents:, correlation:)
        super(
          digest: digest.dup.freeze,
          kind: kind.to_sym,
          from: Canonical.normalize(from),
          to: Canonical.normalize(to),
          payload: Canonical.normalize(payload),
          causal_parents: Canonical.normalize(causal_parents),
          correlation: Canonical.normalize(correlation)
        )
      end
    end
  end
end
