# frozen_string_literal: true

module Lain
  class Sensitivity
    Masked = Data.define(:text, :fresh, :prior)

    # Reopened rather than defined with a `Data.define ... do` block: a constant
    # written inside that block is scoped to the enclosing module.
    #
    # Text after masking, and what it holds: `fresh` regions masked by this pass,
    # `prior` placeholders that were already in the input. They are kept apart
    # because a placeholder is a slot whose bytes are gone, so meeting one again
    # is a fact about the text and not a new secret.
    class Masked
      # @param text [String] text that was not masked and held no placeholder
      # @return [Masked]
      def self.plain(text) = new(text:, fresh: 0, prior: 0)

      def initialize(text:, fresh:, prior:)
        super(text: -text, fresh:, prior:)
      end

      # @param other [Masked] the text that follows this one
      # @return [Masked]
      def +(other) = self.class.new(text: text + other.text, fresh: fresh + other.fresh, prior: prior + other.prior)
    end
  end
end
