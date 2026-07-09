# frozen_string_literal: true

module Lain
  # Structured events that flow through a {Lain::Channel}.
  #
  # Every event is a small, deeply frozen value object: two events with equal
  # attributes are equal (`Regular` in the project's algebra), and nothing about
  # an event can mutate after construction, so it is safe to share across
  # threads without copying.
  module Event
    # Common behaviour for events: value equality and immutability.
    #
    # Subclasses set their attributes and call {#deep_freeze!} at the end of
    # `initialize`; equality is then defined structurally over the class and the
    # frozen instance variables.
    class Base
      # @return [Boolean] structural equality over class and attributes
      def ==(other)
        other.is_a?(self.class) && self.class == other.class &&
          state == other.state
      end
      alias eql? ==

      # @return [Integer]
      def hash
        [self.class, state].hash
      end

      # The tuple of attribute values that defines this event's identity.
      # @return [Array]
      def state
        instance_variables.sort.map { |ivar| instance_variable_get(ivar) }
      end

      private

      # Freeze the receiver and each of its attribute values, giving a value
      # object that is immutable all the way down.
      # @return [self]
      def deep_freeze!
        instance_variables.each do |ivar|
          value = instance_variable_get(ivar)
          value.freeze
        end
        freeze
      end
    end

    # Genuine bytes emitted by a running tool, already attributed to the
    # `tool_use_id` that produced them and the stream they came from. A `bash`
    # subprocess's output enters the system as a stream of these, so provenance
    # is captured at the source rather than reconstructed later.
    class ToolOutput < Base
      # The only valid values for {#stream}.
      STREAMS = %i[stdout stderr].freeze

      # @return [String] the id of the `tool_use` block that produced the bytes
      attr_reader :tool_use_id
      # @return [Symbol] `:stdout` or `:stderr`
      attr_reader :stream
      # @return [String] the raw bytes
      attr_reader :bytes

      # @param tool_use_id [String]
      # @param stream [Symbol] `:stdout` or `:stderr`
      # @param bytes [String]
      # @raise [ArgumentError] if `stream` is not one of {STREAMS}
      def initialize(tool_use_id:, stream:, bytes:)
        super()
        unless STREAMS.include?(stream)
          raise ArgumentError, "stream must be one of #{STREAMS.inspect}, got #{stream.inspect}"
        end

        @tool_use_id = tool_use_id
        @stream = stream
        @bytes = bytes
        deep_freeze!
      end
    end
  end
end
