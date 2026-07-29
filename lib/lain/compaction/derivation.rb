# frozen_string_literal: true

module Lain
  module Compaction
    # The second lineage: a DERIVED Timeline in the source's own Store, whose
    # replacement events name the source events they subsume.
    #
    # Compaction today is a render-time projection ({Context::Compact} rewrites
    # the message array inside `Context#render`) and the result is never
    # materialized, never addressable, never diffable. Here it is an artifact
    # with a content address: the session timeline stays the lossless record,
    # and the derived chain is what a provider sees.
    #
    # == Why the causal fan-in is safe
    #
    # {Timeline#to_a} follows `render_parent` ONLY (`timeline.rb:96-114`), so a
    # replacement event can name every source digest it subsumes in
    # `causal_parents` and the derived chain still renders the replacement
    # rather than the turns it replaced. `causal_parents` is the FIBRE of the
    # collapse -- a replacement's preimage -- which is what lets {DerivationAudit}
    # check a re-derivation without a separate pre/post mapping being stored
    # anywhere. {Ledger#unique_turns} (`ledger.rb:115-119`) walks
    # `timeline.ancestors`, render ancestry, so the fan-in double-counts nothing.
    #
    # {Arm::Synthesis} is the existing fan-in writer and this copies its
    # discipline exactly: a causal parent is never filtered or dropped, so a
    # digest the Store has not seen RAISES ({Store::MissingObject}) rather than
    # quietly leaving an edge out.
    #
    # == There is no prefix sharing, and none is needed
    #
    # `Event#payload` folds `render_parent` (`event.rb:100`), so a retained turn
    # re-committed under a new parent chain gets a DIFFERENT digest: the derived
    # chain shares nothing with its source, and successive derived chains share
    # nothing with each other. What makes that affordable is that the WRITTEN
    # chain is bounded by the retained tail plus the number of ranges, never by
    # history length -- measured at 23 objects per derivation whether the source
    # holds 50 turns or 3200. So the derivation runs FULLY, every compacting
    # turn.
    #
    # What is constant is the OBJECTS, not the time. A derivation is O(n) in
    # history length and always will be: it walks the whole chain
    # ({Timeline#to_a}) and projects every message before it can find the span.
    # The win over the projection it replaces is a much smaller CONSTANT, not a
    # better complexity class -- this never `Canonical.dump`s the whole history,
    # and that dump is most of what {Context::Compact} spends. T9 pays this walk
    # on every compacting turn and should read the sentence that way.
    #
    # That is also why there is no `#extend`: an incremental extension would
    # have to hold the last derived head -- the state the non-recursive ruling
    # exists to avoid -- and would buy nothing. Derivation is not a functor on
    # the prefix order (`T1 <= T2` does not imply `derive(T1) <= derive(T2)`),
    # and `spec/lain/compaction/derivation_spec.rb` pins that as a
    # characterization example rather than as a defect to be fixed.
    #
    # == Non-recursive, by ruling
    #
    # The source is the SESSION timeline, never a previously derived one. That
    # is what keeps a derived head a pure content address of (source head,
    # strategy), which is what makes re-derivation exact and the artifact
    # diffable.
    #
    # == What this object does not decide
    #
    # WHICH sub-spans collapse and WHAT replaces one belong to the {Strategy};
    # WHERE the span may be cut belongs to {Boundary}; whether the result is a
    # conversation the Messages API accepts belongs to {Context::Conversation}.
    # This object owns exactly one decision of its own -- the replacement's role
    # -- and it is fixed, never computed from history parity (Open decisions:
    # with no pins the replacement IS `messages[0]`, which the API requires to
    # be `user`). Pins are not taken here either: a pin is a CUT POINT in a
    # strategy's proposal, not a shield the derivation applies afterwards.
    #
    # == The derived chain carries role and content, and nothing else
    #
    # `meta` is DROPPED, which both compaction projections already do
    # (`head.rb:38`, `source.rb:212`). So a derived event never carries
    # `spawned_from`, and subagent lineage must still be read off the session
    # timeline -- the derived chain is a rendering artifact, not a second copy
    # of the record.
    class Derivation
      # The derived chain's projection is not a conversation the Messages API
      # would accept. Raised rather than repaired: this class is the production
      # caller of {Context::Conversation}, and a derivation that silently fixed
      # up its own output would hide the strategy bug that produced it.
      class Invalid < Error; end

      # Decided here, once. See the class doc.
      REPLACEMENT_ROLE = "user"

      # Hoisted, because a `[].freeze` literal allocates a fresh Array per read.
      NO_RANGES = [].freeze
      private_constant :NO_RANGES

      # @param strategy [Strategy::Base] which sub-spans collapse, and into what
      # @param keep_last [Integer] the trailing messages the derivation retains
      #   verbatim. Validated by {Boundary}, which owns that refusal for every
      #   consumer (`boundary.rb:120-125`), so a non-positive value raises at
      #   the first derivation rather than here -- one rule, one place.
      # @param journal [#<<] where the derivation edge lands; the Null channel
      #   by default, so no caller guards `if journal`.
      def initialize(strategy:, keep_last:, journal: Channel::Null.instance)
        @strategy = strategy
        @keep_last = keep_last
        @journal = journal
        freeze
      end

      # @param source [Timeline] the session timeline
      # @param into [Store] where the derived chain is written. The source's own
      #   store is the only answer -- a replacement's causal edges name source
      #   digests, and {Store#put} refuses an edge it does not hold -- and this
      #   parameter is that sentence in CHECKED form rather than as a promise:
      #   named, defaulted, and refused when it is foreign. Without the refusal
      #   a strategy that collapses nothing would build a whole chain in the
      #   wrong store in silence, since only a replacement carries an edge that
      #   would dangle.
      # @param walk [Walk, nil] `source` already walked and projected, for a
      #   caller that has done both -- {Compaction::Source} decides on the very
      #   same projection before it gets here. nil is "nothing to thread", and
      #   the walk is then made below, AFTER the refusal: `walk: Walk.of(source)`
      #   as a default argument is evaluated before the method body, so a
      #   foreign-store call would walk the entire chain and only then raise.
      # @return [Timeline] the derived chain, in `into`
      def derive(source, into: source.store, walk: nil)
        refuse_foreign(source, into)
        plan = Plan.over(strategy: @strategy, walk: walk || Walk.of(source), keep_last: @keep_last)
        writes = plan.writes
        refuse_invalid(writes)
        derived = writes.inject(Timeline.empty(store: into)) { |chain, write| write.onto(chain) }
        @journal << edge(plan, source, derived)
        derived
      end

      # {Head}'s projection verbatim (`head.rb:38`): the derived chain has to be
      # validated in the very bytes a render will send, and `meta` is
      # deliberately absent from both -- it is not where a derived mapping
      # belongs, and the only `meta` key anywhere in `lib/` is `spawned_from`.
      def self.projected(turns)
        turns.map { |turn| { "role" => turn.role, "content" => turn.content } }
      end

      # ONE walk of a chain, as a value: the turns it yielded and the projection
      # of them. Both are O(n) in history length and every consumer on the
      # render path needs both -- {Head} slices the projection, {Need} and
      # {Scheduler} measure it, the digests come off the turns -- so walking per
      # consumer is how a turn came to read the same Store three times and
      # project the same messages three times over.
      #
      # A VALUE rather than two arguments threaded side by side: turns and their
      # projection are index-aligned, {Plan} and {Compaction::Source} both zip
      # them, and a pair passed separately is a pair that can be passed
      # mismatched. There is no memo anywhere here -- a Timeline is a new value
      # on every commit, so a per-instance cache would be a fresh miss every
      # turn; the walk's owner makes it once and hands it down.
      Walk = Data.define(:turns, :messages) do
        def self.of(timeline)
          turns = timeline.to_a
          new(turns:, messages: Derivation.projected(turns))
        end

        # Both invariants live in the OBJECT and not in `.of`, so no Walk can
        # exist without them however it was built.
        #
        # The PAIRING, because a mismatched pair is the one way this value can
        # lie, and it would lie quietly: `#zip` pads with nil, so a short
        # projection pairs a turn's digest with another turn's text and nothing
        # raises. Claiming "index-aligned" in a docstring while accepting
        # `Walk.new(turns:, messages: [])` leaves the claim to the constructor
        # that happens to be careful.
        #
        # DEEPLY FROZEN BY COPY, {Head}'s discipline and for {Head}'s reasons: a
        # value object whose elements a caller can still mutate is one whose
        # consumers' measurements go stale, and freezing in place would reach
        # back into an array the caller may still own and leave it frozen under
        # them. `Ractor.shareable?` then holds, which is what CLAUDE.md asks of
        # a value object and what the docstring above would otherwise only be
        # asserting. Measured: 0.35 ms on an 800-turn history, against the
        # ~18 ms per compacting turn the threading saves.
        def initialize(turns:, messages:)
          unless turns.size == messages.size
            raise ArgumentError, "a Walk pairs one projected message per turn, got #{turns.size} " \
                                 "turns and #{messages.size} messages"
          end

          super(turns: Ractor.make_shareable(turns, copy: true),
                messages: Ractor.make_shareable(messages, copy: true))
        end
      end

      private

      def refuse_foreign(source, into)
        return if source.empty? || into.key?(source.head_digest)

        raise Store::MissingObject, "no object #{source.head_digest.inspect} in store: deriving into it would " \
                                    "dangle every replacement's causal edges, which name the source turns " \
                                    "they subsume"
      end

      # Judged from the WRITES, before a single object reaches the Store. The
      # Store is append-only and a refusal is not a rollback, so validating the
      # committed chain would leave a dead chain behind on every refusal --
      # bounded for a deterministic strategy, which re-derives to the same
      # addresses, and unbounded for a model-backed one on the render path.
      #
      # `Canonical.normalize` is what makes this the SAME judgement the
      # committed chain would get rather than a nearby one: it is the transform
      # {Event::Payload} applies on the way in, so these are the bytes the
      # provider would have seen.
      def refuse_invalid(writes)
        messages = Canonical.normalize(writes.map(&:projection))
        conversation = Context::Conversation.new(messages)
        return if conversation.valid?

        raise Invalid, "#{@strategy.name} derives a chain the Messages API would reject: " \
                       "#{conversation.violations.map(&:message).join("; ")}"
      end

      def edge(plan, source, derived)
        Telemetry::ContextDerived.new(source_head: source.head_digest, derived_head: derived.head_digest,
                                      strategy: @strategy.name, spans: plan.spans, cut: plan.cut,
                                      moved: plan.boundary.moved, keep_last: @keep_last)
      end

      # One event the derived chain will carry, and the only place a role is
      # assigned: a retained turn keeps its own, a replacement takes the fixed
      # one. `causal_parents` is EMPTY for a retained turn -- the derived chain
      # records what a replacement SUBSUMED, which is the fibre of the collapse,
      # and a retained turn subsumes nothing.
      Write = Data.define(:role, :content, :causal_parents) do
        def self.retaining(turn) = new(role: turn.role, content: turn.content, causal_parents: [])

        def self.replacing(content, subsumed) = new(role: REPLACEMENT_ROLE, content:, causal_parents: subsumed)

        # What this write will render as once committed -- {Head}'s projection,
        # available BEFORE the Store is touched, which is what lets the chain be
        # judged without being written.
        def projection = { "role" => role, "content" => content }

        # Unfiltered, {Arm::Synthesis}'s discipline (`arm/synthesis.rb:66`): a
        # causal parent the Store has not seen flows to {Timeline#commit} and
        # raises, rather than being quietly dropped from the edge.
        def onto(timeline) = timeline.commit(role:, content:, causal_parents:)
      end
      private_constant :Write

      # The per-source half of a derivation, as a value: which source turns,
      # their projection, where the span was cut, and which sub-spans the
      # strategy answered over it. {Derivation} is the POLICY -- a strategy, a
      # keep_last and a journal, held across many turns -- and these four travel
      # together for exactly ONE source; the alternative is the same four
      # arguments threaded through five private methods.
      #
      # The ranges are asked for ONCE and held, never recomputed: a strategy may
      # hold an oracle, and asking it twice is a second payment.
      Plan = Data.define(:strategy, :walk, :boundary, :ranges) do
        def self.over(strategy:, walk:, keep_last:)
          boundary = Boundary.new(messages: walk.messages, keep_last:)
          new(strategy:, walk:, boundary:, ranges: proposed(strategy, walk.messages, boundary))
        end

        # The walk's two halves, named where the rest of this object reads them:
        # the source turns it plans over, and the projection it plans FROM.
        def turns = walk.turns

        def messages = walk.messages

        # A strategy is asked only about a span there is something to collapse
        # in, and the two reasons there might not be are asked SEPARATELY --
        # never as `index.zero?`, which is the one spelling that erases the
        # distinction {Boundary} exists to make. The empty span `0...0` is not a
        # small question but no question at all: the natural whole-span proposal
        # `[span]` would come back as an empty range, which {Strategy::Base}
        # rightly refuses as {Strategy::NotAPartition}, and turning a legal
        # quiet turn into a raise inside the render path is not a bargain. The
        # derivation still runs -- a chain with no collapsed range is the
        # identity derivation -- and {#cut} is what records WHY nothing
        # collapsed.
        def self.proposed(strategy, messages, boundary)
          return NO_RANGES if boundary.empty? || boundary.declined?

          strategy.ranges(messages, span: 0...boundary.index)
        end
        private_class_method :proposed

        # Why the span was what it was, as the journalled edge's diagnosis:
        # `:empty` (the request was vacuous), `:declined` (no valid cut existed)
        # or `:offered` (the strategy was handed a real span). Only the last of
        # these means an empty `spans` is the STRATEGY's answer, and the three
        # are otherwise indistinguishable on the record -- same empty spans,
        # same derived length.
        #
        # ASKED, never reconstructed. The two predicates are the only things
        # that know which state a {Boundary} is in; deriving the answer from
        # `moved`, from the naive split, or from `index.zero?` would re-implement
        # a rule that lives there and would go quietly wrong the next time the
        # cut rule is relaxed -- a decline is not characterized by any particular
        # distance walked.
        def cut
          return :empty if boundary.empty?
          return :declined if boundary.declined?

          :offered
        end

        # One write per retained turn and one per collapsed range, in source
        # order. The ranges are an ascending, non-overlapping interval partition
        # -- {Strategy::Base#ranges} is what guarantees that, rather than the
        # hook a strategy implements -- and this fold is what that guarantee
        # BUYS: the derived chain is exactly the gaps between the ranges, so
        # there is no per-index membership test and no set of collapsed indices
        # to hold.
        #
        # A range whose collapse answers DROP contributes no write at all --
        # that is the unit of the monoid {Strategy::Base#collapse} maps into,
        # and it is how a range vanishes leaving no replacement event.
        def writes
          folded, cursor = ranges.inject([[], 0]) do |(events, from), range|
            [events + retained(from...range.first) + [replacement(range)].compact, range.max + 1]
          end
          folded + retained(cursor...turns.size)
        end

        # Each collapsed range as the pair of source digests it spans -- the
        # journalled edge's diagnostic half. ENDPOINTS, not the whole preimage:
        # the interior is recoverable from the source chain the record already
        # names, and a 400-turn range would otherwise write 400 digests into one
        # NDJSON line.
        #
        # `#max`, never `#last`: `(0...5).last` is 5 -- the EXCLUDED end -- and a
        # strategy may answer either kind of Range, so the naive spelling names
        # a turn the range does not cover (or runs off the end of the chain).
        def spans = ranges.map { |range| [digest(range.first), digest(range.max)] }

        private

        def retained(indices) = turns[indices].map { |turn| Write.retaining(turn) }

        def replacement(range)
          collapse = strategy.collapse(messages[range])

          Write.replacing(collapse.content, subsumed(range)) unless collapse.drop?
        end

        def subsumed(range) = range.map { |index| digest(index) }

        def digest(index) = turns.fetch(index).digest
      end
      private_constant :Plan
    end
  end
end
