# frozen_string_literal: true

require "fileutils"

module Lain
  module Isolation
    # Where a repository's landings for one branch are coordinated: queued
    # entries, their results, and the lock that keeps one drainer at a time.
    module MergeCoordinator
      DIRECTORY = "lain-coordinator"

      # The key is the last segment of the branch's handback ref, so a branch
      # is named the same way here as in the handback record, and the slug plus
      # fingerprint keeps it path-safe and injective where the raw name, with
      # its slashes, is neither.
      Home = Data.define(:dir) do
        # @param repo_root [String] any directory inside the repository
        # @param branch [String] the branch the coordinator lands onto
        # @param shell_out_factory [#call] builds the subprocess that finds the common git dir
        # @return [Home]
        # @raise [Lain::Error] when repo_root is in no repository
        def self.for(repo_root:, branch:, shell_out_factory: Shell::Out.public_method(:new))
          new(dir: File.join(common_dir(File.expand_path(repo_root), shell_out_factory), DIRECTORY, key(branch)))
        end

        def self.common_dir(root, shell_out_factory)
          shell = Checkout.new(root, shell_out_factory:).run("rev-parse", "--path-format=absolute", "--git-common-dir")
          unless shell.exitstatus.zero?
            raise Error,
                  "#{root} is in no git repository, so it has no merge coordinator home"
          end

          shell.stdout.strip
        end

        def self.key(branch) = File.basename(Worktree::Handback::Naming.new(branch).ref)
        private_class_method :common_dir, :key

        # @return [String] where queued entries are written
        def entries = File.join(dir, "entries")

        # @return [String] where each entry's result is written
        def results = File.join(dir, "results")

        # Creates the home directory, since the lock file lives in it.
        # @return [FileLock] held by the one process draining this branch
        def drain_lock
          FileUtils.mkdir_p(dir)
          FileLock.new(File.join(dir, "drain.lock"), label: "the landing drain for #{File.basename(dir)}")
        end
      end
    end
  end
end
