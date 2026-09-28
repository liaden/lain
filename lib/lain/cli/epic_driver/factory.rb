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
      #
      # `ladder` rides for `grading`'s reason and is the answer to "bind a rung":
      # the QA rungs a checkpoint climbs are otherwise {QA::SessionTiers}' default,
      # whose voice settles nothing, so a caller with measured models -- a bench
      # comparing tier bindings above all -- has to be able to lend its own. It
      # DEFAULTS to nil, nobody said, and a run that says nothing runs the default.
      #
      # `endpoint` is the run's own edge onto WHERE ITS MODELS RUN, named here
      # rather than reached for through `toolset_build`: that seam is how the
      # epic spawns its children, and asking it a question about servers would
      # make the driver's default depend on the subagent wiring. It is a plain
      # string and the driver only ever asks {Run.width_for} about it, so
      # nothing here holds a provider. It DEFAULTS to nil -- nobody said -- and
      # a run that says nothing carries exactly what it carried before.
      Seams = Data.define(:mount, :paths, :journal, :toolset_build, :asker, :conductor, :grading, :endpoint,
                          :ladder) do
        def initialize(mount:, paths:, journal:, toolset_build:, asker:, conductor:, grading: nil, endpoint: nil,
                       ladder: nil)
          super
        end

        # @param root [String] the project root, which is the checkout the
        #   epic's branch is cut in and landed onto
        # @param library [Skill::Library] the run's ONE skill library
        # @param chronicle [Chronicle] the chat's record
        # @return [Factory, Factory::Unmounted]
        def driver(root:, library:, chronicle:)
          Factory.for(mount:, chronicle:, paths:, root:, library:, journal:, toolset_build:, asker:,
                      grading:, endpoint:, ladder:, interrupt: stopping)
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

        # Where lain checks out an epic's branch to land on, under the same
        # worktree root the issue actors lease from: one checkout per epic, at
        # `landings/<slug>`, so two epics in one project land side by side.
        # Not `landing/`: that was the older per-project checkout itself, and a
        # checkout nested inside one still standing goes with it when gc
        # force-removes the old tree.
        LANDING = "landings"

        # The skill every QA rung is briefed with, which is the whole of what this
        # driver renders for a checkpoint.
        QA_SKILL = "qa"

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

          # A chat that is in no epic was asked to drive one. A {Lain::Error}, so
          # the Repl renders it loudly rather than as a backtrace.
          def self.refuse = raise(Error, UNMOUNTED)
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
          # @param layout [TestLayout] the PROJECT's, never read from `root`: lain's
          #   own checkout is cut by git, so a gitignored config never reaches it
          def initialize(slug:, root:, paths:, base:, config:, journal:, epics:, submit:, layout:)
            @slug = slug
            @root = root
            @paths = paths
            @base = base
            @config = config
            @journal = journal
            @epics = epics
            @submit = submit
            @layout = layout
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
              queue:, layout: @layout, landings: -> { landed_records }
            )
          end

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

        # Lain's own checkout of the epic's branch, which the landing queue
        # merges in.
        #
        # LOCKED WHILE A RUN HOLDS IT, as a lease is ({Isolation::Worktree}):
        # the add takes a lock naming this process in the same command. Every
        # merge moves the checkout's HEAD, and judged unlocked such a checkout
        # reads to `lain worktrees gc` as work folded into the branch, reaped
        # while the queue stands in it. The run's end drops the lock, leaving
        # a checkout gc may age out like any other; the next run cuts or
        # re-locks it.
        class LandingCheckout
          # A chat that already stands on the epic's branch lands where it is,
          # in the human's checkout, which is not lain's to lock.
          InPlace = Data.define(:root) do
            def release = nil
          end

          # @param repo_root [String] the project's repository
          # @param path [String] where lain's own checkout stands
          # @param branch [Isolation::WorkingBranch] `epic/<slug>`
          # @param process_table [Isolation::LeaseLock::ProcessTable] names this
          #   process in the lock, and judges a lock found standing
          # @param shell_out_factory [#call] builds the git subprocess runner
          def initialize(repo_root:, path:, branch:, process_table: Lain::Isolation::LeaseLock::ProcessTable.new,
                         shell_out_factory: Lain::Shell::Out.public_method(:new))
            @git = Lain::Isolation::Checkout.new(repo_root, shell_out_factory:)
            @registry = Lain::Isolation::Worktree::Registry.new(repo_root:, shell_out_factory:)
            @path = path
            @branch = branch
            @process_table = process_table
            @shell_out_factory = shell_out_factory
          end

          # @return [String] the checkout the queue merges in
          def root = @path

          # @return [self] with the checkout standing on the branch, locked
          # @raise [Error] when git will not add or lock it, or when something
          #   else still holds it
          def cut
            standing? ? relock : add
            self
          end

          # Only a lock this process wrote is dropped: one taken since by
          # anybody else is theirs.
          def release
            @registry.unlock(@path) if registered.any? { |entry| entry.seal == reason }
          end

          private

          # An earlier run's checkout is reused where it stands, so a chat
          # driving its epic twice does not accumulate worktrees.
          def standing?
            Dir.exist?(@path) &&
              Lain::Isolation::Checkout.new(@path, shell_out_factory: @shell_out_factory).symbolic_head == @branch.ref
          end

          def add
            FileUtils.mkdir_p(File.dirname(@path))
            refused!(@git.run("worktree", "add", "--lock", "--reason", reason, @path, @branch.name),
                     "could not check out #{@branch.name} at #{@path} to land on")
          end

          # git refuses to lock a locked tree, so a lock that holds nothing --
          # a crashed run's, a retention's, or this process's own -- is taken
          # down first, and one that still holds is refused rather than broken.
          def relock
            registered.each { |entry| taken!(entry) }
            refused!(@registry.lock(@path, reason), "could not lock its landing checkout at #{@path}")
          end

          # Taken over by {Isolation::Worktree::Registry#claim}, a compare-and-
          # swap against the lock as it was judged: two runs starting together
          # after a crash both judge the dead lock, and without the swap the
          # second would unlock the first one's live lock and both would merge
          # in one checkout. Between the claim and `worktree lock` the checkout
          # stands unlocked, and a gc there costs this run a loud refusal.
          def taken!(entry)
            unheld!(entry)
            return if @registry.claim(entry)

            raise Lain::Error, "lain's landing checkout at #{@path} was taken by another run while this one judged " \
                               "its lock, so this run will not merge in it"
          end

          def unheld!(entry)
            return if entry.seal == reason || !entry.lock.held?(@process_table)

            raise Lain::Error, "lain's landing checkout at #{@path} is #{entry.lock.why(@process_table)}, so this " \
                               "run will not merge in it -- stop whatever holds it, or `git worktree unlock` it " \
                               "once nothing does"
          end

          def registered
            spelled = Lain::Project::Resolver.spellings(@path, File)
            @registry.entries.select { |entry| Lain::Project::Resolver.spellings(entry.path, File).intersect?(spelled) }
          end

          def reason = @reason ||= @process_table.current.reason

          def refused!(shell, what)
            return if shell.exitstatus.zero?

            raise Lain::Error, "lain #{what}, so nothing was merged: #{shell.stderr.to_s.strip}"
          end
        end

        # Whether a retired tip carries nothing past the red step's commit.
        #
        # BY THE NET DIFF, NOT BY NAME OR BY COMMIT. Retirement rebases an
        # actor's branch onto the epic's tip, so a sibling that landed
        # meanwhile hands the red commit back under a new SHA; and a branch's
        # history can hide work in a merge or show an empty commit as a
        # change. What the tip would change on the epic is what counts: no
        # work is every path it changes being one the red commit wrote, with
        # the red commit's bytes.
        class RedOnly
          # @param git [Isolation::Checkout] the project's repository
          # @param base [Isolation::WorkingBranch] `epic/<slug>`
          def initialize(git:, base:)
            @git = git
            @base = base
          end

          # @param red [String] the red step's commit
          # @param tip [String] the commit retirement anchored
          # @return [Boolean]
          # @raise [Error] when git cannot compare the two
          def call(red, tip)
            return true if red == tip

            changed = paths("diff", "--name-only", "-z", "--no-renames", git!("merge-base", @base.ref, tip).strip, tip)
            (changed - paths("diff-tree", "-r", "--no-commit-id", "--name-only", "-z", "--no-renames", red)).empty? &&
              unchanged?(red, tip, changed)
          end

          private

          def paths(*) = git!(*).split("\0")

          # Pathspecs from the top and taken literally: a project nested in a
          # larger repository runs git from its own directory, and a file name
          # is never a glob.
          def unchanged?(red, tip, changed)
            changed.empty? || @git.run("diff", "--quiet", red, tip, "--",
                                       *changed.map { |path| ":(top,literal)#{path}" }).exitstatus.zero?
          end

          def git!(*args)
            shell = @git.run(*args)
            return shell.stdout if shell.exitstatus.zero?

            raise Lain::Error, "git #{args.first} could not say whether the retired work goes past its red commit: " \
                               "#{shell.stderr.strip}"
          end
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
        # @param endpoint [String, nil] where this run's models are dialled,
        #   which is all the driver ever needs to know about them -- see
        #   {Seams}. nil means nobody said, and {Run.width_for} reads that as
        #   hosted.
        # @param ladder [#call, nil] `-> QA::Ladder`, asked once per QA pass at a
        #   checkpoint; nil climbs {QA::SessionTiers}' default rungs against the
        #   landing checkout
        def initialize(mount:, chronicle:, paths:, root:, library:, journal:, toolset_build:,
                       asker: nil, config: nil, interrupt: -> { false }, actors: nil, grading: nil,
                       endpoint: nil, ladder: nil)
          @mount = mount
          @chronicle = chronicle
          @paths = paths
          @root = root
          @library = library
          @journal = journal
          @toolset_build = toolset_build
          # The seven a caller may leave to this object: who answers a gate, the
          # project's config, when to stop, what launches an issue, what grades
          # one, where its models run, and which rungs its QA climbs. ONE slot
          # because what they have in common is that a chat supplies none of them
          # -- the required seven above are the object's shape, and these are the
          # seams a bench or a spec lends.
          @optional = { asker:, config:, interrupt:, actors:, grading:, endpoint:, ladder: }
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
          Lain::Isolation::Worktree::Handback::Retirement.over(isolation:, journal: @journal, strategy:,
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

        # The landing checkout is held for exactly the run, and released by an
        # `ensure` around the whole of it: a raise out of the fold, an Async
        # stop of the task running it, and an untrapped signal all drop the
        # lock on the way out, which no issue's rescue would. A chat's own
        # traps swallow SIGINT and SIGTERM while a slash command runs, so from
        # a chat nothing interrupts a run mid-way at all.
        #
        # The layout is resolved ONCE per run, so every issue's plan, red step
        # and landing are judged under the same one.
        #
        # Issue branches an earlier run left are settled before anything is
        # leased, so no issue is cut while its branch is still in question.
        #
        # @param width [Integer, nil] how many issues are carried at once; nil
        #   leaves it to {Run.width_for}, which is where the order of the three
        #   answers is stated
        # @param budget [Integer, nil] how many issues the whole run may land
        # @param resumed [Boolean] whether the chat carrying the run was
        #   resumed, which keeps an earlier run's branches without asking
        # @return [Run::Result]
        def run(width: nil, budget: nil, resumed: false)
          width = Run.width_for(typed: width, configured: config.epics.width,
                                endpoint: @optional.fetch(:endpoint))
          holding(landing_checkout) do |checkout|
            Sync do |task|
              discarded = earlier.call(resumed:)
              fleet = supervisor.run(task)
              begin
                loop_over(fleet, checkout, layout, width:, budget:).call.with(discarded:)
              ensure
                fleet.stop
              end
            end
          end
        end

        private

        def holding(checkout)
          yield checkout
        ensure
          checkout.release
        end

        def loop_over(fleet, checkout, layout, width:, budget:)
          Run.new(progress: -> { epics.progress(slug) }, plans: ->(issue_id) { plan_for(issue_id, layout) },
                  actors: actors(fleet, layout), supervisor: fleet, gate:, landing: landing(checkout, layout), width:,
                  budget:, attempts:, red_only: RedOnly.new(git: parent, base: working_branch),
                  interrupt: @optional.fetch(:interrupt), grading: @optional.fetch(:grading) || Run::Ungraded,
                  qa_gate: qa_gate(checkout))
        end

        # QA runs WHERE THE CLUSTER LANDED: lain's own landing checkout, standing
        # on the epic's branch, which is the only tree in this run that holds what
        # the whole cluster merged into. Its findings are filed through the same
        # write path `lain epic add` takes, so a fix is an ordinary issue from then
        # on.
        def qa_gate(checkout)
          QaGate.new(check: cluster_qa(checkout), filing: ->(issue) { epics.file(issue, slug) },
                     scribe: Lain::Epic::Scribe.new(epic_slug: slug, journal: record))
        end

        def cluster_qa(checkout)
          QaGate::ClusterQa.new(ladder: @optional.fetch(:ladder) || session_ladder(checkout))
        end

        # The ladder is built when a checkpoint is FIRST READY, never at wiring
        # time: an epic with no checkpoint renders no QA skill and spawns nothing,
        # and a fresh ladder per pass is a fresh per-rung budget. The rungs are
        # {Lain::QA::SessionTiers}' default binding, whose own docstring holds the
        # measurement a caller overrules by lending a ladder of its own -- which is
        # the only way to overrule it today, there being no `[qa]` config table.
        def session_ladder(checkout)
          lambda do
            spawn = @toolset_build.role_spawn.within(Lain::WorkerEnv.default.with(cwd: checkout.root))
            Lain::QA::Ladder.new(rungs: Lain::QA::SessionTiers.call(spawn), brief: @library.renderer.render(QA_SKILL))
          end
        end

        def gate = Gate.new(submit:, slug:, journals: method(:signoffs))

        def earlier
          IssueActor::Earlier.new(slug:, repo_root: @root, asker: @optional.fetch(:asker) || IssueActor::Earlier::Unasked,
                                  journal: record)
        end

        # The landing runs in LAIN'S OWN checkout, never the human's -- see
        # {#landing_checkout}.
        def landing(checkout, layout)
          Landing.new(slug:, root: checkout.root, paths: @paths, base: working_branch, config: settings,
                      journal: record, epics:, submit:, layout:)
        end

        # WHERE THE QUEUE MERGES. It refuses unless the checkout it works in
        # stands on the epic's branch, and a human's chat stands wherever they
        # left it -- usually `main`. Switching their checkout under them is not
        # ours to do, so lain cuts a worktree of its own, checked out on the
        # branch, beside the ones the actors lease. A chat that already stands
        # on the branch needs none, and lands where it is.
        def landing_checkout
          return LandingCheckout::InPlace.new(root: @root) if working_branch.current_in?(parent)

          LandingCheckout.new(repo_root: @root, path: File.join(worktree_root, LANDING, slug),
                              branch: working_branch).cut
        end

        # THE PROJECT'S LAYOUT, from the project root. Every checkout this run
        # works in -- an issue's lease, lain's landing checkout -- is cut by
        # git, and a `.lain/config.toml` the project keeps out of history is in
        # none of them: read there, the red step refused every issue and the
        # landing guard checked nothing.
        def layout = Lain::Config.test_layout(root: @root)

        # The issue's plan, as it stands now: approved, and declaring the one
        # source file its failing tests are written for.
        def plan_for(issue_id, layout)
          submit.ensure_plan_approved!(issue_id, slug)
          PlanSubject.read(@mount.home.plan(issue_id), layout:)
        end

        def actors(fleet, layout)
          lent = @optional.fetch(:actors)
          return lent.call(fleet) unless lent.nil?

          IssueActor.new(slug:, supervisor: fleet, subagent: @toolset_build.method(:epic_subagent),
                         tests: issue_tests(layout), renderer: @library.renderer, home: @mount.home,
                         plan: ->(issue_id) { submit.ensure_plan_approved!(issue_id, slug) },
                         repo_root: @root, lanes: child_lanes)
        end

        def issue_tests(layout)
          IssueTests.new(renderer: @library.renderer, role_spawn: @toolset_build.role_spawn, layout:)
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

        def parent = @parent ||= Lain::Isolation::Checkout.new(@root)

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
        # than five. That is a HOSTED number: both halves of it assume the
        # second issue can make progress while the first is mid-turn.
        WIDTH = 2

        # What a run carries when its models are served from THIS machine, and a
        # second constant rather than a smaller {WIDTH} because the argument is a
        # different one -- which is why the two cannot be stated in one sentence.
        # {Provider::Admission} already holds a local endpoint to one request in
        # flight, so the spare time {WIDTH} spends a second issue in does not
        # exist here: a sibling on the same model waits, and a sibling on a
        # DIFFERENT model makes the server swap, which the probes measured at
        # 16-20s on a 30B and which throws away the prefix cache it had warmed.
        # Nothing here re-decides admission -- this only stops the driver
        # offering a one-at-a-time server more issues than it can serve, so the
        # number is REUSED from the gate rather than restated beside it.
        #
        # It defers to the gate's DEFAULT, and only to that.
        # {Provider::Admission::ENV_KEY} widens or disables the gate at runtime
        # and nothing here reads it, so an operator who sets it to 4 locally
        # gets a gate of 4 and a driver of 1 -- conservative, and never {Busy},
        # but not the same number.
        LOCAL_WIDTH = Provider::Admission::DEFAULT_WIDTH

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

        # A QA pass that RAISED holds its checkpoint, the way a refused launch
        # stops only its own issue: nothing a checkpoint blocks may start on a QA
        # that never ran.
        QA_UNRUN = "QA could not run, so the checkpoint holds everything it blocks: %<why>s"

        NOTHING_COMMITTED = "its actor settled having committed nothing, so there was no implementation to submit"

        # The red step commits before the actor's first turn, so an actor that
        # made no commit of its own retires with the red commit as its tip.
        NO_WORK = "its actor settled having committed no work beyond its failing tests at %<sha>s, so there was " \
                  "no implementation to submit"

        ANCHOR_REFUSED = "its work could not be anchored, so nothing was submitted"

        GATE_PARKED = "its implementation gate has not approved %<sha>s, so nothing landed"

        UNCARRIED = "it could not be carried any further, so nothing landed"

        UNREADABLE = "the run stopped because a session journal could not be read, so it carried nothing further: " \
                     "%<why>s"

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

        # How many issues to carry, stated in ONE place because the order is the
        # rule: a human who typed `--width N` meant it, a project that declared
        # `[epics] width` meant it for every run of theirs, and only when neither
        # spoke does where the models run get to decide.
        #
        # Both spoken answers are held to {Config::Epics.width!} rather than to
        # a third refusal written here. Being the single decision point is what
        # obliges this method to refuse at all: a zero reaches {Bounds}, which
        # guards nothing, and `room?` then compares the live count against it,
        # so the loop launches nothing and reports nothing wrong. The refusal
        # names `[epics]` even for a typed width, because one wording is the
        # point of borrowing the check.
        #
        # @param typed [Integer, nil] `--width N`
        # @param configured [Integer, nil] `[epics] width`
        # @param endpoint [String, nil] where this run's models are dialled
        # @return [Integer]
        # @raise [Config::Refusal] when either spoken width is not a whole
        #   number of issues above zero
        def self.width_for(typed: nil, configured: nil, endpoint: nil)
          Lain::Config::Epics.width!(typed) || Lain::Config::Epics.width!(configured) || derived_width(endpoint)
        end

        # An endpoint NOBODY NAMED is hosted, and that guard lives here rather
        # than in {Provider::Admission::Endpoint.local?}: the predicate reads an
        # empty base as a filesystem path and answers true, which is right for
        # it (a unix socket IS local) and wrong for silence. A false local here
        # would quietly serialise a hosted run at one issue.
        #
        # The predicate itself is reused rather than restated. Locality is asked
        # in one place in lain, and a second spelling of it is how the two come
        # to disagree about `0.0.0.0` or a trailing dot.
        def self.derived_width(endpoint)
          return WIDTH if endpoint.to_s.empty?

          Provider::Admission::Endpoint.local?(endpoint) ? LOCAL_WIDTH : WIDTH
        end
        private_class_method :derived_width

        # The red-step judge by identity alone, for callers whose retired tips
        # are never rebased. Blind to a rebase, so never a default: the Factory
        # lends {Factory::RedOnly}.
        module Identical
          def self.call(red, tip) = red == tip
        end

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
        # `discarded` is the earlier run's issue branches the human had deleted
        # before this one leased anything, each speaking its own line.
        #
        # Deeply frozen, like every other value here: the members are interned
        # and the collections copied, so `Ractor.shareable?` holds.
        #
        # `audited` is the QA checkpoints this run RELEASED. A checkpoint QA held
        # is `reported` instead, because what it filed is work left for a human to
        # plan.
        Result = Data.define(:landed, :reported, :stopped, :discarded, :audited) do
          def initialize(landed:, reported:, stopped:, discarded: [], audited: [])
            super(landed: landed.dup.freeze, reported: reported.dup.freeze, stopped: stopped && -stopped,
                  discarded: discarded.dup.freeze, audited: audited.dup.freeze)
          end

          # @return [String] the reply the human reads at `you>`
          def to_s
            [*discarded.map(&:to_s), *landed_lines, *audited_lines, *reported_lines, *stopped_lines,
             summary].join("\n")
          end

          private

          def landed_lines = landed.map { |entry| "landed #{entry.issue_id} at #{entry.sha}" }

          def audited_lines = audited.map { |verdict| "#{verdict.issue_id}: #{verdict.line}" }

          def reported_lines = reported.map { |entry| "#{entry.issue_id}: #{entry.reason}" }

          def stopped_lines = stopped.nil? ? [] : [stopped]

          # A run whose only work was releasing a checkpoint landed nothing and
          # reported nothing, and read "0 landed, 0 left for you" -- a line that
          # says a run did nothing about a run that spent a model on QA.
          def summary
            "#{landed.size} landed#{released}, #{reported.size} left for you"
          end

          def released = audited.empty? ? "" : ", #{audited.size} QA #{"checkpoint".pluralize(audited.size)} released"
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
        # @param width [Integer] how many issues are carried at once. REQUIRED,
        #   and the only one of these with no default: {.width_for} is where
        #   how-many is decided, and a default here would be a second answer
        #   sitting inside the object whose comment says there is one.
        # @param budget [Integer, nil] how many issues the whole run may land
        # @param interrupt [#call] answers whether the run should stop
        # @param attempts [#call] `issue_id ->` which attempt to launch under,
        #   derived from the anchors standing in the repository
        # @param grading [#call] `call(issue_id, registration)`, judged between
        #   an actor settling and its retirement -- see {#settle_one}. The Null
        #   grades nothing, so an ordinary run is unchanged.
        # @param red_only [#call] `call(red_sha, tip_sha)`, answering whether the
        #   tip retirement anchored carries nothing past the red step's commit
        # @param qa_gate [#call] `call(checkpoint, graph) -> QaGate::Verdict`,
        #   asked of each {Epic::QaCheckpoint} as it becomes ready. The Null holds
        #   every checkpoint, because in an epic QA is not optional
        def initialize(progress:, plans:, actors:, supervisor:, gate:, landing:, red_only:, width:, budget: nil,
                       interrupt: -> { false }, attempts: nil, grading: Ungraded, qa_gate: QaGate::Unaudited)
          @qa_gate = qa_gate
          @progress = progress
          @plans = plans
          @actors = actors
          @supervisor = supervisor
          @landing = landing
          @bounds = Bounds.new(width:, budget:, interrupt:)
          @attempts = attempts || ->(_issue_id) { 1 }
          @grading = grading
          @red_only = red_only
          @asking = Asking.new(gate:, interrupt:)
        end

        # A session journal that cannot be read ends the whole run, wherever it
        # is met: the fold, a plan read, a gate or a landing. Before anything has
        # landed that is a refusal, raised; after, the landings are on the branch
        # and the reply has to say so, so the run stops in words instead.
        #
        # @return [Result] what landed, what was reported, and why the loop
        #   stopped when it stopped early
        # @raise [JournalUnreadable] when the run meets one before it has landed
        #   anything
        def call
          @landed = []
          @reported = []
          @audited = []
          @live = []
          @stopped = nil
          drive
          result
        rescue JournalUnreadable => e
          unreadable(e)
        end

        private

        # Fold, run any ready QA checkpoint, report what cannot run, fill the
        # width, settle one, fold again. An empty fill means nothing is startable:
        # {#fill} has already offered every untouched issue a refused launch left
        # room for.
        # The refold is the whole of the dependency order: an issue blocked by
        # the one that just landed becomes runnable because the fold now says
        # its blocker is done, and nothing else here knows about the graph. A
        # released checkpoint is one more thing that moves the graph, which is why
        # a pass sends the loop straight back to the fold.
        def drive
          @stopped = stop_reason
          return strand unless @stopped.nil?

          folded = @progress.call
          return drive if run_checkpoints(folded).any?(&:passed)

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

        def unreadable(error)
          raise error if @landed.empty?

          @stopped = format(UNREADABLE, why: error.message)
          strand
          result
        end

        # An early stop leaves whatever is still working where it stands: its
        # commits are its own actor's to anchor, and this run will not be the
        # thing that reports them landed.
        def strand
          @live.each { |entry| reported(entry, UNSETTLED) }
          @live = []
        end

        # A refused launch takes no room, so each startable issue is offered in
        # turn while the width has any. Iterating one pass rather than
        # re-entering per refusal keeps an epic of many broken plans at one
        # frame.
        def fill(folded)
          startable(folded).each { |issue| launch(issue) if room? }
        end

        def room? = @live.size < @bounds.width

        # NEITHER CLAUSE BELOW CAN FIRE TODAY, and both stay. {#run_checkpoints}
        # goes first and records every ready checkpoint, so {#untouched?} has
        # already excluded them by the time either of these is asked -- a mutation
        # that drops one reddens nothing. What they buy is that "a checkpoint is
        # never launched and never reported as unplanned" does not rest on that
        # ordering: move the audit after the fill and, without them, an
        # implementer spawns against a node with no plan to read.
        def startable(folded) = ready(folded) { |issue| issue.status == STARTABLE && !checkpoint?(issue) }

        # Pending, and nothing standing in its way but its own plan. A checkpoint
        # waits on no plan: {#run_checkpoints} runs it instead of reporting it.
        def unplanned(folded) = pending(folded).reject { |issue| checkpoint?(issue) }

        def pending(folded) = ready(folded) { |issue| issue.status == Lain::Epic::InFlight::PENDING }

        # Every checkpoint whose cluster has landed is run now, BEFORE the fill: a
        # pass is what makes the next cluster startable, and launching around a
        # ready checkpoint would start nothing it holds anyway.
        #
        # Run ONCE PER RUN, which {#untouched?} is what guarantees: the refold is
        # greedy, so a pass whose write the next fold cannot see would otherwise be
        # found ready forever and the epic would never stop folding.
        #
        # Named for what it DOES rather than as a predicate: it spends a model,
        # files issues and journals a transition. The caller reads the answer it
        # hands back -- whether the graph moved, and so whether to fold again.
        def run_checkpoints(folded)
          checkpoints(folded).map { |checkpoint| audit(checkpoint, folded.graph) }
        end

        # A CHECKPOINT IS NEVER LAUNCHED, whatever status it carries: its work is
        # QA, so an actor started on one would put an implementer in front of a
        # node with no plan to read. Both live statuses are run, because a human
        # who approved a plan for a checkpoint moved it into flight and it is still
        # QA's to settle.
        def checkpoints(folded) = ready(folded) { |issue| checkpoint?(issue) && unfinished?(issue) }

        def checkpoint?(issue) = Lain::Epic::QaCheckpoint.of?(issue)

        def unfinished?(issue) = [Lain::Epic::InFlight::PENDING, STARTABLE].include?(issue.status)

        # ScriptError as well as StandardError: a lent `qa_gate:` raising
        # NotImplementedError is neither a StandardError nor a reason to discard a
        # run that has already landed work, and the claim this message makes -- QA
        # could not run, so the checkpoint holds -- is true of both.
        def audit(checkpoint, graph)
          record(checkpoint, @qa_gate.call(checkpoint, graph))
        rescue JournalUnreadable
          raise
        rescue StandardError, ScriptError => e
          record(checkpoint, QaGate::Verdict.new(issue_id: checkpoint.id, passed: false,
                                                 line: format(QA_UNRUN, why: "#{e.class}: #{e.message}")))
        end

        # KEYED OFF THE CHECKPOINT, never off the verdict's own id. {#untouched?}
        # is the whole anti-livelock guard, so a gate answering a pass under
        # somebody else's id would leave this checkpoint untouched and ready, and
        # the greedy refold would ask it forever. The loop already holds the
        # checkpoint it asked about, so it records that.
        def record(checkpoint, verdict)
          verdict.with(issue_id: checkpoint.id).tap { |answered| kept(answered) }
        end

        # A checkpoint QA held is REPORTED rather than audited: what it filed is
        # work for a human to plan before the next run checks again.
        def kept(answered)
          return @audited << answered if answered.passed

          reported(answered, answered.line)
        end

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
          [@live, @landed, @reported, @audited].none? { |seen| seen.any? { |entry| entry.issue_id == id } }
        end

        # A refusal stops THIS issue and nothing else: the plan is not approved,
        # or it declares no subject to write tests for, and either way a human
        # has to look. The rest of the run keeps moving.
        #
        # A session journal that cannot be read is not this issue's: every plan
        # read after it meets the same damage, so it goes to {#call} to end the
        # run, rather than being reported once per issue.
        def launch(issue)
          subject = @plans.call(issue.id)
          launched = @actors.call(issue.id, subject: subject.subject, level: subject.level,
                                            attempt: @attempts.call(issue.id))
          @live << Live.new(issue_id: issue.id, launch: launched)
        rescue JournalUnreadable
          raise
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
        # landed. A journal that cannot be read is reported against the issue
        # too, then goes on to {#call}: the next issue's gate reads the same one.
        def settle_one
          entry = @live.shift
          row = row_of(entry)
          @grading.call(entry.issue_id, row)
          judge(entry, @supervisor.retire(row))
        rescue StandardError => e
          reported(entry, "#{UNCARRIED}: #{e.class}: #{e.message}") if untouched?(entry.issue_id)
          raise if e.is_a?(JournalUnreadable)
        end

        def row_of(entry) = @supervisor.find { |row| row.actor.equal?(entry.launch.actor) }

        # JUDGED BY THE SHA, NEVER BY THE KIND. An actor that committed nothing
        # retires as `nothing_to_do` and a refused anchor as `failed`, and both
        # carry a nil SHA -- so the one question worth asking is whether there is
        # a commit to gate at all. Submitting an empty implementation would put
        # an address nobody can land in front of a human, and so would
        # submitting the red step's own commit: failing tests are not an
        # implementation.
        def judge(entry, report)
          return reported(entry, unkept(report)) if report.sha.nil?
          return reported(entry, format(NO_WORK, sha: report.sha)) if @red_only.call(entry.launch.tests.sha, report.sha)

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
          raise if e.is_a?(JournalUnreadable)
        end

        # `--resume` finishes a merge that HAPPENED and was journaled, so it is
        # the way out of exactly one state. A refusal raised before anything
        # merged has nothing to resume -- the command would answer that there is
        # no landing to resume -- so sending a human there would cost them a second
        # refusal to work out. It reports itself instead.
        def unlanded(entry, report, error)
          return format(REFUSED, why: error.message) if refused_before_merging?(error)

          format(STRANDED, sha: report.sha, issue: entry.issue_id, why: "#{error.class}: #{error.message}")
        end

        def refused_before_merging?(error) = error.is_a?(RefusedBeforeActing)

        def stood(moved)
          stalled = moved.reject(&:done).first
          said = format(NOT_LANDED, kind: stalled.report.kind)
          stalled.report.detail.to_s.empty? ? said : "#{said}: #{stalled.report.detail}"
        end

        def reported(entry, reason) = @reported << Reported.new(issue_id: entry.issue_id, reason:)

        def result = Result.new(landed: @landed, reported: @reported, stopped: @stopped, audited: @audited)
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
      #
      # A KEPT BRANCH MAY ALREADY HOLD THIS STEP. An earlier run of the same
      # criteria left its commit there, and generating again would leave the
      # target exactly as it stands, which reads as no tests at all. So a
      # commit the branch holds past the lease's base, whose message names this
      # target and these criteria, is carried forward while its tests still
      # fail -- with or without the earlier run's work above it.
      class IssueTests
        # What the step left: the generation's record, the failing run, the
        # commit holding the tests, and whether an earlier run made that commit.
        Red = Data.define(:record, :run, :sha, :carried) do
          def initialize(record:, run:, sha:, carried: false) = super
        end

        # The part of a generation's record a carried commit still answers.
        Carried = Data.define(:target, :criteria_digest)

        # @param renderer [Skill::Renderer] renders the test-writing scaffold
        # @param role_spawn [Skill::RoleSpawn] the run's role spawn; its
        #   test_engineer child is lent the held checkout rather than leasing one
        # @param layout [TestLayout] the project's, resolved from its root: the
        #   held checkout is cut by git and carries no gitignored config
        # @param harness [#call] `root -> #run`, the suite runner over a checkout
        # @param shell_out_factory [#call] builds the git subprocess runner
        def initialize(renderer:, role_spawn:, layout:, harness: Lain::Grader::TestHarness.public_method(:new),
                       shell_out_factory: Lain::Shell::Out.public_method(:new))
          @renderer = renderer
          @role_spawn = role_spawn
          @layout = layout
          @harness = harness
          @shell_out_factory = shell_out_factory
        end

        # @param criteria [Gherkin::Criteria] the issue's approved criteria
        # @param worker_env [WorkerEnv] the held checkout, on the issue's branch
        # @param subject [String] the source file the tests are for, relative to
        #   the checkout
        # @param since [String] the commit the lease was cut at; only a commit
        #   past it is one an earlier run of this issue made
        # @param level [String, nil] a level the layout declares; its default
        #   level when nil
        # @return [Red]
        # @raise [Error] when the project declares no test layout, or declares
        #   no level whose tests mirror their sources; when the test_engineer
        #   child leaves no tests the layout accepts; when the subject's tests
        #   already pass before any work is done, or a carried commit's no
        #   longer fail; or when git refuses the failing tests' commit
        def call(criteria, worker_env, subject:, since:, level: nil)
          guard = Lain::TestLayout::Guard.new(layout: declared, root: worker_env.cwd)
          level ||= default_level(guard.layout)
          target = guard.layout.mapping.test_path(subject, level:)
          carried = earlier(worker_env.cwd, target, criteria.digest, since)
          return carry(criteria, worker_env, target, carried) unless carried.nil?

          record = generated(criteria, worker_env, guard, subject:, level:)
          Red.new(record:, run: failing(record, worker_env), sha: commit(worker_env.cwd, record))
        end

        private

        def declared
          return @layout if @layout.in_force?

          raise Error, "this project declares no test layout, so the issue's failing tests have nowhere the " \
                       "layout guard would accept them: add a [tests] table to .lain/config.toml naming " \
                       "its preset and source roots"
        end

        def default_level(layout)
          level = layout.mapping.default_level
          return level.name unless level.nil?

          raise Error, "the [tests] table declares no level whose tests mirror their sources, so there is " \
                       "no level to generate the issue's tests at"
        end

        def generated(criteria, worker_env, guard, subject:, level:)
          record = Lain::Gherkin::TestGeneration.new(renderer: @renderer, role_spawn: @role_spawn.within(worker_env),
                                                     guard:).call(criteria, subject:, level:)
          return record if record.generated?

          raise Error, "the test_engineer child #{ungenerated(record)}, so nothing was committed"
        end

        def ungenerated(record)
          target = record.target
          return "wrote no tests at #{target}" if record.missing?
          return "left #{target} exactly as it already stood" unless record.created? || record.changed?

          "wrote tests at #{target} the layout does not accept (#{record.verdict})"
        end

        def failing(record, worker_env)
          run = ran(record.target, worker_env)
          return run unless run.clean?

          raise Error, "#{record.target} ran #{run.total} examples and none failed before any work was " \
                       "done, so they check nothing the work will change: the criteria or the " \
                       "generation are wrong, and nothing was committed"
        end

        # The newest commit past `since` carrying exactly this step's message,
        # or nil when the branch holds none or its tip no longer has the tests.
        def earlier(root, target, digest, since)
          return unless File.file?(File.join(root, target))

          git = Lain::Isolation::Checkout.new(root, shell_out_factory: @shell_out_factory)
          wanted = message(target, digest)
          git.run("log", "--first-parent", "--format=%H%x00%s", "#{since}..HEAD").stdout.split("\n")
             .map { |line| line.split("\0", 2) }
             .find { |sha, subject| subject == wanted && touched(git, sha) == [target] }&.first
        end

        # A message is only a claim; the commit's own paths are what it did.
        def touched(git, sha)
          git.run("diff-tree", "-r", "--no-commit-id", "--name-only", "-z", "--no-renames", sha).stdout.split("\0")
        end

        # A resumed or forked chat is never asked about earlier branches, so the
        # remedy names a way that asks.
        def carry(criteria, worker_env, target, sha)
          run = ran(target, worker_env)
          record = Carried.new(target:, criteria_digest: criteria.digest)
          return Red.new(record:, run:, sha:, carried: true) unless run.clean?

          raise Error, "#{target} holds the failing tests an earlier run committed at #{sha} from these criteria, " \
                       "but they no longer fail on this branch; start a new chat and answer delete at " \
                       "`/implement-epic` (the old tip is kept under refs/lain/worker/), or delete " \
                       "`#{branch_of(worker_env)}` yourself"
        end

        def branch_of(worker_env)
          Lain::Isolation::Checkout.new(worker_env.cwd, shell_out_factory: @shell_out_factory)
                                   .symbolic_head.delete_prefix("refs/heads/")
        end

        def ran(target, worker_env) = @harness.call(worker_env.cwd).run(worker_env, paths: [target])

        # The target alone, even when the child left other files, so the red
        # commit holds the tests and nothing else. `--no-verify` because the
        # commit fails by design: a hook that runs the suite would refuse
        # exactly the state this step exists to record.
        def commit(root, record)
          git = Lain::Isolation::Checkout.new(root, shell_out_factory: @shell_out_factory)
          committed!(git.run("add", "--", record.target))
          committed!(git.run("commit", "--no-verify", "-q", "-m", message(record.target, record.criteria_digest),
                             "--", record.target))
          git.head.stdout.strip
        end

        def committed!(shell)
          return if shell.exitstatus.zero?

          raise Error, "git refused the failing tests' commit: #{shell.stderr.strip}"
        end

        def message(target, digest) = "test: failing tests at #{target}, from criteria #{digest}"
      end
    end
  end
end
