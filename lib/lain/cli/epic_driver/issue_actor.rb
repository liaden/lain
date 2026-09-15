# frozen_string_literal: true

require "async"

module Lain
  module CLI
    module EpicDriver
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
        ROLE = "issue_orchestrator"

        SKILL = :"execute-plan"

        # What one launch left standing: the actor, the id its anchor will take,
        # the branch its work is on, and the red step that precedes it.
        Launch = Data.define(:actor, :worker_id, :branch, :tests)

        # The issue's branch as the lease found it: `from` is the epic's tip the
        # checkout was cut at, and `stood_at` where the branch stood before the
        # red step, which differs only for a branch an earlier run left.
        Cut = Data.define(:branch, :from, :stood_at) do
          def reused? = stood_at != from
        end

        # The issue branches an earlier run of this epic left standing, settled
        # ONCE, before a re-run leases anything. Kept, each is reused where it
        # stands and the red step carries its commit forward; deleted, each tip
        # is anchored first and every issue is cut fresh from the epic's tip.
        #
        # KEEPING IS THE DEFAULT, because a delete is the one answer a second
        # answer cannot take back: a chat resumed mid-epic is never asked, a
        # session with nobody to ask keeps, and only `delete` deletes -- in any
        # case, with trailing punctuation, the way a gate reads its reply.
        # Only a branch lain's marker licenses is offered at all.
        #
        # ALL OR NOTHING, AS FAR AS GIT ALLOWS. Every branch is judged before
        # any is deleted, so a held or unowned one refuses the lot. A branch a
        # sibling moves after that still refuses its own delete, and the
        # refusal then names each branch already gone and where its tip went.
        class Earlier
          DELETE = "delete"

          UNFINISHED = " (a delete lain left unfinished)"

          # One branch deleted on the human's word, and the anchor its old tip
          # now stands on -- the one place a human can recover it from.
          Discarded = Data.define(:branch, :anchor) do
            def initialize(branch:, anchor:) = super(branch: -branch.to_s, anchor: -anchor.to_s)

            def to_s = "deleted #{branch}, its old tip kept at #{anchor}"
          end

          # A session nobody can ask. Its reply is no word at all, so it keeps.
          module Unasked
            def self.ask(_question) = Lain::Promise.new.tap { |promise| promise.resolve("") }

            def self.withdraw(_promise) = nil
          end

          # @param slug [String] the epic
          # @param repo_root [String] the repository the issue branches live in
          # @param asker [#ask, #withdraw] the chat's own, whose promise resolves
          #   with what the human wrote
          # @param journal [#record] where an asked question is retired, which
          #   must be one the chat's inbox readers fold
          # @param timeout [Numeric] seconds an unanswered question waits before
          #   it keeps
          # @param shell_out_factory [#call] builds the git subprocess runner
          def initialize(slug:, repo_root:, asker:, journal:, timeout: Lain::Approval::Gate::DEFAULT_TIMEOUT,
                         shell_out_factory: Lain::Shell::Out.public_method(:new))
            @slug = slug
            @repo_root = repo_root
            @asker = asker
            @journal = journal
            @timeout = timeout
            @shell_out_factory = shell_out_factory
          end

          # PRECONDITION: runs under an Async reactor, where the chat's answering
          # surfaces are sibling fibers.
          #
          # @param resumed [Boolean] whether the chat carrying the run was resumed
          # @return [Array<Discarded>] each deleted branch and the anchor its tip
          #   stands on; empty when the branches were kept
          # @raise [Isolation::WorkingBranch::Refused] when a branch to delete is
          #   held by a checkout, or git refuses its anchor or its delete
          def call(resumed:)
            standing = resumed ? [] : branches
            return [] if standing.empty? || !delete?(standing)

            registry = Lain::Isolation::Worktree::Registry.new(repo_root: @repo_root,
                                                               shell_out_factory: @shell_out_factory)
            judged(standing, registry).each_with_object([]) do |(branch, tip), gone|
              gone << discarded(branch, tip, registry, gone)
            end
          end

          private

          def branches
            Lain::Isolation::WorkingBranch.owned_under(IssueActor.branch_prefix(@slug),
                                                       repo_root: @repo_root, shell_out_factory: @shell_out_factory)
          end

          # @return [Array<Array(Isolation::WorkingBranch, String)>] each branch
          #   and the tip it is deleted at
          def judged(standing, registry)
            holders = Lain::Isolation::WorkingBranch.holders(registry)
            standing.map { |branch| [branch, branch.discardable!(holders)] }
          end

          def discarded(branch, tip, registry, gone)
            Discarded.new(branch: branch.name, anchor: branch.discard(at: tip, registry:))
          rescue Lain::Isolation::WorkingBranch::Refused => e
            raise if gone.empty?

            raise Lain::Isolation::WorkingBranch::Refused, "#{gone.join("; ")}; then #{e.message}"
          end

          def delete?(standing) = answered(@asker.ask(question(standing)))

          def answered(asked)
            reply(heard(asked)).strip.downcase.sub(Lain::Epic::GateReply::TRAILING_PUNCTUATION, "") == DELETE
          ensure
            settled(asked)
          end

          def heard(asked)
            Async::Task.current.with_timeout(@timeout) { asked.await }
          rescue Async::TimeoutError
            ""
          end

          def reply(resolved) = resolved.respond_to?(:words) ? resolved.words.to_s : resolved.to_s

          # For {Approval::Gate#withdrawn}'s and {Approval::Gate#retired}'s
          # reasons: an asker admits one outstanding question, and an inbox
          # lists a question until something in the record retires it.
          def settled(asked)
            @asker.withdraw(asked)
            return unless asked.respond_to?(:digest)

            @journal.record(Lain::Telemetry::QuestionsConsumed.new(turn: nil, digests: [asked.digest]))
          end

          def question(standing)
            listed = standing.map { |branch| "#{branch.name} at #{branch.tip}#{UNFINISHED if branch.unfinished?}" }
                             .join(", ")
            "An earlier run of epic #{@slug.inspect} left #{listed}. Reply keep to reuse each where it stands, " \
              "carrying its failing tests forward; delete removes all #{standing.size} of these earlier branches, " \
              "saving each tip under #{Lain::Isolation::Worktree::Handback::Naming::REF_NAMESPACE}/ and cutting " \
              "every issue fresh from the tip of #{Lain::Isolation::WorkingBranch.epic_name(@slug)}. Any other " \
              "reply keeps them."
          end
        end

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
        Brief = Data.define(:renderer, :home, :slug, :issue, :cut, :tests) do
          def to_s = [renderer.render(SKILL), carrying, planned, satisfying, failing, settling].join("\n\n")

          def working_branch = Lain::Isolation::WorkingBranch.epic_name(slug)

          def branch = cut.branch.name

          private

          def carrying
            <<~SECTION.strip
              ## The issue you are carrying

              Issue `#{issue.id}` of epic `#{slug}`: #{issue.title}. #{standing}
            SECTION
          end

          def standing
            return "Your checkout stands on `#{branch}`, cut from the tip of `#{working_branch}`." unless cut.reused?

            "Your checkout stands on `#{branch}`, reused as an earlier run left it at `#{cut.stood_at}` rather " \
              "than cut from the tip of `#{working_branch}`."
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

              #{committed}

              - `#{tests.record.target}`

              Make them pass. Never weaken or delete one -- if a test is wrong, say so in your answer
              instead of editing it away.
            SECTION
          end

          def committed
            return "Generated from those criteria and committed on your branch before your first turn:" unless
              tests.carried

            "Generated from those criteria by an earlier run, committed on your branch at `#{tests.sha}`, and " \
              "still failing:"
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

        # @param slug [String] the epic
        # @param issue_id [String] the issue
        # @return [String] the branch one issue's work stands on
        def self.branch_name(slug, issue_id) = "#{branch_prefix(slug)}/#{issue_id}"

        # @param slug [String] the epic
        # @return [String] the prefix every one of the epic's issue branches takes
        def self.branch_prefix(slug) = "lain/issue/#{slug}"

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
        # @raise [Error] for an issue that declares no acceptance criteria, so
        #   there are no failing tests to write
        # @raise [Error] when this attempt's anchor is already written, so the
        #   attempt already stands and a second run would overwrite its work
        # @raise [Error] when the issue's branch cannot be checked out in the
        #   issue's lease
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
          held = nil
          actor = @supervisor.adopt(role: ROLE, worker_id: lane) do |worker_env|
            held = cut(worker_env, issue.id)
            red = @tests.call(criteria, worker_env, subject:, level:, since: held.from)
            spawner(worker_env, held.branch, lane).launch_actor(brief(issue, held, red), worker_env:)
          end
          Launch.new(actor:, worker_id: lane, branch: held.branch.name, tests: red)
        end

        # The issue's own lain-owned branch, established at the tip the lease
        # was cut from and checked out. {Isolation::WorkingBranch} owns every
        # rule about it: the legal name, the clash with a branch nested against
        # it, the marker that licenses a later reaping, and the refusal to claim
        # a branch lain did not create.
        def cut(worker_env, issue_id)
          git = checkout(worker_env.cwd)
          from = git.head.stdout.strip
          branch = Lain::Isolation::WorkingBranch.owned(self.class.branch_name(@slug, issue_id),
                                                        repo_root: worker_env.cwd, from:,
                                                        shell_out_factory: @shell_out_factory)
          Cut.new(branch: switched!(git, branch), from:, stood_at: branch.tip)
        end

        def switched!(git, branch)
          shell = git.run("switch", "-q", branch.name)
          return branch.tap(&:still_owned!) if shell.exitstatus.zero?

          raise Error, "#{branch.name} could not be checked out in the issue's lease: #{said(shell)}"
        end

        def lane_for(issue_id, attempt) = "issue.#{@slug}.#{issue_id}.#{attempt}"

        def checkout(dir) = Lain::Isolation::Checkout.new(dir, shell_out_factory: @shell_out_factory)

        # git's stderr arrives as ASCII-8BIT, so a refusal interpolating it raw
        # dies of Encoding::CompatibilityError rather than naming itself.
        def said(shell) = shell.stderr.to_s.dup.force_encoding(Encoding::UTF_8).scrub.strip

        def criteria_of(issue)
          return Lain::Gherkin::Criteria.parse(issue.criteria) unless issue.criteria.nil?

          raise Error, "issue #{issue.id} declares no acceptance criteria, so there are no failing tests " \
                       "to write before its plan runs"
        end

        # An attempt whose anchor still stands would be refused at retirement,
        # where the work is already done and the refusal costs the whole run.
        # Refusing here costs nothing.
        def unanchored!(lane)
          ref = Lain::Isolation::Worktree::Handback::Naming.new(lane).ref
          held = checkout(@repo_root).target(ref)
          return if held.empty?

          raise Error, "#{lane} already ran: #{ref} still anchors its work at #{held}, and a " \
                       "retirement under that id would be refused rather than move it -- launch the " \
                       "next attempt instead"
        end

        def spawner(worker_env, branch, lane)
          @subagent.call(**@lanes.over(worker_env, branch.name), lane:)
        end

        def brief(issue, cut, red)
          Brief.new(renderer: @renderer, home: @home, slug: @slug, issue:, cut:, tests: red).to_s
        end
      end
    end
  end
end
