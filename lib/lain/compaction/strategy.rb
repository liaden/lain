# frozen_string_literal: true

module Lain
  module Compaction
    # HOW a span collapses, kept swappable: asking a model to summarize it,
    # dropping it to an attested elision, and collapsing a finished plan step to
    # a deterministic marker are three policies over one span, comparable like
    # every other axis of this bench.
    #
    # {Base} is the duck and {Identity} its Null. {Replacement} is what a
    # collapse answers, and DROP is the unit that makes a range vanish.
    # {Composed} runs two of them over one span, a commutative monoid with
    # {Identity} as its unit.
    module Strategy
    end
  end
end
