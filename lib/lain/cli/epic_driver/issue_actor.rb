# frozen_string_literal: true

module Lain
  module CLI
    module EpicDriver
      class IssueActor # rubocop:disable Style/Documentation -- doc lives on the reopen below
        ROLE = "issue_orchestrator"

        SKILL = :"execute-plan"

        class NoCriteria < Error; end
        class AttemptStands < Error; end
        class NotCheckedOut < Error; end

        # What one launch left standing: the actor, the id its anchor will take,
        # the branch its work is on, and the red step that precedes it.
        Launch = Data.define(:actor, :worker_id, :branch, :tests)

        # @param slug [String] the epic
        # @param issue_id [String] the issue
        # @return [String] the branch one issue's work stands on
        def self.branch_name(slug, issue_id) = "lain/issue/#{slug}/#{issue_id}"

        # @param slug [String] the epic
        # @param supervisor [Supervisor] the epic's own, whose checkouts are cut
        #   from `epic/<slug>`
        # @param subagent [#call] `epic_subagent(isolation:, handoff:, lane:)`
        # @param tests [IssueTests] the red step, run in the held checkout
        # @param renderer [Skill::Renderer] renders the plan-running skill
        # @param home [Epic::Home] where the issue and its plan are read
        # @param plan [#call] `issue_id ->` the approved plan's digest, raising
        #   when that plan is not approved
        # @param repo_root [String] the repository the worker anchors live in
        # @param lanes [Lanes] builds the issue's own isolation and handoff
        # @param shell_out_factory [#call] builds the git subprocess runner
        def initialize(slug:, supervisor:, subagent:, tests:, renderer:, home:, plan:, repo_root:, lanes:,
                       shell_out_factory: Lain::Shell::Out.public_method(:new))
          @slug = slug
          @supervisor = supervisor
          @subagent = subagent
          @tests = tests
          @renderer = renderer
          @home = home
          @plan = plan
          @repo_root = repo_root
          @lanes = lanes
          @shell_out_factory = shell_out_factory
        end

        # @param issue_id [String] the issue to launch
        # @param subject [String] the source file its tests are for, relative to
        #   the checkout, as its plan declares ({PlanSubject})
        # @param level [String, nil] the layout level to generate them at
        # @param attempt [Integer] which attempt this is. It names the worker AND
        #   its children's lane, so a retry anchors apart from the attempt
        #   before it.
        # @return [Launch]
        # @raise [NoCriteria] for an issue that declares none
        # @raise [AttemptStands] when this attempt's anchor is already written
        # @raise [NotCheckedOut] when the issue's branch cannot be checked out
        # @raise [Isolation::WorkingBranch::Refused] when its branch is
        #   unholdable, nested against, or one lain did not create
        def call(issue_id, subject:, level: nil, attempt: 1)
          @plan.call(issue_id)
          issue = @home.read_epic.fetch(issue_id)
          lane = lane_for(issue.id, attempt)
          unanchored!(lane)
          adopted(issue, lane, subject:, level:)
        end

        private

        # Everything inside the lease, in the order that makes the actor's first
        # turn a turn taken against a red suite: the branch, the tests on it,
        # then the launch. The actor's worker id and its children's lane are ONE
        # string, so a second attempt's children cannot compare-and-swap the
        # first attempt's anchors away.
        def adopted(issue, lane, subject:, level:)
          criteria = criteria_of(issue)
          red = nil
          branch = nil
          actor = @supervisor.adopt(role: ROLE, worker_id: lane) do |worker_env|
            branch = cut(worker_env, issue.id)
            red = @tests.call(criteria, worker_env, subject:, level:)
            spawner(worker_env, branch, lane).launch_actor(brief(issue, branch, red), worker_env:)
          end
          Launch.new(actor:, worker_id: lane, branch: branch.name, tests: red)
        end

        # The issue's own lain-owned branch, established at the tip the lease
        # was cut from and checked out. {Isolation::WorkingBranch} owns every
        # rule about it: the legal name, the clash with a branch nested against
        # it, the marker that licenses a later reaping, and the refusal to claim
        # a branch lain did not create.
        def cut(worker_env, issue_id)
          git = checkout(worker_env.cwd)
          branch = Lain::Isolation::WorkingBranch.owned(self.class.branch_name(@slug, issue_id),
                                                        repo_root: worker_env.cwd, from: git.head.stdout.strip,
                                                        shell_out_factory: @shell_out_factory)
          switched!(git, branch)
        end

        def switched!(git, branch)
          shell = git.run("switch", "-q", branch.name)
          return branch if shell.exitstatus.zero?

          raise NotCheckedOut, "#{branch.name} could not be checked out in the issue's lease: #{said(shell)}"
        end

        def lane_for(issue_id, attempt) = "issue.#{@slug}.#{issue_id}.#{attempt}"

        def checkout(dir) = Lain::Isolation::Checkout.new(dir, shell_out_factory: @shell_out_factory)

        # git's stderr arrives as ASCII-8BIT, so a refusal interpolating it raw
        # dies of Encoding::CompatibilityError rather than naming itself.
        def said(shell) = shell.stderr.to_s.dup.force_encoding(Encoding::UTF_8).scrub.strip

        def criteria_of(issue)
          return Lain::Gherkin::Criteria.parse(issue.criteria) unless issue.criteria.nil?

          raise NoCriteria, "issue #{issue.id} declares no acceptance criteria, so there are no failing tests " \
                            "to write before its plan runs"
        end

        # An attempt whose anchor still stands would be refused at retirement,
        # where the work is already done and the refusal costs the whole run.
        # Refusing here costs nothing.
        def unanchored!(lane)
          ref = Lain::Isolation::Worktree::Handback::Naming.new(lane).ref
          held = checkout(@repo_root).target(ref)
          return if held.empty?

          raise AttemptStands, "#{lane} already ran: #{ref} still anchors its work at #{held}, and a " \
                               "retirement under that id would be refused rather than move it -- launch the " \
                               "next attempt instead"
        end

        def spawner(worker_env, branch, lane)
          @subagent.call(**@lanes.over(worker_env, branch.name), lane:)
        end

        def brief(issue, branch, red)
          Brief.new(renderer: @renderer, home: @home, slug: @slug, issue:, branch: branch.name, tests: red).to_s
        end
      end

      # One issue, launched as an actor running the `execute-plan` skill in a
      # checkout of its own.
      #
      # The ORDER is the whole of it. A plan that is not approved stops the
      # issue before anything is leased. Then the epic's supervisor cuts the
      # checkout at `epic/<slug>`'s tip, the checkout is switched onto the
      # issue's own lain-owned branch, and the failing tests are generated and
      # committed there -- so by the actor's first turn, the plan it is handed
      # already has its red step in the history behind it.
      #
      # Nothing the actor or its children commit reaches `epic/<slug>`: the
      # children lease from the issue's branch and hand back into the actor's
      # checkout, and retirement anchors that branch's tip for the issue's
      # implementation gate to stand in front of.
      class IssueActor
        # Reopened rather than nested mid-body: the split keeps each class body
        # within Metrics/ClassLength instead of loosening it.

        # Where the actor's children work: each leasing a checkout cut from the
        # ISSUE's branch, and handing its work back into the actor's own
        # checkout. Nothing here reaches the chat's tree or the epic's branch,
        # which the issue's implementation gate stands in front of.
        class Lanes
          # @param root [String] where the children's checkouts live
          # @param role_spawn [Skill::RoleSpawn] spawns the resolver a conflicted
          #   handback needs, inside the actor's own checkout, which is where
          #   the conflict is
          # @param journal [#<<] where the handback records land
          # @param strategy [Isolation::MergeStrategy] how a handback merges
          # @param shell_out_factory [#call] builds the git subprocess runner
          def initialize(root:, role_spawn:, journal: Lain::Channel::Null.instance,
                         strategy: Lain::Isolation::MergeStrategy::DEFAULT,
                         shell_out_factory: Lain::Shell::Out.public_method(:new))
            @root = root
            @role_spawn = role_spawn
            @journal = journal
            @strategy = strategy
            @shell_out_factory = shell_out_factory
          end

          # @param worker_env [WorkerEnv] the actor's lease
          # @param branch [String] the issue's branch, which its children are
          #   cut from and hand back onto
          # @return [Hash{Symbol=>Object}] the `isolation:` and `handoff:` the
          #   issue's own epic Subagent is built over
          def over(worker_env, branch)
            checkout = worker_env.cwd
            base = working_branch(checkout, branch)
            { isolation: Lain::Isolation::Worktree.new(root: @root, repo_root: checkout, base:,
                                                       shell_out_factory: @shell_out_factory),
              handoff: Lain::Isolation::WorkerHandoff.over(repo_root: checkout, base:, journal: @journal,
                                                           strategy: @strategy,
                                                           resolver: @role_spawn.within(worker_env)) }
          end

          private

          def working_branch(checkout, branch)
            Lain::Isolation::WorkingBranch.new(branch, repo_root: checkout,
                                                       git: Lain::Isolation::Checkout.new(
                                                         checkout, shell_out_factory: @shell_out_factory
                                                       ))
          end
        end

        # What the actor is seeded with: the skill that runs a plan, then this
        # issue's own contract -- where its approved plan is, what it must
        # satisfy, the failing tests it must turn green, and where its work has
        # to end up.
        Brief = Data.define(:renderer, :home, :slug, :issue, :branch, :tests) do
          def to_s = [renderer.render(SKILL), carrying, planned, satisfying, failing, settling].join("\n\n")

          def working_branch = Lain::Isolation::WorkingBranch.epic_name(slug)

          private

          def carrying
            <<~SECTION.strip
              ## The issue you are carrying

              Issue `#{issue.id}` of epic `#{slug}`: #{issue.title}. Your checkout stands on `#{branch}`,
              cut from the tip of `#{working_branch}`.
            SECTION
          end

          def planned
            <<~SECTION.strip
              ## Its plan

              Read `#{home.plan(issue.id).path}` before anything else. It is approved, and it is this
              run's contract: follow its steps, its scope and its escalation triggers.
            SECTION
          end

          def satisfying
            <<~SECTION.strip
              ## What it must satisfy

              #{issue.criteria}
            SECTION
          end

          def failing
            <<~SECTION.strip
              ## The failing tests

              Generated from those criteria and committed on your branch before your first turn:

              - `#{tests.record.target}`

              Make them pass. Never weaken or delete one -- if a test is wrong, say so in your answer
              instead of editing it away.
            SECTION
          end

          def settling
            <<~SECTION.strip
              ## Before you settle

              Commit your work on `#{branch}`, rebase it onto `#{working_branch}`, resolve any conflict
              yourself, and leave the tree clean. Your last answer says what landed and what did not:
              it is reviewed, and the harness merges the work, never you.
            SECTION
          end
        end
      end
    end
  end
end
