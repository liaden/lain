# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # Canonical fields keep a nested payload deterministic, as the child's digest depends on it.
      class ChildTurn < Declarative::Carrier
        attribute :digest, :lain_interned
        attribute :kind
        attribute :from, :lain_canonical
        attribute :to, :lain_canonical
        attribute :render_parent, :lain_canonical
        attribute :payload, :lain_canonical
        attribute :causal_parents, :lain_canonical
        attribute :correlation, :lain_canonical
      end
    end

    # A SPAWNED chain's turn, promoted to the session record. Its own type, and
    # the reason is mechanical: a child's chain shares no render edge with the
    # parent's, so {Bench::Session::ChainFold} -- which re-commits every `turn`
    # record onto ONE accumulating chain -- would re-derive a different digest
    # for it and call the file {Bench::Session::Corrupt}. It cannot wear the
    # `message` shape either: a :turn's `render_parent` IS part of its content
    # address, and {Message} does not carry one.
    #
    # It has to be recorded at all because things OUTSIDE the child's chain
    # cite it -- a child's `ask_human` question names the head it asked from,
    # and {Tools::Subagent::Lineage#message} names the child's final turn -- so
    # a session that spawned anything was previously unforkable: replaying
    # those messages raised {Ext::Store::MissingObject} over a turn no record
    # carried.
    #
    # It is not cheap, and the price is the child's whole transcript: measured
    # over mock runs, these records are 47% of a journal with one trivial spawn
    # and 88% of one with eight four-deep spawns (136KB, 180 records, 18.6ms to
    # reload). That is the deliberate cost of the session being forkable at all
    # -- a subagent's work was previously the one part of a run the experiment
    # record could not reproduce.
    ChildTurn = Data.define(:digest, :kind, :from, :to, :render_parent, :payload, :causal_parents, :correlation) do
      include Journalable

      def self.from_event(event)
        new(digest: event.digest, kind: event.kind, from: event.from, to: event.to,
            render_parent: event.render_parent, payload: event.body,
            causal_parents: event.causal_parents, correlation: event.correlation)
      end

      def initialize(digest:, kind:, from:, to:, render_parent:, payload:, causal_parents:, correlation:)
        super(**Carriers::ChildTurn.settle!(digest:, kind: kind.to_sym, from:, to:, render_parent:, payload:,
                                            causal_parents:, correlation:))
      end
    end
  end
end
