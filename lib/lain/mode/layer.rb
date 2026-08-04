# frozen_string_literal: true

module Lain
  class Mode
    # One composable, orthogonal toggle -- Emacs' minor mode. A layer is
    # DECLARATION only: a name, the lighter it renders, and whether it can move
    # an approval or capability outcome. It constructs nothing and resolves
    # nothing; the posture owns the exclusive slot, and a layer is everything
    # that does not need one.
    #
    # == Why `alters_outcome` is a declared field rather than a comment
    #
    # A silently-active policy is a bug. Emacs' own convention is that a minor
    # mode carries a lighter so the mode line can say it is on, and the layers
    # that can change what a tool call is allowed to do are exactly the ones a
    # human must not have to guess about. So the obligation is checked where a
    # layer is BORN: declaring one outcome-altering and silent raises, which
    # binds the fifth layer somebody adds long after this file was reviewed.
    # The converse is deliberately free -- a layer that cannot move an outcome
    # may render nothing.
    Layer = Data.define(:name, :lighter, :alters_outcome) do
      # `Layer::Declaration` is qualified because constants defined inside a
      # `Data.define do ... end` block are lexically scoped to the ENCLOSING
      # module (here `Lain::Mode`), not to the Data class -- so a bare
      # `Declaration` would resolve against `Lain::Mode` and fail.
      def initialize(name:, lighter:, alters_outcome:)
        Layer::Declaration.check!(name:, lighter:, alters_outcome:)
        # `-lighter.to_s` and not `lighter.to_s.freeze`: `Symbol#to_s` returns a
        # MUTABLE String, and one mutable member is enough to flip
        # `Ractor.shareable?` to false for the whole value.
        super(name: name.to_sym, lighter: -lighter.to_s, alters_outcome:)
      end

      def alters_outcome? = alters_outcome

      def to_s = lighter.empty? ? name.to_s : "#{name} (#{lighter})"
    end

    # Reopened rather than written inside the block above, for the same reason
    # the comment there gives: nested classes and constants declared in a
    # `Data.define` block do not land on the Data class.
    class Layer
      # The lighter obligation, as validate-then-freeze. It lives on a throwaway
      # {Lain::Guard} carrier because a frozen value must never include
      # ActiveModel itself -- `valid?` leaves mutable ivars behind and
      # `Ractor.shareable?` goes false.
      class Declaration < Guard
        attribute :name
        attribute :lighter, :string
        attribute :alters_outcome

        validates :name, presence: true
        # Not `presence: true` on a Boolean: `false.present?` is false, so a
        # perfectly valid silent layer would be rejected. Inclusion is the check
        # that actually means "is a Boolean".
        validates :alters_outcome, inclusion: { in: [true, false] }
        validates :lighter, presence: true, if: -> { alters_outcome }
      end

      # @param name [Symbol, String] one of {NAMES}
      # @return [Layer]
      # @raise [ArgumentError] naming every declared layer -- an unknown layer
      #   is a typo in a `/mode +foo` invocation, and the human needs the list
      def self.for(name)
        DECLARED.fetch(name.to_sym) do
          raise ArgumentError, "unknown mode layer #{name.inspect}, expected one of #{NAMES.inspect}"
        end
      end

      # Every declared layer, in declaration order. That order is the precedence
      # order a {LayerSet} canonicalizes to and the one `/mode` reports in.
      def self.all = DECLARED.values

      # Declared after the class body's methods, as {Capability::Policy} does
      # with its STRATEGIES: `.for` reads it at call time, so nothing above
      # needs a forward reference. Private -- `.for` and `.all` are the surface.
      #
      # `:auto_approve` is the only member that answers `alters_outcome?` today;
      # it turns {Approval::AutoSurface} on, which decides tool calls a human
      # would otherwise have been asked about. The other three change what the
      # human sees or how input is read, never what is permitted.
      DECLARED = {
        auto_approve: new(name: :auto_approve, lighter: "AA", alters_outcome: true),
        goal: new(name: :goal, lighter: "GOAL", alters_outcome: false),
        notify: new(name: :notify, lighter: "NOTIFY", alters_outcome: false),
        vi: new(name: :vi, lighter: "VI", alters_outcome: false)
      }.freeze
      private_constant :DECLARED

      # Public so an error can list the valid options, and DERIVED from the
      # table so the roster and that error can never drift apart.
      NAMES = DECLARED.keys.freeze
    end

    # The set of layers active right now. Emacs states order-independence as a
    # convention -- *"it should be possible to activate and deactivate minor
    # modes in any order"* -- and this is where that becomes a property: `#|` is
    # a commutative, idempotent monoid whose unit is the empty set, so the set
    # of active layers determines behavior and the sequence that produced it
    # does not.
    #
    # Deeply frozen and `Ractor.shareable?`: Symbols in a frozen Array in a
    # frozen object.
    class LayerSet
      include Enumerable
      include Inspectable

      # Canonicalized by SELECTING from the declaration order rather than by
      # sorting the input, so two sets holding the same layers are `==` however
      # they were built, and iteration yields precedence order rather than
      # alphabetical accident.
      #
      # @param names [Enumerable] layer names, in any order, with any repeats
      # @raise [ArgumentError] through {Layer.for} on an undeclared name
      def initialize(names = [])
        requested = names.map { |name| Layer.for(name).name }
        @names = Layer::NAMES.select { |name| requested.include?(name) }.freeze
        freeze
      end

      # @return [Array<Symbol>] the active layer names, in declaration order
      attr_reader :names

      def self.empty = EMPTY

      def each(&block) = names.each(&block)

      def empty? = names.empty?

      def size = names.size

      # The declared values behind the names, for anything that needs a lighter.
      def layers = names.map { |name| Layer.for(name) }

      def include?(name) = names.include?(Layer.for(name).name)

      # `#enable`/`#disable` reconstruct from the underlying names rather than
      # delegating to `#|`, so the order-independence specs and the union laws
      # stay independent claims: a degenerate `#|` cannot be hidden by an
      # `#enable` that happens to agree with it.
      def enable(name) = self.class.new(names + [name])

      # Disabling a layer that was never enabled is a no-op, not an error --
      # `/mode -goal` from a session that never enabled it means the same thing
      # either way. An UNDECLARED name still raises: that is a typo, not a
      # request to remove nothing.
      def disable(name) = self.class.new(names - [Layer.for(name).name])

      def |(other) = self.class.new(names + other.names)
      alias union |

      # ==/eql?/hash agree, over the canonical name list. Guarded with
      # `instance_of?` and not `is_a?`: the sibling this borrows its
      # frozen-sorted-symbol-set shape from, {Capability::DegradedSet}, writes
      # `is_a?` and records the resulting asymmetry as a latent caveat (under
      # subclassing `parent == child` holds while `child == parent` does not,
      # and a class-embedding `hash` makes that a live ==/hash violation).
      # {Lain::Toolset} is the corrected form and is the one followed here.
      # Converging DegradedSet and {Lain::ContentAddressed} onto `instance_of?`
      # is owed; until it lands, this comment says the three differ on purpose.
      def ==(other) = other.instance_of?(self.class) && names == other.names
      alias eql? ==

      def hash = [self.class, names].hash

      # to_s is the human-facing list; inspect keeps the class-tagged, debug
      # form -- the DegradedSet convention.
      def to_s = names.join(", ")

      # The monoid's unit, built once: a fresh empty set per call would be a
      # fresh allocation for a value that can never differ.
      EMPTY = new
    end
  end
end
