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

      # A JSON-object representation for {Lain::Journal}. Every event is already a
      # small attributed value, so its journal form is its attributes plus a
      # `type` tag that lets a reader discriminate the record without inspecting
      # its shape. The {Lain::Journal} adds durability and a timestamp; an event
      # only has to describe itself.
      # @return [Hash{String=>Object}]
      def to_journal
        attributes = instance_variables.to_h do |ivar|
          [ivar.to_s.delete_prefix("@"), instance_variable_get(ivar)]
        end
        { "type" => journal_type }.merge(attributes)
      end

      # The record's discriminator: the class's short name in snake_case, so
      # {ToolOutput} journals as `"tool_output"`. Overridable, but the default is
      # what a reader expects.
      # @return [String]
      def journal_type
        self.class.name.split("::").last.gsub(/([a-z])([A-Z])/, '\1_\2').downcase
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

    # A marker that N events were dropped to make room for newer ones. Emitted by
    # a drop-oldest channel (see {Lain::Channel::DropOldest}) so a consumer that
    # freely drops still learns *that* it dropped, and how many. The frontend can
    # render "... (12 events dropped)"; the Journal, which never drops, never
    # produces one. `count` is the number lost since the last marker was surfaced.
    class Dropped < Base
      # @return [Integer] events dropped since the previous marker (always > 0)
      attr_reader :count

      # @param count [Integer] number of dropped events (must be positive)
      # @raise [ArgumentError] if `count` is not a positive Integer
      def initialize(count:)
        super()
        unless count.is_a?(Integer) && count.positive?
          raise ArgumentError,
                "count must be a positive Integer, got #{count.inspect}"
        end

        @count = count
        deep_freeze!
      end
    end

    # A transport-level retry, made visible. A silent retry hides real spend --
    # on a bench whose headline metric is token cost, a retried (or dropped)
    # request can bill more than the reported Usage ever shows -- so every retry
    # lands here, in the Journal, where `Compare` can report attempts alongside
    # tokens. `will_retry_in` is nil once the attempts are exhausted.
    class ProviderRetry < Base
      # @return [Integer] 1 for the first retry, 2 for the second, ...
      attr_reader :attempt
      # @return [Float, nil] seconds the transport will back off before retrying,
      #   or nil when retries are exhausted and it is giving up
      attr_reader :will_retry_in
      # @return [Integer, nil] the failed response's HTTP status, when known
      attr_reader :status
      # @return [String, nil] what triggered the retry (an exception class name)
      attr_reader :reason

      def initialize(attempt:, will_retry_in: nil, status: nil, reason: nil)
        super()
        @attempt = attempt
        @will_retry_in = will_retry_in
        @status = status
        @reason = reason
        deep_freeze!
      end
    end

    # A Context combinator declared it `requires` a capability the Provider does
    # not have, and the run's policy chose to DEGRADE rather than raise: the
    # tactic silently became a no-op. "Silently" is the whole danger -- a
    # cross-provider A/B where half the context tactics no-oped on one arm is a
    # lie -- so the degradation is made LOUD here, as a durable record, and
    # `Compare` refuses to compare two runs whose degraded sets differ.
    #
    # `requirer` and `provider` are names (Strings), not the objects, so the
    # record is a self-describing value that serializes to one NDJSON line.
    class CapabilityDegraded < Base
      # @return [Symbol] the capability that was required but unsupported
      attr_reader :capability
      # @return [String] the requirer (a Context combinator) that needed it
      attr_reader :requirer
      # @return [String] the provider that lacked it
      attr_reader :provider

      # @param capability [Symbol]
      # @param requirer [String]
      # @param provider [String]
      def initialize(capability:, requirer:, provider:)
        super()
        @capability = capability
        @requirer = requirer
        @provider = provider
        deep_freeze!
      end
    end
  end
end
