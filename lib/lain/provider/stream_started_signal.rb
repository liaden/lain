# frozen_string_literal: true

module Lain
  class Provider
    # CE-5's first-token signal, shared by both Anthropic backends so they
    # cannot drift on when it fires or how an observer's own failure is
    # isolated -- the same one-implementation-in-both shape
    # {AnthropicEncoding} already uses for #encode. Included by a class that
    # already carries `@channel` (Lain::Channel) from its own initializer.
    module StreamStartedSignal
      private

      # @param on_stream_started [#call, nil] CE-5: called with the request's
      #   digest the instant the response begins streaming, IN ADDITION TO the
      #   {Telemetry::StreamStarted} pushed onto `@channel`. A second,
      #   Channel-free path so a per-request orchestration policy (the
      #   stagger scheduler awaiting one sibling's first token) can observe
      #   the signal without becoming a second destructive consumer of the
      #   Channel -- that consumer is the frontend, and only the frontend.
      def emit_stream_started(request, on_stream_started)
        @channel.push(Telemetry::StreamStarted.new(digest: request.digest))
        call_stream_started_observer(on_stream_started, request.digest)
      end

      # A caller-supplied orchestration hook, not part of this round trip's
      # own contract -- a bug in it must not cost #complete a response it
      # already has. Isolated to just this call, not the Channel push above
      # (that has its own contract and is not what is at risk here).
      def call_stream_started_observer(on_stream_started, digest)
        on_stream_started&.call(digest)
      rescue StandardError => e
        @channel.push(Telemetry::ObserverFailed.new(hook: :stream_started, digest:, message: e.message))
      end
    end
  end
end
