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
    # deletes nothing, since what a spike wrote there is the only copy of its
    # work, unless the release discards it, as a quit does.
    class Scratch
      ROOT = File.join(Dir.tmpdir, "lain", "scratch")

      # Names a release lists before it only counts, so a child that writes
      # thousands of files cannot flood its parent's context.
      LISTED = 50

      DISCARDED = "the plan scope's scratch directory %<dir>s was discarded, with everything written there"

      UNDISCARDED = "the plan scope's scratch directory %<dir>s could not be discarded, so what is left of it " \
                    "stays: %<reason>s"

      # @param root [String] the directory each lease is made under
      # @param prefix [String] what each directory's name starts with, so a
      #   human listing the root can tell whose work each one holds
      def initialize(root: ROOT, prefix: "plan-")
        @root = root
        @prefix = prefix
      end

      # The root could not be written, or a directory made in it.
      class Unwritable < Error
        # @return [String] the directory it tried to make
        attr_reader :dir
        # @return [String] the errno's own reason, in lower case
        attr_reader :reason

        def initialize(dir, reason)
          @dir = dir
          @reason = reason
          super("the research workspace could not be created at #{dir}: #{reason}")
        end
      end

      # Named by its real path, because a worker's paths are compared by where
      # they really land.
      #
      # @return [Lease] over a new, empty directory
      # @raise [Unwritable]
      def acquire(_worker_id = nil)
        FileUtils.mkdir_p(@root)
        dir = File.realpath(Dir.mktmpdir(@prefix, @root))
        Lease.new(worker_env: WorkerEnv.new(cwd: dir, env: ENV.to_h), origin: Lease::Origin.new(path: dir))
      rescue SystemCallError => e
        raise Unwritable.new(@root, Error.reason_of(e).downcase)
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
      # what was written there, unless the release discards it.
      #
      # @param lease [Lease]
      # @param discard [Boolean] delete the directory, as at quit, when nobody
      #   is left to come back for what was written there
      # @return [String] the files written under it, absolute, 1 per line, the
      #   first {LISTED} and a count of the rest; empty when there are none.
      #   A discarding release says the directory went instead.
      def release(lease, discard: false)
        lease.release(discard:)
        discard ? discarded(lease.origin.path) : listed(lease.worker_env.cwd)
      end

      private

      def discarded(dir)
        FileUtils.rm_r(dir, secure: true)
        format(DISCARDED, dir:)
      rescue SystemCallError => e
        format(UNDISCARDED, dir:, reason: Error.reason_of(e))
      end

      def listed(dir)
        written = Dir.glob("**/*", File::FNM_DOTMATCH, base: dir, sort: true)
                     .map { |name| File.join(dir, name) }
                     .reject { |path| File.lstat(path).directory? }
        (written.first(LISTED) + elided(written.size, dir)).join("\n")
      end

      def elided(count, dir)
        count > LISTED ? ["... and #{count - LISTED} more under #{dir}"] : []
      end
    end
  end
end
