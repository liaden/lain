# frozen_string_literal: true

module Lain
  class Tool
    # What a tool round has to work with: the window, the turn that made the
    # calls, the reply ceiling, and that turn's digest.
    #
    # @!attribute [r] window
    #   @return [Integer] the context window in tokens
    # @!attribute [r] usage
    #   @return [Usage] the turn that made the calls
    # @!attribute [r] ceiling
    #   @return [Integer] the output cap in tokens
    # @!attribute [r] head
    #   @return [String, nil] that turn's digest, named by the record because call ids can repeat
    Room = Data.define(:window, :usage, :ceiling, :head)
  end
end
