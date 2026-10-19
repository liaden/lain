# frozen_string_literal: true

module Lain
  module Telemetry
    # A tool round whose results a {Tool::RoundBudget} shortened: which policy,
    # how many bytes it allowed, and what became of each call. Written only
    # when a result was withheld or deduplicated, so a round that went through
    # whole leaves no line.
    #
    # @!attribute [r] head
    #   @return [String, nil] the digest of the assistant turn that made the
    #     calls, since a provider may reuse call ids round after round
    # @!attribute [r] basis
    #   @return [String] the policy, `window` or `static`
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
        ids = ->(list) { list.map { |id| id.to_s.dup.freeze }.freeze }
        super(head: head&.then { |digest| -digest.to_s }, basis: basis.to_s.dup.freeze, budget: Integer(budget),
              delivered: ids.call(delivered), deduplicated: ids.call(deduplicated), withheld: ids.call(withheld))
      end
    end
  end
end
