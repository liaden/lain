# frozen_string_literal: true

module Lain
  module Telemetry
    # The durable per-turn/per-request telemetry stream: what left for the
    # model, what it cost, and what a tool produced.

    module Carriers
      # A dropped-event count must be a positive Integer.
      class Dropped < Declarative::Carrier
        attribute :count
        validates :count, numericality: { only_integer: true, greater_than: 0,
                                          message: "must be a positive Integer, got %<value>s" }
      end

      # A usage record must name the turn it paid for and why the model stopped.
      class TurnUsage < Declarative::Carrier
        attribute :digest
        attribute :stop_reason
        validates :digest, presence: { message: "must name the committed turn, got nil" }
        validates :stop_reason, presence: { message: "must name why the model stopped, got nil" }
      end

      # `stream` must be a real boolean so it round-trips through the journal. A
      # required boolean is validated by inclusion in [true, false], because
      # `presence: true` would reject `false` (the Tool::Input idiom).
      class RequestSent < Declarative::Carrier
        attribute :stream
        # %<value>s echoes the offender un-inspected ("got yes", not 'got "yes"')
        # -- the one diagnostic byte lost versus the hand-rolled guard.
        validates :stream, inclusion: { in: [true, false], message: "must be true or false, got %<value>s" }
      end

      # `root` carries no rule -- nil is the empty index's identity, not an
      # absence -- but it is declared, because `settle!` hands back exactly the
      # attributes the carrier names and the record needs both.
      class MemoryRoot < Declarative::Carrier
        attribute :turn_digest
        attribute :root
        validates :turn_digest, presence: { message: "must name the committed turn, got nil" }
      end

      # The reason is the pattern that matched or the judgment that declined,
      # never the matched bytes. `tool_use_id` is declared without a rule for
      # the reason {MemoryRoot}'s `root` is: `settle!` must hand it back.
      class WriteRefused < Declarative::Carrier
        attribute :tool_use_id
        attribute :pattern
        validates :pattern, presence: { message: "must name what matched or what declined, got nil" }
      end

      # `survived` is checked by inclusion rather than `presence:`, which would
      # silently reject `false` -- the same reasoning as {RequestSent}'s
      # `stream`.
      class Verdict < Declarative::Carrier
        attribute :digest
        attribute :survived
        attribute :why
        validates :digest, presence: { message: "must name the finding it judged, got nil" }
        validates :survived, inclusion: { in: [true, false], message: "must be true or false, got %<value>s" }
        validates :why, presence: { message: "must explain the verdict, got nil" }
      end

      # A `check!` rather than a `settle!` for the reason {ToolOutput}'s own
      # `bytes.freeze` gives: settling COPIES, and copying possibly-large
      # subprocess output would double it.
      class ToolOutput < Declarative::Carrier
        STREAMS = %i[stdout stderr].freeze

        attribute :stream
        validate :stream_is_known

        private

        # Bespoke rather than `inclusion:`, so the refusal keeps the hand-rolled
        # guard's exact bytes: `%<value>s` renders a Symbol un-inspected ("got
        # nope"), losing the colon that says the offender was one.
        def stream_is_known
          return if STREAMS.include?(stream)

          errors.add(:stream, "must be one of #{STREAMS.inspect}, got #{stream.inspect}")
        end
      end
    end

    # Bytes emitted by a running tool, attributed at the source rather than
    # reconstructed later. `tool_use_id`/`bytes` are frozen at construction
    # because `Data` freezes the instance but not a contained mutable String,
    # and one unfrozen ivar would make the event non-`Ractor.shareable?`.
    ToolOutput = Data.define(:tool_use_id, :stream, :bytes) do
      include Journalable

      def initialize(tool_use_id:, stream:, bytes:)
        Carriers::ToolOutput.check!(stream:)

        # bytes is frozen in place, not dup'd: copying possibly-large subprocess output would double it.
        super(tool_use_id: tool_use_id.dup.freeze, stream:, bytes: bytes.freeze)
      end
    end

    # A marker that N events were dropped to make room for newer ones, so a
    # consumer that freely drops still learns *that* it dropped, and how many.
    # `count` is the number lost since the last marker was surfaced.
    Dropped = Data.define(:count) do
      include Journalable

      def initialize(count:)
        Carriers::Dropped.check!(count:)
        super
      end
    end

    # A transport-level retry, made visible. A silent retry hides real spend --
    # on a bench whose headline metric is token cost, a retried request can bill
    # more than the reported Usage ever shows. `attempt` is 1 for the first
    # retry; `will_retry_in` is the backoff seconds, nil once retries are
    # exhausted; `reason` names what triggered it (an exception class name).
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
    # `digest` is a JOIN KEY onto content, NOT a dedupe key for spend, and it is
    # not unique across records: rewind the Timeline, regenerate an identical
    # turn, and two records land here with the SAME digest, both genuinely paid
    # for. Deduplicating by digest would undercount every regenerated turn.
    # Unique-digest aggregation is the rule for CONTENT reachable from a
    # branched head, which is why usage lives here and not in `Turn#meta` -- the
    # digest must stay content-only.
    #
    # `usage` is held in canonical wire form so the event stays
    # Ractor-shareable; `model` is nil when the provider reported none.
    TurnUsage = Data.define(:digest, :model, :stop_reason, :usage) do
      include Journalable

      def initialize(digest:, model:, stop_reason:, usage:)
        Carriers::TurnUsage.check!(digest:, stop_reason:)

        super(
          digest: digest.dup.freeze,
          model: model&.to_s&.freeze,
          stop_reason: stop_reason.to_sym,
          usage: Canonical.normalize(usage)
        )
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

    # A hand-edited request resent from the editor: the EDIT's projection
    # record, never the wire's. It IS a {RequestSent} by inheritance, so every
    # projection that diffs or renders requests treats it identically, under its
    # own journal discriminator.
    #
    # The distinct type is the provenance stamp. {Middleware::JournalRequests}
    # documents that "a request_sent with no following turn_usage is how a
    # failure reads", so recording a hand-edit as a plain request_sent would
    # fabricate one failed real dispatch per edit. The stamp lives in the TYPE
    # rather than in `extra`, because `extra` is exactly what Request.new needs
    # to rebuild the request -- a marker there would ride onto the wire on any
    # rebuild-and-dispatch.
    #
    # A resend that goes on to dispatch leaves its own ORDINARY request_sent/
    # turn_usage pair (the loop saw an ordinary Request), joined to this record
    # by digest; an unbridged one leaves this record alone. So the failure
    # reading survives intact either way.
    class RequestResent < RequestSent
    end

    # The memory root in force at one committed turn. Emitted by
    # {Memory::JournalMemoryRoot} and never by the Agent, which stays
    # memory-blind throughout. Pairing the two digests is what makes recall
    # replayable: `Index#checkout(root)` reproduces exactly the snapshot this
    # turn could see, however far the live index has moved since. The name is
    # QUALIFIED -- `turn_digest`, not `digest` -- because this record carries
    # two digests, and it is the join key onto {TurnUsage}'s `digest`.
    #
    # `root` may be nil where `turn_digest` may not: an EMPTY index has no root
    # node to name, and nil IS its identity (`checkout(nil)` answers it) rather
    # than an absence.
    MemoryRoot = Data.define(:turn_digest, :root) do
      include Journalable

      # A nil `root` needs no `&.` here: `settle!` copies what it is given and
      # nil is already `Ractor.shareable?`, so absence survives untouched. But
      # `root` must still be NAMED: it carries no validation to catch an
      # accidental nil, so its keyword is the only thing standing between a
      # caller and a record that silently claims the index was empty.
      def initialize(turn_digest:, root:) = super(**Carriers::MemoryRoot.settle!(turn_digest:, root:))
    end

    # Something declared it `requires` a capability the Provider does not have,
    # and the run's policy chose to DEGRADE rather than raise: the tactic
    # silently became a no-op. "Silently" is the whole danger -- a
    # cross-provider A/B where half the context tactics no-oped on one arm is a
    # lie -- so the degradation is made LOUD here, and `Compare` refuses to
    # compare two runs whose degraded sets differ.
    #
    # `requirer` and `provider` are NAMES rather than the objects, so the record
    # serializes to one self-describing NDJSON line.
    #
    # `requirer` names whatever was handed to {Capability::Policy#resolve},
    # which in a real chat is the run's whole {Context} -- so a live record
    # reads `"Lain::Context"`, never the combinator that wanted the capability.
    # That is the best value available: `Context#requires` is a UNION over its
    # pipeline while `#resolve` folds over one requirer, so the combinator is
    # not recoverable where the record is built. A reader wanting to know WHICH
    # stage no-oped reads the pipeline the session header pins.
    CapabilityDegraded = Data.define(:capability, :requirer, :provider) do
      include Journalable

      def initialize(capability:, requirer:, provider:)
        super(capability:, requirer: requirer.dup.freeze, provider: provider.dup.freeze)
      end
    end

    # Attribution for the session-fixed prompt slots, written ONCE at session
    # start. `digests` content-addresses each slot's RENDERED bytes -- the join
    # key onto a {RequestSent}'s system blocks -- and `fills` carries the raw
    # override SOURCE, the bytes a reader diffs to see WHY two runs' prompts
    # differ. Pure attribution, not replay: the rendered system text is
    # recoverable from {RequestSent}, so this adds identity and diffability
    # rather than a second copy of the prompt.
    SlotFills = Data.define(:digests, :fills) do
      include Journalable
      include Declarative

      # Anonymous (`declare`), because the record carries no validation a
      # reader would ever go looking for by name.
      declare do
        attribute :digests, :lain_canonical
        attribute :fills, :lain_canonical
      end

      # The session's one record, attributing what ACTUALLY rendered. An
      # `override:` renders INSTEAD of the slots, so a record still built from
      # them would carry digests that fail the join onto {RequestSent}'s system
      # blocks -- a coherent-looking lie.
      def self.from(slots, override: nil)
        return new(digests: slots.digests, fills: slots.fills) if override.nil?

        new(digests: { "system" => Canonical.digest(override) }, fills: { "system" => override })
      end

      # Explicit keywords: `Canonical.normalize(nil)` is nil, so a nameless
      # construction would build a perfectly valid record attributing nothing.
      def initialize(digests:, fills:) = super(**self.class.settle!(digests:, fills:))
    end

    # A `memory_write` withheld by {Middleware::RefuseSecretWrites} before it
    # ever reached the recorder. `pattern` NAMES the reason -- e.g. "aws access
    # key id" -- and MUST NEVER be the matched bytes themselves: a refusal
    # record that quoted the secret would write it to the very Journal the
    # refusal exists to protect.
    #
    # The field carries TWO kinds of reason and a reader must not conflate
    # them. A named credential pattern means "this looks like a credential"; a
    # *decline* means an oracle judged the write not worth making, with no
    # pattern matching at all. Declines live in a reserved namespace -- test for
    # one with {Middleware::RefuseSecretWrites.decline?} rather than by
    # membership in `PATTERNS`, which drifts as shapes are added. Counting every
    # WriteRefused as a security finding over-counts by every decline.
    WriteRefused = Data.define(:tool_use_id, :pattern) do
      include Journalable

      # `tool_use_id` is the correlation key onto the call that was refused, and
      # it carries no validator -- so, like {MemoryRoot}'s `root`, its keyword is
      # what keeps a refusal from journaling as uncorrelatable.
      def initialize(tool_use_id:, pattern:) = super(**Carriers::WriteRefused.settle!(tool_use_id:, pattern:))
    end

    # A finding's refutation verdict ({Grader::Verified}'s second pass).
    # `digest` is the finding's OWN content address rather than an id it does
    # not carry the way a tool call carries a `tool_use_id` -- it is the join
    # key {Grader::Refuter::Recorded.from_journal} looks the verdict back up by,
    # the same content-addressed replay {Effect::Handler::Recorded} does.
    # `survived` is the refuter's thresholded pass/fail, since a continuous
    # Rubric score alone is not a verdict; `score` keeps the raw 0..1
    # confidence alongside.
    Verdict = Data.define(:digest, :survived, :score, :why) do
      include Journalable

      def initialize(digest:, survived:, score:, why:)
        Carriers::Verdict.check!(digest:, survived:, why:)

        super(digest: digest.dup.freeze, survived:, score: score.to_f.clamp(0.0, 1.0), why: -why.to_s)
      end
    end
  end
end
