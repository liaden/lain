# frozen_string_literal: true

require "async"
require "fileutils"

module Lain
  module CLI
    module EpicDriver
      # A chat that is in no epic was asked to drive one. Its own class, and a
      # {Lain::Error}, so the Repl renders it loudly rather than as a backtrace.
      class NoEpicMounted < Error; end

      # The conductor arrives as the OBJECT rather than as a thunk over its
      # state, and that is what keeps {Wiring#assemble_surface} inside
      # Metrics/AbcSize: a `-> { @conductor.closed? }` written at the call site
      # spends that method a send it has no room for, while the same lambda
      # built here costs it nothing. Every other member is a plain value, taken
      # after {Wiring#wire_agent} has settled them.
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

      class Factory # rubocop:disable Style/Documentation -- doc lives on the reopen below
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
          # grades one. One slot because they are the OPTIONAL half, and naming
          # them apart bought nothing but the line that put #initialize over
          # Metrics/MethodLength.
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
        # Reopened rather than nested mid-body: the split keeps each class body
        # within Metrics/ClassLength instead of loosening it.

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
      end
    end
  end
end
