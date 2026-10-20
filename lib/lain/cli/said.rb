# frozen_string_literal: true

module Lain
  module CLI
    # What a command said and how it went, returned together so the status is
    # the answer's own and not state the command object keeps between calls.
    #
    # @!attribute [r] text
    #   @return [String] the words to print
    # @!attribute [r] status
    #   @return [Integer] the process exit status; 0 leaves Thor's normal return
    Said = Data.define(:text, :status) do
      def initialize(text:, status:) = super(text: -text, status:)
    end
  end
end
