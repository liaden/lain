# frozen_string_literal: true

module Lain
  module EventLog
    # The one projection from walked turns to the messages a provider is sent,
    # shared by {Ext::Timeline#messages}, the compaction head and the derivation walk.
    module Messages
      # Shareable without a deep copy because a turn's content is already frozen.
      #
      # @param turns [Array<Ext::Event>] root first
      # @return [Array<Hash>] deep frozen
      def self.project(turns)
        turns.map { |turn| { "role" => turn.role, "content" => turn.content }.freeze }.freeze
      end
    end
  end
end
