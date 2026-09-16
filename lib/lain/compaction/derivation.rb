# frozen_string_literal: true

module Lain
  module Compaction
    # The second lineage: a DERIVED Timeline in the source's own Store, whose
    # replacement events name the source events they subsume. Where
    # {Context::Compact} rewrites the message array inside `Context#render` and
    # materializes nothing, this is an artifact with a content address -- the
    # session timeline stays the lossless record, and the derived chain is what
    # a provider sees.
    #
    # == Why the causal fan-in is safe
    #
    # {Timeline#to_a} follows `render_parent` ONLY, so a replacement event can
    # name every source digest it subsumes in `causal_parents` and the derived
    # chain still renders the replacement rather than the turns it replaced.
    # `causal_parents` is the FIBRE of the collapse -- a replacement's preimage
    # -- which is what makes checking a re-derivation possible with no
    # separate pre/post mapping stored anywhere. {Ledger#unique_turns} walks
    # render ancestry, so the fan-in double-counts nothing. A causal parent is
    # never filtered or dropped ({Arm::Synthesis}'s discipline), so a digest
    # the Store has not seen RAISES rather than leaving an edge out quietly.
    #
    # == There is no prefix sharing, and none is needed
    #
    # `Event#payload` folds `render_parent`, so a retained turn re-committed
    # under a new parent chain gets a DIFFERENT digest: the derived chain
    # shares nothing with its source, and successive derived chains share
    # nothing with each other. What makes that affordable is that the WRITTEN
    # chain is bounded by the retained tail plus the number of ranges, never by
    # history length -- measured at 23 objects per derivation whether the
    # source holds 50 turns or 3,200.
    #
    # Constant in OBJECTS, not in time. A derivation is O(n) in history length
    # and always will be, since it walks the whole chain and projects every
    # message before it can find the span; the win over the projection it
    # replaces is a much smaller CONSTANT, because this never
    # `Canonical.dump`s the whole history and that dump is most of what
    # {Context::Compact} spends.
    #
    # That is also why there is no `#extend`: an incremental extension would
    # have to hold the last derived head -- the state non-recursion exists to
    # avoid -- and would buy nothing, since derivation is not a functor on the
    # prefix order (`A <= B` does not imply `derive(A) <= derive(B)`), pinned
    # as a characterization example in the spec. The source is the SESSION
    # timeline, never a previously derived one, which is what keeps a derived
    # head a pure content address of (source head, strategy, cut) and so makes
    # re-derivation exact and the artifact diffable.
    #
    # == A held cut
    #
    # A {Seam} is what a committed compaction froze: a SOURCE digest and the
    # replacement every range at or before it collapsed into. Handed one, a
    # derivation still starts from the source root, but those ranges are not
    # the strategy's to answer again -- they are written from the record --
    # and the strategy is offered only the span after the cut. So the cut is
    # policy state its owner passes in, never a derived head held here, and
    # while it holds with nothing new collapsing the derived chain DOES extend
    # as the source does: the replacement's bytes and its parent chain are the
    # same turn to turn. That monotonicity is the cut's purpose, and it is
    # pinned beside the negative above.
    #
    # == What this object does not decide
    #
    # WHICH sub-spans collapse and WHAT replaces one belong to the {Strategy};
    # WHERE the span may be cut belongs to {Boundary}; whether the result is a
    # conversation the Messages API accepts belongs to {Context::Conversation}.
    # It owns one decision of its own -- the replacement's role -- and that is
    # fixed rather than computed from history parity, because with no pins the
    # replacement IS `messages[0]`, which the API requires to be `user`. Pins
    # are not taken here either: a pin is a CUT POINT in a strategy's proposal,
    # not a shield the derivation applies afterwards.
    #
    # `meta` is DROPPED, as both compaction projections already do. Nothing
    # lineage needs is lost by it: subagent lineage rides `:spawn` and
    # completion events in the shared Store, never a turn's meta.
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

      # A seam as a derivation reads one: the source digest the held ranges
      # reach up to, and every held range with its replacement, root first. A
      # plain value, carrying no record of its own -- where it was committed,
      # by which arm and after which parent are its owner's to know.
      #
      # `keeps_last` is the one thing a seam knows that its ranges do not: a
      # HANDOFF collapses the keep_last tail on purpose -- it exists because
      # that tail is what would not fit -- so a seam carrying one is exempt
      # from the boundary refusal below. It defaults true and is INHERITED by
      # every seam built from this one, so the exemption cannot be picked up by
      # an advance that never handed off, nor dropped by one that did.
      Seam = Data.define(:digest, :collapses, :keeps_last) do
        # `make_shareable` and not `Canonical.normalize`: the collapses arrive
        # either from records already normalized or from replacements already
        # vetted, so freezing is what is missing, and re-normalizing a whole
        # lineage every turn would be the cost.
        def initialize(digest:, collapses:, keeps_last: true)
          super(digest:, collapses: Ractor.make_shareable(collapses), keeps_last:)
        end

        def spans = collapses.map { |collapse| collapse.fetch("span") }
      end

      # The seam before any compaction has committed: nothing held, and the
      # strategy offered the whole droppable span. A Null Object, so a
      # derivation with no cut and one with a cut are the same code path.
      UNCUT = Seam.new(digest: nil, collapses: NO_RANGES)

      # @param strategy [Strategy::Base] which sub-spans collapse, and into what
      # @param keep_last [Integer] the trailing messages the derivation retains
      #   verbatim. Validated by {Boundary}, which owns that refusal for every
      #   consumer, so a non-positive value raises at the first derivation
      #   rather than here -- one rule, one place.
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
      #   digests, and {Store#put} refuses an edge it does not hold -- and it is
      #   refused here rather than left to dangle, because a strategy that
      #   collapses nothing would otherwise build a whole chain in the wrong
      #   store in silence.
      # @param walk [Walk, nil] `source` already walked and projected, for a
      #   caller that has done both. nil makes the walk below, AFTER the
      #   refusal: `walk: Walk.of(source)` as a default argument is evaluated
      #   before the method body, so a foreign-store call would walk the entire
      #   chain and only then raise.
      # @param cut [Seam] the seam to hold. Its digest must be on `source`'s
      #   chain and short of the keep_last boundary -- the caller decides which
      #   cut still holds, and holding one anywhere else would collapse either
      #   the wrong range or turns a forward run sent verbatim
      # @yieldparam derived [Timeline] the derived chain
      # @yieldparam seam [Seam] the seam this derivation froze: `cut` itself
      #   when nothing after it collapsed, and otherwise a later one holding
      #   every range this chain collapsed. It is the caller's to commit or
      #   discard -- a derivation does not know whether its chain will be sent.
      # @return [Timeline, Object] the derived chain, in `into`; or the block's
      #   value when a block is given
      def derive(source, into: source.store, walk: nil, cut: UNCUT)
        refuse_foreign(source, into)
        plan = Plan.over(strategy: @strategy, walk: walk || Walk.of(source), keep_last: @keep_last, cut:)
        collapsed = plan.collapsed
        derived = committed(plan.writes(collapsed), into)
        @journal << edge(plan, source, derived)
        block_given? ? yield(derived, plan.seam(collapsed)) : derived
      end

      # {Head}'s projection verbatim: the derived chain has to be validated in
      # the very bytes a render will send.
      def self.projected(turns)
        turns.map { |turn| { "role" => turn.role, "content" => turn.content } }
      end

      # ONE walk of a chain, as a value: the turns it yielded and their
      # projection. Both are O(n) in history length and every consumer on the
      # render path needs both -- {Head} slices the projection, {Need} and
      # {Scheduler} measure it, the digests come off the turns -- so walking
      # per consumer is how a turn came to read the same Store three times and
      # project the same messages three times over.
      #
      # A VALUE rather than two arguments threaded side by side, because turns
      # and projection are index-aligned and a pair passed separately is a pair
      # that can be passed mismatched. No memo: a Timeline is a new value on
      # every commit, so a per-instance cache would miss every turn; the walk's
      # owner makes it once and hands it down.
      Walk = Data.define(:turns, :messages) do
        def self.of(timeline)
          turns = timeline.to_a
          new(turns:, messages: Derivation.projected(turns))
        end

        # Both invariants live in the OBJECT and not in `.of`, so no Walk can
        # exist without them however it was built.
        #
        # The PAIRING, because a mismatched pair is the one way this value can
        # lie, and it lies quietly: `#zip` pads with nil, so a short projection
        # pairs a turn's digest with another turn's text and nothing raises.
        #
        # DEEPLY FROZEN BY COPY, {Head}'s discipline and for {Head}'s reasons.
        # Measured: 0.35 ms on an 800-turn history, against the ~18 ms per
        # compacting turn the threading saves.
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

      def committed(writes, into)
        refuse_invalid(writes)
        writes.inject(Timeline.empty(store: into)) { |chain, write| write.onto(chain) }
      end

      def refuse_foreign(source, into)
        return if source.empty? || into.key?(source.head_digest)

        raise Store::MissingObject, "no object #{source.head_digest.inspect} in store: deriving into it would " \
                                    "dangle every replacement's causal edges, which name the source turns " \
                                    "they subsume"
      end

      # Judged from the WRITES, before a single object reaches the Store: the
      # Store is append-only and a refusal is not a rollback, so validating the
      # committed chain would leave a dead chain behind on every refusal --
      # bounded for a deterministic strategy, unbounded for a model-backed one.
      #
      # `Canonical.normalize` is the transform {Event::Payload} applies on the
      # way in, so these are the bytes the provider would have seen and this is
      # the SAME judgement the committed chain would get.
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
                                      moved: plan.boundary.moved, keep_last: @keep_last,
                                      compaction_cut: plan.held.digest)
      end

      # One event the derived chain will carry, and the only place a role is
      # assigned. `causal_parents` is EMPTY for a retained turn: the chain
      # records what a replacement SUBSUMED -- the fibre of the collapse -- and
      # a retained turn subsumes nothing.
      Write = Data.define(:role, :content, :causal_parents) do
        def self.retaining(turn) = new(role: turn.role, content: turn.content, causal_parents: [])

        def self.replacing(content, subsumed) = new(role: REPLACEMENT_ROLE, content:, causal_parents: subsumed)

        # What this write will render as once committed -- {Head}'s projection,
        # available BEFORE the Store is touched, which is what lets the chain be
        # judged without being written.
        def projection = { "role" => role, "content" => content }

        # Unfiltered, {Arm::Synthesis}'s discipline: a causal parent the Store
        # has not seen flows to {Timeline#commit} and raises, rather than being
        # quietly dropped from the edge.
        def onto(timeline) = timeline.commit(role:, content:, causal_parents:)
      end
      private_constant :Write

      # The per-source half of a derivation, as a value: which source turns,
      # their projection, where the span was cut, the cut it holds, and which
      # sub-spans were collapsed -- the held ranges first, then the strategy's
      # answer over the span after them. {Derivation} is the POLICY, held
      # across many turns; these travel together for exactly ONE source.
      #
      # The ranges are asked for ONCE and held, never recomputed: a strategy
      # may hold an oracle, and asking it twice is a second payment. For the
      # same reason each range is COLLAPSED once ({#collapsed}), and both the
      # writes and the seam read that one answer.
      Plan = Data.define(:strategy, :walk, :boundary, :held, :floor, :held_ranges, :live_ranges) do
        def self.over(strategy:, walk:, keep_last:, cut:)
          boundary = Boundary.new(messages: walk.messages, keep_last:)
          at = walk.turns.each_with_index.to_h { |turn, index| [turn.digest, index] }
          floor = cut.digest.nil? ? 0 : held_index(at, cut.digest) + 1
          refuse_past(boundary, floor, cut)
          new(strategy:, walk:, boundary:, held: cut, floor:,
              held_ranges: cut.spans.map { |first, last| held_index(at, first)..held_index(at, last) },
              live_ranges: proposed(strategy, walk.messages, boundary, floor))
        end

        # Raised rather than skipped: a cut whose digest is not on this chain
        # would collapse whatever happens to sit at the wrong indices, and
        # deciding which cut still holds is the caller's, before it gets here.
        def self.held_index(at, digest)
          at.fetch(digest) do
            raise ArgumentError, "the held compaction cut names #{digest}, which is not on the chain being derived"
          end
        end

        # A cut holds only on a chain containing the head it was committed at,
        # and there its floor never passes the boundary. One that does would
        # collapse turns keep_last retains -- a request no forward run sent --
        # so it is refused rather than rendered. A seam that does not keep
        # keep_last is the stated exception and the only one: a handoff
        # replaces that tail deliberately, having been fired because the tail
        # is what would not fit.
        def self.refuse_past(boundary, floor, cut)
          return if boundary.declined? || !cut.keeps_last || floor <= boundary.index

          raise ArgumentError, "the held compaction cut ends at message #{floor}, past the keep_last boundary at " \
                               "#{boundary.index}; a cut holds only on a chain containing the head it was committed at"
        end

        # The two reasons a span may hold nothing to collapse are asked
        # SEPARATELY, never as `index.zero?`, which is the one spelling that
        # erases the distinction {Boundary} exists to make. The empty span
        # `0...0` is no question at all: the natural whole-span proposal
        # `[span]` comes back as an empty range, which {Strategy::Base} refuses
        # as {Strategy::NotAPartition}, and turning a legal quiet turn into a
        # raise inside the render path is not a bargain. The derivation still
        # runs -- a chain with no collapsed range is the identity derivation --
        # and {#cut} records WHY nothing collapsed.
        #
        # `floor` is where a held cut ends, so a boundary AT it offers nothing
        # past the cut -- the same vacuous request an empty boundary is.
        def self.proposed(strategy, messages, boundary, floor)
          return NO_RANGES if boundary.declined? || boundary.index <= floor

          strategy.ranges(messages, span: floor...boundary.index)
        end
        private_class_method :proposed, :held_index, :refuse_past

        def turns = walk.turns

        def messages = walk.messages

        def ranges = held_ranges + live_ranges

        # Why the span was what it was, as the journalled edge's diagnosis:
        # `:empty` (nothing was droppable past the held cut), `:declined` (no
        # valid cut existed) or `:offered` (the strategy was handed a real
        # span). Only the last means an empty live answer is the STRATEGY's,
        # and the three are otherwise indistinguishable on the record.
        #
        # ASKED, never reconstructed: deriving the answer from `moved`, from
        # the naive split, or from `index.zero?` re-implements a rule that
        # lives in {Boundary} and goes quietly wrong the next time the cut rule
        # is relaxed. With no cut held the floor is 0, and `index <= 0` off a
        # boundary that did not decline is exactly {Boundary#empty?}.
        def cut
          return :declined if boundary.declined?
          return :empty if boundary.index <= floor

          :offered
        end

        # Every range paired with what replaces it: a held range with the
        # replacement its cut recorded, a live one with the strategy's collapse.
        # The range travels WITH its slice because {Strategy::Composed} needs
        # it to route the collapse to whichever operand proposed it -- the one
        # fact about a range the slice cannot carry. Others ignore it.
        def collapsed
          recorded = held.collapses.map { |collapse| Strategy::Replacement.of(collapse.fetch("content")) }
          held_ranges.zip(recorded) + live_ranges.map { |range| [range, strategy.collapse(messages[range], range:)] }
        end

        # One write per retained turn and one per collapsed range, in source
        # order. {Strategy::Base#ranges} guarantees an ascending,
        # non-overlapping partition of the live span, every held range ends at
        # or before the floor it starts at, and this fold is what that BUYS:
        # the derived chain is exactly the gaps between the ranges, so there is
        # no per-index membership test and no set of collapsed indices to hold.
        #
        # A range whose collapse answers DROP contributes no write at all --
        # the unit of the monoid {Strategy::Base#collapse} maps into, and how a
        # range vanishes leaving no replacement event.
        def writes(collapsed)
          folded, cursor = collapsed.inject([[], 0]) do |(events, from), (range, replacement)|
            [events + retained(from...range.first) + replacing(range, replacement), range.max + 1]
          end
          folded + retained(cursor...turns.size)
        end

        # Each collapsed range as the pair of source digests it spans.
        # ENDPOINTS, not the whole preimage: the interior is recoverable from
        # the source chain the record already names, and a 400-turn range would
        # otherwise write 400 digests into one NDJSON line.
        #
        # `#max`, never `#last`: `(0...5).last` is 5 -- the EXCLUDED end -- and a
        # strategy may answer either kind of Range, so the naive spelling names
        # a turn the range does not cover (or runs off the end of the chain).
        def spans = ranges.map { |range| endpoints(range) }

        # The seam this derivation froze. The held one when nothing after it
        # collapsed -- the SAME object, so a caller can tell no advance by
        # identity -- and otherwise a seam at the last turn any range collapsed,
        # carrying every range's replacement, held ranges first. A turn in the
        # live span that no range covered stays past the seam, to be offered
        # again.
        def seam(collapsed)
          return held if live_ranges.empty?

          Seam.new(digest: digest(live_ranges.last.max), collapses: collapsed.map { |pair| recorded(*pair) },
                   keeps_last: held.keeps_last)
        end

        private

        def retained(indices) = turns[indices].map { |turn| Write.retaining(turn) }

        def replacing(range, replacement)
          replacement.drop? ? NO_RANGES : [Write.replacing(replacement.content, subsumed(range))]
        end

        def endpoints(range) = [digest(range.first), digest(range.max)]

        def recorded(range, replacement) = { "span" => endpoints(range), "content" => replacement.content }

        def subsumed(range) = range.map { |index| digest(index) }

        def digest(index) = turns.fetch(index).digest
      end
      private_constant :Plan
    end
  end
end
