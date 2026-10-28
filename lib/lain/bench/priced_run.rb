# frozen_string_literal: true

require "bigdecimal"

module Lain
  module Bench
    # The priced preflight a live sweep shares: the requests it counted, what a human is asked to
    # confirm, the dollar ceiling each lane then runs under, and the wording of the halt a dollar
    # stop leaves for the lanes after it. `unit` names what a sweep runs ("lane", "question").
    class PricedRun
      DOLLAR_HALT = "not run: an earlier %s passed its dollar ceiling"
      LANE = ->(request) { [request.arm, request.journal] }

      # @param counted [Array<CompactionSweep::Live::Counted>]
      # @param price_book [PriceBook]
      # @param model [String]
      # @param confirm [#call, nil] answers the {CompactionSweep::Live::Preflight} with whether to spend
      # @param unit [String]
      # @param key [#call] names the lane a counted request belongs to
      def initialize(counted:, price_book:, model:, confirm:, unit:, key: LANE)
        @counted = counted
        @price_book = price_book
        @model = model
        @confirm = confirm
        @unit = unit
        @key = key
      end

      # @return [CompactionSweep::Live::Preflight]
      def preflight
        @preflight ||= Ractor.make_shareable(project)
      end

      # @return [Hash{Object => Budget::Ceilings}] each lane's dollar ceiling, its projection times
      #   {CompactionSweep::Live::CEILING}
      # @raise [CompactionSweep::Live::Declined] unless the preflight is confirmed
      def ceilings
        raise CompactionSweep::Live::Declined, CompactionSweep::Live::DECLINED unless @confirm.call(preflight)

        preflight.requests.group_by(&@key).transform_values do |requests|
          Budget.ceilings.with(dollars: requests.sum(BigDecimal(0), &:cost) * CompactionSweep::Live::CEILING)
        end
      end

      # @param stop [Exception, nil]
      # @return [String, nil] what later lanes are told, when this stop was a dollar ceiling
      def halt_for(stop)
        format(DOLLAR_HALT, @unit) if stop.is_a?(Budget::Exceeded) && stop.kind == :dollars
      end

      private

      def project
        boundary = @price_book.price(@model).tiers.map(&:above_prompt_tokens).min
        CompactionSweep::Live::Preflight.new(
          requests: @counted,
          projected: @counted.group_by(&:arm).transform_values { _1.sum(BigDecimal(0), &:cost) },
          over_tier: boundary ? @counted.select { _1.tokens > boundary } : []
        )
      end
    end
  end
end
