# frozen_string_literal: true

module Lain
  class Event
    # The kind-tagged body an {Event} references by digest. Held out of the
    # envelope and content-addressed on its own so large results and snapshots
    # never inline into the header; the same Store that holds envelopes holds
    # payloads, and `event.payload_digest` retrieves this back.
    #
    # `kind` is the closed, loud enum the envelope shares (a :turn payload and a
    # :snapshot payload with identical bodies are different things and address
    # differently). `body` is the kind-specific content -- for a :turn, the role
    # and full content-block list -- normalized to canonical wire form so the
    # digest is stable and the value stays Ractor-shareable. The envelope holds
    # only this payload's digest, so envelope/payload kind agreement is the
    # constructor's responsibility, not something the digest can cross-check.
    class Payload
      include ContentAddressed

      attr_reader :kind, :body, :digest

      def initialize(kind:, body:)
        @kind = Event.normalize_kind(kind)
        @body = Canonical.normalize(body)
        @digest = Canonical.digest(payload)
        freeze
      end

      # The exact structure that was hashed. Also what a Journal writes.
      def payload
        { "kind" => kind, "body" => body }
      end

      def to_s
        "#<Lain::Event::Payload #{kind} #{digest[0, 19]}...>"
      end
      alias inspect to_s
    end
  end
end
