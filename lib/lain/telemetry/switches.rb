# frozen_string_literal: true

module Lain
  # The two live-switch flips (/yolo's policy, /model's model). Each is a DUMB
  # CARRIER: the switch that emits it ({Approval::PolicySwitch}/
  # {Context::ModelSwitch}) owns the from/to naming and keeps its own live
  # `@current`; the record only serializes the flip. The discriminator strings
  # "policy_switch"/"model_switch" derive from the class basename
  # ({Journalable#journal_type}), and journal readers and replay match on them,
  # so the class names must not drift.
  module Telemetry
    # A /yolo gate flip, attributed to the surface that made it -- "who turned
    # the gate off, and when" is evidence on a study bench, not incident
    # detail. `from`/`to` are the snake_case policy names {Approval::PolicySwitch}
    # derives; `surface` names the deciding surface. Deeply frozen (interned
    # strings) so the record stays Ractor-shareable.
    PolicySwitch = Data.define(:from, :to, :surface) do
      include Journalable

      def initialize(from:, to:, surface:)
        super(from: from.to_s.dup.freeze, to: to.to_s.dup.freeze, surface: surface.to_s.dup.freeze)
      end
    end

    # A /model flip, the same shape and the same attributed-evidence purpose as
    # {PolicySwitch}: `from`/`to` are the model ids {Context::ModelSwitch} held
    # and now holds, `surface` the deciding surface. Deeply frozen so it stays
    # Ractor-shareable.
    ModelSwitch = Data.define(:from, :to, :surface) do
      include Journalable

      def initialize(from:, to:, surface:)
        super(from: from.to_s.dup.freeze, to: to.to_s.dup.freeze, surface: surface.to_s.dup.freeze)
      end
    end
  end
end
