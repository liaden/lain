# frozen_string_literal: true

module Lain
  module Middleware
    # Records every outbound Request in the model phase as an
    # {Telemetry::RequestSent}, then passes the env through untouched.
    #
    # Middleware rather than ModelCaller because WHETHER to record requests is a
    # per-experiment wiring decision: a bench arm opts in by adding this to
    # `model_middleware`, and the recorded stream is what dry replay rebuilds
    # requests from. It observes only, so its position changes what it SEES, never
    # what happens -- for the bytes the provider actually received, the placement
    # a {Bench::Session} baseline needs, put it INNERMOST.
    #
    # The record lands BEFORE dispatch, so a call that fails still leaves its
    # attempt in the Journal: a request_sent with no following turn_usage is how a
    # failure reads.
    #
    # The sender's prefix-chain memo rides the env as `prefix_chain`, so a
    # long conversation's chain is extended rather than recomputed per call.
    class JournalRequests < Base
      # @param journal [#<<] where RequestSent records land; the Null channel by
      #   default, so no caller guards `if journal`
      def initialize(journal: Channel::Null.instance)
        @journal = journal
        super()
        freeze
      end

      def call(env, &app)
        @journal << Telemetry::RequestSent.from(env.fetch(:request),
                                                prefix_chain: env.fetch(:prefix_chain, Request::PrefixChain::NONE))
        downstream(env, &app)
      end
    end
  end
end
