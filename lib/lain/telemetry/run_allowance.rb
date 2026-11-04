# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # A grant that names no ceiling would leave the run with nothing to restore.
      class RunAllowance < Declarative::Carrier
        attribute :iterations
        validates :iterations, numericality: { only_integer: true,
                                               message: "must be the iteration ceiling granted, got %<value>s" }
      end
    end

    # The iteration ceiling a skill granted the run, which stands for every later ask until a newer
    # grant replaces it, and which a resumed chat reads back from the journal.
    #
    # @!attribute [r] iterations
    #   @return [Integer] the ceiling each ask of the run is bounded by
    RunAllowance = Data.define(:iterations) do
      include Journalable

      def initialize(iterations:) = super(**Carriers::RunAllowance.settle!(iterations:))
    end
  end
end
