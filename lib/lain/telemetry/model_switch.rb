# frozen_string_literal: true

module Lain
  module Telemetry
    # A /model flip, the same shape and the same attributed-evidence purpose as
    # {PolicySwitch} -- and the same dumb carrier, for {Context::ModelSwitch}.
    # Its "model_switch" discriminator derives from the class basename, which
    # journal readers and replay match on, so the class name must not drift.
    ModelSwitch = Data.define(:from, :to, :surface) do
      include Journalable

      def initialize(from:, to:, surface:)
        super(from: from.to_s.dup.freeze, to: to.to_s.dup.freeze, surface: surface.to_s.dup.freeze)
      end
    end
  end
end
