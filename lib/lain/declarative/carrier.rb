# frozen_string_literal: true

require "active_model"

module Lain
  module Declarative
    # A throwaway ActiveModel carrier for the attributes a class is constructed
    # under: their defaults, their coercions, their validations, and the refusal.
    #
    # A frozen value object must never `include ActiveModel::Validations` itself:
    # the first `valid?`/`invalid?` call materializes both an `@errors` AND a
    # `@context_for_validation` ivar, both mutable, and either one surviving to
    # `freeze` flips `Ractor.shareable?` to false -- the mechanical spec for "no
    # reachable mutable state". So construction is validated on a SEPARATE
    # carrier that is checked and discarded: the value object never touches
    # ActiveModel, and its shareability is preserved by construction rather than
    # by remembering to scrub whichever ivars ActiveModel happens to leave
    # behind.
    #
    # Subclass it, declare `attribute`/`validates` like any ActiveModel, and
    # reach it from a constructor through {Lain::Declarative.check!} (refuse and
    # discard) or {Lain::Declarative.settle!} (refuse, then take the settled
    # values). `declare do ... end` builds an anonymous subclass for a value that
    # would never mention its carrier by name. Subclassing and declaring are two
    # entry points onto one mechanism; this class is the carrier both validate.
    #
    # Like {Lain::Tool::Input}, these validations check SHAPE, not safety.
    class Carrier
      include ActiveModel::Model
      include ActiveModel::Attributes
      include Declarative

      # ActiveModel::Naming needs a name for `errors.full_messages`; an anonymous
      # carrier (built by a DSL) would raise before it could report the error.
      # Named subclasses fall back to their own constant name. Same reason as
      # {Lain::Tool::Input.model_name}.
      def self.model_name
        @model_name ||= ActiveModel::Name.new(self, nil, name || "Carrier")
      end

      # The class this carrier validates for. A named subclass declares itself;
      # `declare` replaces this with the class whose body built it, so an
      # anonymous carrier's refusal names something a reader can go and find.
      def self.declarer = self

      # Construct, containing ActiveModel's own exception here rather than
      # letting it escape: the carrier is an implementation detail of HOW a
      # declaration validates, so `ActiveModel::UnknownAttributeError` -- whose
      # message names an anonymous carrier by heap address -- must not become
      # part of a constructor's contract.
      #
      # @raise [UndeclaredAttribute] if a name the declaration does not carry was passed
      def self.build(**attrs)
        new(**attrs)
      rescue ActiveModel::UnknownAttributeError => e
        raise UndeclaredAttribute,
              "#{declarer} was constructed with :#{e.attribute}, which its declaration does not carry -- " \
              "it declares #{attribute_names.join(", ")}."
      end

      # The declared attributes with their defaults applied, their types cast,
      # symbol-keyed for `super(**settled)`, and deeply frozen.
      #
      # @return [Hash{Symbol => Object}] frozen
      # @raise [UnsettleableAttribute] if an attribute holds something uncopyable
      def settled
        attributes.each_with_object({}) { |(name, value), acc| acc[name.to_sym] = Copy.new(name).of(value) }.freeze
      end

      # One attribute's value, deeply frozen -- or the refusal naming what could
      # not be copied.
      #
      # The value/collaborator distinction is drawn by what may be COPIED, not by
      # what may be frozen, and that inversion is the whole design: a collection
      # is rebuilt and a String is duped, so settling NEVER calls `#freeze` on an
      # object its caller handed it. The alternative was measured -- a bare
      # `#freeze` on an attribute holding `$stdout` freezes STDOUT and kills the
      # interpreter's output for the rest of the process -- and in a codebase
      # whose central discipline is an injected {Lain::Sink}, that hazard is live
      # rather than theoretical.
      #
      # An object, rather than a recursive private method, because the walk
      # carries two pieces of state: the attribute's name, which every refusal
      # has to report, and the containers currently OPEN on the path, which is
      # how a cycle is told from mere sharing.
      class Copy
        # @param attribute [String] name of the attribute being settled
        def initialize(attribute)
          @attribute = attribute
          @open = {}.compare_by_identity
        end

        # @param value [Object]
        # @return [Object] deeply frozen
        # @raise [UnsettleableAttribute]
        def of(value)
          copy = frozen_copy(value)
          return copy if Ractor.shareable?(copy)

          # Belt and braces. The walk refuses everything it knows it cannot copy;
          # this refuses anything it was wrong about, so "deeply frozen" is
          # asserted on the one exit path rather than argued for in a comment.
          refuse(copy, "is still not Ractor.shareable? once copied")
        end

        private

        def frozen_copy(value)
          return value if Ractor.shareable?(value)
          return string_copy(value) if value.is_a?(String)
          return traverse(value) { value.map { |element| frozen_copy(element) } } if value.instance_of?(Array)
          return hash_copy(value) if value.instance_of?(Hash)

          refuse(value, "is not a String, an Array, a Hash, or a value that is already Ractor.shareable?")
        end

        # `dup` copies ivars faithfully, so a String carrying one comes back
        # frozen around something mutable. Naming the ivars beats letting the
        # shareability assert report that a String is not a String.
        def string_copy(string)
          refuse(string, "carries instance variables, which its frozen copy would keep") if
            string.instance_variables.any?

          string.dup.freeze
        end

        # `instance_of?`, not `is_a?`: rebuilding as a plain frozen literal is
        # only honest for a plain literal. A Hash subclass and an Array subclass
        # collapse to their base class, and all three states below are lost --
        # every one of them silently, because the shareability assert cannot see
        # a copy that is shareable and wrong.
        def hash_copy(hash)
          if stateful?(hash)
            refuse(hash, "carries lookup behaviour (a default, a default_proc, or compare_by_identity) that a " \
                         "frozen copy would lose")
          end

          traverse(hash) { hash.to_h { |key, value| [frozen_copy(key), frozen_copy(value)] } }
        end

        def stateful?(hash) = !hash.default.nil? || !hash.default_proc.nil? || hash.compare_by_identity?

        # The open set is the current PATH, marked on entry and cleared on exit,
        # not everything already visited: a container reached again from INSIDE
        # itself is a cycle, while the same container reached twice side by side
        # is merely shared and copies twice. Without this the recursion below is
        # a SystemStackError -- one of the two failures {NoDeclaration}'s
        # docstring exists to prevent, put back by the copy that replaced it.
        def traverse(container)
          refuse(container, "contains itself, and a cycle has no frozen copy") if @open.key?(container)

          @open[container] = true
          copy = yield.freeze
          @open.delete(container)
          copy
        end

        # "reaches", not "holds": the offender is whatever the walk was looking
        # at when it gave up, which for a nested collaborator is several
        # containers down. Naming the container instead reports that an attribute
        # holds an Array and that an Array is allowed -- two facts that together
        # say nothing.
        def refuse(value, reason)
          raise UnsettleableAttribute,
                "#{@attribute} cannot be settled: it reaches #{value.class}, which #{reason}. A declaration " \
                "carrying something settle! cannot copy wants check!, which settles nothing."
        end
      end
    end
  end
end
