# frozen_string_literal: true

module Lain
  class Tool
    # What a tool round has to work with: the window, the turn that made the
    # calls, and the reply ceiling.
    #
    # @!attribute [r] window
    #   @return [Integer] the context window in tokens
    # @!attribute [r] usage
    #   @return [Usage] the turn that made the calls
    # @!attribute [r] ceiling
    #   @return [Integer] the output cap in tokens
    Room = Data.define(:window, :usage, :ceiling)
  end
end
