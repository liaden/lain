# frozen_string_literal: true

module Lain
  module Bench
    # One run persisted as NDJSON in the Journal's OWN format: the live run's
    # journal already carries request_sent / turn_usage / capability_degraded
    # lines, and {Session.write} appends what those cannot express -- one
    # "session" header (the Context, tool schema, and reminders in effect) and
    # one "turn" record per committed turn. {Session.load} then rebuilds a
    # {Recording} from the bytes alone, re-deriving each turn's content address
    # so the file's own digests are its integrity check.
    #
    # The header captures exactly {Lain::Context}'s constructor inputs, a
    # catalog pipeline by its recorded name, so a loaded Recording rebuilds the
    # Context the run rendered under. A pipeline no catalog word names -- a
    # Context subclass, or one injected as a value -- still round-trips its
    # data, the header's `context_class` naming what rendered it, but reloads
    # under the default, and {Recording#dry_replay} claims byte identity only
    # for catalog-pipeline sessions. That is the stated limit of this format.
    #
    # == One run, one journal, one file
    #
    # Concatenation is outside the format: a second "session" header in one
    # stream raises {Corrupt} rather than guessing which run is meant. The
    # header's `head` anchor is what rejects truncation and cross-run splices
    # through the turn chain -- a Merkle chain self-verifies only its PREFIX,
    # so without the anchor a deleted tail would load as a shorter session that
    # still replays identically. Stated honestly: a baseline substituted
    # WHOLESALE from a same-shape foreign run is self-consistent record by
    # record, so it stays detectable only as non-identity under dry replay,
    # never at load time. Likewise the transport fields sit outside the content
    # address and load unverified, since {Request#digest} deliberately excludes
    # them -- the integrity envelope covers content, not transport.
    #
    # == Open sessions and resume chains
    #
    # {SessionRecord}'s live format can leave a header's `head` nil -- an OPEN
    # session still running, or one a SIGKILL just stopped -- rather than this
    # class's own header, which is always anchored because it is written AFTER
    # the run. A nil header `head` verifies against a `session_closed` record's
    # OWN `head` when one is present, since the header itself is never rewritten
    # at close; with neither anchor, {Loader} loads the prefix
    # UNVERIFIED-but-self-consistent, and {Recording#open?} names which shape a
    # caller got.
    #
    # A header MAY also carry `resumed_from` -- the prior file's basename and
    # its recorded head digest -- naming a PRIOR file this session continues.
    # {Loader} follows it through an INJECTED resolver duck, never a filesystem
    # call of its own, verifies the prior file's own rebuilt head against the
    # recorded digest, and folds its turns and `message` records in BEFORE this
    # file's own, so {Recording#timeline} is one continuous conversation across
    # the chain. Only the Timeline and the `message` events merge that way;
    # `baseline`, `degraded`, `mode`, `memory` and `ledger_index` stay scoped
    # to the file actually loaded, which is this format's current limit.
    class Session
      # A session file whose records no longer cohere: a turn or request_sent
      # whose content re-derives to a different digest than the one recorded
      # under it, a turn chain whose rebuilt head misses the header's anchor,
      # or a journal with no session header to rebuild a Context from (or with
      # more than one). Extended for the live session format's open sessions
      # and resume chains: a `resumed_from` head that does not match the
      # prior file's own rebuilt head, a `message` record whose envelope no
      # longer re-derives to its recorded digest, or more than one
      # `session_closed` closer in one file.
      class Corrupt < Error; end

      HEADER_TYPE = "session"
      TURN_TYPE = "turn"

      # How a record damaged in a key it is rebuilt from refuses, and how the
      # refusal names and quotes it. A journal is bytes, so a key can simply be
      # GONE -- torn mid-write, or hand-edited -- and a bare `fetch` then
      # raises KeyError, which is no {Lain::Error}: `exe/lain`'s rescue misses
      # it and the three doors that read a session file rescue {Corrupt}, so an
      # operator got a raw backtrace where every other kind of rot names
      # itself. {MessageReplay} and {ChainFold} had each written that argument
      # longhand for one field of their own before it was one place.
      module RequiredKeys
        # Two bounds, and they cannot be one number. Both exist because the
        # field a refusal quotes is usually the damage itself -- a 20,000-char
        # `role` made a 20KB refusal -- and a flood of bytes costs the cockpit,
        # scribbling through the chat pane the frontend is painting. The label
        # is a name, so it clips short; a quoted VALUE may be a digest, which
        # is what a reader takes back to the file and must never be the thing
        # that got clipped, so that bound sits above one.
        FIELD_LIMIT = 60
        VALUE_LIMIT = 160

        module_function

        # The label arrives as a BLOCK, called only when refusing: a fold reads
        # two required keys per turn record and a replay six per message, so a
        # label built up front is a string per read that a healthy file never
        # looks at -- 23,983 objects on a clean 4,000-turn fold, 6.7% of its
        # whole allocation, for refusals that never happen.
        #
        # @param record [Hash] one parsed journal record
        # @param key [String] the field the rebuild cannot do without
        # @yieldreturn [String] the label the refusal names the record by
        # @raise [Corrupt] naming the record and the key it does not carry
        def read(record, key)
          record.fetch(key) { raise Corrupt, missing(yield, key) }
        end

        # The other half of "required", for `role` and `kind` alone -- the only
        # fields a VALIDATOR reads before any digest exists. A falsey value
        # there refuses out of {Event} as a bare {Lain::Error}, honest about
        # the names it allows but in a currency no door rescues and with
        # neither the file nor the record index on it, while a falsey value in
        # any other field announces itself as the content-address mismatch it
        # really is. Both hold a name from a closed enum, so absent, null and
        # `false` are one damage here and get one sentence.
        #
        # @raise [Corrupt] for a key that is absent, or carries null or false
        def read_filled(record, key)
          value = record[key]
          return value if value

          raise Corrupt, missing(yield, key)
        end

        # No parenthetical for a field the record cannot name: "turn record 0
        # (unnamed role) has no role key" reads as the tool arguing with
        # itself, and the index alone already says which record.
        def labelled(noun, index, field = nil)
          return "#{noun} record #{index}" unless field

          "#{noun} record #{index} (#{clipped(field, FIELD_LIMIT)})"
        end

        # A value a refusal quotes, bounded and inspected -- so a null reads
        # `nil` rather than leaving a hole in the sentence where it was.
        def shown(value) = clipped(value.inspect, VALUE_LIMIT)

        def missing(label, key)
          "#{label} has no #{key} key; the field is part of what the record is rebuilt from, " \
            "so this record has been truncated or edited"
        end

        def clipped(field, limit)
          text = field.to_s
          text.length <= limit ? text : "#{text[0, limit]}..."
        end

        private_class_method :missing, :clipped
      end

      # The recorded tool schema, wearing the one duck {Context#render} consumes
      # from a toolset. The live {Lain::Toolset} cannot be rebuilt from a
      # journal -- tools are capabilities, code included -- but the render seam
      # never needed it: the schema bytes are what reached the model.
      RecordedToolset = Data.define(:schema) do
        def initialize(schema:)
          super(schema: Canonical.normalize(schema))
        end

        def to_schema
          schema
        end
      end

      # The per-turn memory surface a {Loader} rebuilds: the {Memory::Index}
      # root in force when each recorded turn committed -- replayed from the
      # recording's own successful memory_write calls, since the turns ARE the
      # write log -- and the fully replayed index, whose store resolves every
      # one of those roots. A root is nil for a turn that committed before any
      # write: nil IS the empty index's identity, a value here, exactly as
      # {Telemetry::MemoryRoot} records it on the wire.
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
      # never constantized: `context` is rebuilt as a plain Context under the
      # pipeline the header NAMES, and under the default when it names none, so
      # a consumer comparing the two can tell a custom-pipeline recording
      # (which legitimately will not replay to byte identity) from a genuine
      # harness leak.
      #
      # `open` names whether {Loader} verified a full anchor or only the
      # unverified-prefix shape; `messages` is the session's re-put
      # :message/:spawn events, root-first like `baseline`, holding the SAME
      # Store {timeline} does.
      #
      # `mode` is the mode trajectory this run walked, folded off the same journal
      # `degraded` comes from and carried for the same reason: each is a fact
      # about what makes two recordings COMPARABLE, not a measurement of one.
      # Required, exactly as `degraded` is, and deliberately given no default:
      # {Compare::Mode::UNRECORDED} is a true Null Object, but a DEFAULT of
      # it would let a future rebuild forget the axis and ship a comparison that
      # silently agrees with everything -- which is the vacuous-pass shape
      # {Compare}'s own docstring warns a caller about.
      Recording = Data.define(:context, :context_class, :toolset, :workspace,
                              :timeline, :baseline, :ledger_index, :degraded, :mode, :memory,
                              :open, :messages) do
        def initialize(context:, context_class:, toolset:, workspace:, timeline:, baseline:, ledger_index:,
                       degraded:, mode:, memory:, open:, messages:)
          super(context:, context_class: -context_class.to_s, toolset:, workspace:,
                timeline:, baseline: baseline.freeze, ledger_index:, degraded:, mode:, memory:,
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
        # @param provider [String, nil] the provider name the run dispatched
        #   through, recorded as pure data beside the model and never
        #   constantized. Optional so an existing caller that has not threaded
        #   one through yet still writes a valid header.
        # @return [#<<] the journal
        def write(journal, timeline:, context:, toolset:, workspace: Workspace.empty, provider: nil)
          journal << header_record(timeline, context, toolset, workspace, provider)
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

        # `head` anchors the whole turn chain. `provider` rides beside `model`
        # rather than inside `context` because it genuinely is not one of
        # {Context}'s constructor inputs: the choice of backend and the render
        # pipeline are separate concerns that only happen to be pinned by the
        # same header.
        #
        # It merges in only when given, {SessionRecord.header}'s `resumed_from`
        # idiom: an existing caller that has not threaded a provider name
        # through must keep writing byte-identical headers, so absence is NO
        # KEY, never a nil value -- proven by the committed variance fixtures'
        # own byte-identity regeneration spec.
        def header_record(timeline, context, toolset, workspace, provider)
          record = {
            "type" => HEADER_TYPE, "context_class" => context.class.name,
            "model" => context.model, "max_tokens" => context.max_tokens,
            "system" => context.system, "stream" => context.stream, "extra" => context.extra,
            "head" => timeline.head_digest,
            "tools" => toolset.to_schema, "reminders" => workspace.reminders
          }.merge(SessionRecord.context_pipeline(context))
          provider.nil? ? record : record.merge("provider" => provider)
        end

        # Delegated rather than duplicated. This WAS a byte-compatible twin of
        # {SessionRecord.turn}, kept in step by hand -- and it fell out of step
        # exactly once, when {Event} grew `causal_parents` and neither writer
        # followed. One Loader reads both formats, so "byte-compatible" is a
        # requirement, not a coincidence. The header stays its own method
        # because it genuinely differs, by `provider`.
        def turn_record(turn)
          SessionRecord.turn(turn)
        end
      end
    end
  end
end
