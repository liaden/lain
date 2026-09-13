# frozen_string_literal: true

require "async"
require "fileutils"

module Lain
  module CLI
    # What carries an epic's issues from the chat: each issue launched as an
    # actor in a checkout of its own, once its failing tests exist.
    #
    # {IssueActor} and {PlanSubject} are files of their own: the actor owns a
    # lifecycle, and the plan's declaration is read from outside this subtree.
    module EpicDriver
      # A chat that is in no epic was asked to drive one. Its own class, and a
      # {Lain::Error}, so the Repl renders it loudly rather than as a backtrace.
      class NoEpicMounted < Error; end

      # The conductor arrives as the OBJECT rather than as a thunk over its
      # state, so that what a caller hands this value is the collaborator
      # itself and the question asked of it -- whether the session is closed --
      # is spelled once, here, beside the run it stops. Every other member is a
      # plain value, taken after {Wiring#wire_agent} has settled them.
      # `grading` is what makes the driver's own hook reachable from outside the
      # chat: a bench holds these seams, not the Factory's constructor, so a
      # grader bound per issue has to ride here or it cannot be bound at all. It
      # DEFAULTS, because an ordinary chat lends none and must construct exactly
      # as it did.
      Seams = Data.define(:mount, :paths, :journal, :toolset_build, :asker, :conductor, :grading) do
        def initialize(mount:, paths:, journal:, toolset_build:, asker:, conductor:, grading: nil)
          super
        end

        # @param root [String] the project root, which is the checkout the
        #   epic's branch is cut in and landed onto
        # @param library [Skill::Library] the run's ONE skill library
        # @param chronicle [Chronicle] the chat's record
        # @return [Factory, Factory::Unmounted]
        def driver(root:, library:, chronicle:)
          Factory.for(mount:, chronicle:, paths:, root:, library:, journal:, toolset_build:, asker:,
                      grading:, interrupt: stopping)
        end

        private

        # A run stops between issues once the human has closed the session, so
        # a Ctrl-C at the prompt ends the loop rather than leaving it driving
        # an epic nobody is watching.
        def stopping = -> { conductor.closed? }
      end

      # What a chat seated in an epic can drive, built from the ONE mount the
      # seat resolved.
      #
      # The collaborators here are the ones an epic may NOT share with the chat
      # around it. Its Supervisor leases worktrees cut from `epic/<slug>`
      # whatever `--isolation` the chat was started with, because an epic that
      # ran in the human's own tree would have several issues editing one
      # checkout. Its retirement anchors and never merges, so the gate in front
      # of each issue is real. It lands in a checkout of lain's own, because the
      # queue merges only on the epic's branch and a human's chat stands
      # wherever they left it. What it DOES share is the chat's journal, its
      # asker and its toolset: a parked approval reaches the human already
      # draining questions, and the epic's Subagent is built from the same
      # capability floor every other child attenuates from.
      class Factory
        UNMOUNTED = "this chat is in no epic, so there is nothing to implement -- start one with " \
                    "`lain chat --epic SLUG`, and `lain epic status` lists the epics this project has"

        # Where lain checks out the epic's branch to land on, under the same
        # worktree root the issue actors lease from.
        LANDING = "landing"

        # No epic mounted, so no epic to drive. A refusing Null rather than nil:
        # the command is registered in every chat, reads this through the Env
        # like any other collaborator, and never writes `if env.epic_driver`.
        #
        # It answers the WHOLE published surface, not merely `#run`: a caller
        # reaching for the isolation or the supervisor hears the same named
        # refusal, where a missing method would be a NoMethodError three frames
        # from the fact that this chat is in no epic.
        module Unmounted
          def self.mounted? = false

          def self.slug = nil

          def self.run(**) = refuse

          def self.isolation = refuse

          def self.retirement = refuse

          def self.supervisor = refuse

          def self.attempts = refuse

          def self.refuse = raise(NoEpicMounted, UNMOUNTED)
          private_class_method :refuse
        end

        # One issue's implementation gate, submitted over the commit its
        # retirement anchored.
        #
        # It ASKS THE RECORD rather than reading the verdict's prose: a submit
        # answers a rendered String, and a policy that parked has journaled a
        # deferral whose shape the landing reads back the same way. So the
        # question "may this land" is answered by the same records that will
        # answer it at the queue, and the two cannot disagree.
        #
        # ONE GATE AT A TIME, which the loop guarantees by settling one actor at
        # a time: the chat's asker admits a single outstanding question, so two
        # issues asking at once would refuse the second.
        class Gate
          # @param submit [EpicSubmit] the in-process gate
          # @param slug [String] the epic
          # @param journals [#call] answers this project's sign-off records,
          #   re-read after the submit so a decision just made is visible
          def initialize(submit:, slug:, journals:)
            @submit = submit
            @slug = slug
            @journals = journals
          end

          # @param issue_id [String] whose gate this is
          # @param sha [String] the anchored commit
          # @return [Boolean] whether the gate approved this exact commit
          def call(issue_id, sha:)
            @submit.submit("implementation", @slug, issue: issue_id, digest: sha)
            approved?(issue_id, sha)
          end

          private

          def approved?(issue_id, sha)
            Lain::Forge::LocalLanding::Approvals.from(@journals.call)
                                                .approved?(address(issue_id, sha), issue_id)
          end

          def address(issue_id, sha)
            Lain::Epic::Submission.implementation(slug: @slug, issue_id:, digest: sha).digest
          end
        end

        # The landing queue, as the run drives it -- and the only thing in the
        # whole loop that merges. Rebuilt per issue because every check it makes
        # is over records this run has been writing: the gate decision it just
        # journaled, and the transitions of whatever landed before it.
        class Landing
          # @param slug [String] the epic
          # @param root [String] the checkout that stands on the epic's branch,
          #   which is lain's own wherever the human's does not
          # @param paths [Paths] where the session journals are read from
          # @param base [Isolation::WorkingBranch] `epic/<slug>`
          # @param config [Config::Isolation] the merge strategy and retry count
          # @param journal [#<<] where each landing's records go
          # @param epics [CLI::Epic] answers the epic's progress, read fresh
          # @param submit [EpicSubmit] re-checks the plan approval at land time
          def initialize(slug:, root:, paths:, base:, config:, journal:, epics:, submit:)
            @slug = slug
            @root = root
            @paths = paths
            @base = base
            @config = config
            @journal = journal
            @epics = epics
            @submit = submit
          end

          # @param issue_id [String] the issue whose work this is
          # @param sha [String] the anchored commit
          # @param ref [String] the anchor it stands on
          # @return [Array<Forge::LocalLanding::Landed>]
          def call(issue_id, sha:, ref:)
            landing.call(issue_id, sha:, ref:).landed
          end

          private

          def landing
            Lain::Forge::LocalLanding.new(
              epic_slug: @slug, repo_root: @root, base: @base, approvals:,
              plan: ->(issue) { @submit.ensure_plan_approved!(issue, @slug) },
              progress: -> { @epics.progress(@slug) },
              scribe: Lain::Epic::Scribe.new(epic_slug: @slug, journal: @journal),
              queue:, layout: Lain::Config.test_layout(root: @root), landings: -> { landed_records }
            )
          end

          # Spelled in a method body rather than as a constant: this unit loads
          # before `lain/forge`, so naming it in the class body is a NameError
          # at boot.
          def landed_records = records(Lain::Forge::LocalLanding::LANDED).to_a

          def queue
            Lain::Isolation::LandingQueue.new(repo_root: @root, base: @base, journal: @journal,
                                              retries: @config.rebase_retries,
                                              strategy: Lain::Isolation::MergeStrategy.from(@config))
          end

          def approvals
            Lain::Forge::LocalLanding::Approvals.from(records(Approval::SignoffQueue::JOURNAL_TYPE).to_a)
          end

          # FRESH per read, for {SessionJournals}' own reason: it caches its walk.
          def records(type) = SessionJournals.new(dir: @paths.sessions_dir, types: [type])
        end

        # @param mount [EpicMount, EpicMount::NoEpic] the seat's ONE mount
        # @param seams [Hash] forwarded to {#initialize} for a real mount
        # @return [Factory, Unmounted]
        def self.for(mount:, **seams)
          return Unmounted if mount.equal?(EpicMount::NoEpic)

          new(mount:, **seams)
        end

        # @param mount [EpicMount] which epic this chat is seated in, already
        #   resolved -- never mounted a second time here, because a second
        #   {Epic::Review} over one journal stops guarding in silence
        # @param chronicle [Chronicle] the chat's record; its journal is where
        #   every gate decision and landing of this run lands
        # @param paths [Paths] the state home the sessions directory resolves under
        # @param root [String] the project root, and the repository the epic's
        #   branch lives in
        # @param library [Skill::Library] the run's ONE library
        # @param journal [#<<] the chat's channel, where isolation and handback
        #   records land
        # @param toolset_build [Wiring::ToolsetBuild] where the epic's Subagent
        #   and the run's role spawn come from
        # @param asker [#ask, nil] who answers an interactive implementation
        #   gate; the chat's own asker, so a parked call reaches the human who
        #   is already draining questions
        # @param config [Config] `.lain/config.toml`, already read
        # @param interrupt [#call] answers whether the run should stop
        # @param actors [#call, nil] `fleet ->` what launches an issue; the
        #   real {IssueActor} when nobody says otherwise
        # @param grading [#call, nil] `call(issue_id, registration)`, judged
        #   between an actor settling and its retirement, while its lease still
        #   holds the checkout; nil grades nothing. A bench binds its own
        #   per-issue grader here.
        def initialize(mount:, chronicle:, paths:, root:, library:, journal:, toolset_build:,
                       asker: nil, config: nil, interrupt: -> { false }, actors: nil, grading: nil)
          @mount = mount
          @chronicle = chronicle
          @paths = paths
          @root = root
          @library = library
          @journal = journal
          @toolset_build = toolset_build
          # The five a caller may leave to this object: who answers a gate, the
          # project's config, when to stop, what launches an issue, and what
          # grades one. ONE slot because what they have in common is that a
          # chat supplies none of them -- the required seven above are the
          # object's shape, and these are the seams a bench or a spec lends.
          @optional = { asker:, config:, interrupt:, actors:, grading: }
        end

        def mounted? = true

        def slug = @mount.slug

        # The backend every issue actor leases from: worktrees cut from the
        # epic's own branch, whatever `--isolation` the chat was started with.
        # An epic that ran in the chat's tree would have its issues editing one
        # checkout at once.
        #
        # LAZY, and that is not an optimization: a chat is seated in its epic at
        # startup, while this cuts and marks `epic/<slug>` -- so a project that
        # is not a git repository must still be able to open a chat in an epic
        # and be told what it cannot do only when it asks for it.
        def isolation
          @isolation ||= Lain::Isolation::Worktree.new(root: worktree_root, repo_root: @root, base: working_branch,
                                                       paths: @paths)
        end

        # Anchor-only: a settled actor's commits go onto its ref and no further,
        # so the issue's implementation gate stands between the work and the
        # branch. It is also what makes every adopted actor's environment
        # editorless, so a rebase it is asked to finish opens no editor.
        def retirement
          Lain::Supervisor::Retirement.over(isolation:, journal: @journal, strategy:,
                                            retries: settings.rebase_retries)
        end

        # FRESH per call: one reactor per Supervisor life, so driving the same
        # epic twice in one chat is a second run rather than an AlreadyRunning
        # refusal.
        def supervisor
          Lain::Supervisor.new(journal: @journal, isolation:, retirement:)
        end

        # WHICH ATTEMPT AN ISSUE'S NEXT LAUNCH TAKES, read from the repository
        # rather than carried in memory. An attempt's anchor outlives the run
        # that made it, and a second attempt under a standing anchor is refused
        # loudly -- so the next attempt is the first whose anchor is absent,
        # which makes a retry after a failed run actually launch.
        def attempts = @attempts ||= method(:next_attempt)

        # @param width [Integer] how many issues are carried at once
        # @param budget [Integer, nil] how many issues the whole run may land
        # @return [Run::Result]
        def run(width: Run::WIDTH, budget: nil)
          Sync do |task|
            fleet = supervisor.run(task)
            begin
              loop_over(fleet, width:, budget:).call
            ensure
              fleet.stop
            end
          end
        end

        private

        def loop_over(fleet, width:, budget:)
          Run.new(progress: -> { epics.progress(slug) }, plans: method(:plan_for), actors: actors(fleet),
                  supervisor: fleet, gate:, landing:, width:, budget:, attempts:,
                  interrupt: @optional.fetch(:interrupt), grading: @optional.fetch(:grading) || Run::Ungraded)
        end

        def gate = Gate.new(submit:, slug:, journals: method(:signoffs))

        # The landing runs in LAIN'S OWN checkout, never the human's -- see
        # {#landing_root}.
        def landing
          Landing.new(slug:, root: landing_root, paths: @paths, base: working_branch, config: settings,
                      journal: record, epics:, submit:)
        end

        # WHERE THE QUEUE MERGES. It refuses unless the checkout it works in
        # stands on the epic's branch, and a human's chat stands wherever they
        # left it -- usually `main`. Switching their checkout under them is not
        # ours to do, so lain cuts a worktree of its own, checked out on the
        # branch, beside the ones the actors lease. A chat that already stands
        # on the branch needs none, and lands where it is.
        def landing_root
          @landing_root ||= working_branch.current_in?(parent) ? @root : cut_landing
        end

        def cut_landing
          path = File.join(worktree_root, LANDING)
          return path if standing_on?(path)

          FileUtils.mkdir_p(File.dirname(path))
          added = parent.run("worktree", "add", path, working_branch.name)
          raise Lain::Error, refused_landing(path, added) unless added.exitstatus.zero?

          path
        end

        # An earlier run's landing checkout is reused where it stands, so a
        # chat driving its epic twice does not accumulate worktrees.
        def standing_on?(path)
          Dir.exist?(path) && checkout(path).symbolic_head == working_branch.ref
        end

        def refused_landing(path, shell)
          "lain could not check out #{working_branch.name} at #{path} to land on, so nothing was merged: " \
            "#{shell.stderr.to_s.strip}"
        end

        # The issue's plan, as it stands now: approved, and declaring the one
        # source file its failing tests are written for.
        def plan_for(issue_id)
          submit.ensure_plan_approved!(issue_id, slug)
          PlanSubject.read(@mount.home.plan(issue_id), layout: Lain::Config.test_layout(root: @root))
        end

        def actors(fleet)
          lent = @optional.fetch(:actors)
          return lent.call(fleet) unless lent.nil?

          IssueActor.new(slug:, supervisor: fleet, subagent: @toolset_build.method(:epic_subagent),
                         tests: issue_tests, renderer: @library.renderer, home: @mount.home,
                         plan: ->(issue_id) { submit.ensure_plan_approved!(issue_id, slug) },
                         repo_root: @root, lanes: child_lanes)
        end

        def issue_tests
          IssueTests.new(renderer: @library.renderer, role_spawn: @toolset_build.role_spawn)
        end

        # The orchestrator's own children lease here, cut from the ISSUE's
        # branch rather than the epic's -- a root of their own so their
        # checkouts cannot collide with the issue actors' above them.
        def child_lanes
          IssueActor::Lanes.new(root: File.join(worktree_root, "children"), role_spawn: @toolset_build.role_spawn,
                                journal: @journal, strategy:)
        end

        # The first attempt whose anchor is not standing. Bounded only by the
        # anchors that exist, which is one per attempt actually made.
        def next_attempt(issue_id)
          (1..).find { |attempt| parent.target(anchor_of(issue_id, attempt)).empty? }
        end

        def anchor_of(issue_id, attempt)
          Lain::Isolation::Worktree::Handback::Naming.new("issue.#{slug}.#{issue_id}.#{attempt}").ref
        end

        # Built once per factory so the run's gate, its landing and its
        # retirement all name the same branch object.
        def working_branch
          @working_branch ||= Lain::Isolation::WorkingBranch.epic(slug, repo_root: @root)
        end

        def parent = @parent ||= checkout(@root)

        def checkout(dir) = Lain::Isolation::Checkout.new(dir)

        def worktree_root = IsolationBackend.worktree_root(@root, paths: @paths)

        def strategy = Lain::Isolation::MergeStrategy.from(settings)

        def settings = config.isolation

        def config = @config ||= @optional.fetch(:config) || Lain::Config.load(root: @root)

        def epics = @epics ||= Epic.new(root: @root, paths: @paths, config:)

        # The chat's own journal, which is where a decision has to land: the
        # read-back that judges an approval re-walks the sessions directory this
        # file lives in.
        def record = @chronicle.record_journal

        # Lent, never closed: it is the chat's, and the chat goes on using it.
        def submit
          @submit ||= EpicSubmit.new(root: @root, paths: @paths, config:, asker: @optional.fetch(:asker),
                                     journal: record, epics:)
        end

        # FRESH per read, never memoized: a decision this run just journaled has
        # to be visible to the very next question about it.
        def signoffs
          SessionJournals.new(dir: @paths.sessions_dir, types: [Approval::SignoffQueue::JOURNAL_TYPE]).to_a
        end
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

        # One issue's work, from the launch that started it to the retirement
        # that ends it.
        Live = Data.define(:issue_id, :launch)

        # What a run may do before it stops of its own accord: how many issues
        # it carries at once, how many it may land in all, and what answers
        # whether it should stop now. ONE value because {Run#stop_reason} reads
        # all three as one question -- whether this run may start another
        # issue -- and nothing else ever reads any of them alone.
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

      # An issue's red step, run in the checkout its actor holds before the
      # actor's first turn: tests generated from the issue's approved criteria
      # into the file the project's test layout mirrors from the subject, run
      # there, and committed on the checkout's branch only once they fail.
      #
      # Every refusal stops the issue with nothing committed. A project with no
      # `[tests]` table is refused rather than handed a layout detected from
      # its files, because enforcement is opt-in: a detected preset would
      # impose level roots the project never declared. Tests that pass before
      # any work is done are refused too. They check nothing the work will
      # change, so the criteria or the generation are wrong, and a human has
      # to look.
      class IssueTests
        class NoLayout < Error; end
        class NotGenerated < Error; end
        class AlreadyGreen < Error; end
        class Uncommitted < Error; end

        # What the step left: the generation's record, the failing run, and the
        # commit holding the tests.
        Red = Data.define(:record, :run, :sha)

        # @param renderer [Skill::Renderer] renders the test-writing scaffold
        # @param role_spawn [Skill::RoleSpawn] the run's role spawn; its
        #   test_engineer child is lent the held checkout rather than leasing one
        # @param harness [#call] `root -> #run`, the suite runner over a checkout
        # @param shell_out_factory [#call] builds the git subprocess runner
        def initialize(renderer:, role_spawn:, harness: Lain::Grader::TestHarness.public_method(:new),
                       shell_out_factory: Lain::Shell::Out.public_method(:new))
          @renderer = renderer
          @role_spawn = role_spawn
          @harness = harness
          @shell_out_factory = shell_out_factory
        end

        # @param criteria [Gherkin::Criteria] the issue's approved criteria
        # @param worker_env [WorkerEnv] the held checkout, on the issue's branch
        # @param subject [String] the source file the tests are for, relative to
        #   the checkout
        # @param level [String, nil] a level the layout declares; its default
        #   level when nil
        # @return [Red]
        # @raise [NoLayout, NotGenerated, AlreadyGreen, Uncommitted]
        def call(criteria, worker_env, subject:, level: nil)
          guard = Lain::TestLayout::Guard.new(layout: declared(worker_env.cwd), root: worker_env.cwd)
          record = generated(criteria, worker_env, guard, subject:, level: level || default_level(guard.layout))
          Red.new(record:, run: failing(record, worker_env), sha: commit(worker_env.cwd, record))
        end

        private

        def declared(root)
          layout = Lain::Config.test_layout(root:)
          return layout if layout.in_force?

          raise NoLayout, "#{root} declares no test layout, so the issue's failing tests have nowhere the " \
                          "layout guard would accept them: add a [tests] table to .lain/config.toml naming " \
                          "its preset and source roots"
        end

        def default_level(layout)
          level = layout.mapping.default_level
          return level.name unless level.nil?

          raise NoLayout, "the [tests] table declares no level whose tests mirror their sources, so there is " \
                          "no level to generate the issue's tests at"
        end

        def generated(criteria, worker_env, guard, subject:, level:)
          record = Lain::Gherkin::TestGeneration.new(renderer: @renderer, role_spawn: @role_spawn.within(worker_env),
                                                     guard:).call(criteria, subject:, level:)
          return record if record.generated?

          raise NotGenerated, "the test_engineer child left no tests the layout accepts at #{record.target} " \
                              "(#{record.verdict}), so nothing was committed"
        end

        def failing(record, worker_env)
          run = @harness.call(worker_env.cwd).run(worker_env, paths: [record.target])
          return run unless run.clean?

          raise AlreadyGreen, "#{record.target} ran #{run.total} examples and none failed before any work was " \
                              "done, so they check nothing the work will change: the criteria or the " \
                              "generation are wrong, and nothing was committed"
        end

        # The target alone, even when the child left other files, so the red
        # commit holds the tests and nothing else. `--no-verify` because the
        # commit fails by design: a hook that runs the suite would refuse
        # exactly the state this step exists to record.
        def commit(root, record)
          git = Lain::Isolation::Checkout.new(root, shell_out_factory: @shell_out_factory)
          committed!(git.run("add", "--", record.target))
          committed!(git.run("commit", "--no-verify", "-q", "-m", message(record), "--", record.target))
          git.head.stdout.strip
        end

        def committed!(shell)
          return if shell.exitstatus.zero?

          raise Uncommitted, "git refused the failing tests' commit: #{shell.stderr.strip}"
        end

        def message(record) = "test: failing tests at #{record.target}, from criteria #{record.criteria_digest}"
      end
    end
  end
end
