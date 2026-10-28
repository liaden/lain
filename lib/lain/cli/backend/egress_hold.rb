# frozen_string_literal: true

require "active_support/number_helper"

module Lain
  module CLI
    class Backend
      # Where every provider a {Backend} builds asks the human before a request
      # leaves, under `--supervise-egress`. Late-bound because providers are
      # built before the approval queue; unbound it refuses, so a request sent
      # before the bind is never sent unasked.
      #
      # The scope is decided where each provider is built, by the requester it
      # is built for, never from the request itself.
      class EgressHold
        SCOPES = %w[off oracle all].freeze
        KIND = "egress"
        ORACLE = :secret_oracle

        NOT_READY = "egress supervision not ready: the request was refused because nothing was bound yet to " \
                    "ask the human"
        HEADLESS = "the request was refused: --supervise-egress needs a human to answer, and none is attached"

        Unbound = Data.define do
          def accepts?(_queue) = true

          def ask_decision(_decision) = raise Provider::HTTP::EgressGuard::Refused, NOT_READY
        end

        Headless = Data.define do
          def accepts?(queue) = queue.nil?

          def ask_decision(_decision) = raise Provider::HTTP::EgressGuard::Refused, HEADLESS
        end

        Bound = Data.define(:queue) do
          def accepts?(other) = queue.equal?(other)

          def ask_decision(decision) = queue.ask_decision(decision)
        end
        private_constant :Unbound, :Headless, :Bound

        # The hold one provider's guard asks, for one requester.
        Supervised = Data.define(:holder, :requester) do
          def supervises? = true

          # @param summary [Hash] what {Provider::HTTP::EgressGuard} says about the request
          # @return [Boolean] true to send
          def call(summary) = holder.ask(requester, summary)
        end

        # @param scope [String, nil] one of {SCOPES}; nil is off
        # @raise [ArgumentError] on a scope outside {SCOPES}
        def initialize(scope)
          @scope = scope || "off"
          raise ArgumentError, "unknown egress supervision #{scope.inspect}, expected one of #{SCOPES.join(", ")}" \
            unless SCOPES.include?(@scope)

          @binding = Unbound.new
        end

        # The same queue again is no rebind: one board may back its agent twice.
        #
        # @param queue [#ask_decision, nil] nil when no human is attached
        # @return [self]
        # @raise [Rebound] when already bound to another queue
        def bind(queue)
          raise Rebound, "the egress hold is already bound to another queue" unless @binding.accepts?(queue)

          @binding = queue.nil? ? Headless.new : Bound.new(queue)
          self
        end

        # @param requester [Symbol] who the provider sends for, as {Provider::Journaled} names it
        # @return [#supervises?, #call] the hold that provider's guard asks
        def for(requester)
          return Provider::HTTP::EgressGuard::Unsupervised unless supervised?(requester)

          Supervised.new(holder: self, requester:)
        end

        # @param requester [Symbol]
        # @param summary [Hash] endpoint, bytes (canonical, not the wire's), body_digest, literal_hits,
        #   flagged; never the body
        # @return [Boolean] the human's answer
        # @raise [Provider::HTTP::EgressGuard::Refused] when nobody can be asked
        def ask(requester, summary) = @binding.ask_decision(decision(requester, summary))

        private

        def supervised?(requester) = @scope == "all" || (@scope == "oracle" && requester == ORACLE)

        def decision(requester, summary)
          Approval::Parked::Queue::Decision.new(requester: Requester.of(requester.to_s), kind: KIND,
                                                summary: line(requester, summary), digest: summary.fetch(:body_digest))
        end

        def line(requester, summary)
          bytes = ActiveSupport::NumberHelper.number_to_delimited(summary.fetch(:bytes))
          "#{requester} sends #{bytes} canonical bytes to #{summary.fetch(:endpoint)} (body " \
            "#{summary.fetch(:body_digest)}), holding #{summary.fetch(:literal_hits)} known value(s) and " \
            "#{summary.fetch(:flagged)} region(s) shaped like a credential"
        end
      end
    end
  end
end
