# frozen_string_literal: true

module Lain
  class Arm
    # One rung above {OneShot}: the task is PLANNED first, and the plan is then
    # carried out by an issue actor running lain's own execute-plan skill. There
    # is no epic around it -- nothing gates, nothing lands, and the two epic-wide
    # rungs are never visited.
    #
    # It is the arm that isolates what PLANNING alone buys. Between this and
    # one-shot the only difference is that a plan was written and handed to an
    # actor; between this and the epic arms, that nobody signed anything off.
    #
    # THE PLAN DECLARES THE SUBJECT. An issue actor places its failing tests by
    # mirroring a source file through the project's layout, and there is no
    # {Epic::Issue} here to carry one -- so the planner's own output is read for
    # the `Subject:` line, exactly as the epic driver reads `plans/<id>.md`. A
    # plan that declares none refuses by name rather than inventing a path.
    class PlanOnly < Arm
      # Where it joins {Ladder}: the first rung an epic would gate, entered with
      # no epic to gate it.
      ENTRY = "issue_plan"

      # The one issue this arm carries. A plan-only run has no issue graph to
      # draw an id from, so it names the single unit of work after the arm.
      ISSUE = "plan-only"

      # What a refusal about the plan NAMES. A plan-only run has no epic home to
      # write a plan into, so it is held in memory -- and a refusal naming
      # `plans/plan-only.md` would send a reader looking for a file that was
      # never written. It says what it is instead.
      PLAN_SOURCE = "the plan-only arm's plan, held in memory"

      # The planner's answer, shaped as the artifact {CLI::EpicDriver::PlanSubject}
      # reads -- `#read` and `#path` are the whole of what it asks.
      Planned = Data.define(:text, :path) do
        def read = text
      end

      # @param planner [#call] `call(task, worker_env:, journal:, spawn_seam:) -> String`,
      #   the create-plan step; its answer is the plan text
      # @param actors [#call] `call(issue_id, subject:, level:, attempt:) -> Launch`,
      #   a {CLI::EpicDriver::IssueActor}
      # @param supervisor [#find, #retire] the fleet the actor was adopted into
      # @param name [String] the arm's label
      # @param instrument [Instrument] times the run and prices its journal
      # @param layout [TestLayout] the subject project's declared layout, which
      #   is what decides whether a declared subject is checked for placement;
      #   the Null layout checks only that one was declared at all
      # @param grading [#call] `call(lease:, grader:) -> #grade`, the judge for a
      #   run: the subject's own suite, bound to the checkout this arm leased.
      #   The default passes the caller's own grader straight through.
      # @param journal_factory [#call] builds the per-run journal
      # @param synthesis [Synthesis] the fold that re-attributes the actor's
      #   spend onto a head this run can reach
      # @param handoff [#reclaim, #surrender] forwarded to the base's lease bracket
      def initialize(planner:, actors:, supervisor:, name: "plan-only", instrument: Instrument.new,
                     layout: TestLayout::None, grading: OneShot::PASS_THROUGH,
                     journal_factory: -> { Channel.new },
                     synthesis: Synthesis.new, handoff: Isolation::WorkerHandoff::Null)
        super(name:, handoff:)
        @planner = planner
        @actors = actors
        @supervisor = supervisor
        @instrument = instrument
        @layout = layout
        @grading = grading
        @journal_factory = journal_factory
        @synthesis = synthesis
      end

      # @return [Array<String>] issue_plan, implementation, land
      def rungs = Ladder.from(ENTRY)

      # Plan, carry the plan in an actor, retire it, and hand back the graded,
      # priced, timed {Run}.
      #
      # THE ACTOR'S SPEND IS RE-ATTRIBUTED. Its turns sit on its own fresh-root
      # Timeline, which this run's head does not RENDER-reach, so folding the
      # lead alone would price a paid actor at zero -- the one failure {Run}'s
      # reachability contract names. The fold re-keys those payments onto the
      # reachable head, each still carrying the model that priced it.
      #
      # @param task [String] what to plan and then carry out
      # @param spawn_seam [#call] the agent factory, threaded to the planner
      # @param grader [#grade] scores the resulting Timeline
      # @param isolation [#acquire] the injected backend
      # @param grading [#call, nil] this run's own judge seam, overriding the
      #   constructed one; a bench varies it per task
      # @return [Run]
      def run(task, spawn_seam:, grader:, isolation: NoIsolation, grading: nil)
        leased(isolation:) do |lease|
          journal = @journal_factory.call
          elapsed, carried = @instrument.timed { carry(task, lease:, journal:, spawn_seam:) }
          folded = @synthesis.fold(lead_for(task), [settled(carried, journal)])
          assembled(folded, elapsed:, judge: judge(lease, grader, grading))
        end
      end

      private

      # The arm's own lead: one user turn naming the task, and the head every
      # re-attributed payment is keyed onto.
      def lead_for(task)
        Timeline.empty(store: Store.new).commit(role: :user, content: [{ "type" => "text", "text" => task }])
      end

      # A run-level seam WINS over the constructed one, {OneShot}'s rule and for
      # its reason: a bench varies the judge per task while the arm is built once.
      def judge(lease, grader, grading) = (grading || @grading).call(lease:, grader:)

      def assembled(folded, elapsed:, judge:)
        Run.new(arm: name, timeline: folded.timeline, grade: judge.grade(folded.timeline), elapsed:,
                ledger: @instrument.price_records(folded.ledger_entries))
      end

      # Plan first, then launch: a refusal from the declaration leaves nothing
      # launched and nothing to retire.
      # The actor carries the plan out in the checkout THIS arm is holding, the
      # same environment the planner was handed -- otherwise it works wherever
      # the process happened to stand, which on a bench is lain's own tree
      # rather than the subject project under test.
      def carry(task, lease:, journal:, spawn_seam:)
        declared = subject_of(planned(task, lease:, journal:, spawn_seam:))
        launch = @actors.call(ISSUE, subject: declared.subject, level: declared.level, attempt: 1,
                                     worker_env: lease.worker_env)
        @supervisor.retire(row_of(launch))
      end

      def planned(task, lease:, journal:, spawn_seam:)
        Planned.new(path: PLAN_SOURCE,
                    text: @planner.call(task, worker_env: lease.worker_env, journal:, spawn_seam:))
      end

      # Spelled in a method body rather than as a constant: this unit loads after
      # `lain/cli`, but naming it here keeps the rule every arm follows.
      def subject_of(plan) = Lain::CLI::EpicDriver::PlanSubject.read(plan, layout: @layout)

      def row_of(launch) = @supervisor.find { |row| row.actor.equal?(launch.actor) }

      # `head_digest: nil` because the actor's head lives in a Store this run
      # does not hold, so it is named causally by nothing -- the usage still
      # re-attributes, which is the half that must not be lost.
      def settled(report, journal)
        Synthesis::Result.ok(head_digest: nil, text: report.to_s, usage_records: journal.drain.map(&:to_journal))
      end
    end
  end
end
