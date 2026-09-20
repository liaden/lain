# frozen_string_literal: true

module Lain
  class Context
    # The pair {Combinator#>>} fuses.
    #
    # Associativity falls out of this being plain function composition:
    # however you group the `>>`s, the resulting call order is the same, so
    # there is only one behavior to observe.
    class Composed < Combinator
      def initialize(first, second)
        super()
        @first = first
        @second = second
        freeze
      end

      def call(messages)
        @second.call(@first.call(messages))
      end

      # The union: a composed pipeline needs whatever either stage needs.
      def requires
        (@first.requires | @second.requires).freeze
      end

      # The FIRST stage alone decides, unlike #requires: `second` is handed
      # `first`'s output and can never see the list this composition was
      # called with, so a substituting stage blinds everything behind it. The
      # converse is what makes the union wrong here -- a reading stage in
      # front of a substituting one still reads.
      def reads_messages?
        @first.reads_messages?
      end
    end
  end
end
