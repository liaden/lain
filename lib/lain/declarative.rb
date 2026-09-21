# frozen_string_literal: true

require "active_model"
require "active_support/concern"

module Lain
  # Declared attributes -- their defaults, their coercion, their validation, and
  # the refusal -- for a class that must not carry ActiveModel itself.
  # {Lain::Declarative::Carrier} is the authority on why that matters.
  #
  # ONE mechanism, two entry points: subclass {Lain::Declarative::Carrier} where
  # the carrier is worth a name and a docstring of its own, `declare` where the
  # rules belong to the value and nothing else would ever mention the carrier.
  #
  # ```ruby
  #   Epics = Data.define(:home) do
  #     include Declarative
  #
  #     declare raising: BadHome do
  #       attribute :home, :string
  #       attribute :depth, default: 1
  #       validates :home, inclusion: { in: ->(_) { HOMES } }
  #     end
  #
  #     def initialize(**attrs) = super(**self.class.settle!(**attrs))
  #   end
  # ```
  #
  # Either way the carrier dies with the call, taking ActiveModel's `@errors`
  # and `@context_for_validation` with it -- which is what lets a declarative
  # default reach a value object that must stay `Ractor.shareable?`.
  #
  # There is deliberately no third entry point wrapping `initialize` for you. A
  # class wanting the refusal writes the one line
  # `def initialize(**a) = (super; self.class.check!(**a))`, which validates
  # EVERY argument it was given and has no positional blind spot -- a `prepend`
  # reading keyword arguments has both, and its whole population was two classes.
  #
  # A validation set given as a lambda is called at VALIDATION time, so a
  # declaration may cite a constant whose own file has not been read yet when
  # the declaring class body runs.
  #
  # `raising:` is per-DECLARATION, not per-rule: a namespace needing a different
  # exception class per broken rule computes that where the rule lives, rather
  # than putting the translation in this object.
  #
  # And `raising:` names a CLASS, not a refusal: the raise is `raise refusal,
  # <string>`, one positional, so nothing here can thread a value the CALL knows
  # and the declaration does not. A refusal that has to name, say, the config
  # file a bad value came from cannot be expressed through this mechanism at
  # all -- see {Lain::Config::Refusal}, which is that shape and is built by hand
  # for exactly this reason. The example above is illustrative only; do not read
  # it as advice for a validation whose message depends on where the value came
  # from.
  #
  # Like {Lain::Tool::Input}, these validations check SHAPE, not safety.
  module Declarative
    extend ActiveSupport::Concern

    # A mistake in a declaring class, never a value a user got wrong -- the
    # refusal for a bad value is the declaration's own `raising:` class.
    #
    # Deliberately outside {Lain::Error}: a malformed VALUE is user-facing, and
    # `exe/lain` strips its backtrace into a one-line message; a malformed
    # DECLARATION is a programmer error, where that backtrace is the file and
    # line locating it.
    class DeclarationError < StandardError; end

    # Raised when a class includes this concern and never declares.
    #
    # Deliberately NOT an ArgumentError: both silent failures it replaces were
    # unreadable. A plain class raised `ArgumentError: wrong number of
    # arguments` -- the very class a REFUSAL raises -- and a Data value in the
    # shape documented above recursed `check!` -> `new` -> `check!` into
    # SystemStackError.
    class NoDeclaration < DeclarationError; end

    # Raised when {ClassMethods#settle!} reaches an attribute holding something
    # it may not copy -- a live collaborator, a cycle, or a container whose
    # behaviour a frozen copy would lose.
    class UnsettleableAttribute < DeclarationError; end

    # Raised when a constructor passes a name the declaration does not carry.
    #
    # ActiveModel raises `UnknownAttributeError` here, whose message names an
    # anonymous carrier by heap address -- and letting it escape would make
    # ActiveModel part of a constructor's contract, when the carrier is meant to
    # be an implementation detail of HOW we validate.
    class UndeclaredAttribute < DeclarationError; end

    class_methods do
      # Declare the attributes and validations this class is constructed under.
      #
      # The carrier is reached through a singleton method closing over it rather
      # than a class-level ivar: written once, at class-definition time, and
      # thereafter genuinely immutable rather than merely unwritten.
      #
      # @param raising [Class] exception class a refusal raises
      # @param block [Proc] evaluated in the carrier, so `attribute`/`validates` read as usual
      # @return [void]
      def declare(raising: ArgumentError, &block)
        carrier = Class.new(Carrier, &block)
        declarer = self
        define_singleton_method(:declared_carrier) { carrier }
        # So an anonymous carrier's own refusals can name a class a reader can find.
        carrier.define_singleton_method(:declarer) { declarer }
        # On BOTH, so the answer is the same whichever one a caller asks: the
        # carrier is reachable and answers `check!` in its own right.
        [self, carrier].each { |scope| scope.define_singleton_method(:refusal) { raising } }
      end

      # The class whose attributes and validations {check!} and {settle!} run. A
      # {Lain::Declarative::Carrier} IS a carrier and so validates itself;
      # `declare` replaces this with the subclass it built.
      #
      # @return [Class]
      # @raise [NoDeclaration] if the includer never declared
      def declared_carrier
        raise NoDeclaration, "#{self} includes Declarative but never declared" unless self <= Carrier

        self
      end

      # @return [Class] exception class a refusal raises, unless `declare` named another
      def refusal = ArgumentError

      # Validate the kwargs and discard the carrier, so a caller that only wants
      # the refusal keeps its own arguments.
      #
      # @param attrs [Hash] the constructor's arguments, by attribute name
      # @return [void]
      def check!(**attrs)
        validated(**attrs)
        nil
      end

      # Validate the kwargs and hand back the carrier's settled values: defaults
      # applied, types cast, deeply frozen, symbol-keyed for `super(**...)`.
      #
      # @param attrs [Hash] the constructor's arguments, by attribute name
      # @return [Hash{Symbol => Object}] frozen
      # @raise [UnsettleableAttribute] if an attribute holds a live collaborator
      def settle!(**attrs) = validated(**attrs).settled

      private

      # Raise naming EVERY offending attribute, so one raise reports the whole
      # refusal rather than the first half of it.
      def validated(**attrs)
        carrier = declared_carrier.build(**attrs)
        return carrier if carrier.valid?

        raise refusal, carrier.errors.map { |error| "#{error.attribute} #{error.message}" }.join(", ")
      end
    end
  end
end

# Registered HERE rather than in the file defining the types, because a
# declaration names a type by SYMBOL (`attribute :body, :lain_canonical`) and a
# symbol cannot make {Lain::Declarative::Types} load. Naming the constants is
# what does, and every declaring class reaches this file first -- through
# `include Declarative` or by subclassing {Lain::Declarative::Carrier} -- so the
# registry is populated before any `declare` block looks a symbol up.
#
# Prefixed (`lain_...`), not a bare `:canonical`/`:strict_integer`:
# `ActiveModel::Type`'s registry is process-wide and last-write-wins with no
# error, so a generic symbol can be silently taken over by another gem
# registering the same name.
ActiveModel::Type.register(:lain_strict_integer, Lain::Declarative::Types::StrictInteger)
ActiveModel::Type.register(:lain_canonical, Lain::Declarative::Types::Canonicalized)
