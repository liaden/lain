# frozen_string_literal: true

require "active_support/core_ext/string/inflections"

module Lain
  # Structured events that flow through a {Lain::Channel}.
  #
  # Every event is a small, deeply frozen `Data` value object: two events with
  # equal attributes are equal (`Regular` in the project's algebra), and nothing
  # about an event can mutate after construction, so it is safe to share across
  # threads without copying. Equality, `#hash`, and immutability come from `Data`
  # itself; {Journalable} adds the one behaviour they share — serializing to a
  # tagged JSON object for the {Lain::Journal}.
  module Telemetry
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
      # {ToolOutput} journals as `"tool_output"`. `String#underscore` produces
      # the byte-identical string the hand-rolled gsub did for every current
      # event -- an equivalence the spec pins, because this string is the journal
      # discriminator and recorded journals replay against it.
      # @return [String]
      def journal_type
        self.class.name.split("::").last.underscore
      end
    end

    # Construction contracts for the events whose hand-rolled guards moved to
    # validate-then-freeze (Ruling 2). Each is a throwaway {Lain::Guard} carrier
    # validated BEFORE the (auto-frozen) Data value exists -- see {Lain::Guard}
    # for why validation must live off the frozen value. Named, so they stay
    # reachable for introspection and shoulda-matchers.
    module Guards
      # A dropped-event count must be a positive Integer.
      class Dropped < Guard
        attribute :count
        validates :count, numericality: { only_integer: true, greater_than: 0,
                                          message: "must be a positive Integer, got %<value>s" }
      end

      # A usage record must name the turn it paid for and why the model stopped.
      class TurnUsage < Guard
        attribute :digest
        attribute :stop_reason
        validates :digest, presence: { message: "must name the committed turn, got nil" }
        validates :stop_reason, presence: { message: "must name why the model stopped, got nil" }
      end

      # `stream` must be a real boolean so it round-trips through the journal. A
      # required boolean is validated by inclusion in [true, false], because
      # `presence: true` would reject `false` (the Tool::Input idiom).
      class RequestSent < Guard
        attribute :stream
        # %<value>s echoes the offender un-inspected ("got yes", not 'got "yes"')
        # -- the one diagnostic byte lost versus the hand-rolled guard.
        validates :stream, inclusion: { in: [true, false], message: "must be true or false, got %<value>s" }
      end

      # A memory-root record must name the committed turn it snapshots.
      class MemoryRoot < Guard
        attribute :turn_digest
        validates :turn_digest, presence: { message: "must name the committed turn, got nil" }
      end

      # A refusal record must name what matched (never the matched bytes).
      class WriteRefused < Guard
        attribute :pattern
        validates :pattern, presence: { message: "must name what matched, got nil" }
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
        super(tool_use_id: tool_use_id.dup.freeze, stream:, bytes: bytes.freeze)
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
        Guards::Dropped.check!(count:)
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
        super(attempt:, will_retry_in:, status:, reason: reason&.dup&.freeze)
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
        Guards::TurnUsage.check!(digest:, stop_reason:)

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
        Guards::RequestSent.check!(stream:)

        super(
          digest: digest.dup.freeze,
          payload: Canonical.normalize(payload),
          stream:,
          extra: Canonical.normalize(extra),
          prefix_digests: Canonical.normalize(prefix_digests)
        )
      end
    end

    # A hand-edited request resent from the editor (4-2.3), never dispatched to
    # a provider. The same shape as {RequestSent} -- and it IS one, by
    # inheritance, so every projection that diffs or renders requests treats it
    # identically -- under its OWN journal discriminator ("request_resent",
    # derived from the class name like every {Journalable}). The distinct type
    # is the provenance stamp: {Middleware::JournalRequests} documents that "a
    # request_sent with no following turn_usage is how a failure reads", and a
    # resend never dispatches, so recording it as a plain request_sent would
    # fabricate one failed real dispatch per hand-edit. The stamp lives in the
    # TYPE rather than in `extra` because `extra` is exactly what Request.new
    # needs to rebuild the request -- a marker there would ride onto the wire
    # on any rebuild-and-dispatch.
    class RequestResent < RequestSent
    end

    # The memory root in force at one committed turn: `turn_digest` names the
    # assistant Turn just committed (the Timeline head at commit time) and
    # `root` names the Memory::Index root live at that moment. Emitted by
    # {Memory::JournalMemoryRoot}, the journal decorator that pairs each
    # {TurnUsage} it forwards with the recorder's current root -- never by the
    # Agent, which stays memory-blind throughout.
    # Pairing the two digests in the Journal is what makes recall
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
        Guards::MemoryRoot.check!(turn_digest:)

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
        super(capability:, requirer: requirer.dup.freeze, provider: provider.dup.freeze)
      end
    end

    # Attribution for the session-fixed prompt slots (PS-2), written ONCE at
    # session start. Two maps keyed by slot name: `digests` content-addresses
    # each slot's RENDERED bytes -- the join key onto a {RequestSent}'s system
    # blocks, whose rendered text is already journaled in full -- and `fills`
    # carries the raw override SOURCE, the bytes a reader diffs to see WHY two
    # runs' prompts differ. Pure attribution, not replay: the rendered system
    # text is recoverable from {RequestSent}, so this record adds identity and
    # diffability, never a second copy of the prompt.
    #
    # Both maps are held in canonical wire form (String keys, deeply frozen) so
    # the event stays Ractor-shareable.
    SlotFills = Data.define(:digests, :fills) do
      include Journalable

      # The session's one record, attributing what ACTUALLY rendered. Built
      # from the loaded {Prompt::Slots} -- per-slot rendered-byte digests and
      # raw fill sources -- unless `override:` names a caller-supplied system
      # prompt (bench record's `--system`), which renders INSTEAD of the slots:
      # a record still built from them would carry digests that fail the join
      # onto {RequestSent}'s system blocks, a coherent-looking lie. The honest
      # record addresses the override bytes, with the override itself as the
      # diffable source.
      def self.from(slots, override: nil)
        return new(digests: slots.digests, fills: slots.fills) if override.nil?

        new(digests: { "system" => Canonical.digest(override) }, fills: { "system" => override })
      end

      def initialize(digests:, fills:)
        super(digests: Canonical.normalize(digests), fills: Canonical.normalize(fills))
      end
    end

    # A `memory_write` withheld by {Middleware::RefuseSecretWrites} before it
    # ever reached the recorder. `pattern` NAMES what matched -- e.g. "aws
    # access key id" -- and MUST NEVER be the matched bytes themselves: a
    # refusal record that quoted the secret would write the secret to the very
    # Journal the refusal exists to protect. `tool_use_id` ties the record back
    # to the tool_result the model actually saw.
    WriteRefused = Data.define(:tool_use_id, :pattern) do
      include Journalable

      def initialize(tool_use_id:, pattern:)
        Guards::WriteRefused.check!(pattern:)

        super(tool_use_id: tool_use_id.dup.freeze, pattern: pattern.dup.freeze)
      end
    end
  end
end
