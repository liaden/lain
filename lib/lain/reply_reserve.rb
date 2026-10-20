# frozen_string_literal: true

module Lain
  # The room a reply needs, apart from `max_tokens`, which is a wire ceiling a
  # generous value costs nothing to raise. Reserving the whole ceiling would
  # starve a small window, so the reserve is an eighth of it, floored, and never
  # over half: a reserve the size of the window puts the compaction trigger at
  # zero.
  module ReplyReserve
    # Below a 32,768-token window the floor term decides and the eighth never binds.
    FLOOR_TOKENS = 4_096

    # @param window [Integer] the context window in tokens
    # @param ceiling [Integer] the output cap in tokens
    # @return [Integer] tokens held back for the next reply
    def self.tokens(window:, ceiling:)
      floor = [FLOOR_TOKENS, window / 4].min
      [ceiling, [floor, window / 8].max, window / 2].min
    end
  end
end
