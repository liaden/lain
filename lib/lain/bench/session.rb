# frozen_string_literal: true

module Lain
  module Bench
    # One run persisted as NDJSON in the Journal's OWN format (design decision
    # D3): the live run's journal already carries request_sent / turn_usage /
    # capability_degraded lines, and {Session.write} appends what those cannot
    # express -- one "session" header (the Context, tool schema, and reminders
    # in effect) and one "turn" record per committed turn. {Session.load} then
    # rebuilds a {Recording} from the bytes alone, re-deriving each turn's
    # content address so the file's own digests are its integrity check.
    #
    # The header captures exactly {Lain::Context}'s constructor inputs, so a
    # loaded Recording rebuilds the DEFAULT-pipeline Context. A run recorded
    # under a Context subclass (a custom pipeline) still round-trips its data
    # -- the header's `context_class` names what rendered it, as data,
    # surfaced as {Recording#context_class} -- but
    # {Recording#dry_replay} against `recording.context` only claims byte
    # identity for default-pipeline sessions; that is the stated limit of
    # this format.
    #
    # == One run, one journal, one file
    #
    # Concatenation is outside the format: a second "session" header in one
    # stream raises {Corrupt} rather than guessing which run is meant. The
    # header's `head` anchor is what rejects truncation and cross-run splices
    # through the turn chain -- a Merkle chain self-verifies only its PREFIX,
    # so without the anchor a deleted tail would load as a shorter session
    # that still replays identically. Stated honestly: a baseline substituted
    # WHOLESALE from a same-shape foreign run is self-consistent record by
    # record, so it stays detectable only as non-identity under dry replay,
    # never at load time. Likewise the transport fields (stream, extra) sit
    # outside the content address and load unverified -- {Request#digest}
    # deliberately excludes them, so the integrity envelope covers content,
    # not transport.
    class Session
      # A session file whose records no longer cohere: a turn or request_sent
      # whose content re-derives to a different digest than the one recorded
      # under it, a turn chain whose rebuilt head misses the header's anchor,
      # or a journal with no session header to rebuild a Context from (or with
      # more than one). Extended for the live session format's open sessions
      # and resume chains (T14): a `resumed_from` head that does not match the
      # prior file's own rebuilt head, a `message` record whose envelope no
      # longer re-derives to its recorded digest, or more than one
      # `session_closed` closer in one file.
      class Corrupt < Error; end

      # == Open sessions and resume chains (T14)
      #
      # {SessionRecord}'s live format (T13) can leave a header's `head` nil --
      # an OPEN session still running, or one a SIGKILL just stopped -- rather
      # than this class's own header, which is always anchored because it is
      # written AFTER the run. A nil header `head` verifies against a
      # `session_closed` record's OWN `head` when one is present (the header
      # itself is never rewritten at close); with neither anchor, {Loader}
      # loads the prefix UNVERIFIED-but-self-consistent, the documented
      # anti-truncation limit ({SessionRecord}'s class comment) -- and
      # {Recording#open?} names which shape a caller got.
      #
      # A header MAY also carry `resumed_from` -- `{"file" => <prior file's
      # basename>, "head" => <prior file's recorded head digest>}` -- naming a
      # PRIOR file this session continues. {Loader} follows it through an
      # INJECTED resolver duck (`resolve.call(basename) -> entries`), never a
      # filesystem call of its own (the Loader's whole contract is "handed
      # records, in"), verifies the prior file's own rebuilt head against the
      # recorded digest, and folds its turns and `message` records in BEFORE
      # this file's own -- so {Recording#timeline} is one continuous
      # conversation across the whole chain. Only the Timeline and the
      # `message` events merge this way; `baseline`, `degraded`, `memory`, and
      # `ledger_index` stay scoped to the file actually loaded, stated
      # honestly as this format's current limit rather than silently partial.

      HEADER_TYPE = "session"
      TURN_TYPE = "turn"

      # The recorded tool schema, wearing the one duck {Context#render}
      # consumes from a toolset: #to_schema. The live {Lain::Toolset} cannot be
      # rebuilt from a journal (tools are capabilities, code included), but the
      # render seam never needed it -- the schema bytes are what reached the
      # model.
      RecordedToolset = Data.define(:schema) do
        def initialize(schema:)
          super(schema: Canonical.normalize(schema))
        end

        def to_schema
          schema
        end
      end

      # The per-turn memory surface a {Loader} rebuilds: the {Memory::Index}
      # root in force when each recorded turn committed (replayed from the
      # recording's own successful memory_write calls -- the turns ARE the
      # write log) and the fully replayed index, whose store resolves every
      # one of those roots. A root is nil for a turn that committed before
      # any write -- nil IS the empty index's identity, a value here, exactly
      # as {Telemetry::MemoryRoot} records it on the wire.
      RecordedMemory = Data.define(:roots, :index) do
        def initialize(roots:, index:)
          super(roots: roots.freeze, index:)
        end

        # @raise [KeyError] for a digest naming no recorded turn -- loud, the
        #   same way Store#fetch answers an unknown digest
        def root_at(turn_digest)
          roots.fetch(turn_digest)
        end

        # The exact snapshot turn_digest's render saw, however far the index
        # moved afterwards.
        def at(turn_digest)
          index.checkout(root_at(turn_digest))
        end
      end

      # Everything {Session.load} rebuilds, as one frozen value. Holds Stores
      # (via its Timeline and its memory surface), so like Timeline itself it
      # cannot be `Ractor.shareable?` whole; every other member is.
      #
      # `context_class` is the header's recorded class name, pure data and
      # never constantized: `context` is always the reloaded DEFAULT-pipeline
      # Context, so a consumer comparing the two can tell a custom-pipeline
      # recording (which legitimately will not replay to byte identity) from a
      # genuine harness leak.
      #
      # `open` and `messages` are T14's additions, both additive: `open` names
      # whether {Loader} verified a full anchor or only the documented
      # unverified-prefix shape (see the class note above); `messages` is the
      # session's re-put :message/:spawn events, root-first like `baseline`,
      # holding the SAME Store {timeline} does (fetchable by digest from
      # either).
      Recording = Data.define(:context, :context_class, :toolset, :workspace,
                              :timeline, :baseline, :ledger_index, :degraded, :memory,
                              :open, :messages) do
        def initialize(context:, context_class:, toolset:, workspace:, timeline:, baseline:, ledger_index:,
                       degraded:, memory:, open:, messages:)
          super(context:, context_class: -context_class.to_s, toolset:, workspace:,
                timeline:, baseline: baseline.freeze, ledger_index:, degraded:, memory:,
                open:, messages: messages.freeze)
        end

        # A recording whose baseline outnumbers the DAG's assistant turns holds
        # a failed attempt (a request_sent with no following turn_usage), and
        # DryReplay's 1:1 guard raises on it -- loudly, by design.
        def dry_replay
          DryReplay.new(timeline:, baseline:, toolset:, workspace:)
        end

        def memory_root_at(turn_digest) = memory.root_at(turn_digest)

        def memory_at(turn_digest) = memory.at(turn_digest)

        def open? = open
      end

      class << self
        # Append the session header and one turn record per turn (root to
        # head) to the run's existing journal.
        #
        # @param journal [#<<] the run's Journal, already carrying its live records
        # @param timeline [Lain::Timeline] the recorded final DAG
        # @param context [Lain::Context] the context the run rendered under
        # @param toolset [#to_schema] the toolset in effect at record time
        # @param workspace [Lain::Workspace] the workspace in effect at record time
        # @return [#<<] the journal
        def write(journal, timeline:, context:, toolset:, workspace: Workspace.empty)
          journal << header_record(timeline, context, toolset, workspace)
          timeline.to_a.each { |turn| journal << turn_record(turn) }
          journal
        end

        # Rebuild a {Recording} from a session file's bytes.
        #
        # @param source [String, Enumerable<Hash, String>] a String is a PATH
        #   (read with File.foreach), never a raw NDJSON line; anything else is
        #   journal entries in the {Journal.parse} duck (foreign lines skip to
        #   nil)
        # @return [Recording]
        # @raise [Corrupt] on a digest or head-anchor mismatch, a missing
        #   session header, or more than one
        def load(source)
          Loader.new(entries(source)).recording
        end

        private

        def entries(source)
          source.is_a?(String) ? File.foreach(source) : source
        end

        # `head` anchors the whole turn chain (see the class note on
        # truncation); `context_class` is pure data -- {Loader} never
        # constantizes it, it names what rendered the run for the record's
        # sake.
        def header_record(timeline, context, toolset, workspace)
          {
            "type" => HEADER_TYPE, "context_class" => context.class.name,
            "model" => context.model, "max_tokens" => context.max_tokens,
            "system" => context.system, "stream" => context.stream, "extra" => context.extra,
            "head" => timeline.head_digest,
            "tools" => toolset.to_schema, "reminders" => workspace.reminders
          }
        end

        # The body fields plus the render edge -- exactly what {Loader#timeline}
        # re-commits through the event chain, so recording them beside the
        # digest is what lets the Loader recompute and compare. (The turn's own
        # envelope hashes correlation too, but correlation derives from the
        # chain itself, so the re-commit reproduces it from these bytes alone.)
        def turn_record(turn)
          { "type" => TURN_TYPE, "digest" => turn.digest, "role" => turn.role,
            "content" => turn.content, "parent" => turn.parent, "meta" => turn.meta }
        end
      end
    end
  end
end

# Anchor, MemoryReplay, MessageReplay, RequestReplay, and ResumeChain before
# Loader: the Loader is the class that sends them messages, so it reads as
# the dependent unit even though all six resolve at runtime.
require_relative "session/anchor"
require_relative "session/memory_replay"
require_relative "session/message_replay"
require_relative "session/request_replay"
require_relative "session/resume_chain"
require_relative "session/loader"
