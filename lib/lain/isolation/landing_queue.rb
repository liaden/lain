# frozen_string_literal: true

module Lain
  module Isolation
    # Lands finished workers' anchored commits onto the working branch, one at
    # a time and in the order they were handed in. On the epic path it is the
    # only thing that merges.
    #
    # LAND WHAT INTEGRATES, THEN ASK. Every commit is probed against the tip it
    # would land on, and re-probed after each landing, so nothing merges
    # against a tip it was not probed against. A stale worker is not asked to
    # re-sync while siblings are still landing: the tip it would rebase onto
    # is about to move again. Once nothing more lands, each stale worker is
    # asked once, against the tip the others produced.
    #
    # WHAT STILL CONFLICTS STANDS. Whatever still conflicts once re-sync is
    # spent is reported conflicted, its work on its ref. Verification then
    # runs once, over what landed.
    #
    # ONE MERGER PER DESK, ACROSS PROCESSES. The run holds its desk's lock;
    # the {CandidateDesk}'s is the branch's drain lock, so `lain epic land` and
    # a drainer of the same branch take turns.
    class LandingQueue
      # A queue that cannot run at all: no branch to land onto.
      class Refused < Error
        include RefusedBeforeActing
      end

      NOTHING_LANDED = "nothing landed, so there was nothing to verify"

      # A finished worker: the commit to land, and the ref its commits are
      # anchored under. The ref is required: a worker's commits are never
      # optional, and one the queue could not name a ref for would be left
      # reachable from nothing if its conflict stood.
      Worker = Data.define(:id, :ref, :sha) do
        def initialize(id:, ref:, sha:)
          raise ArgumentError, "a worker's ref must name where its commits are anchored, got #{ref.inspect}" if
            ref.to_s.strip.empty?

          super(id: -id.to_s, ref: -ref.to_s, sha: -sha.to_s)
        end
      end

      # What one worker's turn in the queue came to, as the handback's own
      # {WorkerHandoff::Report}.
      Landed = Data.define(:worker, :report) do
        def moved? = report.moved?
        def stale? = false
      end

      # A worker whose commit conflicts with the tip, and the paths it
      # conflicts on.
      Stale = Data.define(:worker, :paths) do
        def stale? = true
      end

      # The one verification over the combined tree. `outcome` is `passed`,
      # `failed` or `skipped`.
      Verification = Data.define(:outcome, :tip, :detail) do
        def initialize(outcome:, tip:, detail: "")
          super(outcome: outcome.to_sym, tip: Freezable::Fields.pinned(tip), detail: -detail.to_s)
        end
      end

      # `stale_tip` says the branch moved while the batch was being verified,
      # so nothing landed and the batch is worth building again.
      Result = Data.define(:landed, :verification, :stale_tip) do
        def initialize(landed:, verification:, stale_tip: false)
          super(landed: landed.dup.freeze, verification:, stale_tip: Freezable::Fields.boolean!(stale_tip, "stale_tip"))
        end

        # @raise [KeyError] for a worker that was never queued
        def report(id)
          entry = landed.find { |each| each.worker.id == id.to_s }
          raise KeyError, "no worker #{id.inspect} was queued" if entry.nil?

          entry.report
        end
      end

      # No worker to ask: a commit landed from the command line has no live
      # worker behind it.
      module Resync
        # @return [String, nil] a commit to land instead, or nil
        def self.call(_worker, **) = nil
      end

      # The queue every coordinated landing builds: the batch is a candidate
      # commit verified in the project's scratch checkout, and the branch
      # moves only by fast-forward once verification has not failed. Its lock
      # is the branch's drain lock, so `lain epic land` and a drainer of the
      # same branch take turns.
      #
      # @param root [String] any checkout of the repository; the scratch
      #   checkout is keyed by its main worktree, so every landing of the
      #   branch reuses one
      # @param base [WorkingBranch] the branch the batch lands onto
      # @param journal [#<<] where each landed worker's handback record goes
      # @param isolation [Config::Isolation] merge strategy, retries and verification
      # @param paths [Paths] where the scratch checkout and the suite lock live
      # @param notice [#call] told who holds the branch's landing drain, or the
      #   parent checkout's lock, when a landing waits on it for long, and what
      #   the configured verify did about a verify group a dead holder left
      # @param lock [#hold, nil] a drain lock the caller already holds, handed
      #   to the desk in place of its own; nil lets the desk take its own
      # @param shell_out_factory [#call] builds every git and verify subprocess
      # @param verify [#call] judges the candidate; the configured verifier unless given
      # @return [LandingQueue]
      def self.candidate(root:, base:, journal:, isolation:, paths:, notice: ParentLock::Silent, lock: nil,
                         shell_out_factory: Shell::Out.public_method(:new),
                         verify: Verifier.from(isolation, paths:, shell_out_factory:, notice:))
        checkout = VerifyCheckout.for(repo_root: MergeCoordinator.main_root(root, shell_out_factory:),
                                      branch: base.name, paths:, keep: isolation.verify_keep, shell_out_factory:)
        desk = CandidateDesk.new(
          repo_root: root, base:, journal:, checkout:, strategy: MergeStrategy.from(isolation), shell_out_factory:,
          home: MergeCoordinator::Home.for(repo_root: root, branch: base.name, shell_out_factory:),
          **(lock ? { lock: } : {})
        )
        new(repo_root: root, base:, desk:, retries: isolation.rebase_retries, notice:, shell_out_factory:, verify:)
      end

      # @param repo_root [String] the parent checkout
      # @param base [WorkingBranch] the branch every worker lands onto
      # @param desk [CandidateDesk] where workers land, and where each landing is journalled
      # @param retries [Integer] `rebase_retries`: how many times a stale worker
      #   is asked to re-sync; 0 asks none
      # @param verify [#call] `call(candidate)` answering a {Verification} for
      #   a {Candidate}; called once per run in which anything landed
      # @param notice [#call] told who holds the branch's landing drain, or the
      #   parent checkout's lock, when a landing waits on it for long
      # @param shell_out_factory [#call] builds the subprocess runner
      def initialize(repo_root:, base:, desk:, retries: 1,
                     verify: Verifier::Skipped, notice: ParentLock::Silent,
                     shell_out_factory: Shell::Out.public_method(:new))
        raise Refused, "a landing queue needs a named working branch to land onto; none was given" if base.name.empty?

        root = File.expand_path(repo_root)
        @desk = desk
        @probe = Probe.new(parent: Checkout.new(root, shell_out_factory:), strategy: @desk.strategy)
        @retries = Integer(retries)
        @verify = verify
        @notice = notice
      end

      # @param workers [Array<Worker>] in landing order
      # @param resync [#call] `call(worker, tip:)` answering the full SHA of a
      #   re-synced commit to land instead, or nil. Whatever it answers lands
      #   as the worker's work, so a caller gating what may land gates it here.
      # @return [Result] one {Landed} per worker, in the order given
      # @raise [WorkingBranch::Refused] when the branch names no commit
      def call(workers, resync: Resync)
        @desk.lock.hold(notice: @notice) { settle(workers.to_a, resync) }
      end

      private

      def settle(workers, resync)
        @desk.ready!
        landed, stale = integrate(workers)
        resynced, leftovers = resynced(stale, resync)
        standing = leftovers.map { |waiting| @desk.stand(waiting.worker, waiting.paths) }
        outcomes = landed + resynced + standing
        @desk.conclude(verified(outcomes), ordered(workers, outcomes), notice: @notice)
      end

      # Passes over the waiting workers in order, for as long as a pass lands
      # something: a landing can make a worker that conflicted earlier clean.
      def integrate(workers)
        landed, waiting = workers.map { |worker| attempt(worker) }.partition { |each| !each.stale? }
        return [landed, waiting] if waiting.empty? || landed.none?(&:moved?)

        more, stale = integrate(waiting.map(&:worker))
        [landed + more, stale]
      end

      def resynced(stale, resync)
        return [[], stale] if @retries.zero?

        stale.map { |waiting| asked(waiting, resync, @retries) }.partition { |each| !each.stale? }
      end

      # Up to `rebase_retries` asks per worker, each against the tip as it is
      # then, stopping at the first re-sync that integrates.
      def asked(waiting, resync, asks)
        result = attempt(@desk.resynced(waiting.worker, resync.call(waiting.worker, tip: @desk.tip)))
        result.stale? && asks > 1 ? asked(result, resync, asks - 1) : result
      end

      def attempt(worker)
        probed = @probe.call(@desk.tip, worker.sha)
        case probed.verdict
        when :landed then @desk.already(worker)
        when :fast_forward, :clean then @desk.landed(worker, @desk.merge(worker, probed))
        when :conflicted then Stale.new(worker:, paths: probed.paths)
        else @desk.failed(worker, probed.detail)
        end
      end

      def ordered(workers, outcomes) = workers.map { |worker| outcomes.find { |each| each.worker.id == worker.id } }

      def verified(outcomes)
        return Verification.new(outcome: :skipped, tip: @desk.tip, detail: NOTHING_LANDED) if outcomes.none?(&:moved?)

        @verify.call(@desk.candidate)
      end
    end

    class LandingQueue
      # Whether a commit integrates with a tip, asked of git without touching
      # the parent's index or working tree.
      class Probe
        # `tree` is the merged tree a clean merge wrote, and "" for every other verdict;
        # `tip` is the commit the verdict was taken against.
        Probed = Data.define(:verdict, :paths, :detail, :tree, :tip)

        def initialize(parent:, strategy:)
          @parent = parent
          @strategy = strategy
        end

        # @return [Probed] `landed` when the tip already holds the commit,
        #   `fast_forward`, `clean`, `conflicted` with the paths, or `failed`
        def call(tip, commit) = verdict(tip, commit).with(tip:)

        private

        def verdict(tip, commit)
          return probed(:landed) if ancestor?(commit, tip)
          return probed(:fast_forward) if ancestor?(tip, commit)

          written(@parent.run(*@strategy.probe(tip, commit)))
        end

        def ancestor?(older, newer) = @parent.ancestor?(older, newer)

        # Exit 1 is both "conflicted" and "could not merge at all"; only the
        # first writes a tree first, so the tree is what tells them apart.
        def written(shell)
          fields = shell.stdout.split("\0")
          return probed(:clean, tree: fields.first) if Shell::Out.ok?(shell)
          return probed(:conflicted, paths: conflicted(fields)) if WorkingBranch::FULL_SHA.match?(fields.first.to_s)

          probed(:failed, detail: "git merge-tree failed (exit #{shell.exitstatus}): #{shell.stderr.strip}")
        end

        def conflicted(fields) = fields.drop(1).reject(&:empty?).uniq.map { |path| path.force_encoding(FILESYSTEM) }

        def probed(verdict, paths: [], detail: "", tree: "") = Probed.new(verdict:, paths:, detail:, tree:, tip: "")
      end
    end
  end
end
