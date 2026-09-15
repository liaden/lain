# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module Lain
  module Isolation
    # Where plan scope confines a session whose project is not a git
    # repository: a fresh directory under lain's own temporary root. Nothing of
    # the project is copied there, since outside git nothing says which files
    # are the project's.
    #
    # The directory is the lease's checkout, so a worker's commands are judged
    # in it exactly as they are in a leased worktree. Releasing the lease
    # deletes nothing: what a spike wrote there is the only copy of its work.
    class Scratch
      ROOT = File.join(Dir.tmpdir, "lain", "scratch")

      # @param root [String] the directory each lease is made under
      def initialize(root: ROOT)
        @root = root
      end

      # Named by its real path, because a worker's paths are compared by where
      # they really land.
      #
      # @return [Lease] over a new, empty directory
      def acquire(_worker_id = nil)
        FileUtils.mkdir_p(@root)
        dir = File.realpath(Dir.mktmpdir("plan-", @root))
        Lease.new(worker_env: WorkerEnv.new(cwd: dir, env: ENV.to_h), origin: Lease::Origin.new(path: dir))
      end

      # What the model is told about where it is.
      #
      # @param lease [Lease] one {#acquire} answered
      # @return [String]
      def reminder(lease)
        root = lease.worker_env.checkout
        "Plan scope: your writes and commands are confined to #{root}, an empty scratch directory. The project " \
          "is not a git repository, so none of its files were copied. Nothing written here reaches the project, " \
          "and a path outside #{root} is refused."
      end

      # Gives the lease back and keeps the directory, which is the only copy of
      # what was written there.
      #
      # @param lease [Lease]
      # @return [String] nothing to say
      def release(lease)
        lease.release
        ""
      end
    end
  end
end
