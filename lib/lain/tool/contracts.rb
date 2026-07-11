# frozen_string_literal: true

module Lain
  class Tool
    # Design-by-contract for tools, in the Eiffel sense: preconditions that must
    # hold before the work, postconditions that must hold after.
    #
    # Split from {Lain::Tool} because it answers a different question. The Tool
    # says what a capability *is*; Contracts says what must be true around using
    # it. The motivating case is `edit_file` requiring "this file was read this
    # session" -- an invariant the tool depends on but does not establish, and one
    # a free-form `bash` tool structurally cannot express.
    #
    # A violated predicate RAISES. That is deliberate and is not in tension with
    # correctness gate 3 (a failing tool must never propagate past the loop): the
    # contract mechanism stays honest, and {Lain::Handler::Live} converts the raise
    # into an error Result at the one boundary the loop trusts. Contract violations
    # are our bugs; tool failures are the world's.
    module Contracts
      def self.included(base)
        base.extend(ClassMethods)
      end

      # Declared on the tool class, inherited and composed down the ancestry.
      module ClassMethods
        # Something that must hold *before* the tool runs, checked against
        # `(input, invocation)` -- the SAME {Tool::Invocation} the tool's
        # `#perform` receives (see {Handler::Live#dispatch}), so the
        # caller-threaded context (e.g. a session read-set) is reached through
        # `invocation.context`, not off the Invocation directly. A false predicate
        # raises {Tool::ContractViolation}, so the model learns of the violation
        # as a failed tool call, not a crash.
        #
        #   requires("file was read this session") do |input, invocation|
        #     invocation.context.read?(input["path"])
        #   end
        def requires(message, &predicate)
          own_preconditions << build_contract(message, predicate)
        end

        # Something that must hold *after* the tool runs, checked against
        # `(input, invocation, result)`. Turns a silent wrong answer into a loud one.
        def ensures(message, &predicate)
          own_postconditions << build_contract(message, predicate)
        end

        # Base-class contracts first, so an inherited invariant is checked before a
        # subclass's own. Collected across the ancestry rather than stored once, so
        # subclasses compose contracts instead of overwriting them.
        def preconditions
          contracts_along_ancestry(:own_preconditions)
        end

        def postconditions
          contracts_along_ancestry(:own_postconditions)
        end

        # Contracts declared directly on this class, not its ancestors.
        def own_preconditions
          @own_preconditions ||= []
        end

        def own_postconditions
          @own_postconditions ||= []
        end

        private

        def build_contract(message, predicate)
          raise ArgumentError, "a contract needs a predicate block" unless predicate

          Contract.new(message: message.to_s, predicate: predicate)
        end

        def contracts_along_ancestry(reader)
          ancestors
            .select { |ancestor| ancestor.is_a?(Class) && ancestor <= Tool }
            .reverse
            .flat_map { |ancestor| ancestor.public_send(reader) }
        end
      end

      private

      def check_preconditions!(input, context)
        self.class.preconditions.each do |contract|
          satisfied = instance_exec(input, context, &contract.predicate)
          raise ContractViolation, "precondition failed for #{name}: #{contract.message}" unless satisfied
        end
      end

      def check_postconditions!(input, context, result)
        self.class.postconditions.each do |contract|
          satisfied = instance_exec(input, context, result, &contract.predicate)
          raise ContractViolation, "postcondition failed for #{name}: #{contract.message}" unless satisfied
        end
      end
    end
  end
end
