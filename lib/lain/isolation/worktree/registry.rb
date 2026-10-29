# frozen_string_literal: true

module Lain
  module Isolation
    class Worktree
      # git's own list of a repository's worktrees, and the handful of ways
      # lain changes it. Every call answers the shell rather than raising, so
      # each caller decides which failure is loud.
      class Registry
        include Registered

        # One registered worktree, with its lock read as a {LeaseLock}.
        # `branch` is the full ref a checkout has out, "" when detached.
        # `seal` is the lock's reason exactly as git reported it -- what a
        # {#claim} compares, byte for byte, before anything is unlocked.
        Entry = Data.define(:path, :head, :branch, :lock, :seal)

        # What a refusal names these checkouts by.
        LABEL = "git worktree"

        # @param repo_root [String] any checkout of the repository
        # @param shell_out_factory [#call] builds the subprocess runner
        def initialize(repo_root:, shell_out_factory:)
          @repo_root = repo_root
          @shell_out_factory = shell_out_factory
          @git = Checkout.new(repo_root, shell_out_factory:)
          @repo_lock = RepoLock.for(repo_root)
        end

        # @return [String] the repository every command below runs against
        attr_reader :repo_root

        # @return [String] what a refusal names these checkouts by
        def label = LABEL

        # `-z`, because a path and a lock reason are free text, and the plain
        # porcelain quotes any holding a newline. Records end in an extra NUL.
        # @return [Array<Entry>]
        def entries
          @git.run("worktree", "list", "--porcelain", "-z").stdout.split("\0\0")
              .map { |record| entry(record.split("\0")) }
        end

        def add(path, commit, reason:)
          @repo_lock.synchronize do
            @git.run("worktree", "add", "--lock", "--reason", reason, "--detach", path, commit)
          end
        end

        # git refuses to lock a tree that is already locked, so a caller
        # changing a reason unlocks first.
        def lock(path, reason) = @git.run("worktree", "lock", "--reason", reason, path)

        # Nonzero when the tree was not locked, which every caller treats as
        # nothing to do.
        def unlock(path) = @git.run("worktree", "unlock", path)

        def move(from, to) = @repo_lock.synchronize { @git.run("worktree", "move", from, to) }

        # Refuses a locked tree, which is what makes a lock that appears after
        # a {#claim} stop the removal. It also drops the registration of an
        # unlocked checkout whose directory is already gone, and only that one.
        def remove(path) = @repo_lock.synchronize { @git.run("worktree", "remove", "--force", path) }

        def prune = @repo_lock.synchronize { @git.run("worktree", "prune") }

        # @param path [String] a registered checkout
        # @param clock [#call] answers now
        # @return [Time] when it was cut: `worktree add` writes its `.git` file and nothing rewrites it in
        #   place. One that cannot be read counts as cut now, which errs towards keeping.
        def cut_at(path, clock)
          File.mtime(File.join(path, ".git"))
        rescue SystemCallError
          clock.call
        end

        protected

        # @param path [String] a registered checkout
        # @return [String] the file holding its lock, or "" when git keeps none for it
        def lock_file(path)
          admin = admin(path)
          admin.empty? ? "" : File.join(admin, "locked")
        end

        def at(path) = Checkout.new(path, shell_out_factory: @shell_out_factory)

        private

        def entry(lines)
          field = fields(lines)
          locked = field["locked"]
          Entry.new(path: -field.fetch("worktree"), head: -field["HEAD"].to_s, branch: -field["branch"].to_s,
                    lock: LeaseLock.parse(locked), seal: -locked.to_s)
        end

        # A key with no value (`detached`, a bare `locked`) reads as "".
        def fields(lines) = lines.to_h { |line| line.split(" ", 2).then { |key, value| [key, value.to_s] } }

        # Found through the checkout's own `.git` pointer while the checkout
        # exists, and by scanning the admin directories once it is gone; either
        # way the admin's `gitdir` must name the checkout back. Under
        # `worktree.useRelativePaths` both files hold a path relative to
        # themselves, and either side may be spelled through a symlink, so each
        # is resolved before they are compared.
        # @return [String] the directory, or "" when git keeps none for `path`
        def admin(path)
          pointer = File.join(path, ".git")
          pointed = pointed(pointer)
          return pointed if names?(pointed, pointer)

          scanned(pointer)
        end

        def pointed(pointer)
          target = File.file?(pointer) && File.read(pointer)[/\Agitdir: (.+)$/, 1]
          target ? File.expand_path(target, File.dirname(pointer)) : ""
        end

        def scanned(pointer)
          return "" if common_dir.empty?

          Dir.glob(File.join(common_dir, "worktrees", "*")).find { |admin| names?(admin, pointer) }.to_s
        end

        def names?(admin, pointer)
          gitdir = File.join(admin, "gitdir")
          return false if admin.empty? || !File.file?(gitdir)

          spellings(File.expand_path(File.read(gitdir).chomp, admin)).intersect?(spellings(pointer))
        end

        def spellings(path) = Project::Resolver.spellings(path, File)

        def common_dir
          @common_dir ||= -@git.run("rev-parse", "--path-format=absolute", "--git-common-dir").stdout.strip
        end
      end
    end
  end
end
