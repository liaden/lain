# frozen_string_literal: true

module Lain
  module Bench
    class Session
      # Rebuilds a {Recording} from parsed journal records. A collaborator of
      # {Session.load} rather than a pile of class methods on Session: loading
      # is its own responsibility -- discriminating record types and folding
      # each into the object it reconstructs.
      #
      # Integrity is content-addressing, not trust: every turn record is
      # RE-COMMITTED in file order, so its digest is recomputed over its
      # recorded content and the chain's own parent, and a disagreement with
      # the recorded digest -- edited content, a reordered chain -- raises
      # {Corrupt} instead of loading quietly wrong. The rebuilt head must then
      # match the header's anchor (a Merkle chain self-verifies only its
      # prefix, so truncating the tail would otherwise pass), and every
      # request_sent record must rebuild to its own recorded digest.
      class Loader
        # The default context factory: rebuilds the recorded run's Context with
        # the SAME default pipeline it recorded under. Injectable so a caller
        # replaying push-recall can supply a Context whose pipeline composes a
        # memory stage (Context::Recall) after CacheBreakpoints, WITHOUT this
        # class hardcoding that choice. The default keeps byte-identical
        # behavior for every existing caller -- the transport fields it is handed
        # are exactly the recorded ones.
        DEFAULT_CONTEXT_FACTORY = lambda do |model:, max_tokens:, system:, stream:, extra:|
          Context.new(model:, max_tokens:, system:, stream:, extra:)
        end

        # The default `resolve:` -- raised only when a header actually names a
        # `resumed_from` file and no resolver was injected. The Loader takes
        # entries, never paths (see the class note on chain-following): a
        # caller that wants chains followed must hand in the duck that reads
        # them, so filesystem knowledge never leaks into this unit.
        NO_RESOLVER = lambda do |basename|
          raise ArgumentError, "session resumes from #{basename.inspect} but no resolver was given; " \
                               "pass resolve: ->(basename) { entries for that file } to Loader.new"
        end

        # {#of_type}'s answer for a type this journal holds no record of. One
        # shared empty rather than a fresh Array per miss -- private, unlike
        # {DEFAULT_CONTEXT_FACTORY} and {NO_RESOLVER}, which callers inject
        # against; this one is only a private method's default.
        NO_RECORDS = [].freeze
        private_constant :NO_RECORDS

        # The record types {MessageReplay} rebuilds: events that no render chain
        # carries, so they are reconstructed from their own flat records.
        FLAT_EVENT_TYPES = ["message", SessionRecord::CHILD_TURN_TYPE].freeze
        private_constant :FLAT_EVENT_TYPES

        # @param entries [Enumerable<Hash, String>] the {Journal.parse} duck;
        #   entries it answers nil for are somebody else's records and skipped
        # @param context_factory [#call] builds the Context from the recorded
        #   transport fields; defaults to the recorded default pipeline.
        # @param resolve [#call] `basename -> entries`, consulted only when a
        #   header names `resumed_from`; defaults to {NO_RESOLVER}.
        def initialize(entries, context_factory: DEFAULT_CONTEXT_FACTORY, resolve: NO_RESOLVER)
          @records = entries.filter_map { |entry| Journal.parse(entry) }
          # Seven collaborators each want ONE record type out of this array, so
          # the discrimination is a single partition rather than a linear
          # re-scan per caller. File order survives inside each group, and each
          # group is frozen: one Array is now SHARED by every caller asking for
          # that type, so a collaborator that mutated one would corrupt the
          # others' view -- it says so loudly instead.
          @by_type = @records.group_by { |record| record["type"].to_s }.each_value(&:freeze).freeze
          # The one group a type key cannot answer, taken in the same
          # constructor rather than as a re-scan per call: {MessageReplay}
          # reads TWO types and needs file order ACROSS them, which is exactly
          # what a per-type partition throws away.
          @flat_events = @records.select { |record| FLAT_EVENT_TYPES.include?(record["type"].to_s) }.freeze
          @context_factory = context_factory
          @resolve = resolve
        end

        # Keyword order no longer sequences the two folds, and must not be read
        # as if it did: {#converged} runs the fixpoint before either answers.
        # All the order still decides is WHICH refusal a doubly-damaged journal
        # names first, and both are {Corrupt}.
        #
        # @return [Recording]
        def recording
          Recording.new(
            timeline:, messages:,
            context:, context_class: header.fetch("context_class"),
            toolset:, workspace:, baseline:,
            ledger_index: Ledger::Index.from_journal(@records),
            degraded:, memory:, open: open?
          )
        end

        # The session's recorded slot attribution (PS-2): the one slot_fills
        # record folded back into a {Telemetry::SlotFills} value, or an empty
        # one for a journal written before the record existed (nothing recorded
        # is the empty attribution, a value here, not an absence). Loads
        # UNVERIFIED -- pure attribution, reporting the recorded fills rather
        # than the live disk state; the rendered system text these digests
        # address is separately verified through the request_sent chain.
        def slot_fills
          record = sole_slot_fills
          return Telemetry::SlotFills.new(digests: {}, fills: {}) if record.nil?

          Telemetry::SlotFills.new(digests: record.fetch("digests"), fills: record.fetch("fills"))
        end

        # {#timeline}, {#store}, {#messages}, and {#on_chain?} are public
        # rather than private: a resume chain's {ResumeChain} calls all four
        # on the PRIOR file's own Loader (a separate instance, and a separate
        # class), so none of them can hide behind this instance's own `self`.
        # Memoized because {#on_chain?} needs the fold to have run and every
        # caller may ask more than once; the rebuild is pure, so this is
        # caching, not state.
        #
        # Verified with respect to the TURN CHAIN ONLY, and deliberately so: a
        # journal whose only damage is a flat record still answers here, because
        # the chain this question is about is sound. {#converged} sweeps without
        # forcing, which is what leaves that damage unraised until something
        # actually depends on it -- and it is what keeps {ResumeChain#prior_timeline}
        # from rejecting a whole chain over damage in a half of the predecessor
        # that the seam never consults. A caller wanting the WHOLE journal's
        # integrity asks {#recording}, which asks both halves; every production
        # door does.
        def timeline = @timeline ||= anchor.verify(chain_fold.timeline)

        # T3: fold membership -- true for any digest VERIFIED while rebuilding
        # this file's chain: the resumed base's own ancestors plus every turn
        # record folded here, at its fold position. This set (not ancestry of
        # the final head, and not head equality) is what a chained
        # `resumed_from.head` is checked against ({ResumeChain#prior_timeline}),
        # so a parent that later rewinds below a fork point keeps children
        # forked above it loadable. Every member re-committed to its recorded
        # content address, so membership never vouches for unverified bytes.
        def on_chain?(digest)
          chain_fold.member?(digest)
        end

        # @return [Store] the ONE store this file (and, in a resume chain,
        #   every prior one) rebuilds into -- see {ResumeChain}.
        def store = resume_chain.store

        # {MessageReplay} owns the re-put (see its class comment); this only
        # supplies the file-order `prior` -- a resume chain's PRIOR file's own
        # messages, verified before this file's own so a later `message`
        # naming an earlier one as a causal_parent finds it already landed.
        #
        # The log comes back in FILE order, which is the order a consumer folds
        # ({Event::Projection}'s views are log-order folds). It is no longer the
        # order the Store was written in, and file position is no longer an
        # integrity check -- {MessageReplay}'s class note says what that costs
        # and why a cycle across the spawn boundary forced it.
        def messages
          # A spawned chain's turns land in the SAME replay -- they and the
          # messages cite each other across the spawn boundary -- but they are
          # not mailbox traffic and do not belong in a {Recording}. Folding them
          # in would put :turn events into every {Event::Projection} built over
          # it, where the turn count is load-bearing ({Event::Projection#workspace_at}).
          replayed.reject { |event| event.kind == :turn }
        end

        private

        # Every flat event record this file carries, rebuilt into the shared
        # Store. `message` records are :message/:spawn, which no render chain
        # can hold; {SessionRecord::CHILD_TURN_TYPE} records are a spawned
        # chain's turns, which THIS file's chain cannot hold either -- a child's
        # `ask_human` question cites the head it asked from, and
        # {Tools::Subagent::Lineage#message} cites the child's final turn, so a
        # session that spawned anything was unloadable while they were missing.
        # `@flat_events` rather than the type partition, because file order
        # across the two types is what {MessageReplay} preserves.
        def replayed = @replayed ||= message_replay.messages

        # The fixpoint over the two folds, and the reason there is one.
        #
        # The dependency runs BOTH ways: a `message` record's causal_parents can
        # name a turn ({Agent} stamps a turn with the mailbox messages it
        # folded), and a turn's can name a message ({Agent::ToolRunner}'s
        # delivery edge cites the answered `ask_human` question). That is a
        # cycle, and no ordering of two whole passes satisfies a cycle -- which
        # is why a session that spawned, or that answered a question, used to
        # refuse from every door. So neither pass runs first: each advances as
        # far as the Store lets it and unblocks the other, until a round moves
        # nothing. Each fold then forces its own remainder, so a causal parent
        # no record carries still refuses -- as {Corrupt}, from both.
        #
        # Terminating because both halves are monotone: {ChainFold#advance}
        # only moves its position forward and {MessageReplay#sweep} only
        # shrinks its pending set, so a round that moves neither is a fixpoint
        # and there are at most (turns + flat events) rounds before one.
        #
        # The precondition lives on {#chain_fold} and {#message_replay} rather
        # than on the three public methods that need it, and that placement is
        # the whole point: a precondition three callers must REMEMBER is one
        # that a fourth will forget. {#on_chain?} did forget, and the bug it
        # left was order-dependence -- the same defect, one layer up, that this
        # card exists to delete. Nothing but those two readers hands out a
        # fold, so no path can reach an unconverged one.
        def converged
          @converged ||= fixpoint
        end

        # Builds both folds, then alternates them. Building HERE, rather than
        # in the readers, is what keeps the readers free to gate without
        # recursing back through themselves -- and it makes duplicate
        # construction unrepresentable: {#converged} runs once, so each fold
        # exists once, which the sweep/drain split in {MessageReplay} requires.
        #
        # Both halves must RUN in every round, so their answers are collected
        # into an Array before being asked -- `||` would skip the sweep in any
        # round the chain advanced. Answers `self`, never a Boolean: "did it
        # move" is a question about a ROUND, and a fixpoint is settled by
        # definition.
        def fixpoint
          @chain_fold = ChainFold.new(records: @records, base: fold_base)
          @message_replay = MessageReplay.new(records: @flat_events, store:,
                                              prior: resume_chain.prior_messages)
          moved = true
          moved = [@chain_fold.advance, @message_replay.sweep].any? while moved
          self
        end

        def of_type(type) = @by_type.fetch(type.to_s, NO_RECORDS)

        def header
          @header ||= sole(HEADER_TYPE, "#{HEADER_TYPE.inspect} header records in one journal; " \
                                        "the format is one run, one journal, one file") ||
                      raise(Corrupt, "no #{HEADER_TYPE.inspect} header record to rebuild a context from")
        end

        def sole_slot_fills
          sole("slot_fills", "\"slot_fills\" records in one journal; fills are session-fixed, one record pins them")
        end

        # Session-fixed records: several would make "which one?" an accident
        # of file order, so at most one loads. None at all is the caller's
        # call -- {#header} refuses it, {#slot_fills} defaults it (an older
        # journal simply predates the attribution).
        def sole(type, complaint)
          records = of_type(type)
          return records.first if records.size <= 1

          raise Corrupt, "#{records.size} #{complaint}"
        end

        # The recorded transport fields, handed to the injected factory (default:
        # the recorded default pipeline -- see {DEFAULT_CONTEXT_FACTORY}).
        # `extra` (sampler params) loads unverified like the other transport
        # fields; `|| {}` tolerates recordings written before the key existed.
        def context
          @context_factory.call(model: header.fetch("model"), max_tokens: header.fetch("max_tokens"),
                                system: header["system"], stream: header.fetch("stream"),
                                extra: header["extra"] || {})
        end

        def toolset
          RecordedToolset.new(schema: header.fetch("tools"))
        end

        def workspace
          Workspace.new(reminders: header.fetch("reminders"))
        end

        # {ChainFold} owns the file-order turn+rewound fold and the member
        # set it proves (see its class comment). This and {#message_replay} are
        # the ONE door to either fold, and they converge before opening it --
        # see {#converged} for why the gate belongs here and not on the callers.
        def chain_fold
          converged
          @chain_fold
        end

        # {MessageReplay} owns the flat-event replay (see its class comment).
        # Gated exactly as {#chain_fold} is, and for the same reason.
        def message_replay
          converged
          @message_replay
        end

        # A fresh empty Timeline (no resume chain) or the prior file's own
        # verified head -- either way built on the ONE shared {#store}, so a
        # `message` record on either side of the file boundary can name a
        # causal_parent that crosses it.
        def fold_base
          resume_chain.present? ? resume_chain.prior_timeline : Timeline.empty(store:)
        end

        # {Anchor} owns the open/closed classification and the verify-or-raise
        # (see its class comment); memoized like {#header} since both are
        # asked more than once per {#recording}.
        def anchor
          @anchor ||= Anchor.new(header:, session_closed_records: of_type("session_closed"))
        end

        def open? = anchor.open?

        # {ResumeChain} owns following `resumed_from` and sharing a Store
        # across the files it names (see its class comment); memoized so
        # {#store}, {#build_chain}, and {#messages} all reach the same prior
        # Loader rather than re-resolving it.
        def resume_chain
          @resume_chain ||= ResumeChain.new(resumed_from: header["resumed_from"],
                                            context_factory: @context_factory, resolve: @resolve)
        end

        def baseline = RequestReplay.new(records: of_type("request_sent")).baseline

        def degraded
          Capability::DegradedSet.new(
            of_type("capability_degraded").map { |record| record.fetch("capability") }
          )
        end

        def memory
          MemoryReplay.new(turns: of_type(TURN_TYPE), roots: of_type("memory_root")).recorded_memory
        end
      end
    end
  end
end
