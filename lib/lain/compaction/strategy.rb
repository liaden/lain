# frozen_string_literal: true

require_relative "strategy/replacement"
require_relative "strategy/base"
require_relative "strategy/identity"
require_relative "strategy/elide"
# After the class it subclasses, whose #blocks it inherits rather than restates.
require_relative "strategy/elide_tool_observations"
require_relative "strategy/summarizing"
# After the parent whose oracle contract, journal address and answer memo it
# inherits, and whose #propose_ranges it calls once per run.
require_relative "strategy/summarize_conversation"
# Last: it composes the others, and its own refusal subclasses a value-level
# error rather than this file's alias, which is assigned below these requires.
require_relative "strategy/composed"

module Lain
  module Compaction
    # HOW a span collapses, kept swappable: asking a model to summarize it,
    # dropping it to an attested elision, and collapsing a finished plan step to
    # a deterministic marker are three policies over one span, and they should be
    # comparable like every other axis of this bench.
    #
    # {Base} is the duck -- which sub-spans to collapse, and what replaces one --
    # and {Identity} is its Null. {Replacement} is what a collapse answers, and
    # DROP is the unit that makes a range vanish. {Composed} runs two of them
    # over one span, which is a commutative monoid with {Identity} as its unit.
    module Strategy
    end
  end
end
