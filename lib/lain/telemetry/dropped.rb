# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # A dropped-event count must be a positive Integer.
      class Dropped < Declarative::Carrier
        attribute :count
        validates :count, numericality: { only_integer: true, greater_than: 0,
                                          message: "must be a positive Integer, got %<value>s" }
      end
    end

    # A marker that N events were dropped to make room for newer ones, so a
    # consumer that freely drops still learns *that* it dropped, and how many.
    # `count` is the number lost since the last marker was surfaced.
    Dropped = Data.define(:count) do
      include Journalable

      def initialize(count:)
        Carriers::Dropped.check!(count:)
        super
      end
    end
  end
end
