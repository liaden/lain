# frozen_string_literal: true

require_relative "../channel"
require_relative "../event"
require_relative "../usage"

module Lain
  class Agent
    # The run's token ledger.
    #
    # Split out of the Agent for the same reason Budget was: rolling up and
    # recording spend is bookkeeping, not the loop's job. Per-turn cost lives in
    # the Journal, one {Event::TurnUsage} per model call, keyed by the committed
    # turn's digest (see {Event::TurnUsage} for why content never carries its price).
    class Accounting
      # The run's cumulative {Usage}; the monoid sum of every observed response.
      attr_reader :usage

      # @param journal [#<<] where TurnUsage records land; the Null channel by
      #   default, so no caller guards `if journal`
      def initialize(journal: Channel::Null.instance)
        @journal = journal
        @usage = Usage.zero
      end

      # Roll one model response into the running total and journal it against
      # the turn it was committed as.
      #
      # @param response [Lain::Response]
      # @param digest [String] the committed assistant turn's content address
      # @return [Lain::Usage] the cumulative usage, ready for a budget check
      def observe(response, digest:)
        @usage += response.usage
        @journal << Event::TurnUsage.new(
          digest: digest,
          model: response.model,
          stop_reason: response.stop_reason,
          usage: response.usage.to_h
        )
        @usage
      end
    end
  end
end
