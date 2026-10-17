# frozen_string_literal: true

require "concurrent/map"
require "monitor"

module Lain
  module Isolation
    class Worktree
      # One exclusive section per repository's worktree registry, across threads,
      # fibers and processes. git writes `.git/worktrees/<id>/` in several steps,
      # and a second add, remove, move or prune running over it can read a
      # half-written `commondir`.
      #
      # Two locks, because neither does the other's job: a {Monitor} is what
      # keeps threads and fibers of THIS process apart (a flock belongs to the
      # open file description, so 2 threads that each open the file would not
      # exclude one another), and an flock on a file in the git common dir is
      # what keeps other lain processes on the same repository apart. A linked
      # worktree's `.git` is a file, so the common dir is asked of git.
      #
      # The map of monitors is never pruned: a lock must stay the same object
      # for as long as anything may be holding it, one entry is a monitor and a
      # path, and a process touches few repositories.
      class RepoLock
        FILE = "lain-worktree.lock"

        LOCKS = Concurrent::Map.new
        private_constant :LOCKS

        # @param repo_root [String] any checkout of the repository
        # @return [RepoLock] the one lock for that repository, however spelled
        def self.for(repo_root)
          key = canonical(repo_root)
          LOCKS.compute_if_absent(key) { new(key) }
        end

        def self.canonical(path)
          File.realpath(path)
        rescue SystemCallError
          File.expand_path(path)
        end
        private_class_method :canonical, :new

        def initialize(repo_root)
          @repo_root = repo_root
          @monitor = Monitor.new
        end

        # Re-entrant for the holder, so a caller that already holds the lock may
        # call another method that takes it.
        def synchronize(&)
          @monitor.synchronize do
            return yield if @flocked

            flocking(&)
          end
        end

        private

        def flocking
          lock_path = lock_file
          return yield unless lock_path

          File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |file|
            file.flock(File::LOCK_EX)
            @flocked = true
            yield
          ensure
            @flocked = false
          end
        end

        # nil when git cannot say, which leaves the in-process lock to carry on.
        def lock_file
          @lock_file ||= begin
            shell = Checkout.new(@repo_root).run("rev-parse", "--git-common-dir")
            File.join(File.expand_path(shell.stdout.strip, @repo_root), FILE) if Shell::Out.ok?(shell)
          end
        end
      end
    end
  end
end
