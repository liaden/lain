# frozen_string_literal: true

require_relative "../channel"
require_relative "../event"
require_relative "../middleware"

module Lain
  module Middleware
    # Records every outbound Request in the model phase as an
    # {Event::RequestSent}, then passes the env through untouched.
    #
    # This lives in middleware rather than in ModelCaller because WHETHER to
    # record requests is a per-experiment wiring decision, not the model round
    # trip's business: a bench arm opts in by adding this to `model_middleware`,
    # and the recorded stream is what dry replay rebuilds requests from. It
    # observes only -- no response handling, no env transformation -- so its
    # position in the stack changes what it SEES (post- or pre- other request
    # rewriters), never what happens. When the goal is the bytes the provider
    # actually received -- the placement a Bench::Session baseline needs --
    # put it INNERMOST, after every rewriter has had its say.
    #
    # The record lands BEFORE dispatch, so a call that fails still leaves its
    # attempt in the Journal: replay sees attempts, not just paid-for turns,
    # and a request_sent with no following turn_usage is how a failure reads.
    class JournalRequests < Base
      # @param journal [#<<] where RequestSent records land; the Null channel by
      #   default, so no caller guards `if journal`
      def initialize(journal: Channel::Null.instance)
        @journal = journal
        super()
        freeze
      end

      def call(env, &app)
        request = env.fetch(:request)
        @journal << Event::RequestSent.new(
          digest: request.digest,
          payload: request.cache_payload,
          stream: request.stream,
          extra: request.extra,
          prefix_digests: request.prefix_digests
        )
        downstream(env, &app)
      end
    end
  end
end
