# frozen_string_literal: true

require "active_support/core_ext/string/inflections"
require "bigdecimal"

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

      # A grading verdict must name the finding it judged, say whether it
      # survived as a real boolean (so `presence:` cannot silently reject
      # `false`, the same reasoning as {RequestSent}'s `stream`), and explain
      # itself.
      class Verdict < Guard
        attribute :digest
        attribute :survived
        attribute :why
        validates :digest, presence: { message: "must name the finding it judged, got nil" }
        validates :survived, inclusion: { in: [true, false], message: "must be true or false, got %<value>s" }
        validates :why, presence: { message: "must explain the verdict, got nil" }
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
    #
    # `prefix_chain_version` names the chain's FORMAT
    # ({Request::PREFIX_CHAIN_VERSION} for chains this codebase computes); nil
    # covers both a nil chain and the unversioned format-1 chains in journals
    # recorded before the rolling chain landed. {Bench::Rewrites} compares
    # chains only within one format -- the formats' digests never agree, so an
    # unversioned reader would misread the migration itself as a rewrite.
    RequestSent = Data.define(:digest, :payload, :stream, :extra, :prefix_digests, :prefix_chain_version) do
      include Journalable

      # The journaling constructor ({Middleware::JournalRequests}): every
      # field read off a live {Request}, whose members are already canonical
      # (Request.new normalized them; #cache_payload is canonical by
      # construction) -- so this path asserts `normalized:` and skips the deep
      # re-walk of the full message history the keyword constructor performs
      # on arbitrary input. That skip is R.3's "one normalize pass per
      # payload": the only remaining walk is the digest's own.
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
        Guards::RequestSent.check!(stream:)

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

    # A hand-edited request resent from the editor (4-2.3): the EDIT's
    # projection record, never the wire's. The same shape as {RequestSent} --
    # and it IS one, by inheritance, so every projection that diffs or renders
    # requests treats it identically -- under its OWN journal discriminator
    # ("request_resent", derived from the class name like every {Journalable}).
    # The distinct type is the provenance stamp: {Middleware::JournalRequests}
    # documents that "a request_sent with no following turn_usage is how a
    # failure reads", and recording a hand-edit as a plain request_sent would
    # fabricate one failed real dispatch per edit. The stamp lives in the TYPE
    # rather than in `extra` because `extra` is exactly what Request.new needs
    # to rebuild the request -- a marker there would ride onto the wire on any
    # rebuild-and-dispatch.
    #
    # Since T18, a resend CAN go on to dispatch: {CLI::ResendBridge} journals a
    # {ResendDispatched} marker (attempt-first) and runs the edit through the
    # loop, whose wire path then journals its own ORDINARY request_sent/
    # turn_usage pair -- the loop saw an ordinary Request, and the join key
    # across all three records is the digest. Provenance stays in record TYPES
    # throughout. An UNBRIDGED resend (plain --nvim, no agent wired) still
    # never dispatches: this record alone, with no marker following, is how
    # that pure projection reads -- and the failure reading above survives
    # intact, because a dispatched override always leaves a real request_sent
    # for its turn_usage (or its absence) to say how the wire fared.
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

    # A finding's refutation verdict ({Grader::Verified}'s second pass): whether
    # ONE raw finding from a finding-producing grader survived judgment by an
    # injected {Grader::Refuter}. `digest` is the finding's OWN content address
    # (`Canonical.digest(finding.to_s)`) rather than an id the finding does not
    # carry the way a tool call carries a `tool_use_id` -- it is the join key a
    # replay looks the verdict back up by. `survived` is the refuter's pass/
    # fail (a continuous Rubric score alone is not a verdict -- see
    # {Grader::Rubric}'s own "callers threshold #score" caveat -- so the
    # refuter thresholds it before this record is built); `score` is the raw
    # 0..1 confidence kept alongside for a reader who wants more than the
    # boolean; `why` is the mandatory explanation.
    #
    # {Grader::Refuter::Recorded.from_journal} reads this record back keyed by
    # `digest`, the same content-addressed replay {Effect::Handler::Recorded}
    # does for `tool_use_id` -- deterministic filtering with no model call.
    Verdict = Data.define(:digest, :survived, :score, :why) do
      include Journalable

      def initialize(digest:, survived:, score:, why:)
        Guards::Verdict.check!(digest:, survived:, why:)

        super(digest: digest.dup.freeze, survived:, score: score.to_f.clamp(0.0, 1.0), why: -why.to_s)
      end
    end
  end

  # CE-5's transient scheduling signal and its failure record, reopening
  # Telemetry as their own block for the same reason T13's block below does
  # (CLAUDE.md: a tripped Metrics/ModuleLength cop names a missing seam; here
  # the seam is "the provider round-trip's transient signal, not its durable
  # per-turn/per-request telemetry stream above").
  module Telemetry
    # T-CE5's construction contract, reopening {Guards} the way T16's block
    # further down reopens it (the same validate-then-freeze convention as
    # every carrier above).
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

  # The session-lifecycle records (T13), reopening Telemetry as their own block.
  # They are a distinct responsibility -- the session-record FORMAT's events, not
  # the per-turn/per-request telemetry stream above -- and splitting the module
  # here is what keeps each block within Metrics/ModuleLength without loosening
  # it (CLAUDE.md: a tripped Metrics cop names a missing seam; this is the seam).
  module Telemetry
    # A session's final anchor, written by {SessionRecord::Scribe} on a graceful
    # close. `head` is the Timeline head digest at close (nil for a session that
    # committed nothing); `reason` names WHY the session ended -- an enum, closed
    # and loud like {ToolOutput}'s stream, so a typo fails at construction rather
    # than journaling a reason no reader expects. Its presence is what tells a
    # loader an open session (a header with `head: nil` and no closer -- a
    # SIGKILL'd process) apart from one that ended on purpose.
    SessionClosed = Data.define(:head, :reason) do
      include Journalable

      def initialize(head:, reason:)
        super(head: head&.dup&.freeze, reason: self.class.reason!(reason))
      end
    end

    # REASONS is reopened onto the class rather than declared inside the
    # `Data.define ... do` block: a constant there is lexically scoped to the
    # enclosing MODULE (Telemetry), not the Data class (the pinned Ruby trap the
    # Request::SYSTEM_PREFIX comment records).
    class SessionClosed
      # `:salvaged` (T18) is additive: no reader branches on a
      # {SessionClosed} reason's VALUE, only on its presence (that is what
      # tells {Bench::Session::Anchor} a session closed at all) and, here, on
      # membership in this list -- verified before adding it. It names a
      # closed-file shape none of `exit`/`interrupted`/`grace_expired` is
      # honest about: {CLI::Resume::Salvager} closes the file from a LATER
      # process than the one that opened it, after recovering what it could
      # from the response log, not because the run that opened it stopped on
      # purpose or was interrupted mid-turn.
      REASONS = %i[exit interrupted grace_expired salvaged].freeze

      def self.reason!(reason)
        symbol = reason.to_sym
        return symbol if REASONS.include?(symbol)

        raise ArgumentError, "reason must be one of #{REASONS.inspect}, got #{reason.inspect}"
      end
    end

    # A single run stopped before its response committed -- a Ctrl-C (or an
    # expiring grace window) that beat the model's reply back. Distinct from
    # {SessionClosed}: the session lives on, but THIS ask produced no complete
    # turn, so `head` names the last committed turn the interrupted run was
    # generating from (nil if none yet). A reader pairs it with the absence of a
    # following turn record the way {Middleware::JournalRequests} reads a
    # request_sent with no turn_usage -- the interruption is in the record, not
    # inferred from a gap.
    RunInterrupted = Data.define(:head) do
      include Journalable

      def initialize(head:)
        super(head: head&.dup&.freeze)
      end
    end

    # A :message or :spawn Event promoted to the session record, its OWN additive
    # type so the turn-chain loader's `of_type` narrowing never sees it (a
    # :message can never survive {Timeline#commit}'s digest re-derivation, so it
    # must not wear the `turn` shape). Field-pinned to what a later re-put into a
    # Store needs -- `payload` is the addressed body, `causal_parents` the
    # backward edges a provenance walk descends -- carried as data here; T14 owns
    # reconstructing the Store from it.
    Message = Data.define(:digest, :kind, :from, :to, :payload, :causal_parents, :correlation) do
      include Journalable

      # The one funnel {Event::ChainWriter} observes hands the scribe an Event;
      # this is where its envelope + body become the flat record.
      def self.from_event(event)
        new(digest: event.digest, kind: event.kind, from: event.from, to: event.to,
            payload: event.body, causal_parents: event.causal_parents, correlation: event.correlation)
      end

      def initialize(digest:, kind:, from:, to:, payload:, causal_parents:, correlation:)
        super(
          digest: digest.dup.freeze,
          kind: kind.to_sym,
          from: Canonical.normalize(from),
          to: Canonical.normalize(to),
          payload: Canonical.normalize(payload),
          causal_parents: Canonical.normalize(causal_parents),
          correlation: Canonical.normalize(correlation)
        )
      end
    end
  end

  # T16's two run-state records, reopening Telemetry a third time for the same
  # reason T13's block exists (CLAUDE.md: a tripped Metrics/ModuleLength names
  # a missing seam, and here the seam is "yet another distinct group of
  # session-record events"). Both are emitted by {Session::Journaled}, the
  # decorator that keeps {Session} itself journal-ignorant -- neither the
  # Agent nor any tool ever constructs one directly.
  module Telemetry
    # T16's construction contract, reopening {Guards} the way this block
    # reopens Telemetry (the same validate-then-freeze convention as every
    # carrier above).
    module Guards
      # A read record must name the file read.
      class SessionRead < Guard
        attribute :path
        validates :path, presence: { message: "must name the file read, got nil" }
      end
    end

    # One path, the first time {Session#read?} would flip false -> true for
    # it this session. `path` is the SAME `File.expand_path`-normalized form
    # {Session} keys its read-set on (not the model's raw spelling) --
    # consistent with every other path already reachable from this journal
    # (a `tool_result`'s quoted file contents), and it is what
    # {SessionRecord::Replay} feeds straight back into a fresh Session's
    # `record_read` with no re-normalization required. A RE-read never lands
    # a second record: that dedupe is what keeps a big read/edit loop from
    # journaling one line per iteration.
    SessionRead = Data.define(:path) do
      include Journalable

      def initialize(path:)
        Guards::SessionRead.check!(path:)

        super(path: path.dup.freeze)
      end
    end

    # The run's ENTIRE todo list, one record per {Tools::TodoWrite} call --
    # matching {Session#write_todos}'s own replace-not-merge semantics, so
    # {SessionRecord::Replay} needs no merge logic of its own either: folding
    # every record in order and keeping only the last one's effect IS
    # {Session#write_todos}'s contract, applied N times. `todos` holds
    # `{content, status}` pairs in canonical wire form (String keys), the
    # same shape {Tools::TodoWrite}'s own Item carries.
    TodoSnapshot = Data.define(:todos) do
      include Journalable

      # Built from the duck {Session#write_todos} itself accepts -- any
      # Enumerable of objects answering `#content`/`#status` -- so the
      # decorator forwards its argument here unchanged rather than
      # pre-shaping it into hashes.
      def self.from(todos)
        new(todos: todos.map { |todo| { "content" => todo.content, "status" => todo.status } })
      end

      def initialize(todos:)
        super(todos: Canonical.normalize(todos))
      end
    end
  end

  # T18's one record, reopening Telemetry a fourth time for the same reason
  # every block above does (CLAUDE.md: a tripped Metrics/ModuleLength names a
  # missing seam, and here the seam is "yet another distinct group of
  # session-record events"). Emitted by {CLI::Resume}, never by
  # {SessionRecord::Salvage} itself -- that class is a pure calculation over
  # the ducks it is handed and never touches a file (see its class comment);
  # writing the record, like every other file effect of a resume, is the CLI
  # layer's job.
  module Telemetry
    # One salvage-on-resume: the harness recovered a paid-for-but-uncommitted
    # response from the {Provider::ResponseWal} instead of re-spending.
    # `request_digest` is the join key onto the {RequestSent} the response
    # answers; `head_before`/`head_after` are the Timeline heads either side of
    # the recovery, so a reader sees exactly which turn got recovered without
    # re-deriving it from the surrounding `turn` records. `head_before` is nil
    # when the crashed request was the session's very first -- an empty
    # Timeline has no head to name, the same nil-is-a-value idiom {MemoryRoot}
    # uses for an empty index, though the two are unrelated structures and
    # the nil arises for a different reason in each.
    #
    # Deliberately carries no usage or cost. {Agent::Accounting} never ran this
    # turn through the ordinary commit-then-journal atom -- there was no live
    # Agent, no provider call, that is the entire point of salvage -- so no
    # {TurnUsage} record exists for it either, and {Ledger} prices a salvaged
    # turn at zero. That is an accepted, DOCUMENTED gap, not a bug to route
    # around here: real tokens were genuinely spent the first time around, the
    # same shape as a silently-retried request (see {ProviderRetry}) where
    # real spend can exceed what the reported Usage ever shows. Inventing a
    # {TurnUsage} record after the fact would need a stop_reason and a token
    # count this class has no independent way to attribute correctly (the
    # recovered SSE stream's own `usage` field is exactly the number the
    # ORIGINAL, now-vanished Agent run would have journaled, and re-journaling
    # it a second time under a different digest would double-count it in any
    # aggregate that sums TurnUsage records) -- so the honest choice is a zero
    # line here, not a manufactured one there.
    Salvaged = Data.define(:request_digest, :head_before, :head_after) do
      include Journalable

      def initialize(request_digest:, head_before:, head_after:)
        super(request_digest: request_digest.dup.freeze, head_before: head_before&.dup&.freeze,
              head_after: head_after.dup.freeze)
      end
    end
  end

  # T3's one record, reopening Telemetry a fifth time for the same reason every
  # block above does (CLAUDE.md: a tripped Metrics/ModuleLength names a missing
  # seam; here the seam is "the oracle tier's replayable answer, keyed for
  # substitution, not the per-turn/per-request telemetry stream"). Emitted by
  # {Oracle::Recorded::Journaling}, read back by {Oracle::Recorded.from_journal}
  # -- the same "recorded is a replay of a real interpretation" shape as
  # {Verdict}/{Grader::Refuter::Recorded}, one oracle tier over.
  module Telemetry
    # T3's construction contract, reopening {Guards} the way every block above
    # does (the same validate-then-freeze convention as every carrier here).
    module Guards
      # An oracle-answer record must name the oracle it answered (the digest
      # replay substitutes on) and carry the question that was asked.
      class OracleAnswer < Guard
        attribute :oracle_digest
        attribute :question
        validates :oracle_digest, presence: { message: "must name the oracle it answered, got nil" }
        validates :question, presence: { message: "must carry the question asked, got nil" }
      end
    end

    # One oracle call, recorded for deterministic replay. `oracle_digest` is the
    # {Oracle::Definition#digest} -- the JOIN KEY {Oracle::Recorded} substitutes
    # on, and precisely why a CHANGED oracle schema (a different digest) misses
    # loudly rather than matching a stale answer. `question` is the rendered,
    # `Canonical.normalize`d prompt, the second half of the `(digest, question)`
    # key. `answer` is the raw answer attributes the definition's schema
    # validated, fed straight back through {Oracle::Definition#answer} on replay
    # -- so a schema the recording no longer satisfies raises THERE too, a
    # second loud staleness guard behind the digest key.
    #
    # `model` names the tier's model (nil for the model-free {Oracle::Heuristic}
    # and a bare mock); `usage` is the call's token accounting in canonical wire
    # form (empty when the tier reported none -- the tier interface deliberately
    # hides which tier answered, so the decorator journals what the caller's
    # wiring supplies); `wall_clock` is the measured elapsed seconds. All three
    # are accounting metadata, NOT part of the substitution key -- like
    # {TurnUsage}, this record is a per-call payment stream, not a dedupe set.
    OracleAnswer = Data.define(:oracle_digest, :question, :answer, :model, :usage, :wall_clock) do
      include Journalable

      def initialize(oracle_digest:, question:, answer:, model: nil, usage: {}, wall_clock: 0.0)
        Guards::OracleAnswer.check!(oracle_digest:, question:)

        super(
          oracle_digest: oracle_digest.dup.freeze,
          question: Canonical.normalize(question),
          answer: Canonical.normalize(answer),
          model: model&.to_s&.freeze,
          usage: Canonical.normalize(usage),
          wall_clock: wall_clock.to_f
        )
      end
    end
  end

  # T20's one record (CAC-6), reopening Telemetry a sixth time for the same
  # reason every block above does (CLAUDE.md: a tripped Metrics/ModuleLength
  # names a missing seam; here the seam is "the compaction scheduler's full
  # accounting, not the per-turn/per-request telemetry stream"). Emitted from
  # {Compaction::Scheduler}'s existing `if decision.compact?` guard in
  # `#pipeline` -- REPLACING the lighter `CompactionScheduled` record that
  # guard used to build (`reason`/`tier` alone). There is one record at that
  # call site, not two synchronized ones: extending what was already there,
  # not adding a second, independently-guarded emission path.
  module Telemetry
    module Guards
      # A compaction record must name what fired it and land on one of the
      # three cache states the scheduler's policy actually reaches.
      class Compaction < Guard
        attribute :trigger
        attribute :cache_state
        validates :trigger, presence: { message: "must name the Need signal(s) that fired, got none" }
        validates :cache_state, inclusion: { in: %i[warm cold forced],
                                             message: "must be one of warm/cold/forced, got %<value>s" }
      end
    end

    # Every compaction's full accounting (CAC-6): WHY it fired (`trigger`,
    # the {Compaction::Need} signals that were live) and WHAT cache state the
    # scheduler read (`cache_state`), so {Compare} can attribute a cost delta
    # to the scheduling policy rather than to the summarizer itself.
    #
    # `cache_state` is closed over `:warm`/`:cold`/`:forced`, but a compacting
    # decision only ever reaches `:cold` or `:forced` here: an unforced warm
    # decision always DEFERS (see {Compaction::Scheduler#evaluate}) and never
    # reaches a journal at all. `:warm` completes the enum for a reader who
    # expects the full CAC-6 vocabulary; it is not a value this scheduler
    # emits today.
    #
    # `tokens_before`/`tokens_after` are the SAME canonical-byte-length proxy
    # {Compaction::Need::TokenThreshold} and {Context::Compact} already use in
    # place of a real tokenizer (see either's header for why a deterministic
    # proxy is the only property needed here) -- one consistent unit across
    # the compaction subsystem, not a second, incompatible one.
    #
    # `cost_saved`/`cost_spent` are ESTIMATES, not payments: unlike
    # {TurnUsage}, no model call happens inside a compaction -- `Compact`'s
    # summarizer is a pure, already-injected, deterministic function (see its
    # own header) -- so there is no real {Lain::Usage} to price against.
    # `cost_saved` prices the token delta at the model's plain input rate:
    # what continuing to resend the dropped tokens every subsequent turn
    # would have cost. `cost_spent` prices `tokens_after` at the
    # cache_creation rate ONLY when `cache_state` is `:forced` -- rewriting
    # the message tier while the cache was still warm is exactly what forces
    # that write -- and is zero on `:cold`, matching {Compaction::Scheduler}'s
    # own "a cold cache runs the compaction for free" rationale. Both are
    # zero, DOCUMENTED the way {Salvaged}'s zero-cost gap is, when the
    # scheduler carries no `model` to price with: an unpriced scheduler is a
    # legitimate configuration today (nothing downstream reads cost from it
    # yet), not a caller error worth raising over.
    #
    # Held as fixed-point decimal STRINGS, not `BigDecimal`: `Canonical.normalize`
    # deliberately does not support `BigDecimal` (it has no canonical wire
    # form), and every `Data` field here must already be an immutable, JSON-safe
    # value to keep this record `Ractor.shareable?` -- the same "canonical wire
    # form" idiom {RequestSent}'s `payload` and {TurnUsage}'s `usage` already
    # use for anything that is not natively JSON-safe.
    Compaction = Data.define(:trigger, :cache_state, :tokens_before, :tokens_after, :cost_saved, :cost_spent) do
      include Journalable

      def initialize(trigger:, cache_state:, tokens_before:, tokens_after:, cost_saved:, cost_spent:)
        trigger = Array(trigger).map(&:to_sym).freeze
        cache_state = cache_state.to_sym
        Guards::Compaction.check!(trigger:, cache_state:)
        super(trigger:, cache_state:, tokens_before: Integer(tokens_before), tokens_after: Integer(tokens_after),
              cost_saved: decimal(cost_saved), cost_spent: decimal(cost_spent))
      end

      # The cost delta {Compare} attributes to the scheduling policy:
      # positive means the compaction paid for itself, negative means it cost
      # more than it saved (a forced-warm rewrite on a small delta, say).
      #
      # @return [BigDecimal]
      def cost_delta
        BigDecimal(cost_saved) - BigDecimal(cost_spent)
      end

      private

      # Fixed-point ("F") rather than BigDecimal's default `to_s`, which
      # emits scientific notation (`"0.12345e-2"`) that is technically valid
      # JSON but unreadable in an NDJSON line meant for a human to scan.
      def decimal(value)
        (value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)).to_s("F").freeze
      end
    end
  end

  # B6's one record, reopening Telemetry a seventh time for the same reason
  # every block above does (CLAUDE.md: a tripped Metrics/ModuleLength names a
  # missing seam; here the seam is "the isolation backend's lease lifecycle,
  # not the per-turn/per-request telemetry stream"). Emitted by
  # {Isolation::Journal}, the Journal-duck decorator ({Memory::JournalMemoryRoot}/
  # {Session::Journaled}'s shape, applied to the Isolation seam) that wraps ANY
  # backend's `acquire`/`release` -- never by a backend ({Null}/{Worktree}/a
  # future DbIndex/Compose) itself, which stays journal-ignorant.
  module Telemetry
    module Guards
      # An isolation-lease record must land on one of the lifecycle kinds and
      # name the worker it belongs to.
      class IsolationLease < Guard
        attribute :kind
        attribute :worker_key
        validates :kind, inclusion: { in: %i[acquired released service_provisioned service_torn_down],
                                      message: "must be one of acquired/released/service_provisioned/" \
                                               "service_torn_down, got %<value>s" }
        validates :worker_key, presence: { message: "must name the worker the lease belongs to, got nil" }
      end
    end

    # One transition in an isolation lease's lifecycle: `kind` names WHICH
    # transition (`:acquired`/`:released` today; `:service_provisioned`/
    # `:service_torn_down` complete the vocabulary for a richer backend --
    # B3's Postgres/Redis DB-index, B4's compose stack -- to emit ALONGSIDE
    # these two, the same "closed enum, not every value reached yet" idiom
    # {Compaction#cache_state} documents for its own unreached `:warm`).
    # `worker_key` is the STRING form of whatever `worker_id` the caller
    # passed to `acquire` -- the same arbitrary-object-as-key idiom
    # {Paths#project_hash} already keys a filesystem path on -- so this record
    # stays a self-describing value regardless of what a caller's worker
    # identity actually is, and is the COUNTABLE key `Compare` sums lease/
    # thrash cost over later (a worker with N acquire/release pairs is
    # visible as N records sharing one `worker_key`). `backend` names the
    # class doing the leasing (a String, not the object), so a report can
    # break lease cost down by strategy.
    #
    # `service` is nil for the base `:acquired`/`:released` pair a lease
    # lifecycle always emits -- there is no service to name yet, only a
    # WorkerEnv -- and is the field a `:service_provisioned`/
    # `:service_torn_down` record from a richer backend would fill with a
    # NAME ("postgres", "redis"), never a connection string: this record
    # must never carry a `DATABASE_URL`/`REDIS_URL` or any credential, only
    # attribution. A backend that wants a URL journaled has to redact it
    # first -- this record gives it nowhere to put the raw bytes.
    IsolationLease = Data.define(:kind, :worker_key, :backend, :service) do
      include Journalable

      def initialize(kind:, worker_key:, backend:, service: nil)
        kind = kind.to_sym
        Guards::IsolationLease.check!(kind:, worker_key:)

        super(
          kind:,
          worker_key: worker_key.to_s.dup.freeze,
          backend: backend.to_s.dup.freeze,
          service: service&.to_s&.freeze
        )
      end
    end
  end

  # GG-5's one record, reopening Telemetry an eighth time for the same reason
  # every block above does (CLAUDE.md: a tripped Metrics/ModuleLength names a
  # missing seam; here the seam is "the grader-attestation stream, not the
  # per-turn/per-request telemetry stream"). Emitted by {Grader::Journaling},
  # the decorate-and-journal idiom {Grader::Verified} already established one
  # level up for its own second-pass {Verdict}.
  module Telemetry
    module Guards
      # A grade attestation must name the grader that produced it, the subject
      # it judged, say whether it passed as a real boolean (the same
      # `presence:`-cannot-reject-`false` reasoning as {Verdict}'s `survived`),
      # and explain itself.
      class GradeRecord < Guard
        attribute :grader
        attribute :subject_digest
        attribute :pass
        attribute :why
        validates :grader, presence: { message: "must name the grader class, got nil" }
        validates :subject_digest, presence: { message: "must name the subject graded, got nil" }
        validates :pass, inclusion: { in: [true, false], message: "must be true or false, got %<value>s" }
        validates :why, presence: { message: "must explain the grade, got nil" }
      end
    end

    # GG-5's attestation: a plain {Grader::Grade} was never journaled before
    # this record existed -- {Verdict} above is {Grader::Verified}'s own
    # second-pass verdict, not a record of the ORDINARY `#grade` every grader
    # (`Fixture`/`Recall`/`Rubric`/`TestHarness`) answers with. {Grader::Journaling}
    # decorates any `#grade` duck and journals one of these per call, unchanged
    # alongside the Grade it passes through.
    #
    # `grader` is the producing class's NAME (a String, like {IsolationLease}'s
    # `backend`), not the object -- a self-describing value, never a live
    # reference. `subject_digest` addresses whatever was graded, resolved by
    # {Grader::Journaling#digest_for} in a pinned order that never guesses: an
    # injected `subject_digest:` callable wins outright, else the subject's
    # OWN `#digest` is trusted verbatim, else a bare String subject is hashed
    # via `Canonical.digest`, else a named `UndigestableSubject` raises rather
    # than silently addressing the subject's `Object#inspect` identity -- an
    # attribution key, not a claim that two equal digests graded
    # byte-identical subjects across runs.
    #
    # `criteria_digest` is the {Gherkin::Criteria#digest} this grade was judged
    # against, when the subject was generated from Gherkin acceptance criteria
    # -- optional and nil by default, since not every grader judges against a
    # parsed criteria doc. Its presence is what lets a later {Bench::DryReplay}
    # read recover "which criteria was this run graded against" from the
    # record alone, the same join-key role {MemoryRoot}'s `root` plays for a
    # committed turn's memory snapshot.
    GradeRecord = Data.define(:grader, :score, :pass, :why, :subject_digest, :criteria_digest) do
      include Journalable

      # Built from a live {Grader::Grade} plus the attribution
      # {Grader::Journaling} supplies -- the grade's own fields ride straight
      # through unchanged.
      def self.from(grade, grader:, subject_digest:, criteria_digest: nil)
        new(grader:, score: grade.score, pass: grade.pass?, why: grade.why, subject_digest:, criteria_digest:)
      end

      def initialize(grader:, score:, pass:, why:, subject_digest:, criteria_digest: nil)
        grader = grader.to_s
        Guards::GradeRecord.check!(grader:, subject_digest:, pass:, why:)

        super(
          grader: grader.dup.freeze,
          score: score.to_f.clamp(0.0, 1.0),
          pass:,
          why: -why.to_s,
          subject_digest: subject_digest.dup.freeze,
          criteria_digest: criteria_digest&.dup&.freeze
        )
      end
    end
  end

  # PC-2's Store-pointer-in-the-Journal, reopening Telemetry a ninth time for
  # the same missing-seam reason every block above does (CLAUDE.md: a tripped
  # Metrics/ModuleLength names a missing seam; here the seam is "the
  # plan-closure attestation stream"). Emitted by {Plan::Closure#record}, the
  # same pairing {MemoryRoot} makes: a {Plan::Closure} is put into the in-memory
  # Store by its content address, and this record journals that address so a
  # later process -- P5's calibration, a resumed session -- recovers the closure
  # from the Journal alone, the Store having died with its process.
  module Telemetry
    module Guards
      # A closure pointer must name the closure it points at, the step it
      # closed, the plan that step belongs to, and the step's S/M/L size class
      # (P5 calibrates seam placement over size from the Journal alone).
      class ClosureRecord < Guard
        attribute :closure_digest
        attribute :step_id
        attribute :plan_digest
        attribute :size
        validates :closure_digest, presence: { message: "must name the closure in the Store, got nil" }
        validates :step_id, presence: { message: "must name the step it closed, got nil" }
        validates :plan_digest, presence: { message: "must name the plan the step belongs to, got nil" }
        validates :size, presence: { message: "must name the step's size class, got nil" }
      end
    end

    # The Journal-resident pointer to one {Plan::Closure}: `closure_digest`
    # addresses the frozen record in the Store, `step_id` and `plan_digest` are
    # the join keys a report groups closures by, `size` is the step's S/M/L
    # class (carried so P5 calibrates seam placement over size from the Journal
    # alone -- Plan::Document is never journaled, so this pointer is the only
    # place size survives), and `chunk_turn_digests` names the elided span the
    # closure attests -- the same digests the closure's own `elided_digests`
    # hold, carried here so a Journal reader localizes the chunk without
    # fetching the closure. Deeply frozen (interned digests, frozen array) so
    # the record stays Ractor-shareable.
    ClosureRecord = Data.define(:closure_digest, :step_id, :plan_digest, :size, :chunk_turn_digests) do
      include Journalable

      def initialize(closure_digest:, step_id:, plan_digest:, size:, chunk_turn_digests:)
        Guards::ClosureRecord.check!(closure_digest:, step_id:, plan_digest:, size:)

        super(
          closure_digest: closure_digest.dup.freeze,
          step_id: step_id.dup.freeze,
          plan_digest: plan_digest.dup.freeze,
          size: size.dup.freeze,
          chunk_turn_digests: chunk_turn_digests.map { |digest| -digest.to_s }.freeze
        )
      end
    end
  end

  # PC-3's reopen pointer, reopening Telemetry once more for the same
  # missing-seam reason {ClosureRecord} does: when a plan step REOPENS -- a
  # fresh fork's {Plan::Closure} superseding an earlier one -- {Plan::ForkPerStep}
  # puts a {Plan::Supersession} into the in-memory Store by its content address,
  # and this record journals that address plus both closure digests the
  # succession connects. So a later process (a resumed session, a report reading
  # the Journal) recovers the reopen from the NDJSON alone -- the same
  # Store-pointer-in-the-Journal move {ClosureRecord} makes for the closure it
  # points at, since the Store dies with its process.
  module Telemetry
    module Guards
      # A supersession pointer must name the record it points at, the step that
      # reopened, BOTH closure digests the succession connects, and the plan the
      # step belongs to -- the same join keys {ClosureRecord} carries, so a
      # reader groups reopens by step within a plan without fetching anything.
      class SupersessionRecord < Guard
        attribute :supersession_digest
        attribute :step_id
        attribute :superseded_digest
        attribute :superseding_digest
        attribute :plan_digest
        validates :supersession_digest, presence: { message: "must name the supersession in the Store, got nil" }
        validates :step_id, presence: { message: "must name the step that reopened, got nil" }
        validates :superseded_digest, presence: { message: "must name the superseded closure, got nil" }
        validates :superseding_digest, presence: { message: "must name the superseding closure, got nil" }
        validates :plan_digest, presence: { message: "must name the plan the step belongs to, got nil" }
      end
    end

    # The Journal-resident pointer to one {Plan::Supersession}:
    # `supersession_digest` addresses the frozen sibling in the Store, `step_id`
    # and `plan_digest` are the join keys a report groups reopens by, and
    # `superseded_digest`/`superseding_digest` are the two {Plan::Closure}
    # addresses the succession connects -- carried here so a Journal reader
    # recovers both closures without fetching the supersession. Deeply frozen
    # (interned digests) so the record stays Ractor-shareable.
    SupersessionRecord = Data.define(:supersession_digest, :step_id, :superseded_digest,
                                     :superseding_digest, :plan_digest) do
      include Journalable

      def initialize(supersession_digest:, step_id:, superseded_digest:, superseding_digest:, plan_digest:)
        Guards::SupersessionRecord.check!(supersession_digest:, step_id:, superseded_digest:,
                                          superseding_digest:, plan_digest:)

        super(
          supersession_digest: supersession_digest.dup.freeze,
          step_id: step_id.dup.freeze,
          superseded_digest: superseded_digest.dup.freeze,
          superseding_digest: superseding_digest.dup.freeze,
          plan_digest: plan_digest.dup.freeze
        )
      end
    end
  end

  # GG-1's one record, reopening Telemetry a tenth time for the same
  # missing-seam reason every block above does (CLAUDE.md: a tripped
  # Metrics/ModuleLength names a missing seam; here the seam is "the
  # gherkin-approval-gate attestation stream, not the per-turn/per-request
  # telemetry stream"). Emitted by {Gherkin::Approval#call}, the same
  # decide-then-journal pairing {Approval::Queue} makes for its own
  # `approval_decision` line -- one gate, one durable verdict.
  module Telemetry
    module Guards
      # An approval verdict must name the criteria it judged, say whether it
      # was approved as a real boolean (the same `presence:`-cannot-reject-
      # `false` reasoning as {Verdict}'s `survived`), and name who answered --
      # a surface, never nil, so a journal reader never guards (the same
      # named-not-nil discipline {Approval::Queue::TIMEOUT_SURFACE} keeps).
      class GherkinApproval < Guard
        attribute :criteria_digest
        attribute :approved
        attribute :answered_by
        validates :criteria_digest, presence: { message: "must name the criteria it judged, got nil" }
        validates :approved, inclusion: { in: [true, false], message: "must be true or false, got %<value>s" }
        validates :answered_by, presence: { message: "must name who answered, got nil" }
      end
    end

    # One GG-1 approval verdict over a {Gherkin::Criteria}. `criteria_digest`
    # is the {Gherkin::Criteria#digest} the gate judged -- the JOIN KEY a
    # downstream refuses to consume unapproved, and precisely why an edited
    # clause (a different digest) is a distinct, un-approved criteria rather
    # than a stale match. `approved` is the verdict as a real boolean;
    # `answered_by` NAMES the surface that gave it -- the human surface, the
    # `"auto_approver"` meta-agent, or `"timeout"` when the fail-closed clock
    # denied an unanswered gate -- so a transcript never confuses who approved
    # what (the same signed-surface evidence {Approval::Queue} keeps for its
    # `approval_decision`). `latency` is the measured seconds the verdict took.
    GherkinApproval = Data.define(:criteria_digest, :approved, :answered_by, :latency) do
      include Journalable

      def initialize(criteria_digest:, approved:, answered_by:, latency:)
        Guards::GherkinApproval.check!(criteria_digest:, approved:, answered_by:)

        super(
          criteria_digest: criteria_digest.dup.freeze,
          approved:,
          answered_by: answered_by.to_s.dup.freeze,
          latency: latency.to_f
        )
      end
    end
  end

  # PC-4's one record, reopening Telemetry an eleventh time for the same
  # missing-seam reason every block above does (CLAUDE.md: a tripped
  # Metrics/ModuleLength names a missing seam; here the seam is "the seam-EV
  # decision stream, not the per-turn/per-request telemetry stream"). Emitted by
  # {Plan::SeamDecision#call} -- the same decide-then-journal pairing
  # {Compaction::Scheduler} makes for its own {Compaction} accounting, one seam,
  # one durable verdict.
  module Telemetry
    module Guards
      # A seam-EV verdict must name a REAL chunk size class it weighed (not just
      # any non-nil string -- an "XL" reaching this record through the calibrated
      # estimate path would otherwise journal silently) and land on one of the
      # two answers the policy reaches. The S/M/L set is {Plan::SIZES}, held
      # verbatim here rather than referenced: this Guard's class body evaluates
      # at telemetry.rb load time, before the plan/ unit loads.
      class SeamDecision < Guard
        attribute :size
        attribute :verdict
        validates :size, inclusion: { in: %w[S M L], message: "must be one of S/M/L, got %<value>s" }
        validates :verdict, inclusion: { in: %i[rewrite_now defer],
                                         message: "must be rewrite_now or defer, got %<value>s" }
      end
    end

    # Every seam's full EV accounting (PC-4): the size class weighed (`size`),
    # the turns-remaining estimate it priced payback over (`estimated_turns`)
    # and whether that estimate came from Journal calibration (`calibrated`,
    # false when the annotation default stood in), the tokens a rewrite would
    # drop (`tokens_removed`) and the shorter prefix it would leave
    # (`tokens_after`, priced by `rewrite_cost`), and BOTH priced sides --
    # `rewrite_cost` (one cache write of that shorter prefix) versus `payback`
    # (resending the dropped tokens at the provider's per-turn resend rate --
    # its cache read discount where one exists, full input where it does not --
    # over the estimated remaining turns) -- so {Compare} can audit the
    # rewrite-now/defer decision,
    # AND re-derive each cost from the record alone, against what the chunk
    # ACTUALLY consumed. Recording both token operands (removed AND after)
    # matches the sibling {Compaction} record, which carries `tokens_before`
    # and `tokens_after` for the same self-contained-audit reason.
    # `calibrated: false` on a mis-sized annotation is what keeps the
    # estimate-vs-actual drift visible rather than silently absorbed.
    #
    # `rewrite_cost`/`payback` are held as fixed-point decimal STRINGS, not
    # `BigDecimal`, for exactly the reason {Compaction}'s `cost_saved`/
    # `cost_spent` are: `Canonical.normalize` has no canonical wire form for
    # `BigDecimal`, and every field must be an immutable, JSON-safe value to
    # keep this record `Ractor.shareable?`. `estimated_turns` is a plain
    # Integer or Float (a calibrated median may be fractional) -- both JSON-safe
    # and already immutable.
    SeamDecision = Data.define(:size, :estimated_turns, :calibrated, :tokens_removed, :tokens_after,
                               :rewrite_cost, :payback, :verdict) do
      include Journalable

      def initialize(size:, estimated_turns:, calibrated:, tokens_removed:, tokens_after:,
                     rewrite_cost:, payback:, verdict:)
        size = size.to_s
        verdict = verdict.to_sym
        Guards::SeamDecision.check!(size:, verdict:)

        super(
          size: -size, estimated_turns:, calibrated: calibrated ? true : false,
          tokens_removed: Integer(tokens_removed), tokens_after: Integer(tokens_after),
          rewrite_cost: decimal(rewrite_cost), payback: decimal(payback), verdict:
        )
      end

      # @return [Boolean] whether the decision rewrites the seam now.
      def rewrite? = verdict == :rewrite_now

      # The EV margin {Compare} reads: positive means the rewrite pays for
      # itself over the estimated remaining turns, negative means deferring is
      # cheaper. Mirrors {Compaction#cost_delta}.
      #
      # @return [BigDecimal]
      def net
        BigDecimal(payback) - BigDecimal(rewrite_cost)
      end

      private

      # Fixed-point ("F") rather than BigDecimal's default scientific-notation
      # `to_s`, the same readable-NDJSON reason {Compaction#decimal} carries.
      def decimal(value)
        (value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)).to_s("F").freeze
      end
    end
  end

  # T18's dispatch marker (M4-2), reopening Telemetry once more for the same
  # missing-seam reason every block above does (CLAUDE.md: a tripped
  # Metrics/ModuleLength names a missing seam; here the seam is "the resend
  # bridge's provenance stream, not the per-turn/per-request telemetry
  # stream"). Emitted by {CLI::ResendBridge}, never by the frontend -- the
  # projection half of a resend already journals as {RequestResent}, and this
  # marker is what says the OTHER half happened.
  module Telemetry
    module Guards
      # A dispatch marker must name the resent request it dispatched.
      class ResendDispatched < Guard
        attribute :digest
        validates :digest, presence: { message: "must name the resent request it dispatched, got nil" }
      end
    end

    # A hand-edited resend was handed to the loop for dispatch: T18's
    # provenance stamp, in the record TYPE like {RequestResent}'s own (never in
    # `extra`, which rides onto the wire on any rebuild-and-dispatch). Written
    # by {CLI::ResendBridge} BETWEEN staging the {Agent::RequestOverride} slot
    # and {Agent#run} -- attempt-first, the same record-before-dispatch posture
    # {Middleware::JournalRequests} takes -- so a dispatch whose wire call then
    # raised still reads as attempted. `digest` is the edited request's content
    # address, the join key onto BOTH the {RequestResent} projection it
    # promotes and the ordinary {RequestSent} the wire path journals when the
    # loop actually sends it; a marker with no request_sent after it reads as
    # a dispatch that died before the wire, exactly the way a request_sent
    # with no turn_usage reads as a wire call that died before payment.
    ResendDispatched = Data.define(:digest) do
      include Journalable

      def initialize(digest:)
        Guards::ResendDispatched.check!(digest:)

        super(digest: digest.dup.freeze)
      end
    end
  end
end
