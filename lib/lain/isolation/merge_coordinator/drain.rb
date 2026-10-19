# frozen_string_literal: true

module Lain
  module Isolation
    module MergeCoordinator
      # The one process landing a branch's queued entries: under the branch's
      # drain lock it lands them a batch of up to `batch_cap` at a time,
      # completes each entry with its result, and journals one
      # `landing_batch` record per batch.
      #
      # A drainer that finds the lock held keeps trying while anything is
      # pending, and the holder reads the spool again once it has released, so
      # an entry enqueued between the holder's last read and its release is
      # never stranded: whichever drainer takes the lock next lands it.
      #
      # Results are written before the batch's record, so a drainer killed in
      # between leaves that batch landed but unrecorded.
      class Drain
        # The drain lock as the queue inside a drainer sees it. The drainer
        # already holds the real one, and flock is not reentrant: a second
        # hold from this process would wait on itself.
        module AlreadyHeld
          def self.hold(**) = yield
        end

        # The repository's main worktree is the root of the config read, the
        # journal written and the verify tree reused, whichever checkout
        # started the drainer.
        #
        # @param repo_root [String] any checkout of the repository
        # @param branch [String] the branch whose queue is drained
        # @param paths [Paths] where journals, the verify worktree and the suite lock live
        # @param shell_out_factory [#call] builds every git and verify subprocess
        # @param config [Config] whose `isolation` table names the verifier, the caps and the merge strategy
        # @param notice [#call] told what the verify did about a verify group a killed drainer left running
        # @return [Drain]
        # @raise [Lain::Error] when repo_root is in no repository
        def self.for(repo_root:, branch:, paths:, shell_out_factory: Shell::Out.public_method(:new),
                     config: Config.load(root: MergeCoordinator.main_root(repo_root, shell_out_factory:)),
                     notice: ParentLock::Silent)
          root = MergeCoordinator.main_root(repo_root, shell_out_factory:)
          home = Home.for(repo_root: root, branch:, shell_out_factory:)
          isolation = config.isolation
          journal_path = File.join(paths.sessions_dir(project: paths.project_hash(root)), ::Lain::Journal.stem)
          new(lock: home.drain_lock, branch:, spool: Spool.new(home), isolation:,
              journal: -> { ::Lain::Journal.open(journal_path) },
              verify: Verifier.from(isolation, paths:, shell_out_factory:, notice:),
              queue_for: queues(root, branch, isolation, paths, shell_out_factory),
              git: Checkout.new(root, shell_out_factory:), notice:)
        end

        def self.queues(root, branch, isolation, paths, shell_out_factory)
          base = WorkingBranch.new(branch, repo_root: root, git: Checkout.new(root, shell_out_factory:))
          lambda do |journal:, verify:|
            LandingQueue.candidate(root:, base:, journal:, isolation:, paths:, lock: AlreadyHeld, verify:,
                                   shell_out_factory:)
          end
        end
        private_class_method :queues

        # @param lock [FileLock] the branch's drain lock
        # @param branch [String] the branch the batches land onto
        # @param spool [Spool] the branch's entries and results
        # @param isolation [Config::Isolation] the verifier's name, `batch_cap` and `rebuild_cap`
        # @param journal [#call] opens the journal each `landing_batch` goes to
        # @param verify [#call] `call(candidate)` answering a {LandingQueue::Verification}
        # @param queue_for [#call] `call(journal:, verify:)` answering a fresh {LandingQueue}
        # @param git [Checkout] asked whether a queued commit is an ancestor of a later entry's
        # @param clock [#call] monotonic seconds, which time the verifies
        # @param wall_clock [#call] the Time a batch starts, which entries' waits are measured to
        # @param sleeper [#call] waits between tries while another process holds the lock
        # @param interval [Numeric] seconds between those tries, {FileLock}'s own default
        # @param notice [#call] told when git cannot say whether an entry is superseded
        def initialize(lock:, branch:, spool:, isolation:, journal:, verify:, queue_for:, git:,
                       clock: RunClock::MONOTONIC, wall_clock: -> { Time.now },
                       sleeper: Kernel.method(:sleep), interval: 0.05, notice: ParentLock::Silent)
          @lock = lock
          @branch = branch
          @spool = spool
          @isolation = isolation
          @journal = journal
          @verify = verify
          @queue_for = queue_for
          @git = git
          @notice = notice
          @clock = clock
          @wall_clock = wall_clock
          @sleeper = sleeper
          @interval = interval
        end

        # Each entry's result names its batch by its ordinal within this run,
        # counted from 1, so two runs both have a batch 1.
        # @return [Integer] batches landed this run; 0 when another process
        #   held the drain lock until nothing was pending
        def call
          journal = @journal.call
          total = turn(journal, 0)
          total = turn(journal, total) until @spool.pending.empty?
          total
        ensure
          journal&.close
        end

        private

        def turn(journal, total)
          took = @lock.try { total = batches(journal, total) }
          @sleeper.call(@interval) unless took
          total
        end

        def batches(journal, total)
          until (entries = next_batch).empty?
            total += 1
            land(entries, journal, total)
          end
          total
        end

        # One worker id per batch: a second entry for the same worker is the
        # same work moved on, and lands against what the first one left.
        def next_batch
          waiting = @spool.pending
          superseded = superseded_by(waiting)
          superseded.each { |entry, later| decline_superseded(entry, later) }
          (waiting - superseded.keys).uniq { |entry| entry.worker.id }.first(@isolation.batch_cap)
        end

        # Landing an amended branch's abandoned commits too would land work its owner discarded.
        def superseded_by(waiting)
          waiting.each_with_index.filter_map do |entry, index|
            later = waiting.drop(index + 1).reverse.find { |each| each.worker.id == entry.worker.id }
            [entry, later] if later && !continues?(entry, later)
          end.to_h
        end

        # A git error leaves the pair as it was before supersession was checked, since
        # declining a valid entry on a guess loses work.
        def continues?(entry, later)
          shell = @git.run("merge-base", "--is-ancestor", entry.worker.sha, later.worker.sha)
          return shell.exitstatus.eql?(0) if [0, 1].include?(shell.exitstatus)

          @notice.call("worker #{entry.worker.id}: cannot tell whether entry #{entry.id} is superseded by " \
                       "entry #{later.id}, landing both: #{shell.stderr.strip}")
          true
        end

        def decline_superseded(entry, later)
          report = WorkerHandoff::Report.new(kind: :declined, ref: entry.worker.ref, sha: entry.worker.sha,
                                             detail: "superseded by entry #{later.id}")
          @spool.complete(entry.id, Spool::Result.new(id: entry.id, report:, verification: nil, batch: nil))
        end

        def land(entries, journal, number)
          started = @wall_clock.call.to_f
          stopwatch = Stopwatch.new(@verify, @clock)
          outcome = Batch.new(queue_for: -> { @queue_for.call(journal:, verify: stopwatch) },
                              rebuild_cap: @isolation.rebuild_cap).call(entries.map(&:worker))
          completed(entries, outcome, number)
          journal << Tally.new(entries, outcome).record(branch: @branch, verifier: @isolation.verifier,
                                                        verify_wall_s: stopwatch.seconds, started:)
        end

        def completed(entries, outcome, number)
          entries.zip(outcome.reports, outcome.verifications).each do |entry, report, verification|
            @spool.complete(entry.id, Spool::Result.new(id: entry.id, report:, verification:, batch: number))
          end
        end

        # Times every verify a batch runs, rebuilds and halves included.
        class Stopwatch
          # @return [Float] seconds spent verifying so far
          attr_reader :seconds

          def initialize(verify, clock)
            @verify = verify
            @clock = clock
            @seconds = 0.0
          end

          def call(candidate)
            began = @clock.call
            @verify.call(candidate)
          ensure
            @seconds += @clock.call - began
          end
        end

        # What became of each worker in one batch, as the `landing_batch`
        # record sorts them. A worker already on the branch counts as landed,
        # since its work is there; a declined worker whose verification failed
        # was ejected by the verifier, and every other worker that did not
        # land was declined.
        class Tally
          LANDED = %i[merged resolved nothing_to_do].freeze

          # @param entries [Array<Spool::Entry>] the batch, in landing order
          # @param outcome [Batch::Outcome] one report and verification per entry
          def initialize(entries, outcome)
            @entries = entries
            @outcome = outcome
            @keys = entries.map { |entry| Worktree::Handback::Naming.new(entry.worker.id).key }
            @fates = outcome.reports.zip(outcome.verifications).map { |report, judged| fate(report, judged) }
          end

          # @param branch [String] the branch the batch landed on
          # @param verifier [String] the verifier strategy's name
          # @param verify_wall_s [Float] seconds spent verifying
          # @param started [Float] epoch seconds the batch started at
          # @return [Telemetry::LandingBatch]
          def record(branch:, verifier:, verify_wall_s:, started:)
            Telemetry::LandingBatch.new(
              branch:, desk: :candidate, verifier:, worker_keys: @keys,
              landed: of(:landed), ejected: of(:ejected), declined: of(:declined),
              verifies: @outcome.verifies, rebuilds: @outcome.rebuilds, verify_wall_s:,
              queue_wait_s: waits(started), outcome:
            )
          end

          private

          def fate(report, judged)
            return :landed if LANDED.include?(report.kind)
            return :ejected if report.kind == :declined && judged&.outcome == :failed

            :declined
          end

          def of(fate) = @keys.zip(@fates).filter_map { |key, each| key if each == fate }

          # A wall clock stepped back must not record a negative wait.
          def waits(started) = @keys.zip(@entries).to_h { |key, entry| [key, [started - entry.enqueued_at, 0.0].max] }

          def outcome
            return :landed if @fates.all?(:landed)

            @fates.include?(:landed) ? :partial : :none
          end
        end
      end
    end
  end
end
