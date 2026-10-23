# frozen_string_literal: true

module Lain
  module Friction
    # Names why a prompt prefix broke between two calls, from what a
    # `request_sent` record kept of the prefix. Anthropic's cache is a prefix
    # match over tools, then system, then messages, so the first layer that
    # differs is the cause and the checks run in that order.
    module BreakCause
      CAUSES = %i[tools_changed tool_order_changed system_changed effort_changed
                  history_edited ttl_expired unknown].freeze

      LABELS = { history_edited: "earlier messages edited", ttl_expired: "TTL expired" }.freeze

      # Names and digests only: a Shape is held per call for a whole session,
      # so it must never keep payload bytes.
      Shape = Data.define(:tool_names, :tools_digest, :system_digest, :effort_digest, :at)

      # The cache TTL is not in the journal, so the 5 minute default is assumed.
      DEFAULT_TTL = 300

      # @param record [Hash] a `request_sent` journal record
      # @return [Shape, nil] nil when the payload was not recorded
      def self.shape_of(record)
        payload = record["payload"]
        return nil unless payload.is_a?(Hash)

        tools = Array(payload["tools"])
        Shape.new(tool_names: tools.map { |tool| tool.is_a?(Hash) ? tool["name"].to_s : "" }.freeze,
                  tools_digest: Canonical.digest(tools), system_digest: Canonical.digest(payload["system"]),
                  effort_digest: Canonical.digest(payload["reasoning"]), at: stamped(record["ts"]))
      end

      # @param before [Shape, nil]
      # @param after [Shape, nil]
      # @param ttl [Numeric] seconds a cache entry lives
      # @param cold [Boolean] whether the later call read nothing from the cache
      # @return [Symbol] one of {CAUSES}
      def self.between(before, after, ttl: DEFAULT_TTL, cold: true)
        return :unknown if before.nil? || after.nil?

        changed_layer(before, after) || (expired?(before, after, ttl, cold) ? :ttl_expired : :history_edited)
      end

      def self.changed_layer(before, after)
        return tools_cause(before, after) if before.tools_digest != after.tools_digest
        return :system_changed if before.system_digest != after.system_digest

        :effort_changed if before.effort_digest != after.effort_digest
      end
      private_class_method :changed_layer

      def self.tools_cause(before, after)
        reordered = before.tool_names != after.tool_names && before.tool_names.sort == after.tool_names.sort
        reordered ? :tool_order_changed : :tools_changed
      end
      private_class_method :tools_cause

      def self.expired?(before, after, ttl, cold)
        cold && before.at && after.at && after.at - before.at > ttl
      end
      private_class_method :expired?

      def self.stamped(value)
        Time.iso8601(value).freeze if value.is_a?(String)
      rescue ArgumentError
        nil
      end
      private_class_method :stamped
    end
  end
end
