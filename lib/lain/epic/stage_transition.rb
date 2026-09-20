# frozen_string_literal: true

module Lain
  module Epic
    # One stage boundary crossed. Paired `started`/`completed` events rather than
    # a single "current stage" record, because a stage that started and a stage
    # that finished are different facts and an epic can sit in either for days.
    StageTransition = Data.define(:epic_slug, :stage, :event) do
      include Telemetry::Journalable

      def initialize(epic_slug:, stage:, event:)
        epic_slug = -epic_slug.to_s
        # Through Stage, so the closed pipeline set is asserted once and a
        # {Stage} value is accepted as readily as its name -- both answer #to_s.
        stage = Stage.new(stage.to_s).name
        event = -event.to_s
        Contracts::StageTransition.check!(epic_slug:, event:)

        super
      end
    end

    class StageTransition
      # See {IssueTransition::JOURNAL_TYPE}.
      JOURNAL_TYPE = "stage_transition"
    end
  end
end
