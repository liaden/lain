# frozen_string_literal: true

module Lain
  # The three live-switch flips (/yolo's policy, /model's model, /mode's mode).
  # Each is a DUMB CARRIER: the switch that emits it ({Approval::PolicySwitch}/
  # {Context::ModelSwitch}/{Mode::Switch}) owns the from/to naming and keeps its
  # own live `@current`; the record only serializes the flip. The discriminator
  # strings "policy_switch"/"model_switch"/"mode_switch" derive from the class
  # basename ({Journalable#journal_type}), and journal readers and replay match
  # on them, so the class names must not drift.
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

    module Guards
      # Every field of a switch record is stringified on the way in, so a nil
      # would journal `""` -- a line that parses, sits in the experiment record,
      # and names neither the flip nor who made it. All five are REQUIRED, and
      # the two layer lists are refused as nil rather than coerced: `Array(nil)`
      # answers `[]`, which is a perfectly ordinary layer set and would record
      # "no layers were active" for a caller that knew nothing at all.
      class ModeSwitch < Guard
        attribute :from
        attribute :to
        attribute :from_layers
        attribute :to_layers
        attribute :surface

        validates :from, presence: { message: "must name the posture switched away from, got nil" }
        validates :to, presence: { message: "must name the posture switched to, got nil" }
        validates :surface, presence: { message: "must name the deciding surface, got nil" }
        # Hand-rolled because neither declarative validator can say "not nil"
        # about a list: `presence` rejects the empty layer set, which is the
        # ordinary case, and `exclusion: { in: [nil] }` rejects it too --
        # ActiveModel's Clusivity tests an ARRAY value member-by-member with
        # `all?`, and `[].all?` is vacuously true, so the empty list is exactly
        # the value it excludes.
        validates_each :from_layers, :to_layers do |record, attribute, value|
          fault = layer_list_fault(value)
          record.errors.add(attribute, fault) if fault
        end

        # A name, and not merely "something with a `to_s`". Handing the {Mode}
        # itself to a field that stringifies is the one mistake this record
        # cannot survive quietly: `JSON.generate` would write `#<data
        # Lain::Mode ...>` into the journal, and the NDJSON line would PARSE.
        # Nothing downstream can tell that apart from a posture called
        # `#<data Lain::Mode ...>`, so it has to die here.
        validates_each :from, :to, :surface do |record, attribute, value|
          record.errors.add(attribute, "must be a name, got #{value.class}") unless name_shaped?(value)
        end

        # nil passes deliberately: the `presence:` validators above own the nil
        # message, and reporting "must be a name, got NilClass" beside "must
        # name the deciding surface, got nil" would say the same thing twice in
        # worse words.
        def self.name_shaped?(value) = value.nil? || value.respond_to?(:to_sym)

        # @return [String, nil] why this is not a list of layer names, or nil if
        #   it is. The member check is the other half of the promise the record
        #   makes -- a Mode inside the LIST reaches the NDJSON line exactly as a
        #   Mode in `from` would, and a non-Array reaching the record's `map`
        #   would die a NoMethodError instead of naming the field it came from.
        #   A nil MEMBER is a fault here even though a nil `from` is not: no
        #   validator downstream owns it, and it would journal `""`.
        def self.layer_list_fault(value)
          return "must be a list of layer names, got nil" if value.nil?
          return "must be a list of layer names, got #{value.class}" unless value.is_a?(Array)

          strangers = value.reject { |name| name.respond_to?(:to_sym) }
          "must be a list of layer names, got #{strangers.first.class} in it" unless strangers.empty?
        end
      end
    end

    # A /mode flip. `from`/`to` are POSTURE names -- the exclusive slot a HUD
    # publishes and a bench comparison refuses to cross -- and the two layer
    # lists are the sets active on each side, in the precedence order a
    # {Mode::LayerSet} canonicalizes to.
    #
    # The layer pair is why this record is not the three-field twin of its two
    # siblings above. `/mode +auto_approve` never moves the posture, so from/to
    # alone would journal `manual -> manual` for a flip that turns an
    # outcome-altering layer on; and recording only the resulting set would
    # leave the FIRST flip of a session unable to say what was active before it,
    # since construction journals nothing.
    #
    # Every field is interned on the way in, so the record is deeply frozen and
    # stays Ractor-shareable -- and so that what reaches the NDJSON line is a
    # name or a list of names. A {Mode} itself is refused by the guard, in a
    # name field and inside a layer list alike: `JSON.generate` would write the
    # object's `to_s` into a line that parses while carrying garbage. The
    # constant is public and T8/T22 construct one directly, so that refusal
    # cannot rely on {Mode::Switch} being the only caller.
    ModeSwitch = Data.define(:from, :to, :from_layers, :to_layers, :surface) do
      include Journalable

      def initialize(from:, to:, from_layers:, to_layers:, surface:)
        Guards::ModeSwitch.check!(from:, to:, from_layers:, to_layers:, surface:)

        super(from: -from.to_s, to: -to.to_s, surface: -surface.to_s,
              from_layers: interned_names(from_layers), to_layers: interned_names(to_layers))
      end

      private

      def interned_names(names) = names.map { |name| -name.to_s }.freeze
    end
  end
end
