# frozen_string_literal: true

module Lain
  # The diff-review surface: a changeset, the marks and notes a human leaves on
  # it, and the verdict that closes it.
  module Review
  end
end

# Vocabulary and wire FIRST: every guard in `records` cites a closed set and a
# refusal message while its class body runs.
require_relative "review/vocabulary"
require_relative "review/wire"
require_relative "review/records"
