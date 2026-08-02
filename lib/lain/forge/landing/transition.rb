# frozen_string_literal: true

module Lain
  module Forge
    class Landing
      # The last thing a landing does, and the one member of the {Plan} that is
      # not a forge {Intent}: the {Epic::IssueTransition} that moves the issue to
      # done.
      #
      # == It fires when this run MOVED something, and not otherwise
      #
      # B4: the old code wrote it unconditionally after the merge step, so every
      # resume appended another transition claiming a move from a status the
      # issue no longer held -- three resumes, three moves. The rule here is a
      # law about the run rather than a check somebody has to remember: a run
      # that found every effect already in place changed nothing and has nothing
      # to announce. That is what makes a repeated resume a fixpoint over the
      # epic's records as well as over the journal's intents.
      #
      # It is also why this reads {Running#performed} rather than the journal:
      # `entries` reaches {Landing.resume} already narrowed to this issue's
      # forge records ({CLI::EpicLand::Scoped}), so no transition is visible in
      # them and asking would answer "never moved" every time.
      #
      # == The residual
      #
      # A merge the world confirms but whose {Outcome} was never written -- a
      # hard kill between `gh pr merge` returning and the record landing --
      # resumes with nothing left to perform, so this never fires and the issue
      # stays in_flight. That is a stop SHORT, not a wrong record, and a human
      # moves it. The alternative, firing whenever the merge is in place,
      # appends a duplicate transition on every later resume, forever.
      class Transition
        def initialize(scribe:, issue_id:)
          @scribe = scribe
          @issue_id = issue_id
          freeze
        end

        def advance(run, _evidence) = run.performed ? moved(run) : run

        private

        def moved(run)
          @scribe.issue_moved(@issue_id, from: IN_FLIGHT, to: Epic::DONE)
          run
        end
      end
    end
  end
end
