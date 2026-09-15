# frozen_string_literal: true

module Lain
  module Epic
    # What an approval advances, whichever surface approved it: a verdict from
    # `lain epic submit`, a re-submit over a standing approval, or a sign-off
    # from `lain epic approve`. An approved issue plan puts its issue in flight
    # ({InFlight}); an approved epic-wide stage completes and starts the next;
    # an implementation moves nothing until it lands. Held in one place because
    # a queue approval that forgot the stage left the epic reading research
    # forever, while the same approval through a verdict moved it on.
    #
    # Two steps, because a surface must learn where the epic stands BEFORE it
    # journals the approval: {#read} asks, and can refuse with nothing
    # recorded; what it returns writes. An epic-wide stage is read from the
    # stage fold alone, never from epic.md, which plan-epic writes only once
    # research is approved.
    #
    # Only from the right state: a stage moves while the epic has not got past
    # it, so an approval re-run -- a revised artifact, or the re-submit that
    # repairs an approval whose advance never landed -- writes nothing once the
    # epic stands beyond it.
    #
    # AT LEAST ONCE, for {InFlight}'s reason: the stage is read and then the
    # transitions are written, with no compare-and-append between. Two
    # processes that both read the epic at research both advance it, and the
    # fold reads the last start, so it stands at epic_plan either way.
    class Advance
      # @param epic_slug [String] the epic the approval belongs to
      # @param stage [String, Stage] the stage that was approved
      # @param issue_id [String, nil] the issue an issue-scoped approval is for
      def initialize(epic_slug:, stage:, issue_id:)
        @epic_slug = epic_slug
        @arm = Arm.for(stage.is_a?(Stage) ? stage : Stage.new(stage), issue_id)
      end

      # @return [Boolean] whether the approval writes anything, which is also
      #   whether {#read} asks the epic anything
      def moves? = @arm.moves?

      # @param epics [#stage, #progress] answers where an epic stands, by slug
      # @return [Ready] what to write once the approval is journaled
      # @raise [Lain::Error] from the fold, before anything is written
      def read(epics) = Ready.new(@epic_slug, @arm.read(epics, @epic_slug))

      # The advance, decided against what {#read} saw.
      class Ready
        def initialize(epic_slug, write)
          @epic_slug = epic_slug
          @write = write
        end

        # @param journal [#<<] where the transitions land
        # @return [String] what moved, for the approving surface's report
        def call(journal) = @write.call(Scribe.new(epic_slug: @epic_slug, journal:))
      end

      # One arm per answer to "what does this approval move", chosen once, so
      # whether it moves and what it writes cannot be spelled apart.
      module Arm
        def self.for(stage, issue_id)
          return StartIssue.new(issue_id) if InFlight.starts?(approved: true, stage: stage.name, issue_id:)
          return CompleteStage.new(stage) unless stage.issue_scoped?
          return Still.new("this #{stage} approval names no issue -- nothing moved") if issue_id.nil?

          Still.new("issue #{issue_id}'s #{stage} is approved -- nothing moves until it lands")
        end

        # An epic-wide stage, read from the stage fold alone.
        CompleteStage = Data.define(:stage) do
          def moves? = true

          def read(epics, slug)
            current = epics.stage(slug)
            ->(scribe) { advance(scribe, current) }
          end

          private

          def advance(scribe, current)
            return "epic is at #{current} -- #{stage} is already behind it, nothing moved" if current > stage

            scribe.stage_completed(stage)
            scribe.stage_started(stage.next)
            "#{stage} completed, #{stage.next} started"
          end
        end

        # An issue plan, whose issue's status is folded over the document.
        StartIssue = Data.define(:issue_id) do
          def moves? = true

          def read(epics, slug)
            progress = epics.progress(slug)
            ->(scribe) { InFlight.new(scribe:, progress: -> { progress }, issue_id:).call }
          end
        end

        # Nothing to write, so nothing to read.
        Still = Data.define(:line) do
          def moves? = false

          def read(_epics, _slug) = ->(_scribe) { line }
        end
      end
      private_constant :Arm
    end
  end
end
