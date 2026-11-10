# frozen_string_literal: true

module Lain
  module Isolation
    # Where a repository's common git dir is, asked of git once per process
    # for each repository instead of once per lock or queue that wants it.
    module GitHome
      @memo = Hash.new(nil)
      LOCK = Mutex.new
      private_constant :LOCK

      # Only a root with a `.git` of its own is remembered, since that is the
      # one thing that tells a changed answer: a subdirectory asks git each
      # time. A missing answer is never kept either, so a directory that is
      # later `git init`ed is seen.
      #
      # @param root [String] any directory inside the repository
      # @param shell_out_factory [#call] builds the git subprocess
      # @return [String, nil] the absolute common git dir, or nil when root is in no repository
      def self.common_dir(root, shell_out_factory: Shell::Out.public_method(:new))
        root = File.expand_path(root)
        fingerprint = identity(root)
        return asked(root, shell_out_factory) unless fingerprint

        key = [root, *fingerprint]
        LOCK.synchronize { @memo[key] } || asked(root, shell_out_factory).tap do |found|
          LOCK.synchronize { @memo[key] = found } if found
        end
      end

      def self.asked(root, shell_out_factory)
        shell = Checkout.of(root, shell_out_factory:).run("rev-parse", "--path-format=absolute", "--git-common-dir")
        Shell::Out.ok?(shell) ? shell.stdout.strip : nil
      end

      # A freed inode can be handed straight back to a recreated root, so the
      # inode alone does not tell a new repository from the old: a directory
      # `.git` adds the ctime of its `config`, which `git init` writes and a
      # landing never touches (the directory's own ctime moves whenever a lock
      # file appears in it), and a linked worktree's `.git` file adds what it
      # points at.
      def self.identity(root)
        dot_git = File.join(root, ".git")
        stat = File.lstat(dot_git)
        [stat.dev, stat.ino, stat.directory? ? config_ctime(dot_git) : File.read(dot_git)]
      rescue SystemCallError
        nil
      end

      def self.config_ctime(dot_git)
        File.lstat(File.join(dot_git, "config")).ctime.to_r
      rescue SystemCallError
        nil
      end
      private_class_method :asked, :identity, :config_ctime
    end
  end
end
