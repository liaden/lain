# frozen_string_literal: true

module Lain
  # CE-5's transient scheduling signal and its failure record -- the provider
  # round-trip's transient signals, not the durable stream they ride beside.
  module Telemetry
    module Guards
      # A stream-started record must name the request whose response began
      # streaming -- there is no committed turn yet to name instead.
      class StreamStarted < Guard
        attribute :digest
        validates :digest, presence: { message: "must name the request whose response started, got nil" }
      end
    end

    # A Provider emits this the instant a streaming response's first SSE
    # event arrives -- before any content_block event -- so an orchestrator
    # awaiting it can release staggered cache-sibling fan-out only once the
    # writing request has actually begun streaming (the earliest point a
    # cache write it made becomes probe-able). `digest` names the {Request},
    # not a Turn: nothing has committed yet, so there is no turn digest to
    # carry, only the request whose response just started.
    #
    # Deliberately NOT a Store event: the event-schema's closed `kind` set
    # (`:turn`/`:spawn`/`:message`/`:snapshot`) records durable history, and
    # this is a transient scheduling signal -- exactly what the Channel is
    # for, and exactly what a KINDS entry is not. A non-streaming request
    # never emits one; there is no "first token" to name.
    StreamStarted = Data.define(:digest) do
      include Journalable

      def initialize(digest:)
        Guards::StreamStarted.check!(digest:)

        super(digest: digest.dup.freeze)
      end
    end

    # An injected observer callback -- so far, only CE-5's `on_stream_started`
    # -- raised instead of running cleanly. A caller-supplied orchestration
    # hook is not allowed to cost a round trip its Response just because the
    # hook itself is buggy (see {StreamStarted}'s doc: the Channel push and
    # the observer call are deliberately two independent paths). But a
    # swallowed exception is a lie by omission on a bench whose whole point
    # is an honest record, so the failure lands here instead of vanishing:
    # `hook` names which observer failed, `digest` is the request it fired
    # for (the join key onto the {StreamStarted} it failed alongside),
    # `message` is the exception's own message, not a full backtrace --
    # attribution, not diagnostics.
    ObserverFailed = Data.define(:hook, :digest, :message) do
      include Journalable

      def initialize(hook:, digest:, message:)
        super(hook: hook.to_sym, digest: digest.dup.freeze, message: message.to_s.dup.freeze)
      end
    end
  end
end
