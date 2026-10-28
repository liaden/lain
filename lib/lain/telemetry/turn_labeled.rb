# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # `label` is a String that may be empty: the empty one is the retraction,
      # so `presence:` would reject the very record that clears a label.
      class TurnLabeled < Declarative::Carrier
        attribute :digest, :lain_interned
        attribute :label, :lain_interned
        validates :digest, presence: { message: "must name the turn it labels, got nil" }
        validates :label, exclusion: { in: [nil], message: "must be a String, got nil" }
      end
    end

    # One label transition for a committed turn, recorded so a `--resume`
    # rebuilds the labels. An empty `label` clears; {SessionRecord::Replay}
    # folds in file order, so the last record for a digest wins.
    TurnLabeled = Data.define(:digest, :label) do
      include Journalable

      def initialize(digest:, label:) = super(**Carriers::TurnLabeled.settle!(digest:, label:))
    end
  end
end
