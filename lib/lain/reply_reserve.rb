# frozen_string_literal: true

module Lain
  # The room a reply needs, apart from `max_tokens`, which is a wire ceiling a
  # generous value costs nothing to raise. Reserving the whole ceiling would
  # starve a small window, so the reserve is an eighth of it, floored, and never
  # over half: a reserve the size of the window puts the compaction trigger at
  # zero.
  #
  # @!attribute [r] tokens
  #   @return [Integer]
  # @!attribute [r] basis
  #   @return [Symbol, nil] the provenance of the window it was computed from
  ReplyReserve = Data.define(:tokens, :basis) do
    # @param window [Integer] the context window in tokens
    # @param ceiling [Integer] the output cap in tokens
    # @param basis [Symbol, nil] the window's provenance, carried not interpreted
    # @return [ReplyReserve]
    def self.for(window:, ceiling:, basis: nil)
      share = [4_096, window / 8].max
      new(tokens: [ceiling, share, window / 2].min, basis:)
    end
  end
end
