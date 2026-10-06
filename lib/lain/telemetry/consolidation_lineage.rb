# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # `wrote` is a real boolean for the reason {SessionPin}'s `pinned` is:
      # `presence:` would reject the `false` that most lineages carry. `failure`
      # is declared without a rule because nil is its "this lineage answered".
      class ConsolidationLineage < Declarative::Carrier
        attribute :spawn
        attribute :spawned_from
        attribute :turn_count
        attribute :wrote
        attribute :failure
        validates :spawn, presence: { message: "must name the lineage, got nil" }
        validates :wrote, inclusion: { in: [true, false], message: "must be true or false, got %<value>s" }
      end
    end

    # One lineage a consolidation pass worked and how its clerk ended, so a
    # reader of the pass journal can tell a lineage that wrote from one that
    # failed without replaying the clerk's turns. `failure` is the stop reason
    # and message of a {Response::Failure}, flattened to Strings because the
    # journal's wire form has no Symbol; nil when the clerk answered.
    ConsolidationLineage = Data.define(:spawn, :spawned_from, :turn_count, :wrote, :failure) do
      include Journalable

      def initialize(spawn:, spawned_from:, turn_count:, wrote:, failure:)
        super(**Carriers::ConsolidationLineage.settle!(spawn:, spawned_from:, turn_count:, wrote:,
                                                       failure: Canonical.normalize(failure&.to_h)))
      end
    end
  end
end
