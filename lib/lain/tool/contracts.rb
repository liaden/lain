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
    # contract mechanism stays honest, and {Lain::Effect::Handler::Live} converts the raise
    # into an error Result at the one boundary the loop trusts. Contract violations
    # are our bugs; tool failures are the world's.
    module Contracts
      def self.included(base)
        base.extend(ClassMethods)
      end

      # Where a `subject:`-carrying message puts the subject it is given.
      SUBJECT_SLOT = "%<subject>s"

      # Declared on the tool class, inherited and composed down the ancestry.
      module ClassMethods
        # Something that must hold *before* the tool runs, checked against
        # `(input, invocation)` -- the SAME {Tool::Invocation} the tool's
        # `#perform` receives (see {Effect::Handler::Live#dispatch}), so the
        # caller-threaded context (e.g. a session read-set) is reached through
        # `invocation.context`, not off the Invocation directly. A false predicate
        # raises {Tool::ContractViolation}, so the model learns of the violation
        # as a failed tool call, not a crash.
        #
        #   requires("file was read this session") do |input, invocation|
        #     invocation.context.read?(input.path)
        #   end
        #
        # `subject:` makes the message name what it is refusing, the way
        # {Tool::Bounds#message} interpolates its own `subject` at call time: a
        # callable given the same `(input, invocation)` the predicate sees, its
        # answer filling the message's `%<subject>s` slot.
        #
        #   requires("%<subject>s was never read this session",
        #            subject: ->(input, invocation) { resolved_path(input, invocation) }) { ... }
        def requires(message, subject: nil, &predicate)
          own_preconditions << build_contract(message, predicate, subject)
        end

        # Something that must hold *after* the tool runs, checked against
        # `(input, invocation, result)`. Turns a silent wrong answer into a loud one.
        # `subject:` behaves as {#requires}' does, and is asked for the subject
        # of the CALL -- so it takes `(input, invocation)`, never the result.
        def ensures(message, subject: nil, &predicate)
          own_postconditions << build_contract(message, predicate, subject)
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

        def build_contract(message, predicate, subject)
          raise ArgumentError, "a contract needs a predicate block" unless predicate

          Contract.new(message: phrasing(message.to_s, subject), predicate:)
        end

        # A message and a `subject:` supplier are two halves of one decision, so
        # every mismatch between them is refused HERE, at class definition.
        # That timing is the whole point: the only code path that reads a
        # message is the refusal path, which a green suite almost never walks
        # and production walks constantly, so a defect parked there surfaces
        # first to a model already being refused.
        def phrasing(message, subject)
          return static(message) if subject.nil?

          interpolated(message, usable(subject))
        end

        # The message IS the finished sentence, stored as the String it was
        # written as: contracts stay inspectable ({Tool::Contract}'s reason for
        # being data), and -- less obviously -- a static message never reaches
        # `format`, so an ordinary `100% of it` cannot become a crash.
        #
        # A slot with no supplier is refused rather than passed through, and it
        # is the likelier of the two mismatches: dropping the keyword off a
        # working declaration is all it takes, and the model is then handed a
        # raw `%<subject>s` exactly where the file's name belongs.
        def static(message)
          raise ArgumentError, "#{SUBJECT_SLOT} needs a subject: supplier" if message.include?(SUBJECT_SLOT)

          message
        end

        # A thunk resolved at violation time. The slot is required rather than
        # optional -- a supplier the message has nowhere to put silently drops
        # the subject, which is the defect `subject:` exists to fix -- and the
        # template is rendered once here, because a slot's PRESENCE says nothing
        # about whether the rest of it survives `format`.
        def interpolated(message, subject)
          raise ArgumentError, "a subject: supplier needs a #{SUBJECT_SLOT} slot" unless message.include?(SUBJECT_SLOT)

          renderable(message)
          ->(input, invocation) { format(message, subject: instance_exec(input, invocation, &subject)) }
        end

        # `format` is strict about far more than the slot: a stray `%` reads as
        # a conversion and a second named slot has nothing to fill it, and both
        # raise. Trialling the template against an empty subject turns "dies at
        # the first refusal, in production" into "dies at class definition, in
        # every run".
        def renderable(message)
          format(message, subject: "")
        rescue ArgumentError, TypeError, KeyError => e
          raise ArgumentError, "a subject: message must survive format: #{e.class}: #{e.message}"
        end

        # A supplier is reached with `&`, which accepts far more than it can
        # use: `subject: :upcase` converts happily and then calls that method on
        # the INPUT, so it declares clean and dies on the refusal path with
        # `undefined method 'upcase' for an instance of Hash`. Demanding `#call`
        # makes "a callable taking (input, invocation)" the declared contract
        # rather than a convention.
        #
        # Arity is the other half, and only for arity-STRICT callables -- a
        # lambda or a Method. One written for a single argument raises a bare
        # `wrong number of arguments` in place of the sentence the model was
        # owed, again only on the refusal path. A plain proc is arity-tolerant
        # by design and is left alone: a constant subject that wants neither
        # argument is a legitimate supplier.
        def usable(subject)
          raise ArgumentError, "a subject: supplier must respond to #call" unless subject.respond_to?(:call)
          return subject unless strict_arity?(subject)
          return subject if subject.arity.negative? || subject.arity == 2

          raise ArgumentError, "a subject: supplier takes (input, invocation), not #{subject.arity}"
        end

        def strict_arity?(callable)
          callable.respond_to?(:arity) && (!callable.respond_to?(:lambda?) || callable.lambda?)
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
          violated!("precondition", contract, input, context) unless satisfied
        end
      end

      def check_postconditions!(input, context, result)
        self.class.postconditions.each do |contract|
          satisfied = instance_exec(input, context, result, &contract.predicate)
          violated!("postcondition", contract, input, context) unless satisfied
        end
      end

      def violated!(kind, contract, input, context)
        raise ContractViolation, "#{kind} failed for #{name}: #{sentence(contract, input, context)}"
      end

      # A static message is already the sentence; a `subject:`-carrying one is a
      # thunk, asked here so it resolves as the TOOL -- which is what puts a
      # private resolver like `EditFile#resolved_path` in its reach.
      def sentence(contract, input, context)
        phrasing = contract.message
        return phrasing unless phrasing.respond_to?(:call)

        instance_exec(input, context, &phrasing)
      end
    end
  end
end
