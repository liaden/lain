# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # Every field is a name, interned.
      class ModelSwitch < Declarative::Carrier
        attribute :from, :lain_interned
        attribute :to, :lain_interned
        attribute :surface, :lain_interned
      end
    end

    # A /model flip, the same shape and the same attributed-evidence purpose as
    # {PolicySwitch} -- and the same dumb carrier, for {Context::ModelSwitch}.
    # Its "model_switch" discriminator derives from the class basename, which
    # journal readers and replay match on, so the class name must not drift.
    ModelSwitch = Data.define(:from, :to, :surface) do
      include Journalable

      def initialize(from:, to:, surface:) = super(**Carriers::ModelSwitch.settle!(from:, to:, surface:))
    end
  end
end
