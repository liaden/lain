# frozen_string_literal: true

require_relative "strategy/replacement"
require_relative "strategy/base"
require_relative "strategy/identity"

module Lain
  module Compaction
    # HOW a span collapses, kept swappable: asking a model to summarize it,
    # dropping it to an attested elision, and collapsing a finished plan step to
    # a deterministic marker are three policies over one span, and they should be
    # comparable like every other axis of this bench.
    #
    # {Base} is the duck -- which sub-spans to collapse, and what replaces one --
    # and {Identity} is its Null. {Replacement} is what a collapse answers, and
    # DROP is the unit that makes a range vanish.
    module Strategy
    end
  end
end
