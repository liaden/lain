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
    # writes the posture's gate policy as the consequence of a `/mode` flip, so
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
      # `tool_names` is the same shape as a layer list for the same reason: a
      # posture with no tools left (an emptied `plan` variant, say) is ordinary,
      # while `nil` means nobody supplied the set the flip actually resolved.
      class ModeSwitch < Declarative::Carrier
        attribute :from
        attribute :to
        attribute :from_layers
        attribute :to_layers
        attribute :surface
        attribute :toolset_digest
        attribute :tool_names

        validates :from, presence: { message: "must name the posture switched away from, got nil" }
        validates :to, presence: { message: "must name the posture switched to, got nil" }
        validates :surface, presence: { message: "must name the deciding surface, got nil" }
        validates :toolset_digest,
                  presence: { message: "must name the toolset digest the flip resolved, got nil" }
        # Hand-rolled because neither declarative validator can say "not nil"
        # about a list: `presence` rejects the empty layer set, which is the
        # ordinary case, and `exclusion: { in: [nil] }` rejects it too, since
        # ActiveModel's Clusivity tests an ARRAY member-by-member with `all?`
        # and `[].all?` is vacuously true.
        validates_each :from_layers, :to_layers do |record, attribute, value|
          fault = list_fault(value, "layer")
          record.errors.add(attribute, fault) if fault
        end
        validates_each :tool_names do |record, attribute, value|
          fault = list_fault(value, "tool")
          record.errors.add(attribute, fault) if fault
        end

        # A name, and not merely "something with a `to_s`". Handing the {Mode}
        # itself to a field that stringifies is the one mistake this record
        # cannot survive quietly: `JSON.generate` would write `#<data
        # Lain::Mode ...>` into the journal, and the NDJSON line would PARSE.
        # Nothing downstream can tell that apart from a posture called
        # `#<data Lain::Mode ...>`, so it has to die here. `toolset_digest`
        # joins the group for the same reason a live {Lain::Toolset} would
        # stringify to its own `#<Lain::Toolset ...>` header rather than to the
        # digest a reader can compare against a session header's.
        validates_each :from, :to, :surface, :toolset_digest do |record, attribute, value|
          record.errors.add(attribute, "must be a name, got #{value.class}") unless name_shaped?(value)
        end

        # nil passes deliberately: the `presence:` validators above own the nil
        # message, and reporting "must be a name, got NilClass" beside "must
        # name the deciding surface, got nil" would say the same thing twice in
        # worse words.
        def self.name_shaped?(value) = value.nil? || value.respond_to?(:to_sym)

        # @return [String, nil] why this is not a list of `noun` names, or nil
        #   if it is. The member check is the other half of the promise the
        #   record makes -- a Mode inside the LIST reaches the NDJSON line
        #   exactly as a Mode in `from` would, and a non-Array reaching the
        #   record's `map` would die a NoMethodError instead of naming the
        #   field it came from. A nil MEMBER is a fault here even though a nil
        #   `from` is not: no validator downstream owns it, and it would
        #   journal `""`.
        def self.list_fault(value, noun)
          return "must be a list of #{noun} names, got nil" if value.nil?
          return "must be a list of #{noun} names, got #{value.class}" unless value.is_a?(Array)

          strangers = value.reject { |name| name.respond_to?(:to_sym) }
          "must be a list of #{noun} names, got #{strangers.first.class} in it" unless strangers.empty?
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
    # `toolset_digest`/`tool_names` name what the model is shown AFTER this
    # flip -- the resolved capability set {Mode::Resolution} computed for it,
    # never re-derived from a live slot a reader would have to reconstruct.
    # {Grader::ToolSteering} is the reason: grading a post-flip turn against the
    # session header's widest declaration mistakes "the model could no longer
    # see this tool" for "the model stopped choosing it". The digest is the same
    # bytes prompt caching keys on ({Toolset#digest}), so a reader can also tell
    # two flips resolved to the identical set without diffing name arrays.
    #
    # Every field is interned on the way in, so what reaches the NDJSON line is
    # a name or a list of names. A {Mode} itself is refused by the guard, in a
    # name field and inside a layer list alike: `JSON.generate` would write the
    # object's `to_s` into a line that parses while carrying garbage. The
    # constant is public, so that refusal cannot rely on {Mode::Switch} being
    # the only caller.
    ModeSwitch = Data.define(:from, :to, :from_layers, :to_layers, :surface, :toolset_digest, :tool_names) do
      include Journalable

      # `toolset_digest:`/`tool_names:` are required, with no empty-Toolset
      # default: {Mode::Switch}, the only production caller, always resolves a
      # real one and passes it in, and a default here would be exactly how a
      # caller that forgot to resolve one silently journals a false "nothing
      # declared" set instead of failing where the mistake was made. A spec
      # building this record directly, with nothing to report, names
      # `Lain::Toolset.new` at its own call site instead.
      def initialize(from:, to:, from_layers:, to_layers:, surface:, toolset_digest:, tool_names:)
        Carriers::ModeSwitch.check!(from:, to:, from_layers:, to_layers:, surface:, toolset_digest:, tool_names:)

        super(from: -from.to_s, to: -to.to_s, surface: -surface.to_s, toolset_digest: -toolset_digest.to_s,
              from_layers: interned_names(from_layers), to_layers: interned_names(to_layers),
              tool_names: interned_names(tool_names))
      end

      private

      def interned_names(names) = names.map { |name| -name.to_s }.freeze
    end
  end
end
