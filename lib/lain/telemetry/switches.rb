# frozen_string_literal: true

module Lain
  module Telemetry
    # The three live-switch flips (the gate's policy, /model's model, /mode's mode).
    # Each is a DUMB CARRIER: the switch that emits it ({Approval::PolicySwitch}/
    # {Context::ModelSwitch}/{Mode::Switch}) owns the from/to naming and keeps its
    # own live `@current`; the record only serializes the flip. The discriminator
    # strings "policy_switch"/"model_switch"/"mode_switch" derive from the class
    # basename ({Journalable#journal_type}), and journal readers and replay match
    # on them, so the class names must not drift.

    # A gate-policy flip, attributed to the surface that made it -- "who changed
    # what the gate answers, and when" is evidence on a study bench, not incident
    # detail. The flip is DERIVED rather than typed: {CLI::Switchboard#apply}
    # writes the approval level's gate policy as the consequence of a `/mode` flip, so
    # `surface` names the surface that flipped the MODE.
    PolicySwitch = Data.define(:from, :to, :surface) do
      include Journalable

      def initialize(from:, to:, surface:)
        super(from: from.to_s.dup.freeze, to: to.to_s.dup.freeze, surface: surface.to_s.dup.freeze)
      end
    end

    # A /model flip, the same shape and the same attributed-evidence purpose as
    # {PolicySwitch}.
    ModelSwitch = Data.define(:from, :to, :surface) do
      include Journalable

      def initialize(from:, to:, surface:)
        super(from: from.to_s.dup.freeze, to: to.to_s.dup.freeze, surface: surface.to_s.dup.freeze)
      end
    end

    module Carriers
      # Every field is stringified on the way in, so a nil would journal `""` --
      # a line that parses, sits in the experiment record, and names neither the
      # flip nor who made it. The two layer lists are refused as nil rather than
      # coerced, because `Array(nil)` answers `[]`, an ordinary layer set that
      # would record "no layers were active" for a caller that knew nothing.
      class ModeSwitch < Declarative::Carrier
        NAMES = %i[from_scope to_scope from_approval to_approval surface].freeze

        NAMES.each { |name| attribute name }
        attribute :from_layers
        attribute :to_layers

        validates(*NAMES, presence: { message: "must be named, got nil" })
        # Hand-rolled because neither declarative validator can say "not nil"
        # about a list: `presence` rejects the empty layer set, which is the
        # ordinary case, and `exclusion: { in: [nil] }` rejects it too, since
        # ActiveModel's Clusivity tests an ARRAY member-by-member with `all?`
        # and `[].all?` is vacuously true.
        validates_each :from_layers, :to_layers do |record, attribute, value|
          fault = list_fault(value)
          record.errors.add(attribute, fault) if fault
        end

        # A name, and not merely "something with a `to_s`". Handing the {Mode}
        # itself to a field that stringifies is the one mistake this record
        # cannot survive quietly: `JSON.generate` would write `#<data
        # Lain::Mode ...>` into the journal, and the NDJSON line would PARSE.
        validates_each(*NAMES) do |record, attribute, value|
          record.errors.add(attribute, "must be a name, got #{value.class}") unless name_shaped?(value)
        end

        # nil passes deliberately: the `presence:` validator above owns the nil
        # message, and saying it twice in worse words helps nobody.
        def self.name_shaped?(value) = value.nil? || value.respond_to?(:to_sym)

        # @return [String, nil] why this is not a list of layer names, or nil if
        #   it is. A Mode inside the LIST reaches the NDJSON line exactly as a
        #   Mode in `from_scope` would, and a nil MEMBER would journal `""`.
        def self.list_fault(value)
          return "must be a list of layer names, got nil" if value.nil?
          return "must be a list of layer names, got #{value.class}" unless value.is_a?(Array)

          strangers = value.reject { |name| name.respond_to?(:to_sym) }
          "must be a list of layer names, got #{strangers.first.class} in it" unless strangers.empty?
        end
      end
    end

    # A /mode flip: both exclusive axes and both layer sets, on each side. The
    # layer pair is why this record is not the three-field twin of its two
    # siblings above: `/mode +auto_approve` moves neither axis, and recording
    # only the resulting set would leave the FIRST flip of a session unable to
    # say what was active before it, since construction journals nothing.
    #
    # It names no toolset. A mode never changes what the model is shown, so the
    # session header's declared set stands for the whole run.
    #
    # Every field is interned on the way in, so what reaches the NDJSON line is
    # a name or a list of names. The constant is public, so that refusal cannot
    # rely on {Mode::Switch} being the only caller.
    ModeSwitch = Data.define(:from_scope, :to_scope, :from_approval, :to_approval, :from_layers, :to_layers,
                             :surface) do
      include Journalable

      def initialize(from_scope:, to_scope:, from_approval:, to_approval:, from_layers:, to_layers:, surface:)
        Carriers::ModeSwitch.check!(from_scope:, to_scope:, from_approval:, to_approval:, from_layers:,
                                    to_layers:, surface:)

        super(from_scope: -from_scope.to_s, to_scope: -to_scope.to_s, from_approval: -from_approval.to_s,
              to_approval: -to_approval.to_s, surface: -surface.to_s,
              from_layers: interned_names(from_layers), to_layers: interned_names(to_layers))
      end

      private

      def interned_names(names) = names.map { |name| -name.to_s }.freeze
    end
  end
end
