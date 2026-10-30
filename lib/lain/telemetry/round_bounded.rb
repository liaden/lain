# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # The budget must be an integer, so a string never journals as a byte count.
      class RoundBounded < Declarative::Carrier
        attribute :head
        attribute :basis, :lain_interned
        attribute :budget, :lain_strict_integer
        attribute :delivered, :lain_canonical
        attribute :deduplicated, :lain_canonical
        attribute :withheld, :lain_canonical
      end
    end

    # A tool round whose results a {Tool::RoundBudget} shortened: which policy,
    # how many bytes it allowed, and what became of each call. Written only
    # when a result was withheld or deduplicated, so a round that went through
    # whole leaves no line.
    #
    # @!attribute [r] head
    #   @return [String, nil] the digest of the assistant turn that made the
    #     calls, since a provider may reuse call ids round after round
    # @!attribute [r] basis
    #   @return [String] the policy, `window`, `static` or `dedup`
    # @!attribute [r] budget
    #   @return [Integer] the bytes the round's results could spend
    # @!attribute [r] delivered
    #   @return [Array<String>] the call ids answered with their own result
    # @!attribute [r] deduplicated
    #   @return [Array<String>] the call ids answered by naming an earlier call
    # @!attribute [r] withheld
    #   @return [Array<String>] the call ids answered with an error
    RoundBounded = Data.define(:head, :basis, :budget, :delivered, :deduplicated, :withheld) do
      include Journalable

      def initialize(head:, basis:, budget:, delivered:, deduplicated:, withheld:)
        ids = ->(list) { list.map(&:to_s) }
        super(**Carriers::RoundBounded.settle!(head: head&.to_s, basis:, budget:, delivered: ids.call(delivered),
                                               deduplicated: ids.call(deduplicated), withheld: ids.call(withheld)))
      end
    end
  end
end
