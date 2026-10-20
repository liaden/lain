# frozen_string_literal: true

module Lain
  module Approval
    class Ladder
      # The one place a fault suppresses a later automatic allow, applied at a
      # ladder's edge. An allow reached after any rung faulted becomes "nobody
      # decided", attributed to the rung that broke: a later rule is the same
      # kind of authority as the one that failed, so its yes proves nothing.
      #
      # The edge is also where a reason nobody has read yet is worked out,
      # once, so the outcome it hands out is a deeply frozen value.
      #
      # A deny past a fault still decides. The `exempt` authority's allow
      # stands too, because a human is the authority the ladder escalates TO,
      # and throwing their answer away wedges the session.
      class Poisoning
        # @param ladder [#call] answering an {Outcome}
        # @param exempt [Symbol, nil] the authority whose allow a fault never
        #   suppresses; nil exempts nobody
        def initialize(ladder, exempt: nil)
          @ladder = ladder
          @exempt = exempt
          freeze
        end

        # @return [Outcome]
        def call(*input)
          outcome = @ladder.call(*input).asked
          return outcome unless outcome.faulted? && outcome.allow? && !exempt?(outcome.decision)

          outcome.with(decision: nil, by: outcome.faults.first.rung)
        end

        private

        def exempt?(decision) = !@exempt.nil? && decision.respond_to?(:authority) && decision.authority == @exempt
      end
    end
  end
end
