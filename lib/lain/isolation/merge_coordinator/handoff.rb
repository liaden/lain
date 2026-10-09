# frozen_string_literal: true

module Lain
  module Isolation
    module MergeCoordinator
      # A chat child's completion when its branch is landed by the merge
      # coordinator: anchor the worker's commits on their ref, release the
      # lease, queue the anchored commit for the branch's drainer, and start
      # one. Nothing here merges into the parent checkout, so a human's
      # uncommitted edits there never block a handback, and no handback waits
      # on another's merge.
      #
      # It answers the {WorkerHandoff} duck, so {Leases} and the {Supervisor}
      # hold it where they held that one.
      #
      # The release waits in an `ensure` for the anchor, because once the
      # checkout is reclaimed the ref is all that keeps its commits reachable.
      class Handoff
        QUEUED = "queued as %<id>s; lain land wait %<id>s --branch %<branch>s"

        CHECKS_FAILED = "not queued because the checks failed after their retries"

        UNQUEUED = "the work is anchored on %<ref>s and was not queued; " \
                   "run `lain land enqueue %<ref>s --branch %<branch>s --id %<key>s` to land it"

        # @param repo_root [String] the repository the worker's checkout was cut from
        # @param branch [String] the branch the queued work lands on
        # @param journal [#<<] where each handback's {Telemetry::Handback} record goes
        # @param spawner [#drain] starts the detached drainer; see {Spawner}
        # @param shell_out_factory [#call] builds every git subprocess
        # @return [Handoff]
        def self.over(repo_root:, branch:, journal: Channel::Null.instance, spawner: Spawner.new,
                      shell_out_factory: Shell::Out.public_method(:new))
          handback = Worktree::Handback.new(repo_root:, base: WorkingBranch::NONE, shell_out_factory:)
          new(handback:, repo_root:, branch:, journal:, spawner:, shell_out_factory:)
        end

        # @return [String] the repository the worker's commits are anchored in
        attr_reader :repo_root

        # @param handback [#anchor] {Worktree::Handback}, whose own journal
        #   should be silent, since this object writes the one record
        # @param repo_root [String] the repository the worker's checkout was cut from
        # @param branch [String] the branch the queued work lands on
        # @param journal [#<<] where each handback's {Telemetry::Handback} record goes
        # @param spawner [#drain] starts the detached drainer; see {Spawner}
        # @param shell_out_factory [#call] builds the git subprocess that finds the main worktree
        def initialize(handback:, repo_root:, branch:, journal: Channel::Null.instance, spawner: Spawner.new,
                       shell_out_factory: Shell::Out.public_method(:new))
          @handback = handback
          @repo_root = File.expand_path(repo_root)
          @branch = branch.to_s
          @journal = journal
          @spawner = spawner
          @shell_out_factory = shell_out_factory
        end

        # @param lease [#worker_env, #release, #released?, nil] the live lease
        # @param worker_id [Object] names the ref and the queued entry's worker
        # @param sync [#to_record] what the checks and the self-sync did, which
        #   rides the handback record
        # @return [WorkerHandoff::Report] `:queued` naming the entry, or what
        #   kept the work off the queue
        def reclaim(lease, worker_id:, sync: SelfSync::Result::NONE)
          settle(lease, worker_id, sync) do |anchored|
            checks_failed?(sync) ? declined(anchored, CHECKS_FAILED) : queued(anchored, worker_id)
          end
        end

        # A worker that never returned had no checks run, so its work is
        # anchored and never queued: the spool holds only checked work.
        #
        # @param lease [#worker_env, #release, #released?, nil] the live lease
        # @param worker_id [Object] names the ref the work is anchored on
        # @param sync [#to_record] what the self-sync did on the way out
        # @return [WorkerHandoff::Report] `:declined` naming the ref and how to queue it
        def surrender(lease, worker_id:, sync: SelfSync::Result::NONE)
          settle(lease, worker_id, sync) do |anchored|
            declined(anchored, format(UNQUEUED, ref: anchored.ref, branch: @branch, key: anchored.worker_key))
          end
        end

        private

        def settle(lease, worker_id, sync, &disposal)
          return WorkerHandoff::Report.nothing if lease.nil? || lease.released?

          anchored = anchored(lease, worker_id)
          journaled(anchored.worker_key, disposed(anchored, &disposal), sync)
        end

        def anchored(lease, worker_id)
          @handback.anchor(lease, worker_id:)
        ensure
          lease.release
        end

        # A raise past the anchor still names the ref, since that is where the work is.
        def disposed(anchored)
          return WorkerHandoff::Report.from(anchored) if anchored.ref.nil?

          yield anchored
        rescue StandardError => e
          WorkerHandoff::Report.new(kind: :failed, ref: anchored.ref, sha: anchored.sha,
                                    detail: "anchored but not queued: #{e.class}: #{e.message}")
        end

        def checks_failed?(sync) = sync.to_record.dig(:checks, :outcome) == :failed

        def declined(anchored, detail)
          WorkerHandoff::Report.new(kind: :declined, ref: anchored.ref, sha: anchored.sha, detail:)
        end

        def queued(anchored, worker_id)
          entry = spool.enqueue(LandingQueue::Worker.new(id: worker_id.to_s, ref: anchored.ref, sha: anchored.sha))
          told = format(QUEUED, id: entry.id, branch: @branch)
          told += "; #{format(Spawner::BY_HAND, branch: @branch)}" unless
            @spawner.drain(branch: @branch, root: main_root, home:)
          WorkerHandoff::Report.new(kind: :queued, ref: anchored.ref, sha: anchored.sha, detail: told)
        end

        # Resolved on first use, so a chat whose children never commit asks git nothing.
        def main_root = @main_root ||= MergeCoordinator.main_root(@repo_root, shell_out_factory: @shell_out_factory)

        def home = @home ||= Home.for(repo_root: main_root, branch: @branch, shell_out_factory: @shell_out_factory)

        def spool = @spool ||= Spool.new(home)

        # A journal is a report about the handback and must never overturn it.
        def journaled(worker_key, report, sync)
          @journal << Telemetry::Handback.new(worker_key:, outcome: report.kind, ref: report.ref, **sync.to_record)
          report
        rescue StandardError
          report
        end
      end
    end
  end
end
