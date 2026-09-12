# frozen_string_literal: true

require "async"

module Lain
  module CLI
    module EpicDriver
      class Run # rubocop:disable Style/Documentation -- doc lives on the reopen below
        # What a run may do before it stops of its own accord. The width is how
        # many issues are carried at once; two is enough to keep a second issue
        # moving while the first waits on a human at its gate, and small enough
        # that a conflict at the landing queue is between two commits rather
        # than five.
        WIDTH = 2

        # The ONE status an issue is launched from. Approving an issue's plan is
        # what writes `pending -> in_flight` ({Epic::InFlight}), and it is the
        # only writer: a driver that moved an issue itself would be a second one,
        # and the landing refuses anything not in flight anyway. So a pending
        # issue is reported for its human to plan, never launched.
        STARTABLE = "in_flight"

        # How often a gate wait looks up to ask whether the run is over.
        POLL = 0.1

        BUDGET_SPENT = "the run's budget of %<budget>s issues is spent, so the loop stopped with work still to do"

        INTERRUPTED = "the run was interrupted, so the loop stopped between issues"

        UNSETTLED = "the run stopped while its actor was still working, so this issue was left where it stood"

        UNPLANNED = "it is still pending, so its issue_plan has not been approved yet -- approve the plan and " \
                    "the issue moves itself into flight"

        NOTHING_COMMITTED = "its actor settled having committed nothing, so there was no implementation to submit"

        ANCHOR_REFUSED = "its work could not be anchored, so nothing was submitted"

        GATE_PARKED = "its implementation gate has not approved %<sha>s, so nothing landed"

        UNCARRIED = "it could not be carried any further, so nothing landed"

        NOT_LANDED = "the landing queue left its work off the working branch (%<kind>s), so it waits on its ref"

        # The one state a rerun cannot recover on its own: the work is anchored
        # and the issue is still in flight, but the merge never happened, so the
        # next attempt's anchor would be refused by this one. The way out is a
        # command, and the reply has to name it.
        STRANDED = "its work is anchored at %<sha>s but never reached the working branch (%<why>s) -- finish it " \
                   "with `lain epic land %<issue>s --resume`, which merges what is already anchored"

        # Everything the landing refused BEFORE it merged anything. There is no
        # merge to resume, so the refusal speaks for itself: each of these names
        # its own remedy already.
        REFUSED = "its landing was refused before anything merged, so its work is still anchored and the issue " \
                  "is untouched: %<why>s"

        # One issue's work, from the launch that started it to the retirement
        # that ends it.
        Live = Data.define(:issue_id, :launch)

        # @param progress [#call] answers the epic's {Epic::Progress}, re-read
        #   per fold rather than cached -- a landing changes it, and the next
        #   issue's readiness is exactly that change
        # @param plans [#call] `issue_id ->` the issue's {PlanSubject}, raising
        #   when its plan is not approved or declares no subject
        # @param actors [#call] an {IssueActor}
        # @param supervisor [Supervisor] the epic's own, already running
        # @param gate [#call] `call(issue_id, sha:)`, answering whether the
        #   issue's implementation gate has approved that commit
        # @param landing [#call] `call(issue_id, sha:, ref:)`, the landing queue
        #   -- the only thing that merges. Its answer is believed: an entry that
        #   is not `done` did not land.
        # @param width [Integer] how many issues are carried at once
        # @param budget [Integer, nil] how many issues the whole run may land
        # @param interrupt [#call] answers whether the run should stop
        # @param attempts [#call] `issue_id ->` which attempt to launch under,
        #   derived from the anchors standing in the repository
        # @param grading [#call] `call(issue_id, registration)`, judged between
        #   an actor settling and its retirement -- see {#settle_one}. The Null
        #   grades nothing, so an ordinary run is unchanged.
        def initialize(progress:, plans:, actors:, supervisor:, gate:, landing:,
                       width: WIDTH, budget: nil, interrupt: -> { false }, attempts: nil, grading: Ungraded)
          @progress = progress
          @plans = plans
          @actors = actors
          @supervisor = supervisor
          @landing = landing
          @bounds = Bounds.new(width:, budget:, interrupt:)
          @attempts = attempts || ->(_issue_id) { 1 }
          @grading = grading
          @asking = Asking.new(gate:, interrupt:)
        end

        # @return [Result] what landed, what was reported, and why the loop
        #   stopped when it stopped early
        def call
          @landed = []
          @reported = []
          @live = []
          @stopped = nil
          drive
          result
        end

        private

        # Fold, report what cannot run, fill the width, settle one, fold again.
        # The refold is the whole of the dependency order: an issue blocked by
        # the one that just landed becomes runnable because the fold now says
        # its blocker is done, and nothing else here knows about the graph.
        def drive
          @stopped = stop_reason
          return strand unless @stopped.nil?

          folded = @progress.call
          unplanned(folded).each { |issue| @reported << Reported.new(issue_id: issue.id, reason: UNPLANNED) }
          fill(folded)
          return if @live.empty?

          settle_one
          drive
        end

        def stop_reason
          budget = @bounds.budget
          return format(BUDGET_SPENT, budget:) if budget && @landed.size >= budget
          return INTERRUPTED if @bounds.interrupt.call

          nil
        end

        # An early stop leaves whatever is still working where it stands: its
        # commits are its own actor's to anchor, and this run will not be the
        # thing that reports them landed.
        def strand
          @live.each { |entry| reported(entry, UNSETTLED) }
          @live = []
        end

        def fill(folded)
          startable(folded).take(@bounds.width - @live.size).each { |issue| launch(issue) }
        end

        def startable(folded) = ready(folded) { |issue| issue.status == STARTABLE }

        # Pending, and nothing standing in its way but its own plan.
        def unplanned(folded) = ready(folded) { |issue| issue.status == Lain::Epic::InFlight::PENDING }

        # Indexed ONCE per pass, not once per issue: this is the driver's own
        # loop, re-entered for every issue that settles.
        def ready(folded)
          blockage = Lain::Epic::Blockage.of(folded.graph)
          folded.graph.select { |issue| yield(issue) && untouched?(issue.id) && blockage.clear?(issue.id) }
        end

        # An issue this run has already launched, landed or reported is not
        # offered again: the fold is re-read every turn and would otherwise
        # answer the same issue forever.
        def untouched?(id)
          [@live, @landed, @reported].none? { |seen| seen.any? { |entry| entry.issue_id == id } }
        end

        # A refusal stops THIS issue and nothing else: the plan is not approved,
        # or it declares no subject to write tests for, and either way a human
        # has to look. The rest of the run keeps moving.
        def launch(issue)
          subject = @plans.call(issue.id)
          launched = @actors.call(issue.id, subject: subject.subject, level: subject.level,
                                            attempt: @attempts.call(issue.id))
          @live << Live.new(issue_id: issue.id, launch: launched)
        rescue StandardError => e
          @reported << Reported.new(issue_id: issue.id, reason: e.message)
        end

        # Await the oldest live actor, retire it, and put what it anchored
        # through its gate. Awaiting one actor does not hold the others up: each
        # runs on a fiber of its own under the supervisor's reactor, so a sibling
        # parked at a human's approval goes on being parked while this settles.
        #
        # ONE ISSUE'S REFUSAL STOPS THAT ISSUE. Everything below can refuse --
        # the retirement, the gate, the queue -- and none of them may discard a
        # Result that already carries somebody else's landing.
        # GRADED BEFORE IT IS RETIRED, and the order is the whole point.
        # Retirement anchors the work, stops the actor and RELEASES its lease --
        # which removes the checkout -- so anything that judges an issue by
        # running the subject's own suite has exactly one moment to do it. The
        # row is what carries the lease, so the seam reaches the checkout the
        # actor really worked in rather than a path somebody guessed.
        #
        # A grader that raises is caught by the same rescue as everything else
        # here: it stops THAT issue and leaves the run carrying whatever already
        # landed.
        def settle_one
          entry = @live.shift
          row = row_of(entry)
          @grading.call(entry.issue_id, row)
          judge(entry, @supervisor.retire(row))
        rescue StandardError => e
          reported(entry, "#{UNCARRIED}: #{e.class}: #{e.message}")
        end

        def row_of(entry) = @supervisor.find { |row| row.actor.equal?(entry.launch.actor) }

        # JUDGED BY THE SHA, NEVER BY THE KIND. An actor that committed nothing
        # retires as `nothing_to_do` and a refused anchor as `failed`, and both
        # carry a nil SHA -- so the one question worth asking is whether there is
        # a commit to gate at all. Submitting an empty implementation would put
        # an address nobody can land in front of a human.
        def judge(entry, report)
          return reported(entry, unkept(report)) if report.sha.nil?

          opened = @asking.call(entry.issue_id, sha: report.sha)
          return reported(entry, UNSETTLED) if opened == Asking::STOPPED
          return reported(entry, format(GATE_PARKED, sha: report.sha)) unless opened

          land(entry, report)
        end

        def unkept(report) = report.kind == :failed ? "#{ANCHOR_REFUSED} (#{report.detail})" : NOTHING_COMMITTED

        # HONOUR THE QUEUE'S ANSWER. A call that returned is not a landing: the
        # queue says whether the work reached the branch, and a conflict that
        # still stands is work waiting on its ref, not work that landed.
        def land(entry, report)
          moved = Array(@landing.call(entry.issue_id, sha: report.sha, ref: report.ref))
          return @landed << Landed.new(issue_id: entry.issue_id, sha: report.sha) if moved.all?(&:done)

          reported(entry, stood(moved))
        rescue StandardError => e
          reported(entry, unlanded(entry, report, e))
        end

        # `--resume` finishes a merge that HAPPENED and was journaled, so it is
        # the way out of exactly one state. A refusal raised before anything
        # merged has nothing to resume -- the command would answer
        # NothingToResume -- so sending a human there would cost them a second
        # refusal to work out. It reports itself instead.
        def unlanded(entry, report, error)
          return format(REFUSED, why: error.message) if refused_before_merging?(error)

          format(STRANDED, sha: report.sha, issue: entry.issue_id, why: "#{error.class}: #{error.message}")
        end

        # Spelled in a method body: this unit loads before `lain/forge`, so a
        # constant list in the class body would be a NameError at boot.
        def refused_before_merging?(error)
          [Lain::Forge::LocalLanding::NotInFlight, Lain::Forge::LocalLanding::MisplacedTests,
           Lain::Forge::LocalLanding::AlreadyOnBranch, Lain::Forge::LocalLanding::Ambiguous,
           Lain::Isolation::LandingQueue::Refused, Lain::Approval::Gate::NotApproved,
           EpicSubmit::PlanNotApproved].any? { |refusal| error.is_a?(refusal) }
        end

        def stood(moved)
          stalled = moved.reject(&:done).first
          said = format(NOT_LANDED, kind: stalled.report.kind)
          stalled.report.detail.to_s.empty? ? said : "#{said}: #{stalled.report.detail}"
        end

        def reported(entry, reason) = @reported << Reported.new(issue_id: entry.issue_id, reason:)

        def result = Result.new(landed: @landed, reported: @reported, stopped: @stopped)
      end

      # The epic's loop: fold, launch an issue actor per runnable issue up to a
      # width, retire each as it settles, submit what it anchored to that issue's
      # implementation gate, and land it through the queue.
      #
      # THE REFOLD IS THE DEPENDENCY ORDER. Nothing here holds a wave or a
      # topological sort: an issue is runnable when the fold says its blockers
      # are done, and the fold is re-read after every landing. So a chain runs in
      # order because each landing is what makes the next issue ready, and two
      # independent issues run together because nothing made either wait.
      #
      # NOTHING REACHES THE WORKING BRANCH BEFORE ITS GATE. Retirement anchors
      # and never merges; the gate stands between the anchor and the queue; and
      # the queue is the only thing in this loop that merges anything.
      #
      # ONE ISSUE'S TROUBLE IS ONE ISSUE'S. Every step after the launch can
      # refuse, and each refusal stops that issue, records why, and leaves the
      # loop running -- because a Result that already carries a landing must
      # survive whatever the next issue does.
      class Run
        # Reopened rather than nested mid-body: the split keeps each class body
        # within Metrics/ClassLength instead of loosening it.

        # Asking one issue's gate, in a way a human can interrupt.
        #
        # A gate parks on a person, and a person may be asleep. Asked straight,
        # the wait is unbreakable: a Ctrl-C at 3am would sit behind a five-minute
        # window before the loop noticed the run was over. So wherever there is a
        # reactor to spawn one, the gate is asked on a fiber of its own and this
        # watches both it and the interrupt.
        #
        # Only the INTERRUPT is watched, not the budget: nothing lands while a
        # gate waits, so the budget cannot change mid-wait.
        #
        # Outside a reactor -- a unit spec driving the loop directly -- there is
        # no fiber to spawn and nothing that could interrupt, so the gate is
        # simply called.
        class Asking
          # The gate did not answer because the run ended first.
          STOPPED = :stopped

          # @param gate [#call] `call(issue_id, sha:)`
          # @param interrupt [#call] answers whether the run should stop
          # @param poll [Numeric] seconds between looking up from the wait
          def initialize(gate:, interrupt:, poll: POLL)
            @gate = gate
            @interrupt = interrupt
            @poll = poll
          end

          # @return [Boolean, Symbol] the gate's answer, or {STOPPED}
          def call(issue_id, sha:)
            task = Async::Task.current?
            return @gate.call(issue_id, sha:) if task.nil?

            awaited(task.async { @gate.call(issue_id, sha:) })
          end

          private

          # `return` rather than `break`, so the loop reads as the two answers it
          # has: the gate settled, or the run is over. A gate that RAISED
          # re-raises here, where the caller turns it into that issue's report.
          def awaited(asking)
            loop do
              return asking.wait if asking.finished?
              return stopped(asking) if @interrupt.call

              sleep(@poll)
            end
          end

          def stopped(asking)
            asking.stop
            STOPPED
          end
        end

        # The grading hook's Null: nobody is benching an ordinary
        # `/implement-epic` run, so it judges nothing and the loop is exactly
        # what it was before the seam existed. A module answering the one
        # message rather than a class to subclass -- what a caller supplies is a
        # `#call`, never a type.
        module Ungraded
          def self.call(_issue_id, _registration) = nil
        end

        # What a run may do before it stops of its own accord: how many issues
        # it carries at once, how many it may land in all, and what answers
        # whether it should stop now. ONE value because {Run#stop_reason} reads
        # them as one question -- and because naming them apart is what put
        # `#initialize` over Metrics/MethodLength.
        Bounds = Data.define(:width, :budget, :interrupt)

        # One issue whose work reached the working branch.
        Landed = Data.define(:issue_id, :sha) do
          def initialize(issue_id:, sha:) = super(issue_id: -issue_id.to_s, sha: -sha.to_s)
        end

        # One issue the run did not carry, and the sentence a human acts on. Not
        # a failure: an issue waiting on its plan is the ordinary case, and
        # planning it is the human's job rather than the driver's.
        Reported = Data.define(:issue_id, :reason) do
          def initialize(issue_id:, reason:) = super(issue_id: -issue_id.to_s, reason: -reason.to_s)
        end

        # What a run came to. `stopped` is nil when the loop ran out of runnable
        # issues on its own, and says why when something ended it early.
        #
        # Deeply frozen, like every other value here: the members are interned
        # and the collections copied, so `Ractor.shareable?` holds.
        Result = Data.define(:landed, :reported, :stopped) do
          def initialize(landed:, reported:, stopped:)
            super(landed: landed.dup.freeze, reported: reported.dup.freeze, stopped: stopped && -stopped)
          end

          # @return [String] the reply the human reads at `you>`
          def to_s = [*landed_lines, *reported_lines, *stopped_lines, summary].join("\n")

          private

          def landed_lines = landed.map { |entry| "landed #{entry.issue_id} at #{entry.sha}" }

          def reported_lines = reported.map { |entry| "#{entry.issue_id}: #{entry.reason}" }

          def stopped_lines = stopped.nil? ? [] : [stopped]

          def summary = "#{landed.size} landed, #{reported.size} left for you"
        end
      end
    end
  end
end
