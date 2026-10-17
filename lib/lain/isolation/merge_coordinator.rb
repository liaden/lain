# frozen_string_literal: true

require "fileutils"

module Lain
  module Isolation
    # Where a repository's landings for one branch are coordinated: queued
    # entries, their results, and the lock that keeps one drainer at a time.
    module MergeCoordinator
      DIRECTORY = "lain-coordinator"

      # The repository's main worktree, which every landing of a branch reads
      # its config from, journals under, and keys its verify tree by, whichever
      # of the repository's checkouts it was started from.
      # @param repo_root [String] any directory inside the repository
      # @param shell_out_factory [#call] builds the git subprocess
      # @return [String]
      # @raise [Lain::Error] when repo_root is in no repository, or in a bare one
      def self.main_root(repo_root, shell_out_factory: Shell::Out.public_method(:new))
        listed = Checkout.new(File.expand_path(repo_root), shell_out_factory:)
                         .run("worktree", "list", "--porcelain", "-z")
        raise Error, "#{repo_root} is in no git repository, so it has no main worktree" unless
          Shell::Out.ok?(listed)

        main = listed.stdout.split("\0\0").first.to_s.split("\0")
        raise Error, "#{repo_root} is in a bare repository, which has no main worktree to verify in" if
          main.include?("bare")

        main.first.to_s.delete_prefix("worktree ")
      end

      # The key is the last segment of the branch's handback ref, so a branch
      # is named the same way here as in the handback record, and the slug plus
      # fingerprint keeps it path-safe and injective where the raw name, with
      # its slashes, is neither.
      Home = Data.define(:git_dir, :key) do
        # @param repo_root [String] any directory inside the repository
        # @param branch [String] the branch the coordinator lands onto
        # @param shell_out_factory [#call] builds the subprocess that finds the common git dir
        # @return [Home]
        # @raise [Lain::Error] when repo_root is in no repository
        def self.for(repo_root:, branch:, shell_out_factory: Shell::Out.public_method(:new))
          new(git_dir: common_dir(File.expand_path(repo_root), shell_out_factory), key: key(branch))
        end

        def self.common_dir(root, shell_out_factory)
          shell = Checkout.new(root, shell_out_factory:).run("rev-parse", "--path-format=absolute", "--git-common-dir")
          unless Shell::Out.ok?(shell)
            raise Error,
                  "#{root} is in no git repository, so it has no merge coordinator home"
          end

          shell.stdout.strip
        end

        def self.key(branch) = File.basename(Worktree::Handback::Naming.new(branch).ref)
        private_class_method :common_dir, :key

        # @return [String] the home itself, under the repository's common git dir
        def dir = File.join(git_dir, DIRECTORY, key)

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
