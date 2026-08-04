# frozen_string_literal: true

module Lain
  # The diff-review surface: a changeset, the marks and notes a human leaves on
  # it, and the verdict that closes it.
  module Review
  end
end

# Vocabulary FIRST, and `records` LAST: every guard in `records` cites a closed
# set and a refusal message while its class body runs, and `Anchor::SIDES`
# derives from `Review::SIDES` at class-body time too. `vocabulary` and `wire`
# are mutually independent; only records-last actually binds.
require_relative "review/vocabulary"
require_relative "review/wire"
require_relative "review/anchor"
require_relative "review/records"
