# frozen_string_literal: true

module Lain
  class Agent
    # The run's token ledger.
    #
    # Split out of the Agent for the same reason Budget was: rolling up and
    # recording spend is bookkeeping, not the loop's job. Per-turn cost lives in
    # the Journal, one {Telemetry::TurnUsage} per model call, keyed by the committed
    # turn's digest (see {Telemetry::TurnUsage} for why content never carries its price).
    class Accounting
      # The run's cumulative {Usage}; the monoid sum of every observed response.
      attr_reader :usage

      # @param journal [#<<] where TurnUsage records land; the Null channel by
      #   default, so no caller guards `if journal`
      def initialize(journal: Channel::Null.instance)
        @journal = journal
        @usage = Usage.zero
        @last_turn_usage = nil
      end

      # Roll one model response into the running total and journal it against
      # the turn it was committed as.
      #
      # @param response [Lain::Response]
      # @param digest [String] the committed assistant turn's content address
      # @return [Lain::Usage] the cumulative usage, ready for a budget check
      def observe(response, digest:)
        @usage += response.usage
        @last_turn_usage = response.usage.total_input_tokens
        @journal << Telemetry::TurnUsage.new(
          digest:,
          model: response.model,
          stop_reason: response.stop_reason,
          usage: response.usage.to_h
        )
        @usage
      end

      # Current context occupancy: the most recent response's billed-on-the-way-in
      # tokens (`Usage#total_input_tokens`), not the run's cumulative sum. `#usage`
      # answers "what has this run spent"; compaction's `Need` needs "how full is
      # the context right now", which only the latest response can answer.
      #
      # @return [Integer, nil] nil before any turn -- distinct from zero, which
      #   would read as an empty context on a resumed session whose Accounting is
      #   fresh but whose Timeline is not
      attr_reader :last_turn_usage
    end
  end
end
