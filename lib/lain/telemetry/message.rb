# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # The envelope and body go through Canonical so a record read back from JSON addresses the same.
      class Message < Declarative::Carrier
        attribute :digest
        attribute :kind
        attribute :from, :lain_canonical
        attribute :to, :lain_canonical
        attribute :payload, :lain_canonical
        attribute :causal_parents, :lain_canonical
        attribute :correlation, :lain_canonical
      end
    end

    # A :message or :spawn Event promoted to the session record, its OWN additive
    # type so the turn-chain loader's `of_type` narrowing never sees it (a
    # :message can never survive {Ext::Timeline#commit}'s digest re-derivation, so it
    # must not wear the `turn` shape). Field-pinned to what a later re-put into a
    # Store needs -- `payload` is the addressed body, `causal_parents` the
    # backward edges a provenance walk descends -- carried as data here, and
    # reconstructing the Store from it is a separate job this type does not do.
    Message = Data.define(:digest, :kind, :from, :to, :payload, :causal_parents, :correlation) do
      include Journalable

      # The one funnel {EventLog::ChainWriter} observes hands the scribe an Event;
      # this is where its envelope + body become the flat record. A :turn
      # arriving on that funnel belongs to a SPAWNED chain and wears
      # {ChildTurn} instead -- see there for why the two cannot share a record.
      def self.from_event(event)
        new(digest: event.digest, kind: event.kind, from: event.from, to: event.to,
            payload: event.body, causal_parents: event.causal_parents, correlation: event.correlation)
      end

      def initialize(digest:, kind:, from:, to:, payload:, causal_parents:, correlation:)
        settled = Carriers::Message.settle!(digest:, kind:, from:, to:, payload:, causal_parents:, correlation:)

        super(**settled, kind: settled[:kind].to_sym)
      end
    end
  end
end
