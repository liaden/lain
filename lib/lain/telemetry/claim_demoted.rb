# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # A demotion record names the strategy whose summary was checked and a positive count.
      class ClaimDemoted < Declarative::Carrier
        attribute :strategy
        attribute :count
        validates :strategy, presence: { message: "must name the strategy whose summary was checked, got nil" }
        validates :count, numericality: { only_integer: true, greater_than: 0,
                                          message: "must be a positive Integer, got %<value>s" }
      end
    end

    # A summary sentence about the user that none of the user's own turns supported, marked
    # unverified in the replacement. `count` is the sentences demoted in one collapse.
    ClaimDemoted = Data.define(:strategy, :count) do
      include Journalable

      def initialize(strategy:, count:)
        Carriers::ClaimDemoted.check!(strategy:, count:)
        super
      end
    end
  end
end
