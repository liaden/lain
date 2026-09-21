# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # A stream-started record must name the request whose response began
      # streaming -- there is no committed turn yet to name instead.
      class StreamStarted < Declarative::Carrier
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

      # The keyword stays EXPLICIT. A bare `**attrs` hands arity to ActiveModel,
      # which gives every rule-less attribute a free nil, losing `Data`'s own
      # "you must name this".
      def initialize(digest:) = super(**Carriers::StreamStarted.settle!(digest:))
    end
  end
end
