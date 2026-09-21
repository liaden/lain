# frozen_string_literal: true

# After the class it subclasses, whose #blocks it inherits rather than restates.
# After the parent whose oracle contract, journal address and answer memo it
# inherits, and whose #propose_ranges it calls once per run.
# Last: it composes the others, and its own refusal subclasses a value-level
# error rather than this file's alias, which is assigned below these requires.

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
