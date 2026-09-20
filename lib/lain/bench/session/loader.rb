# frozen_string_literal: true

module Lain
  module Bench
    class Session
      # Rebuilds a {Recording} from parsed journal records.
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
        # Rebuilds the recorded run's Context under the pipeline its header
        # names, re-resolved from the catalog, and under the default when it
        # names none. Injectable so a caller replaying push-recall can supply a
        # Context whose pipeline composes a memory stage, WITHOUT this class
        # hardcoding that choice. Root-qualified: {Bench::CLI} shadows the
        # top-level one for everything inside `Bench`.
        DEFAULT_CONTEXT_FACTORY = lambda do |model:, max_tokens:, system:, stream:, extra:, context_pipeline:|
          ::Lain::CLI::ContextPipeline.named(context_pipeline, origin: "context_pipeline")
                                      .context(model:, max_tokens:, system:, stream:, extra:)
        end

        # Raised only when a header actually names a `resumed_from` file and no
        # resolver was injected. The Loader takes entries, never paths: a caller
        # that wants chains followed hands in the duck that reads them, so
        # filesystem knowledge never leaks into this unit.
        NO_RESOLVER = lambda do |basename|
          raise ArgumentError, "session resumes from #{basename.inspect} but no resolver was given; " \
                               "pass resolve: ->(basename) { entries for that file } to Loader.new"
        end

        # One shared empty rather than a fresh Array per miss.
        NO_RECORDS = [].freeze
        private_constant :NO_RECORDS

        # The record types {MessageReplay} rebuilds: events that no render chain
        # carries, so they are reconstructed from their own flat records.
        FLAT_EVENT_TYPES = ["message", SessionRecord::CHILD_TURN_TYPE].freeze
        private_constant :FLAT_EVENT_TYPES

        # @param entries [Enumerable<Hash, String>] the {Journal.parse} duck;
        #   entries it answers nil for are somebody else's records and skipped
        # @param context_factory [#call] builds the Context from the recorded
        #   transport fields and the recorded `context_pipeline:` name (nil when
        #   the header names none); defaults to {DEFAULT_CONTEXT_FACTORY}.
        # @param resolve [#call] `basename -> entries`, consulted only when a
        #   header names `resumed_from`; defaults to {NO_RESOLVER}.
        def initialize(entries, context_factory: DEFAULT_CONTEXT_FACTORY, resolve: NO_RESOLVER)
          @records = entries.filter_map { |entry| Journal.parse(entry) }
          # Seven collaborators each want ONE record type, so the discrimination
          # is a single partition rather than a linear re-scan per caller. Each
          # group is frozen because one Array is now SHARED by every caller
          # asking for that type.
          @by_type = @records.group_by { |record| record["type"].to_s }.each_value(&:freeze).freeze
          # The one group a type key cannot answer: {MessageReplay} reads TWO
          # types and needs file order ACROSS them, which is exactly what a
          # per-type partition throws away.
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
            degraded:, mode:, memory:, open: open?
          )
        end

        # The session's recorded slot attribution, or an empty one for a journal
        # written before the record existed -- nothing recorded IS the empty
        # attribution, a value here, not an absence. Loads UNVERIFIED: it
        # reports the recorded fills rather than the live disk state, and the
        # rendered system text these digests address is separately verified
        # through the request_sent chain.
        def slot_fills
          record = sole_slot_fills
          return Telemetry::SlotFills.new(digests: {}, fills: {}) if record.nil?

          Telemetry::SlotFills.new(digests: record.fetch("digests"), fills: record.fetch("fills"))
        end

        # {#timeline}, {#store}, {#messages} and {#on_chain?} are public because
        # {ResumeChain} calls all four on the PRIOR file's own Loader, so none
        # of them can hide behind this instance's `self`. The rebuild is pure,
        # so memoizing is caching rather than state.
        #
        # Verified with respect to the TURN CHAIN ONLY, deliberately: a journal
        # whose only damage is a flat record still answers here, because the
        # chain this question is about is sound. {#converged} sweeps without
        # forcing, which is what keeps {ResumeChain#prior_timeline} from
        # rejecting a whole chain over damage in a half of the predecessor the
        # seam never consults. A caller wanting the WHOLE journal's integrity
        # asks {#recording}, which asks both halves.
        def timeline = @timeline ||= anchor.verify(chain_fold.timeline)

        # True for any digest VERIFIED while rebuilding this file's chain: the
        # resumed base's own ancestors plus every turn record folded here. This
        # set -- not ancestry of the final head, and not head equality -- is
        # what a chained `resumed_from.head` is checked against, so a parent
        # that later rewinds below a fork point keeps children forked above it
        # loadable. Every member was re-committed to its recorded content
        # address, so membership never vouches for unverified bytes.
        def on_chain?(digest)
          chain_fold.member?(digest)
        end

        # @return [Store] the ONE store this file (and, in a resume chain,
        #   every prior one) rebuilds into -- see {ResumeChain}.
        def store = resume_chain.store

        # {MessageReplay} owns the re-put; this only supplies the file-order
        # `prior` -- a resume chain's PRIOR file's own messages, verified before
        # this file's own so a later `message` naming an earlier one as a
        # causal_parent finds it already landed.
        #
        # The log comes back in FILE order, which is the order a consumer folds.
        # It is no longer the order the Store was written in, so file position
        # is no longer an integrity check; {MessageReplay} says what that costs.
        def messages
          # A spawned chain's turns land in the SAME replay -- they and the
          # messages cite each other across the spawn boundary -- but they are
          # not mailbox traffic. Folding them in would put :turn events into
          # every {Event::Projection} built over it, where the turn count is
          # load-bearing.
          replayed.reject { |event| event.kind == :turn }
        end

        private

        # Every flat event record this file carries, rebuilt into the shared
        # Store. `message` records are :message/:spawn, which no render chain
        # can hold; {SessionRecord::CHILD_TURN_TYPE} records are a spawned
        # chain's turns, which THIS file's chain cannot hold either -- a child's
        # `ask_human` question cites the head it asked from, so a session that
        # spawned anything was unloadable while they were missing.
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
        # than on the three public methods that need it: a precondition three
        # callers must REMEMBER is one a fourth will forget, and {#on_chain?}
        # did forget, leaving an order-dependence bug. Nothing but those two
        # readers hands out a fold, so no path can reach an unconverged one.
        def converged
          @converged ||= fixpoint
        end

        # Building both folds HERE rather than in the readers keeps the readers
        # free to gate without recursing through themselves, and makes duplicate
        # construction unrepresentable -- which the sweep/drain split in
        # {MessageReplay} requires.
        #
        # Both halves must RUN in every round, so their answers are collected
        # into an Array before being asked: `||` would skip the sweep in any
        # round the chain advanced.
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

        # Session-fixed records: several would make "which one?" an accident of
        # file order, so at most one loads. None at all is the caller's call --
        # {#header} refuses it, {#slot_fills} defaults it.
        def sole(type, complaint)
          records = of_type(type)
          return records.first if records.size <= 1

          raise Corrupt, "#{records.size} #{complaint}"
        end

        # `extra` (sampler params) loads unverified like the other transport
        # fields; `|| {}` tolerates recordings written before the key existed.
        # A missing `context_pipeline` is the ordinary case, not an old one:
        # a session nobody named a pipeline for writes no key.
        #
        # A name the catalog no longer holds refuses as {Corrupt}, {#mode}'s
        # rule: every loader caller rescues that class by name. It cites the
        # header, not the flag -- whoever replays never typed one.
        def context
          @context_factory.call(model: header.fetch("model"), max_tokens: header.fetch("max_tokens"),
                                system: header["system"], stream: header.fetch("stream"),
                                extra: header["extra"] || {}, context_pipeline: header["context_pipeline"])
        rescue ::Lain::CLI::ContextPipeline::Unknown => e
          raise Corrupt, "the session header records context_pipeline #{header["context_pipeline"].inspect}, " \
                         "which no longer resolves: #{e.message}"
        end

        def toolset
          RecordedToolset.new(schema: header.fetch("tools"))
        end

        def workspace
          Workspace.new(reminders: header.fetch("reminders"))
        end

        # This and {#message_replay} are the ONE door to either fold, and they
        # converge before opening it -- see {#converged} for why the gate
        # belongs here and not on the callers.
        def chain_fold
          converged
          @chain_fold
        end

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

        # Memoized like {#header}, since both are asked more than once per
        # {#recording}.
        def anchor
          @anchor ||= Anchor.new(header:, session_closed_records: of_type("session_closed"))
        end

        def open? = anchor.open?

        # Memoized so {#store}, {#fold_base} and {#messages} all reach the same
        # prior Loader rather than re-resolving it.
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

        # The mode trajectory this run walked, off the flips it journaled.
        # {Compare::Mode} owns the discriminator, the record shape it reads
        # and the chaining refusal; what this adds is the vocabulary those
        # refusals have to arrive in.
        #
        # Every session load comes through here, not just the bench's:
        # {CLI::Resume} and {Supervisor::Restart} rebuild from this class too,
        # and all three callers rescue {Corrupt} BY NAME. A damaged flip left to
        # escape as a bare Lain::Error or ArgumentError would make a chat
        # session unresumable over one rotten line, with a raw backtrace and no
        # file named on it -- the exact asymmetry {CLI::Resume#fork}'s own
        # comment records paying for once already. Interleaved records are
        # ordinary under fan-out, so this is a real input class, not a
        # hypothetical one.
        def mode
          Compare::Mode.from_journal(of_type(Compare::Mode::RECORD_TYPE))
        rescue Error, ArgumentError => e
          raise Corrupt, "damaged #{Compare::Mode::RECORD_TYPE.inspect} record: #{e.message}"
        end

        # The WHOLE record array, in file order: the seed, the turns, the head
        # moves and the roots are only foldable together, and a per-type
        # partition is exactly what throws that order away.
        def memory
          MemoryReplay.new(records: @records).recorded_memory
        end
      end
    end
  end
end
