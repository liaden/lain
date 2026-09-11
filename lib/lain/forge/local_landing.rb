# frozen_string_literal: true

require "tmpdir"

module Lain
  module Forge
    # One approved issue's commit, landed onto its epic's working branch in
    # this repository, and nowhere else: nothing is pushed per issue. The epic
    # reaches the remote once, as one branch and one pull request, through
    # {Landing}.
    #
    # EVERY CHECK BEFORE ANY MERGE, in this order: the issue is in flight; its
    # plan is approved as it stands now; its implementation gate approved this
    # exact commit; and the tests the commit changes sit where the project's
    # layout says. The plan is asked again here because an implementation
    # parked before its plan was edited can still be approved from the queue.
    #
    # THE LAYOUT IS READ AT THE WORKER'S COMMIT. The commit's tree is checked
    # out into a scratch directory and the guard runs there, so a class and
    # its test landing together pass, and a test whose class no source in the
    # commit defines is refused: by landing time the class has to exist.
    #
    # RESUMABLE WITHOUT AN INTENT. A merge onto a local branch can be observed
    # afterwards -- the branch holds the commit or it does not -- so a crash
    # between the merge and the transition resumes by asking git.
    class LocalLanding
      IN_FLIGHT = "in_flight"

      # What a queue report says that this issue's work reached the branch.
      MOVED = %i[merged resolved].freeze

      # {Telemetry::Handback}'s journal type: the record a landing writes as it merges.
      LANDED = "handback"

      class NotInFlight < Error; end
      class MisplacedTests < Error; end
      class NothingToResume < Error; end
      class Ambiguous < Error; end
      class AlreadyOnBranch < Error; end

      # An issue whose commit passed every check, as the worker the queue lands.
      Admission = Data.define(:issue_id, :worker)

      # What one issue's landing came to: the worker's commit, the queue's
      # report, and whether the issue moved to done.
      Landed = Data.define(:issue_id, :sha, :report, :done)

      Result = Data.define(:landed, :verification) do
        def initialize(landed:, verification:) = super(landed: landed.dup.freeze, verification:)
      end

      # @param epic_slug [String] the epic the issue belongs to
      # @param repo_root [String] the parent checkout standing on `base`
      # @param base [Isolation::WorkingBranch] `epic/<slug>`
      # @param approvals [#approved?] `approved?(address, issue_id)`, the
      #   implementation gate's approvals scoped to their issue ({Approvals})
      # @param plan [#call] `call(issue_id)`, raising unless the issue's plan
      #   is approved as it stands now
      # @param progress [#call] answers the epic's {Epic::Progress}, read fresh
      # @param scribe [#issue_moved] {Epic::Scribe}
      # @param queue [#call] {Isolation::LandingQueue}, the only thing that merges
      # @param layout [TestLayout] the project's `[tests]` layout; {TestLayout::None}
      #   when it declares none, which checks nothing
      # @param landings [#call] answers the journal records landings of this
      #   epic wrote; a commit already on the branch counts as this issue's
      #   landing only when one of them is this issue's merge
      # @param shell_out_factory [#call] builds the subprocess runner
      def initialize(epic_slug:, repo_root:, base:, approvals:, plan:, progress:, scribe:, queue:, layout: TestLayout::None,
                     landings: -> { [] }, shell_out_factory: Shell::Out.public_method(:new))
        @epic_slug = epic_slug
        @base = base
        @approvals = approvals
        @plan = plan
        @progress = progress
        @scribe = scribe
        @queue = queue
        @landings = Landings.new(landings, epic_slug:)
        @commits, @placement = inspecting(File.expand_path(repo_root), layout, base, shell_out_factory)
      end

      # @return [Result]
      def call(issue_id, sha:, ref:, resync: Isolation::LandingQueue::Resync)
        land([admit(issue_id, sha:, ref:)], resync:)
      end

      # @param issue_id [String] the issue whose work this is
      # @param sha [String] the full object name of the worker's commit
      # @param ref [String] the ref the commit is anchored under
      # @return [Admission]
      # @raise [NotInFlight, Approval::Gate::NotApproved, MisplacedTests, AlreadyOnBranch] before anything merges
      def admit(issue_id, sha:, ref:)
        ready!(issue_id)
        approved!(issue_id, sha)
        admitted(issue_id, sha, ref)
      end

      # {#admit} for the commit a handback anchored, found by asking the gate
      # which anchored commit it approved for this issue.
      # @return [Admission]
      def anchored(issue_id)
        ready!(issue_id)
        admitted(issue_id, *approved_commit(issue_id, @commits.anchored))
      end

      # @param admissions [Admission, Array<Admission>] in landing order
      # @param resync [#call] as {Isolation::LandingQueue#call} takes it; a
      #   re-synced commit lands only if it would itself be admitted
      # @return [Result]
      def land(admissions, resync: Isolation::LandingQueue::Resync)
        admitted = Array(admissions)
        result = @queue.call(admitted.map(&:worker), resync: Gated.new(resync, self, admitted))
        Result.new(landed: admitted.zip(result.landed).map { |admission, entry| settled(admission, entry.report) },
                   verification: result.verification)
      end

      # Finish a landing whose merge happened, and was journaled, and whose
      # transition did not. Nothing merges here.
      # @return [Result]
      # @raise [NothingToResume] when the branch does not hold the commit, or
      #   holds it with no landing of this issue journaled
      def resume(issue_id)
        ready!(issue_id)
        sha, ref = approved_commit(issue_id, @commits.all)
        raise NothingToResume, never_merged(issue_id, sha) unless @commits.landed?(sha)
        raise NothingToResume, "#{unjournaled(issue_id, sha)} -- there is no landing to resume" unless
          @landings.merged?(issue_id)

        report = Isolation::WorkerHandoff::Report.new(kind: :nothing_to_do, ref:, detail: "#{@base.name} holds #{sha}")
        Result.new(landed: [settled_at(issue_id, sha, report)],
                   verification: Isolation::LandingQueue::Verification.new(outcome: :skipped, tip: @base.tip,
                                                                           detail: "a resume merges nothing"))
      end

      # Whether `sha` would pass the gate and the layout for `issue_id`: what a
      # re-synced commit has to answer before it may land in the original's place.
      def admissible?(issue_id, sha) = approved?(issue_id, sha) && @placement.refusals(sha).empty?

      private

      def inspecting(root, layout, base, shell_out_factory)
        [Commits.new(git: Isolation::Checkout.new(root, shell_out_factory:), base:),
         Placement.new(repo_root: root, layout:, base:, shell_out_factory:)]
      end

      def ready!(issue_id)
        status = @progress.call.status(issue_id)
        raise NotInFlight, not_in_flight(issue_id, status) unless status == IN_FLIGHT

        @plan.call(issue_id)
      end

      def approved?(issue_id, sha)
        @approvals.approved?(Epic::Submission.implementation(slug: @epic_slug, issue_id:, digest: sha).digest, issue_id)
      end

      def approved!(issue_id, sha)
        return if approved?(issue_id, sha)

        raise Approval::Gate::NotApproved, "issue #{issue_id}'s implementation gate has not approved #{sha}, so " \
                                           "nothing landed -- #{approve(issue_id, sha)}"
      end

      def placed!(issue_id, sha)
        refused = @placement.refusals(sha)
        raise MisplacedTests, misplaced(issue_id, sha, refused) unless refused.empty?
      end

      # One commit per issue: two approved ones would leave the choice of
      # which work lands to whichever the listing happened to name first.
      def approved_commit(issue_id, candidates)
        approved = candidates.select { |sha, _| approved?(issue_id, sha) }.group_by(&:first)
        raise Approval::Gate::NotApproved, unanchored(issue_id) if approved.empty?
        raise Ambiguous, ambiguous(issue_id, approved.keys) unless approved.one?

        sha, found = approved.first
        [sha, found.filter_map(&:last).first]
      end

      def admitted(issue_id, sha, ref)
        placed!(issue_id, sha)
        raise AlreadyOnBranch, "#{unjournaled(issue_id, sha)}, so nothing lands for issue #{issue_id}" if
          @commits.landed?(sha) && !@landings.merged?(issue_id)

        Admission.new(issue_id:, worker: @landings.worker(issue_id, ref:, sha:))
      end

      def settled(admission, report) = settled_at(admission.issue_id, admission.worker.sha, report)

      def settled_at(issue_id, sha, report)
        done = landed?(issue_id, report) && in_flight?(issue_id)
        @scribe.issue_moved(issue_id, from: IN_FLIGHT, to: Epic::DONE) if done
        Landed.new(issue_id:, sha:, report:, done:)
      end

      # Already on the branch is not landed: it counts only when this issue's
      # own merge is journaled, which is the crash between a merge and its
      # transition.
      def landed?(issue_id, report)
        MOVED.include?(report.kind) || (report.kind == :nothing_to_do && @landings.merged?(issue_id))
      end

      def unjournaled(issue_id, sha)
        "issue #{issue_id}'s approved commit #{sha} is already on #{@base.name}, and no landing of issue " \
          "#{issue_id} is journaled"
      end

      # Read again rather than remembered, so a second landing of the same
      # issue writes no second transition.
      def in_flight?(issue_id) = @progress.call.status(issue_id) == IN_FLIGHT

      def approve(issue_id, sha)
        "approve it with `lain epic submit implementation #{@epic_slug} --issue #{issue_id} --digest #{sha}`"
      end

      def not_in_flight(issue_id, status)
        "issue #{issue_id} is #{status}, not #{IN_FLIGHT}: only an issue whose plan was approved and whose work " \
          "has not landed yet can land"
      end

      def unanchored(issue_id)
        "no worker commit anchored for epic #{@epic_slug} carries an approved implementation gate for issue " \
          "#{issue_id}, so nothing landed -- #{approve(issue_id, "SHA")}"
      end

      def ambiguous(issue_id, shas)
        "issue #{issue_id}'s implementation gate approved #{shas.size} different commits (#{shas.join(", ")}); " \
          "land the one meant with its full object name"
      end

      def never_merged(issue_id, sha)
        "#{@base.name} does not hold issue #{issue_id}'s approved commit #{sha}, so there is no merge to resume -- " \
          "land it with `lain epic land #{issue_id} #{@epic_slug}`"
      end

      def misplaced(issue_id, sha, refused)
        ["issue #{issue_id}'s commit #{sha} puts tests where the project's [tests] layout refuses them, so " \
         "nothing landed:", *refused.map { |verdict| "  #{verdict.path}: #{verdict.reason}#{placed_at(verdict)}" }]
          .join("\n")
      end

      def placed_at(verdict) = verdict.expected ? " -- it belongs at #{verdict.expected}" : ""
    end

    class LocalLanding
      # This epic's journaled landings, read fresh: a commit already on the
      # branch is this issue's landing only when its own merge is among them.
      class Landings
        def initialize(records, epic_slug:)
          @records = records
          @epic_slug = epic_slug
        end

        # The queue's and the journal's name for an issue's worker, one per
        # issue of one epic.
        def worker_id(issue_id) = "#{@epic_slug}/#{issue_id}"

        def worker(issue_id, ref:, sha:) = Isolation::LandingQueue::Worker.new(id: worker_id(issue_id), ref:, sha:)

        def merged?(issue_id)
          Journal.records(@records.call, type: LANDED)
                 .any? { |record| record["worker_key"] == worker_id(issue_id) && record["outcome"].to_s == "merged" }
        end
      end

      # The implementation gate's approvals, as issue and address together. An
      # implementation's address composes the stage, the epic and the commit
      # but not the issue, so the registry alone reads issue c's approval of a
      # commit as issue b's too. The decision record names its issue, and a
      # decision naming none approves no issue's landing.
      class Approvals
        # @param entries [Enumerable<Hash, String>] journal records or lines
        def self.from(entries)
          new(Journal.records(entries, type: Approval::SignoffQueue::JOURNAL_TYPE)
                     .select { |decision| implementation?(decision) }
                     .to_set { |decision| [decision["issue_id"], decision["artifact_digest"]] })
        end

        def self.implementation?(decision)
          decision["approved"] == true && decision["stage"] == "implementation" && !decision["issue_id"].to_s.empty?
        end
        private_class_method :implementation?

        def initialize(pairs)
          @pairs = pairs.freeze
          freeze
        end

        def approved?(digest, issue_id) = @pairs.include?([issue_id.to_s, digest.to_s])
      end

      # A re-sync's commit, handed to the queue only when it would itself be
      # admitted: nothing reaches the working branch before its gate.
      class Gated
        def initialize(resync, landing, admitted)
          @resync = resync
          @landing = landing
          @issues = admitted.to_h { |admission| [admission.worker.id, admission.issue_id] }
        end

        def call(worker, tip:)
          commit = @resync.call(worker, tip:)
          commit if commit && @landing.admissible?(@issues.fetch(worker.id), commit)
        end
      end

      # The commits a landing may be about: those a handback anchored, and
      # those the working branch already carries beyond the trunk.
      class Commits
        def initialize(git:, base:)
          @git = git
          @base = base
        end

        # @return [Array<Array(String, String)>] `[sha, ref]` per anchor
        def anchored
          listed = @git.run("for-each-ref", "--format=%(objectname) %(refname)",
                            "#{Isolation::Worktree::Handback::Naming::REF_NAMESPACE}/")
          listed.stdout.lines.map { |line| line.split(" ", 2).map(&:strip) }
        end

        # Anchors can be reaped once their work is on the branch, so a resume
        # also looks at what the branch itself carries.
        def all = anchored + carried

        def landed?(sha) = @git.run("merge-base", "--is-ancestor", sha, @base.ref).exitstatus.zero?

        private

        def carried
          shell = @git.run("rev-list", @base.ref, "--not", "refs/heads/#{Isolation::WorkingBranch::TRUNK}")
          shell.exitstatus.zero? ? shell.stdout.split.map { |sha| [sha, nil] } : []
        end
      end

      # The layout guard over the tests a commit changes, run over that
      # commit's own tree.
      class Placement
        def initialize(repo_root:, layout:, base:, shell_out_factory:)
          @repo_root = repo_root
          @layout = layout
          @base = base
          @shell_out_factory = shell_out_factory
        end

        # Every refusing verdict counts, `:no_source` included.
        # @return [Array<TestLayout::Guard::Verdict>]
        def refusals(sha)
          return [] unless @layout.in_force?

          tests = changed(sha).select { |path| @layout.mapping.test_file?(path) }
          tests.empty? ? [] : snapshot(sha) { |tree| checked(tree, tests) }
        end

        private

        # Against the merge base, so a sibling's tests already on the branch
        # are not judged as this commit's; `--relative` names them from the
        # project, which may sit inside a larger repository, and drops the rest.
        def changed(sha)
          listed = git!({}, "diff", "--name-only", "-z", "--relative", "--no-renames", "--diff-filter=d",
                        "#{@base.tip}...#{sha}")
          listed.stdout.split("\0").map { |path| path.force_encoding(Isolation::Checkout::FILESYSTEM) }
        end

        def checked(tree, tests)
          guard = TestLayout::Guard.new(layout: @layout, root: tree)
          tests.map { |path| guard.check(path, File.read(File.join(tree, path))) }.select(&:refused?)
        end

        # A throwaway index, so the commit's tree is written out without
        # touching the parent's index or registering a worktree.
        def snapshot(sha)
          Dir.mktmpdir("lain-landing-layout") do |scratch|
            tree = File.join(scratch, "tree")
            index = { "GIT_INDEX_FILE" => File.join(scratch, "index") }
            git!(index, "read-tree", sha)
            git!(index, "checkout-index", "--all", "--force", "--prefix=#{tree}/")
            yield File.join(tree, git!({}, "rev-parse", "--show-prefix").stdout.strip)
          end
        end

        def git!(env, *args)
          shell = @shell_out_factory.call("git", "-C", @repo_root, *args,
                                          environment: Isolation::Worktree::GIT_CONTEXT_SCRUB.merge(env))
          shell.run_command
          return shell if shell.exitstatus.zero?

          raise MisplacedTests, "the layout check could not run: git #{args.first} failed " \
                                "(exit #{shell.exitstatus}): #{shell.stderr.strip}"
        end
      end
    end
  end
end
