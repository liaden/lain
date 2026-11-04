# frozen_string_literal: true

module Lain
  class StatusFeed
    # A session journal observer handing the feed every payment that is not the
    # chat's own turn: a spawned child's, and the judge's. The tee writes through
    # that journal too, so every record the feed already folds passes here as
    # well, and only those are taken.
    class ChildPayments
      # @param feed [#paid_aside]
      def initialize(feed)
        @feed = feed
      end

      # @param entry [Object] any record the journal wrote
      # @return [self]
      def <<(entry)
        @feed.paid_aside(entry) if entry.is_a?(Telemetry::TurnUsage) && (entry.spawn || !entry.agent?)
        self
      end
    end
  end
end
