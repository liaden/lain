# frozen_string_literal: true

require "active_support/core_ext/module/delegation"

module Lain
  class Provider
    # A Provider-duck decorator that records every outbound {Lain::Request} as a
    # {Telemetry::RequestSent} before handing it to the provider it wraps.
    #
    # It exists for the ORACLE tiers. An agent turn's round trip is already
    # recorded by {Middleware::JournalRequests}; an oracle's is not, because
    # {Oracle::Model} calls `#complete` directly with no middleware stack
    # anywhere near it -- measured as journals holding zero records for traffic
    # the run really paid for.
    #
    # == Why a decorator above the wire, and not a Faraday middleware
    #
    # {Telemetry::RequestSent.from} reads `#digest`, `#cache_payload` and
    # `#prefix_digests` off the live Request, and none of the three survives
    # serialization: the digest is over canonical bytes the encoder has already
    # discarded, and the prefix chain names cache markers the wire renders as
    # `cache_control` and cannot be read back into positions. A byte-level
    # observer could see the payload and would still be unable to rebuild the
    # record that makes dry replay possible. So the seam has to sit where a
    # Request is still a Request.
    #
    # == It is not applied to every provider, and that is the design
    #
    # Whether to record requests is a per-experiment wiring decision, and a
    # bench arm opts in through `model_middleware`. Wrapping the chat provider
    # here as well would hand every other arm records it never asked for and
    # give the opted-in arms a duplicate per turn. The measured gap is the
    # oracle, so this wraps the oracle tiers and nothing else.
    #
    # The forwarding is explicit rather than a `SimpleDelegator`, for the reason
    # {CLI::Switchboard::LiveToolset} gives: the surface a decorator passes
    # through is a claim about what its subject IS, and a message outside the
    # Provider duck should fail loudly here rather than reach a provider that
    # this object cannot honestly stand in for.
    class Journaled
      # The provider that will actually make the round trip, so a caller whose
      # security property is "the judge is a local model" can assert on the
      # object that answers rather than on the decorator in front.
      # @return [Provider]
      attr_reader :inner

      # @param provider [Provider] the round trip this one records
      # @param journal [#<<] where {Telemetry::RequestSent} records land; the
      #   Null channel by default, so no caller guards `if journal` -- the same
      #   default {Middleware::JournalRequests} and {Oracle::Recorded::Journaling}
      #   take. Pass a late-binding forwarder where the run's destination is not
      #   known at construction ({CLI::Backend::Summarizer::RunJournal}).
      def initialize(provider:, journal: Channel::Null.instance)
        @inner = provider
        @journal = journal
        freeze
      end

      # One round trip, recorded then forwarded.
      #
      # The record lands BEFORE dispatch, so a call that fails still leaves its
      # attempt behind: replay sees attempts, not just paid-for answers, and a
      # request_sent with no following {Telemetry::OracleAnswer} is how a failed
      # oracle reads.
      #
      # Keywords are forwarded rather than named because the arms disagree about
      # them -- {Anthropic#complete} takes `on_stream_started:` and
      # {Ollama#complete} does not -- and a decorator that fixed one signature
      # would refuse the other.
      #
      # @param request [Lain::Request]
      # @return [Lain::Response] the wrapped provider's own, untouched
      def complete(request, **)
        @journal << Telemetry::RequestSent.from(request)
        @inner.complete(request, **)
      end

      # Everything this decorator does NOT record. Declared rather than written
      # out as ten bodies, so the one message it does decorate (`#complete`)
      # is the only method in the class and a reader cannot miss it.
      delegate :capabilities, :supports?, :require!, :cache_profile, :context_window_tokens, :window_probe,
               :trained_context_tokens, :serves?, :model_capabilities, :admission_endpoint, :encode, :to_s,
               to: :@inner
    end
  end
end
