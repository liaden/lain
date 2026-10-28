# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # The count and turn stay untyped here: the record coerces them to Integer, and a nil turn is real.
      class EgressRefused < Declarative::Carrier
        attribute :host, :lain_interned
        attribute :count
        attribute :turn
      end

      # Counts only, never a value; the record coerces them to Integer.
      class EgressFlagged < Declarative::Carrier
        attribute :host, :lain_interned
        attribute :regions
        attribute :values
      end
    end

    EgressRefused = Data.define(:host, :count, :turn) do
      include Journalable

      def initialize(host:, count:, turn:)
        settled = Carriers::EgressRefused.settle!(host:, count:, turn:)

        super(**settled, count: Integer(settled[:count]), turn: settled[:turn]&.then { Integer(_1) })
      end
    end

    # A model request refused before it left because its body carried a known
    # secret. It names where the request was going and how many distinct values
    # it carried, never a value: the session file's `request_sent` record
    # already holds the whole payload, so a reader finds the value there, and a
    # second copy here would only add a place it is written. `turn` is the
    # position of the first message carrying one, nil when only another part did.
    class EgressRefused
      # One model request sent although what it adds held shapes the region
      # detector names, or values the masker knows but does not refuse on.
      # Either is triage, not a verdict, so it is journaled rather than refused.
      # Counts only, never a value.
      Flagged = Data.define(:host, :regions, :values) do
        include Journalable

        def initialize(host:, regions:, values:)
          settled = Carriers::EgressFlagged.settle!(host:, regions:, values:)

          super(**settled, regions: Integer(settled[:regions]), values: Integer(settled[:values]))
        end

        # Its own discriminator, since the short name would read `flagged`.
        def journal_type = "egress_flagged"
      end
    end
  end
end
