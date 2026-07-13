# frozen_string_literal: true

require_relative "canonical"

module Lain
  # Structured events that flow through a {Lain::Channel}.
  #
  # Every event is a small, deeply frozen `Data` value object: two events with
  # equal attributes are equal (`Regular` in the project's algebra), and nothing
  # about an event can mutate after construction, so it is safe to share across
  # threads without copying. Equality, `#hash`, and immutability come from `Data`
  # itself; {Journalable} adds the one behaviour they share — serializing to a
  # tagged JSON object for the {Lain::Journal}.
  module Event
    # The NDJSON self-description every event owes the {Lain::Journal}. Mixed into
    # each `Data` event: its journal form is its attributes plus a `type` tag that
    # lets a reader discriminate the record without inspecting its shape. The
    # Journal adds durability and a timestamp; an event only has to describe
    # itself.
    module Journalable
      # @return [Hash{String=>Object}] the attributes, string-keyed, tagged.
      def to_journal
        { "type" => journal_type }.merge(to_h.transform_keys(&:to_s))
      end

      # The record's discriminator: the class's short name in snake_case, so
      # {ToolOutput} journals as `"tool_output"`.
      # @return [String]
      def journal_type
        self.class.name.split("::").last.gsub(/([a-z])([A-Z])/, '\1_\2').downcase
      end
    end

    # Genuine bytes emitted by a running tool, already attributed to the
    # `tool_use_id` that produced them (a String) and the stream they came from
    # (`:stdout`/`:stderr`). A `bash` subprocess's output enters the system as a
    # stream of these, so provenance is captured at the source rather than
    # reconstructed later. `tool_use_id`/`bytes` are frozen at construction
    # because `Data` freezes the instance but not a contained mutable String, and
    # one unfrozen ivar would make the event non-`Ractor.shareable?`.
    ToolOutput = Data.define(:tool_use_id, :stream, :bytes) do
      include Journalable

      def initialize(tool_use_id:, stream:, bytes:)
        streams = %i[stdout stderr]
        unless streams.include?(stream)
          raise ArgumentError, "stream must be one of #{streams.inspect}, got #{stream.inspect}"
        end

        # bytes is frozen in place, not dup'd: copying possibly-large subprocess output would double it.
        super(tool_use_id: tool_use_id.dup.freeze, stream: stream, bytes: bytes.freeze)
      end
    end

    # A marker that N events were dropped to make room for newer ones. Emitted by
    # a drop-oldest channel (see {Lain::Channel::DropOldest}) so a consumer that
    # freely drops still learns *that* it dropped, and how many. The frontend can
    # render "... (12 events dropped)"; the Journal, which never drops, never
    # produces one. `count` is the number lost since the last marker was surfaced.
    Dropped = Data.define(:count) do
      include Journalable

      def initialize(count:)
        unless count.is_a?(Integer) && count.positive?
          raise ArgumentError, "count must be a positive Integer, got #{count.inspect}"
        end

        super
      end
    end

    # A transport-level retry, made visible. A silent retry hides real spend --
    # on a bench whose headline metric is token cost, a retried (or dropped)
    # request can bill more than the reported Usage ever shows -- so every retry
    # lands here, in the Journal, where `Compare` can report attempts alongside
    # tokens. `attempt` is 1 for the first retry, 2 for the second, ...;
    # `will_retry_in` is the backoff seconds, nil once retries are exhausted;
    # `status` is the failed response's HTTP status when known; `reason` names
    # what triggered the retry (an exception class name).
    ProviderRetry = Data.define(:attempt, :will_retry_in, :status, :reason) do
      include Journalable

      def initialize(attempt:, will_retry_in: nil, status: nil, reason: nil)
        super(attempt: attempt, will_retry_in: will_retry_in, status: status, reason: reason&.dup&.freeze)
      end
    end

    # Token accounting for ONE model call, pinned to the assistant turn the call
    # was committed as. Every record is a payment: aggregating spend means
    # summing over RECORDS, full stop.
    #
    # `digest` is a JOIN KEY onto content -- it names the committed Turn (the
    # Timeline head at commit time) so cost can be joined onto what was said. It
    # is NOT a dedupe key for spend and it is NOT unique across records: rewind
    # the Timeline, regenerate an identical turn, and two records land here with
    # the SAME digest, both genuinely paid for. Deduplicating by digest would
    # undercount every regenerated turn. (Unique-digest aggregation is the rule
    # for CONTENT reachable from a branched head; it does not apply to this
    # per-payment stream, which is exactly why usage lives here in the Journal
    # and not in `Turn#meta` -- the digest must stay content-only.)
    #
    # `usage` is held in canonical wire form (String keys, deeply frozen) so the
    # event stays Ractor-shareable; `model` is nil when the provider reported
    # none (a bare mock).
    TurnUsage = Data.define(:digest, :model, :stop_reason, :usage) do
      include Journalable

      def initialize(digest:, model:, stop_reason:, usage:)
        raise ArgumentError, "digest must name the committed turn, got nil" if digest.nil?
        raise ArgumentError, "stop_reason must name why the model stopped, got nil" if stop_reason.nil?

        super(
          digest: digest.dup.freeze,
          model: model&.to_s&.freeze,
          stop_reason: stop_reason.to_sym,
          usage: Canonical.normalize(usage)
        )
      end
    end

    # One Request as it left for the model, recorded losslessly. `payload` is the
    # request's cache_payload and `digest` its content address -- but the digest
    # deliberately EXCLUDES `stream` and `extra` (transport concerns, not prompt
    # identity), so digest equality alone cannot prove a recorded request can be
    # replayed. The event therefore carries `stream` and `extra` alongside the
    # payload: everything `Request.new` needs to rebuild the exact request, which
    # is what makes dry replay from the Journal possible at all.
    #
    # `payload` and `extra` are held in canonical wire form (String keys, deeply
    # frozen) so the event stays Ractor-shareable; `stream` must be a real
    # boolean because a truthy stand-in would journal as something JSON cannot
    # round-trip back into `Request.new` unchanged.
    #
    # Known trade-off: each record embeds the FULL message history, so an
    # n-turn session journals O(n^2) payload bytes. Accepted while sessions are
    # short; if it bites, the fix is content-addressed dedupe (journal digests,
    # store the blocks once), not trimming the record.
    #
    # `prefix_digests` is the request's own CE-2 digest chain --
    # `Request#prefix_digests`, `[[position, digest], ...]`, where position -1
    # (`Request::SYSTEM_PREFIX`) names a marker in the system blocks and
    # message indices are always >= 0 -- carried alongside rather than
    # recomputed from `payload`, since recomputation would need the ORIGINAL
    # Request object this record was built from, not the JSON-shaped payload
    # Hash. Defaults to nil, meaning NOT COMPUTED: a caller that never asked
    # for the chain journals `null`, while a computed chain over a marker-free
    # request journals `[]`. An offline rewrite projection must not read
    # "nobody measured" as "zero markers", so absence IS the signal here --
    # nil is a value, not a missing Null Object.
    RequestSent = Data.define(:digest, :payload, :stream, :extra, :prefix_digests) do
      include Journalable

      def initialize(digest:, payload:, stream:, extra:, prefix_digests: nil)
        raise ArgumentError, "stream must be true or false, got #{stream.inspect}" unless [true, false].include?(stream)

        super(
          digest: digest.dup.freeze,
          payload: Canonical.normalize(payload),
          stream: stream,
          extra: Canonical.normalize(extra),
          prefix_digests: Canonical.normalize(prefix_digests)
        )
      end
    end

    # The memory root in force at one committed turn: `turn_digest` names the
    # assistant Turn just committed (the Timeline head at commit time) and
    # `root` names the Memory::Index root live at that moment. Recorded by the
    # BENCH observing the run, never by the Agent -- the Agent stays
    # memory-blind. Pairing the two digests in the Journal is what makes recall
    # replayable: `Index#checkout(root)` reproduces exactly the snapshot this
    # turn could see, however far the live index has moved since. The name is
    # QUALIFIED -- `turn_digest`, not `digest` -- because this record carries
    # two digests, and `turn_digest` is the join key onto {TurnUsage}'s
    # `digest`: one committed turn, its cost, and its memory snapshot line up
    # in the Journal on that one value.
    #
    # `root` may be nil where `turn_digest` may not: a record only exists
    # because a turn committed, so there is always a turn to name, but an EMPTY
    # index has no root node to name -- nil IS the empty index's identity
    # (`checkout(nil)` answers it), a value here rather than an absence.
    MemoryRoot = Data.define(:turn_digest, :root) do
      include Journalable

      def initialize(turn_digest:, root:)
        raise ArgumentError, "turn_digest must name the committed turn, got nil" if turn_digest.nil?

        super(turn_digest: turn_digest.dup.freeze, root: root&.dup&.freeze)
      end
    end

    # A Context combinator declared it `requires` a capability the Provider does
    # not have, and the run's policy chose to DEGRADE rather than raise: the
    # tactic silently became a no-op. "Silently" is the whole danger -- a
    # cross-provider A/B where half the context tactics no-oped on one arm is a
    # lie -- so the degradation is made LOUD here, as a durable record, and
    # `Compare` refuses to compare two runs whose degraded sets differ.
    #
    # `capability` is the Symbol required-but-unsupported; `requirer` and
    # `provider` are names (Strings), not the objects, so the record is a
    # self-describing value that serializes to one NDJSON line.
    CapabilityDegraded = Data.define(:capability, :requirer, :provider) do
      include Journalable

      def initialize(capability:, requirer:, provider:)
        super(capability: capability, requirer: requirer.dup.freeze, provider: provider.dup.freeze)
      end
    end
  end
end
