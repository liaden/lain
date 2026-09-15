# frozen_string_literal: true

module Lain
  module Compaction
    class Source
      # The cut that holds on THIS turn's chain, what holding it renders, and
      # the record a new advance past it commits.
      #
      # A recorded cut holds while three things are true:
      # - the chain contains the head it was COMMITTED at;
      # - it was committed by this run's arm;
      # - its seam still falls short of the keep_last boundary.
      #
      # The head rule is what makes a rewind or a fork a forward run. Below the
      # commit head, the original run sent those turns verbatim, and a summary
      # committed later in time has no business replacing the turn a human
      # rewound TO. The commit head is the turn the render stood on
      # ({Event.stands_on}), not the prompt at the head: an ask refused before
      # any model saw it withdraws that prompt and the next takes its place, so
      # a cut committed at the prompt itself retreated and was committed again
      # on every stuck ask. The arm rule keeps one arm's prefix from being sent
      # under another on a bench that compares them. The boundary rule keeps a
      # resume under a larger `--compact-keep` from collapsing turns keep_last
      # retains.
      # The latest recorded cut meeting all three holds, with its lineage;
      # otherwise none does.
      #
      # Per turn, because the chain is; built once, so the held render a
      # rewrite is measured against and the one a deferring turn sends are one
      # derivation.
      class HeldCut
        # @param session [Session] whose recorded cuts are asked
        # @param timeline [Timeline] this turn's chain
        # @param derived [Derived] the run's derive-and-substitute step
        # @param arm [String] the name of the arm this run collapses under
        # @return [HeldCut]
        def self.on(session:, timeline:, derived:, arm:)
          walk = Derivation::Walk.of(timeline)
          at = walk.turns.each_with_index.to_h { |turn, index| [turn.digest, index] }
          boundary = Boundary.new(messages: walk.messages, keep_last: derived.keep_last).index
          held = session.compaction_cuts.reverse_each.find { |cut| holds?(cut, arm, at, boundary) }
          new(session:, timeline:, walk:, derived:, arm:, lineage: lineage(session, held), at:)
        end

        def self.holds?(cut, arm, at, boundary)
          cut.strategy == arm && at.key?(cut.head) && at.fetch(cut.digest) < boundary
        end

        # Root first. Every hop is on the chain: a child is committed while its
        # parent holds, so the parent's head is an ancestor of the child's.
        def self.lineage(session, held)
          return [] if held.nil?

          Enumerator.produce(held) { |cut| cut.parent ? session.compaction_cut(cut.parent) : raise(StopIteration) }
                    .to_a.reverse
        end
        private_class_method :holds?, :lineage

        def initialize(session:, timeline:, walk:, derived:, arm:, lineage:, at:)
          @session = session
          @timeline = timeline
          @walk = walk
          @derived = derived
          @arm = arm
          @lineage = lineage
          @seam = seam_of(lineage)
          @floor = lineage.empty? ? 0 : at.fetch(lineage.last.digest) + 1
        end

        # @return [Timeline] this turn's chain
        attr_reader :timeline

        # @return [Derivation::Walk] that chain, walked once
        attr_reader :walk

        # @return [Derivation::Seam] what holds, or {Derivation::UNCUT}
        attr_reader :seam

        # What a compaction may still collapse: the messages past the cut.
        # Measured by {Head}, so a threshold fires on history the cut has not
        # already dealt with rather than forever on the history it has.
        def remaining = @walk.messages.drop(@floor)

        # This chain with the cut held and nothing new collapsed. The Null
        # outcome, deriving nothing, when no cut holds and the record already
        # says so; when no cut holds but the record's last edge may still name
        # one, an uncut derivation, so the retreat is on the record.
        def outcome
          @outcome ||= derives? ? @derived.held(@timeline, walk: @walk, cut: @seam) : Derived::Outcome::NOTHING
        end

        # What a turn sends if it compacts no further -- the `before` a new
        # rewrite has to beat, since beating the full history is free once a
        # cut holds.
        def messages = outcome.refused? ? @walk.messages : outcome.messages

        # Record the advance a chosen derivation froze, once, when it moved:
        # only the ranges it newly collapsed, linked to the cut it advanced
        # past. It is recorded when the pipeline is CHOSEN, before the request
        # is sent; a send that then fails leaves a cut the next render holds
        # consistently anyway.
        #
        # @param shipped [Derived::Outcome] the derivation this turn renders
        # @return [self]
        def advance(shipped)
          return self if shipped.seam.equal?(@seam)

          @session.record_compaction_cut(
            Telemetry::CompactionCut.new(
              digest: shipped.seam.digest, head: Event.stands_on(@walk.turns.last), strategy: @arm,
              parent: @lineage.last&.address,
              collapses: shipped.seam.collapses.drop(@seam.collapses.size),
              plan_step_completions: @session.plan_step_completions
            )
          )
          self
        end

        private

        def seam_of(lineage)
          return Derivation::UNCUT if lineage.empty?

          Derivation::Seam.new(digest: lineage.last.digest, collapses: lineage.flat_map(&:collapses))
        end

        def derives? = !@lineage.empty? || @derived.stale_edge?(nil, recorded: !@session.compaction_cuts.empty?)
      end
      private_constant :HeldCut
    end
  end
end
