# frozen_string_literal: true

require "active_support/concern"

module Lain
  # Declared attributes -- their defaults, their coercion, their validation, and
  # the refusal -- for a class that must not carry ActiveModel itself.
  # {Lain::Declarative::Carrier} is the authority on why that matters.
  #
  # `declare` builds a {Lain::Declarative::Carrier} subclass for the including
  # class and evaluates the block in it, so `attribute` and `validates` read
  # exactly as they do in a named Carrier. ONE mechanism with two entry points,
  # not two mechanisms: subclass {Lain::Declarative::Carrier} where the carrier
  # is worth a name and a docstring of its own, `declare` where the rules belong
  # to the value and nothing else would ever mention the carrier.
  #
  # Two ways to reach the carrier, and the choice is what the caller wants back:
  #
  # ```ruby
  #   Epics = Data.define(:home) do
  #     include Declarative
  #
  #     declare raising: InvalidHome do
  #       attribute :home, :string
  #       attribute :depth, default: 1
  #       validates :home, inclusion: { in: ->(_) { HOMES } }
  #     end
  #
  #     def initialize(**attrs) = super(**self.class.settle!(**attrs))
  #   end
  # ```
  #
  # {ClassMethods#check!} validates a throwaway carrier and discards it, so a
  # caller that only wants the refusal keeps its own arguments.
  # {ClassMethods#settle!} validates and then hands back the carrier's coerced,
  # defaulted, deeply frozen values -- which is what lets declarative defaults
  # reach a value object that must stay `Ractor.shareable?`. Either way the
  # carrier itself dies with the call, taking ActiveModel's `@errors` and
  # `@context_for_validation` with it.
  #
  # There is deliberately no third entry point wrapping `initialize` for you. A
  # class wanting the refusal and no hand-written constructor writes the one line
  # `def initialize(**a) = (super; self.class.check!(**a))`, which validates
  # EVERY argument it was given and has no positional blind spot -- a `prepend`
  # reading keyword arguments has both, and its whole population was two classes.
  #
  # A validation set given as a lambda is called at VALIDATION time, so the class
  # body evaluates during `require` without resolving it -- which is what lets a
  # declaration cite a constant defined further down the load manifest than the
  # file declaring it.
  #
  # `raising:` is per-DECLARATION, not per-rule. A namespace needing a different
  # exception class per broken rule computes that where the rule lives and keeps
  # the shape checks here; growing this concern to raise per rule would put the
  # translation in the wrong object.
  #
  # Like {Lain::Tool::Input}, these validations check SHAPE, not safety.
  module Declarative
    extend ActiveSupport::Concern

    # Every error raised BY this concern names a mistake in a declaring class --
    # never a value a user got wrong. The refusal for a bad value is the
    # declaration's own `raising:` class, and nothing here replaces it.
    #
    # Deliberately outside {Lain::Error}, which is the policy this codebase now
    # holds for the boundary: a malformed VALUE is user-facing, so `exe/lain`'s
    # four `rescue Lain::Error => e; raise Thor::Error, e.message` sites turn it
    # into a clean one-line message; a malformed DECLARATION is a programmer
    # error in lib code, and stripping its backtrace throws away the file and
    # line that locate it. Choosing the boundary per class rather than by what
    # the failure IS produced one of each mistake before it was written down.
    class DeclarationError < StandardError; end

    # Raised when a class includes this concern and never declares.
    #
    # Named, and deliberately NOT an ArgumentError, because both silent failures
    # it replaces were unreadable: a plain class raised `ArgumentError: wrong
    # number of arguments`, the very class a REFUSAL raises, and a Data value in
    # the shape documented above recursed `check!` -> `new` -> `check!` into
    # SystemStackError. A missing declaration must never be mistakable for a
    # refused value.
    class NoDeclaration < DeclarationError; end

    # Raised when {ClassMethods#settle!} reaches an attribute holding something
    # it may not copy -- a live collaborator, a cycle, or a container whose
    # behaviour a frozen copy would lose.
    class UnsettleableAttribute < DeclarationError; end

    # Raised when a constructor passes a name the declaration does not carry.
    #
    # ActiveModel raises `UnknownAttributeError` here, whose message names an
    # anonymous carrier by heap address. Letting that escape would also make
    # ActiveModel part of a constructor's contract, when the whole point of the
    # carrier is that it is an implementation detail of HOW we validate.
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
      # `declare` replaces this with the subclass it built. Anything else has
      # nothing to validate against.
      #
      # @return [Class]
      # @raise [NoDeclaration] if the includer never declared
      def declared_carrier
        raise NoDeclaration, "#{self} includes Declarative but never declared" unless self <= Carrier

        self
      end

      # @return [Class] exception class a refusal raises, unless `declare` named another
      def refusal = ArgumentError

      # Validate the kwargs and discard the carrier, returning nothing a caller
      # could hold on to.
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

      # Raise naming EVERY offending attribute -- the message is `"<attribute>
      # <message>"` per error, joined by `", "`, so it reads as diagnostically as
      # the guard clause it replaces and one raise reports the whole refusal
      # rather than the first half of it.
      def validated(**attrs)
        carrier = declared_carrier.build(**attrs)
        return carrier if carrier.valid?

        raise refusal, carrier.errors.map { |error| "#{error.attribute} #{error.message}" }.join(", ")
      end
    end
  end
end

require_relative "declarative/types"
require_relative "declarative/carrier"
