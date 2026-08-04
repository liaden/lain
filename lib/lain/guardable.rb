# frozen_string_literal: true

require "active_support/concern"

module Lain
  # Declarative validate-then-freeze for a value class that must never include
  # ActiveModel itself -- {Lain::Guard} is the authority on why that matters.
  #
  # `guard` builds a {Lain::Guard} subclass for the including class and evaluates
  # the block in it, so `attribute` and `validates` read exactly as they do in a
  # named Guard; `check!` then validates a throwaway instance of that carrier and
  # discards it. ONE mechanism with two entry points, not two mechanisms:
  # subclass {Lain::Guard} where the carrier is worth a name and a docstring of
  # its own, declare `guard` where the rules belong to the value and nothing else
  # would ever mention the carrier.
  #
  #   Epics = Data.define(:home) do
  #     include Guardable
  #
  #     guard raising: InvalidHome do
  #       attribute :home, :string
  #       validates :home, inclusion: { in: ->(_) { HOMES } }
  #     end
  #
  #     def initialize(home:)
  #       self.class.check!(home:)   # BEFORE super: super is when the value freezes
  #       super
  #     end
  #   end
  #
  # A validation set given as a lambda is called at VALIDATION time, so the class
  # body evaluates during `require` without resolving it -- which is what lets a
  # guard cite a constant defined further down the load manifest than the file
  # declaring the guard.
  #
  # `raising:` is per-GUARD, not per-rule. A namespace needing a different
  # exception class per broken rule computes that where the rule lives and keeps
  # the shape checks here; growing this concern to raise per rule would put the
  # translation in the wrong object.
  #
  # Like {Lain::Tool::Input}, these validations check SHAPE, not safety.
  module Guardable
    extend ActiveSupport::Concern

    # Raised when a class includes this concern and never declares a guard.
    #
    # Named, and deliberately NOT an ArgumentError, because both silent failures
    # it replaces were unreadable: a plain class raised `ArgumentError: wrong
    # number of arguments`, the very class a REFUSAL raises, and a Data value in
    # the shape documented above recursed `check!` -> `new` -> `check!` into
    # SystemStackError. A missing declaration must never be mistakable for a
    # refused value.
    class NoGuardDeclared < Error; end

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
      def guard(raising: ArgumentError, &block)
        carrier = Class.new(Guard, &block)
        define_singleton_method(:guard_carrier) { carrier }
        # On BOTH, so the answer is the same whichever one a caller asks: the
        # carrier is reachable and answers `check!` in its own right.
        [self, carrier].each { |scope| scope.define_singleton_method(:refusal) { raising } }
      end

      # The class whose attributes and validations {check!} runs. A {Lain::Guard}
      # IS a carrier and so validates itself; `guard` replaces this with the
      # subclass it built. Anything else has nothing to validate against.
      #
      # @return [Class]
      # @raise [NoGuardDeclared] if the includer never declared a guard
      def guard_carrier
        raise NoGuardDeclared, "#{self} includes Guardable but never declared a guard" unless self <= Guard

        self
      end

      # @return [Class] exception class a refusal raises, unless `guard` named another
      def refusal = ArgumentError

      # Validate the kwargs and raise, naming EVERY offending attribute -- the
      # message is `"<attribute> <message>"` per error, joined by `", "`, so it
      # reads as diagnostically as the guard clause it replaces and one raise
      # reports the whole refusal rather than the first half of it. The carrier
      # is never returned or stored, so ActiveModel's `@errors` and
      # `@context_for_validation` die with it.
      #
      # @param attrs [Hash] the constructor's arguments, by attribute name
      # @return [void]
      def check!(**attrs)
        carrier = guard_carrier.new(**attrs)
        return if carrier.valid?

        raise refusal, carrier.errors.map { |error| "#{error.attribute} #{error.message}" }.join(", ")
      end
    end
  end
end
