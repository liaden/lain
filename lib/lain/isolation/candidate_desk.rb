# frozen_string_literal: true

module Lain
  module Isolation
    # A {LandingQueue} desk that lands a batch as one candidate commit, built
    # in the object store, and moves the branch to it only once verification
    # has not failed. No checkout merges anything on the way: the candidate is
    # verified in a scratch worktree, and the branch moves by a fast-forward
    # where it is checked out, or by compare-and-swap where it is not.
    #
    # The journal hears of a worker only after the branch holds its work,
    # because resuming an epic reads a `merged` handback record as landed.
    #
    # The lock is the branch's drain lock, so the order is always the drain
    # lock, then {ParentLock}, and only one drainer resets the scratch tree.
    class CandidateDesk
      REASON = "lain candidate"

      # @param repo_root [String] any checkout of the repository
      # @param base [WorkingBranch] the branch the batch lands onto
      # @param home [MergeCoordinator::Home] the branch's home, whose drain lock the run holds
      # @param checkout [VerifyCheckout] the scratch worktree a candidate is verified in
      # @param journal [#<<] where each landed worker's {Telemetry::Handback} goes
      # @param strategy [MergeStrategy] how probes and merges are spelt
      # @param shell_out_factory [#call] builds the subprocess runner
      def initialize(repo_root:, base:, home:, checkout:, journal:, strategy:, shell_out_factory:)
        @base = base
        @home = home
        @checkout = checkout
        @journal = journal
        @strategy = strategy
        root = File.expand_path(repo_root)
        @git = Checkout.new(root, shell_out_factory:)
        @scratch = Checkout.new(checkout.path, shell_out_factory:)
        @probe = LandingQueue::Probe.new(parent: @git, strategy:)
        @forward = Forward.new(repo_root: root, base:, strategy:, shell_out_factory:)
        # Its own records would land before the branch moves; this desk journals at the end.
        @handback = Worktree::Handback.new(base:, repo_root: checkout.path, journal: Channel::Null.instance,
                                           strategy:, shell_out_factory:)
      end

      # @return [String] the candidate's head, the branch's tip until something merges
      attr_reader :tip

      attr_reader :strategy

      # @return [FileLock]
      def lock = @home.drain_lock

      def branch = @base.name

      # Where a conflicted merge stands for a resolver to edit: the scratch
      # worktree, never a checkout anybody works in.
      def repo_root = @checkout.path

      # Reads the branch's tip once, under the lock, as the candidate's start.
      # @raise [WorkingBranch::Refused] when the branch names no commit
      def ready!
        @start = @tip = @base.tip
      end

      # @return [Candidate] the scratch worktree standing on the candidate
      def candidate
        anchored = @git.update_ref(candidate_ref, tip, reason: REASON)
        raise Error, "lain could not write #{candidate_ref}: #{anchored.stderr.strip}" unless anchored.exitstatus.zero?

        @checkout.at(tip)
      end

      # @return [Worktree::Handback::Outcome] `merged` with the candidate's new
      #   head, `conflicted` with the merge replayed in the scratch worktree for
      #   a resolver, `nothing_to_do`, or `failed`
      def merge(worker)
        probed = @probe.call(tip, worker.sha)
        case probed.verdict
        when :landed then outcome(:nothing_to_do, worker, detail: "the candidate already holds #{worker.sha}")
        when :fast_forward then advanced(worker, worker.sha, fast_forward: true)
        when :clean then joined(worker, probed.tree)
        when :conflicted then replayed(worker, probed.paths)
        else outcome(:failed, worker, detail: probed.detail)
        end
      end

      def continue(worker)
        continued = @handback.continue(worker.sha, worker_id: worker.id)
        @tip = continued.sha if continued.kind == :merged
        continued
      end

      def abandon(worker) = @handback.abandon(worker.sha, worker_id: worker.id)

      def landed(worker, outcome)
        LandingQueue::Landed.new(worker:, report: WorkerHandoff::Report.from(outcome).with(ref: worker.ref))
      end

      def already(worker) = report(worker, :nothing_to_do, detail: "#{branch} already holds #{worker.sha}")

      def failed(worker, detail) = report(worker, :failed, detail:)

      def stand(worker, paths, detail = LandingQueue::ParentDesk::STANDS)
        report(worker, :conflicted, paths:, detail:)
      end

      # Moves the worker's anchor to a re-synced commit by compare-and-swap,
      # so the ref keeps what will land. A lost swap keeps the worker as it was.
      def resynced(worker, commit)
        return worker if commit.nil? || commit == worker.sha

        moved = @git.update_ref(worker.ref, commit, worker.sha, reason: "lain landing queue: re-synced")
        moved.exitstatus.zero? ? worker.with(sha: commit) : worker
      end

      # @param verification [LandingQueue::Verification] the verifier's verdict on the candidate
      # @param outcomes [Array<LandingQueue::Landed>] one per worker, in landing order
      # @param notice [#call] told who holds the parent checkout's lock when
      #   moving the branch waits on it for long
      # @return [LandingQueue::Result] the outcomes as they stand once the
      #   branch moved; every moved worker declined when it did not
      def conclude(verification, outcomes, notice: ParentLock::Silent)
        return LandingQueue::Result.new(landed: outcomes, verification:) if outcomes.none?(&:moved?)
        return declined(outcomes, verification, "the batch failed verification: #{verification.detail}") if
          verification.outcome == :failed

        forwarded(@forward.call(from: @start, to: tip, notice:), verification, outcomes)
      ensure
        @git.run("update-ref", "-d", candidate_ref)
      end

      private

      def forwarded(move, verification, outcomes)
        case move.outcome
        when :moved then journaled(outcomes, verification)
        when :stale then declined(outcomes, verification, move.detail, stale_tip: true)
        else declined(outcomes, verification, move.detail)
        end
      end

      def journaled(outcomes, verification)
        outcomes.select(&:moved?).each { |entry| record(entry) }
        LandingQueue::Result.new(landed: outcomes, verification:)
      end

      def declined(outcomes, verification, detail, stale_tip: false)
        landed = outcomes.map { |entry| entry.moved? ? report(entry.worker, :declined, detail:) : entry }
        LandingQueue::Result.new(landed:, verification:, stale_tip:)
      end

      def candidate_ref = "refs/lain/candidate/#{File.basename(@home.dir)}"

      def joined(worker, tree)
        made = @git.run("commit-tree", tree, "-p", tip, "-p", worker.sha, "-m", "Merge #{worker.ref} into #{branch}")
        return outcome(:failed, worker, detail: "git commit-tree failed: #{made.stderr.strip}") unless
          made.exitstatus.zero?

        advanced(worker, made.stdout.strip, fast_forward: false)
      end

      def advanced(worker, commit, fast_forward:)
        @tip = commit
        outcome(:merged, worker, sha: commit, fast_forward:)
      end

      # The resolver edits files and cannot run git, so the conflict is laid
      # out in the scratch worktree with its markers for it to read.
      def replayed(worker, paths)
        @checkout.at(tip)
        @scratch.run(*@strategy.merge(worker.sha))
        outcome(:conflicted, worker, paths:, parent_state: :merging, detail: Worktree::Handback::IN_PROGRESS)
      end

      def outcome(kind, worker, **)
        Worktree::Handback::Outcome.new(kind:, worker_key: key(worker), ref: worker.ref, **)
      end

      def key(worker) = Worktree::Handback::Naming.new(worker.id).key

      def report(worker, kind, **)
        LandingQueue::Landed.new(worker:, report: WorkerHandoff::Report.new(kind:, ref: worker.ref, **))
      end

      # A journal reports a decision and never overturns one, so a sink that
      # raises costs the line.
      def record(entry)
        @journal << Telemetry::Handback.new(worker_key: key(entry.worker), outcome: :merged, ref: entry.worker.ref,
                                            strategy: @strategy.to_s, fast_forward: entry.report.fast_forward,
                                            sha: entry.report.sha)
      rescue StandardError
        nil
      end
    end

    class CandidateDesk
      # Moves a branch from one commit to another without ever merging: a
      # fast-forward in the worktree that has it checked out, so that checkout
      # follows, or a compare-and-swap where none has. A worktree git lists as
      # prunable has no directory left to follow, so it holds nothing here.
      class Forward
        Move = Data.define(:outcome, :detail)

        def initialize(repo_root:, base:, strategy:, shell_out_factory:)
          @repo_root = repo_root
          @git = Checkout.new(repo_root, shell_out_factory:)
          @base = base
          @strategy = strategy
          @shell_out_factory = shell_out_factory
        end

        # @return [Move] `moved`, `stale` when the branch is no longer at
        #   `from`, or `refused` with what stood in the way
        def call(from:, to:, notice: ParentLock::Silent)
          ParentLock.for(repo_root: @repo_root, shell_out_factory: @shell_out_factory).hold(notice:) do
            holder = holding
            holder ? fast_forwarded(holder, from, to) : swapped(from, to)
          end
        end

        private

        def holding
          listed = @git.run("worktree", "list", "--porcelain", "-z").stdout.split("\0\0")
          held = listed.map { |record| fields(record) }
                       .find { |each| each["branch"] == @base.ref && !each.key?("prunable") }
          held && Checkout.new(held.fetch("worktree"), shell_out_factory: @shell_out_factory)
        end

        # A key with no value, such as `detached` or `prunable` alone, reads as "".
        def fields(record) = record.split("\0").to_h { |line| line.split(" ", 2).then { |key, val| [key, val.to_s] } }

        # A branch moved backward would still fast-forward to the candidate,
        # so the tip is checked first; the swap's own old value covers it there.
        def fast_forwarded(holder, from, to)
          stale = unmoved(from)
          return stale if stale

          shell = holder.run(*@strategy.fast_forward(to))
          return Move.new(outcome: :moved, detail: "") if @git.target(@base.ref) == to

          unmoved(from) || in_the_way(holder, from, to, shell)
        end

        def swapped(from, to)
          shell = @git.update_ref(@base.ref, to, from, reason: "lain landing: candidate")
          return Move.new(outcome: :moved, detail: "") if shell.exitstatus.zero?

          unmoved(from) || Move.new(outcome: :refused, detail: "git update-ref refused: #{shell.stderr.strip}")
        end

        def unmoved(from)
          return if @git.target(@base.ref) == from

          Move.new(outcome: :stale, detail: "#{@base.name} moved while the batch was verified")
        end

        def in_the_way(holder, from, to, shell)
          blocking = written(from, to) & uncommitted(holder)
          named = if blocking.empty?
                    shell.stderr.strip
                  else
                    "uncommitted or untracked files stand where the batch writes: #{blocking.join(", ")}"
                  end
          Move.new(outcome: :refused, detail: "#{@base.name} could not fast-forward: #{named}")
        end

        def written(from, to) = paths(@git.run("diff", "--name-only", "-z", from, to).stdout.split("\0"))

        def uncommitted(holder)
          paths(holder.run("status", "--porcelain", "-z", "--no-renames", "--untracked-files=all").stdout.split("\0")
                      .grep(/\A.. /).map { |line| line[3..] })
        end

        def paths(listed) = listed.map { |path| path.force_encoding(FILESYSTEM) }
      end
    end
  end
end
