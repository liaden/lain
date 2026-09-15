# frozen_string_literal: true

module Lain
  module Compaction
    class Source
      # The cut that holds on THIS turn's chain, what holding it renders, and
      # the record a new commit past it writes.
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
      # A collapse in that lineage names the cuts it re-wrote, and they fold
      # OUT of the seam here rather than being retracted from the record: the
      # superseded cuts are what a chain below the collapse's commit head still
      # holds, so both readings have to stay available.
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
          @at = at
          @lineage = lineage
          @held = standing(lineage)
          @seam = seam_of(@held)
          @floor = @held.empty? ? 0 : at.fetch(@held.last.digest) + 1
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

        # Whether there is more than one cut to re-collapse INTO one. A single
        # cut re-summarized where it stands buys a second answer to the same
        # question; several rewritten together are what makes room once nothing
        # past them is droppable.
        #
        # @return [Boolean]
        def collapsible? = @held.size > 1

        # The stretch a collapse re-writes: the held replacements, and whatever
        # the cuts retained between them, as this turn renders them.
        #
        # @return [Stretch]
        def stretch = @stretch ||= Stretch.new(timeline: @timeline, walk: @walk, at: @at, cut: @seam)

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

        # Record what a chosen derivation froze, once, when it moved: an
        # ADVANCE past the cuts that hold, carrying only the ranges it newly
        # collapsed, or a COLLAPSE of those cuts, carrying the seam that
        # replaces theirs. It is recorded when the pipeline is CHOSEN, before
        # the request is sent; a send that then fails leaves a cut the next
        # render holds consistently anyway.
        #
        # An advance moves the seam and a collapse rewrites it where it stands,
        # so the shipped digest is what tells them apart.
        #
        # @param shipped [Derived::Outcome] the derivation this turn renders
        # @return [self]
        def advance(shipped)
          return self if shipped.seam.equal?(@seam)

          @session.record_compaction_cut(shipped.seam.digest == @seam.digest ? collapse(shipped) : moved(shipped))
          self
        end

        private

        def moved(shipped)
          cut(shipped, kind: "advance", supersedes: [],
                       collapses: shipped.seam.collapses.drop(@seam.collapses.size))
        end

        def collapse(shipped)
          cut(shipped, kind: "collapse", supersedes: @held.map(&:address), collapses: shipped.seam.collapses)
        end

        def cut(shipped, kind:, supersedes:, collapses:)
          Telemetry::CompactionCut.new(
            digest: shipped.seam.digest, head: Event.stands_on(@walk.turns.last), strategy: @arm, kind:,
            parent: @lineage.last&.address, supersedes:, collapses:,
            plan_step_completions: @session.plan_step_completions
          )
        end

        # The cuts whose ranges this chain renders: the lineage with everything
        # a collapse in it re-wrote taken out. A superseding cut is recorded
        # after the cuts it supersedes, so one pass over the whole lineage
        # gathers every address that has been re-written.
        def standing(lineage)
          superseded = lineage.flat_map(&:supersedes).to_set
          lineage.reject { |cut| superseded.include?(cut.address) }
        end

        def seam_of(held)
          return Derivation::UNCUT if held.empty?

          Derivation::Seam.new(digest: held.last.digest, collapses: held.flat_map(&:collapses))
        end

        def derives? = !@held.empty? || @derived.stale_edge?(nil, recorded: !@session.compaction_cuts.empty?)

        # The stretch the held cuts cover, as this turn renders it: each held
        # range as the replacement that stands for it, each turn the cuts
        # retained between them verbatim. What a re-collapse is offered.
        #
        # A STATED NARROWING of the non-recursive rule, and the whole of it:
        # the summarizer's input may be earlier replacements, so a collapse
        # re-summarizes summaries rather than a history nothing can fit. What
        # it ANSWERS is still a range over the source turns, addressed by their
        # digests, so no derivation ever holds a derived head.
        class Stretch
          # One rendered message of the stretch and the source turns it stands
          # for: a retained turn, or a held range with the collapse that
          # recorded it. A dropped range shows no message and is still a piece
          # -- it covers source turns a merge has to carry.
          Piece = Data.define(:range, :message, :collapse) do
            def shown? = !message.nil?

            def held? = !collapse.nil?
          end
          private_constant :Piece

          def initialize(timeline:, walk:, at:, cut:)
            @timeline = timeline
            @walk = walk
            @at = at
            @cut = cut
            @pieces = pieces
            @shown = @pieces.select(&:shown?)
          end

          # @return [Timeline] the chain the stretch is read off
          attr_reader :timeline

          # @return [Derivation::Walk] that chain, walked once
          attr_reader :walk

          # @return [Derivation::Seam] the seam this stretch renders
          attr_reader :cut

          # @return [Array<Hash>] the stretch as the model sees it now
          def messages = @shown.map(&:message)

          # @param policy [Strategy::Base] the run's collapse policy, asked
          #   about the stretch exactly as it is asked about raw turns
          # @param pins [Context::PinnedMessages] this turn's pins; cut points
          #   here as everywhere, so a pinned turn between two held ranges is
          #   retained rather than swallowed by the merge
          # @return [Derivation::Seam] a seam whose ranges replace the held
          #   ones, or the held seam itself when nothing merged -- so a caller
          #   can tell "nothing to do" by identity, and a tier that is down
          #   leaves the cuts standing
          def recollapsed(policy, pins)
            merged = merges(policy, pins)
            return @cut if merged.empty?

            Derivation::Seam.new(digest: @cut.digest, collapses: recorded(merged))
          end

          private

          # Only a run of more than one shown message is offered, and only a
          # range covering more than one is taken: a range over a single piece
          # is a second answer to a question already answered, at the price of
          # a model call.
          def merges(policy, pins)
            runs(policy, pins).flat_map { |run| policy.ranges(messages, span: run) }
                              .select { |range| range.max > range.first }
                              .map { |range| [raw(range), policy.collapse(messages[range], range:)] }
          end

          def runs(policy, pins)
            IntervalPartition.covering(0...@shown.size, excluding: pins.indices_in(messages), owner: policy.name)
                             .validated.select { |run| run.max > run.first }
          end

          def raw(range) = @shown.fetch(range.first).range.first..@shown.fetch(range.max).range.max

          # The merged ranges, plus every held range no merge covered, in source
          # order: a collapse carries the whole seam it supersedes, so what it
          # did not rewrite is still rendered from the record.
          def recorded(merged)
            spans = merged.map(&:first)
            kept = @pieces.select { |piece| piece.held? && spans.none? { |span| span.cover?(piece.range) } }
                          .map { |piece| [piece.range, piece.collapse] }
            (merged.map { |range, replacement| [range, endpoints(range, replacement.content)] } + kept)
              .sort_by { |range, _| range.first }.map(&:last)
          end

          def endpoints(range, content)
            { "span" => [digest(range.first), digest(range.max)], "content" => content }
          end

          def digest(index) = @walk.turns.fetch(index).digest

          # Root first, ending where the seam does: the held ranges in order,
          # with the turns between them.
          def pieces
            held = @cut.collapses.map { |collapse| [indices(collapse.fetch("span")), collapse] }
            return [] if held.empty?

            held.inject([[], held.first.first.first]) do |(built, from), (range, collapse)|
              [built + retained(from...range.first) + [collapsed(range, collapse)], range.max + 1]
            end.first
          end

          def indices(span) = @at.fetch(span.first)..@at.fetch(span.last)

          def retained(indices)
            indices.map { |index| Piece.new(range: index..index, message: @walk.messages.fetch(index), collapse: nil) }
          end

          def collapsed(range, collapse)
            content = collapse.fetch("content")
            Piece.new(range:, collapse:,
                      message: content.empty? ? nil : { "role" => Derivation::REPLACEMENT_ROLE, "content" => content })
          end
        end
        private_constant :Stretch
      end
      private_constant :HeldCut
    end
  end
end
