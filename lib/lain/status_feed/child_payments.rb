# frozen_string_literal: true

module Lain
  class StatusFeed
    # A session journal observer handing a spawned child's payments to the
    # feed. The tee writes through that journal too, so every record the feed
    # already folds passes here as well, and only the child's are taken.
    class ChildPayments
      # @param feed [#child_paid]
      def initialize(feed)
        @feed = feed
      end

      # @param entry [Object] any record the journal wrote
      # @return [self]
      def <<(entry)
        @feed.child_paid(entry) if entry.is_a?(Telemetry::TurnUsage) && entry.spawn
        self
      end
    end
  end
end
