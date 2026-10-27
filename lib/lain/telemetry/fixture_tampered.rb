# frozen_string_literal: true

module Lain
  module Telemetry
    # An arm edited the test tree it was to be graded by, so its run is void
    # rather than low. Names the arm and the changed paths, never file bytes.
    FixtureTampered = Data.define(:arm, :paths) do
      include Journalable

      def initialize(arm:, paths:)
        super(arm: -arm.to_s, paths: paths.map { |path| -path.to_s }.freeze)
      end
    end
  end
end
