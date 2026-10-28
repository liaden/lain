# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # Copy rebuilds the hash, so freezing the record never freezes the caller's arms.
      class RunArms < Declarative::Carrier
        attribute :arms
      end
    end

    # The bench arms a run without a session header was started with, written once at
    # the top of its journal so the file says what it measured.
    RunArms = Data.define(:arms) do
      include Journalable

      def initialize(arms:) = super(**Carriers::RunArms.settle!(arms: arms.to_h))
    end
  end
end
