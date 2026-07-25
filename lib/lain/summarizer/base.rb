# frozen_string_literal: true

module Lain
  module Summarizer
    # The contract every declared summarizer implements: a predicate saying what
    # it handles, and the compaction itself.
    #
    #   suitable?(result) -> Boolean
    #   compact(result)   -> String
    #
    # A summarizer is PURE and SYNCHRONOUS -- text in, text out. No provider, no
    # model, no IO. That restraint IS the tier's value: it compacts a tool result
    # for no tokens and no latency, which is the whole reason to try it before
    # asking a model to summarize.
    #
    # Both methods raise {NotImplementedError} NAMING the summarizer, in the
    # shape {Arm#run} uses -- a declaration that implements neither fails loudly
    # at the first result it is offered rather than silently doing nothing. The
    # name, not `self.class`, does the naming: every declared summarizer is an
    # ANONYMOUS subclass (see {Builder}), so `self.class` would print an object
    # address where the user needs to read which of their declarations is at
    # fault.
    #
    # Frozen on construction ({Freezable}) -- but only for a summarizer built
    # through THIS initialize. A user's own `initialize` is defined on the
    # declared subclass, which sits ahead of this prepend in the MRO, so
    # {Builder} freezes the instance again after construction; neither freeze is
    # redundant.
    #
    # Both freezes are SHALLOW, so purity is only PARTLY mechanical: they stop a
    # summarizer taking on new ivars (a `@memo ||=` in `compact` raises), but an
    # object a user assigned in their own `initialize` can still be mutated in
    # place, and such a summarizer does accumulate across calls. The bar that
    # would state purity outright is this codebase's usual one --
    # `Ractor.shareable?(summarizer)`, false for exactly that leaky instance and
    # true for a well-behaved one. Not enforced yet; it is the acceptance test
    # for the deep-freeze follow-up.
    class Base
      prepend Freezable

      # The name the user declared, used to name this summarizer in errors.
      attr_reader :name

      def initialize(name)
        @name = -name.to_s
      end

      def suitable?(_result)
        raise NotImplementedError,
              "summarizer #{name.inspect} must implement #suitable?(result) -> Boolean"
      end

      def compact(_result)
        raise NotImplementedError,
              "summarizer #{name.inspect} must implement #compact(result) -> String"
      end
    end
  end
end
