# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # `stream` must be a real boolean so it round-trips through the journal. A
      # required boolean is validated by inclusion in [true, false], because
      # `presence: true` would reject `false` (the Tool::Input idiom).
      class RequestSent < Declarative::Carrier
        attribute :stream
        # %<value>s echoes the offender un-inspected ("got yes", not 'got "yes"')
        # -- the one diagnostic byte lost versus the hand-rolled guard.
        validates :stream, inclusion: { in: [true, false], message: "must be true or false, got %<value>s" }
      end
    end

    # One Request as it left for the model, recorded losslessly. The digest
    # deliberately EXCLUDES `stream` and `extra` (transport concerns, not prompt
    # identity), so digest equality alone cannot prove a recorded request can be
    # replayed -- which is why the event carries both alongside the payload:
    # everything `Request.new` needs to rebuild the exact request. `stream` must
    # be a real boolean, because a truthy stand-in would journal as something
    # JSON cannot round-trip back into `Request.new` unchanged.
    #
    # Known trade-off: each record embeds the FULL message history, so an
    # n-turn session journals O(n^2) payload bytes. Accepted while sessions are
    # short; if it bites, the fix is content-addressed dedupe (journal digests,
    # store the blocks once), not trimming the record.
    #
    # `prefix_digests` is carried rather than recomputed from `payload`, since
    # recomputation would need the ORIGINAL Request object rather than the
    # JSON-shaped Hash. It defaults to nil, meaning NOT COMPUTED, where a
    # computed chain over a marker-free request journals `[]`: an offline
    # rewrite projection must not read "nobody measured" as "zero markers", so
    # absence IS the signal and nil is a value rather than a missing Null
    # Object.
    #
    # `prefix_chain_version` names the chain's FORMAT; nil covers both a nil
    # chain and the unversioned chains in older journals. {Bench::Rewrites}
    # compares chains only within one format -- the formats' digests never
    # agree, so an unversioned reader would misread the migration itself as a
    # rewrite.
    RequestSent = Data.define(:digest, :payload, :stream, :extra, :prefix_digests, :prefix_chain_version) do
      include Journalable

      # The journaling constructor: every field is read off a live {Request},
      # whose members are already canonical, so this path asserts `normalized:`
      # and skips the deep re-walk of the full message history the keyword
      # constructor performs on arbitrary input -- one normalize pass per
      # payload, the only remaining walk being the digest's own.
      def self.from(request)
        new(digest: request.digest, payload: request.cache_payload, stream: request.stream,
            extra: request.extra, prefix_digests: request.prefix_digests,
            prefix_chain_version: Request::PREFIX_CHAIN_VERSION, normalized: true)
      end

      # `normalized: true` is a trust assertion, not an optimization hint: the
      # caller vouches that payload and extra are ALREADY canonical wire form
      # (String keys, sorted, deeply frozen). Only {.from} may make it -- a
      # wrong assertion corrupts journal bytes with no error anywhere. The
      # chain is normalized regardless: it arrives as small fresh Arrays that
      # still need freezing, at O(markers) cost.
      def initialize(digest:, payload:, stream:, extra:, prefix_digests: nil, prefix_chain_version: nil,
                     normalized: false)
        Carriers::RequestSent.check!(stream:)

        super(
          digest: digest.dup.freeze,
          payload: normalized ? payload : Canonical.normalize(payload),
          stream:,
          extra: normalized ? extra : Canonical.normalize(extra),
          prefix_digests: Canonical.normalize(prefix_digests),
          prefix_chain_version:
        )
      end
    end
  end
end
