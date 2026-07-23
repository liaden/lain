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

        # @param entries [Enumerable<Hash, String>] the {Journal.parse} duck;
        #   entries it answers nil for are somebody else's records and skipped
        # @param context_factory [#call] builds the Context from the recorded
        #   transport fields; defaults to the recorded default pipeline.
        # @param resolve [#call] `basename -> entries`, consulted only when a
        #   header names `resumed_from`; defaults to {NO_RESOLVER}.
        def initialize(entries, context_factory: DEFAULT_CONTEXT_FACTORY, resolve: NO_RESOLVER)
          @records = entries.filter_map { |entry| Journal.parse(entry) }
          @context_factory = context_factory
          @resolve = resolve
        end

        # {#timeline} must build (and so populate {#store}) before {#messages}
        # re-puts a single message: a `message` record's causal_parents can
        # name a turn, and keyword arguments evaluate left to right, so
        # `timeline:` stays the FIRST keyword naming either.
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
        def messages
          MessageReplay.new(records: of_type("message"), store:, prior: resume_chain.prior_messages).messages
        end

        private

        def of_type(type)
          @records.select { |record| record["type"].to_s == type }
        end

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
        # set it proves (see its class comment); the base is either a fresh
        # empty Timeline (no resume chain) or the prior file's own verified
        # head -- either way built on the ONE shared {#store}, so a `message`
        # record on either side of the file boundary can name a causal_parent
        # that crosses it. Memoized because {#timeline} and {#on_chain?} must
        # consult the SAME fold.
        def chain_fold
          @chain_fold ||= ChainFold.new(
            records: @records,
            base: resume_chain.present? ? resume_chain.prior_timeline : Timeline.empty(store:)
          )
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
