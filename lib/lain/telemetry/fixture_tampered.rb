# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # Names the arm; the paths are interned by the record before they are settled.
      class FixtureTampered < Declarative::Carrier
        attribute :arm, :lain_interned
        attribute :paths
      end
    end

    # An arm edited the test tree it was to be graded by, so its run is void
    # rather than low. Names the arm and the changed paths, never file bytes.
    FixtureTampered = Data.define(:arm, :paths) do
      include Journalable

      def initialize(arm:, paths:)
        # Interned before settling: a frozen String is kept as it is, and a copy would not be shared.
        super(**Carriers::FixtureTampered.settle!(arm:, paths: paths.map { |path| -path.to_s }))
      end
    end
  end
end
