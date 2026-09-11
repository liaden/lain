# frozen_string_literal: true

require "securerandom"

module Lain
  module Isolation
    class Worktree
      # git's own list of a repository's worktrees, and the handful of ways
      # lain changes it. Every call answers the shell rather than raising, so
      # each caller decides which failure is loud.
      class Registry
        # One registered worktree, with its lock read as a {LeaseLock}.
        # `branch` is the full ref a checkout has out, "" when detached.
        # `seal` is the lock's reason exactly as git reported it -- what a
        # {#claim} compares, byte for byte, before anything is unlocked.
        Entry = Data.define(:path, :head, :branch, :lock, :seal)

        # The two places git keeps a rebase in progress, each naming the
        # branch it will rewrite when it finishes.
        REBASES = %w[rebase-merge rebase-apply].freeze

        # What {#claim} renames a lock to while it holds it.
        CLAIMED = "locked.lain-claim-"

        # @param repo_root [String] any checkout of the repository
        # @param shell_out_factory [#call] builds the subprocess runner
        def initialize(repo_root:, shell_out_factory:)
          @repo_root = repo_root
          @shell_out_factory = shell_out_factory
        end

        # `-z`, because a path and a lock reason are free text, and the plain
        # porcelain quotes any holding a newline. Records end in an extra NUL.
        # @return [Array<Entry>]
        def entries
          git("worktree", "list", "--porcelain", "-z").stdout.split("\0\0").map { |record| entry(record.split("\0")) }
        end

        def add(path, commit, reason:) = git("worktree", "add", "--lock", "--reason", reason, "--detach", path, commit)

        # git refuses to lock a tree that is already locked, so a caller
        # changing a reason unlocks first.
        def lock(path, reason) = git("worktree", "lock", "--reason", reason, path)

        # Nonzero when the tree was not locked, which every caller treats as
        # nothing to do.
        def unlock(path) = git("worktree", "unlock", path)

        def move(from, to) = git("worktree", "move", from, to)

        # Refuses a locked tree, which is what makes a lock that appears after
        # a {#claim} stop the removal. It also drops the registration of an
        # unlocked checkout whose directory is already gone, and only that one.
        def remove(path) = git("worktree", "remove", "--force", path)

        def prune = git("worktree", "prune")

        # @return [Anchorage] over this repository
        def anchorage = Anchorage.new(repo_root: @repo_root, shell_out_factory: @shell_out_factory)

        # Untracked files count: a file a worker wrote and never added is
        # uncommitted work too. Ignored ones do not, being regenerable by
        # definition. Anything that stops git answering -- a corrupt index, a
        # timeout -- counts as uncommitted, since "unknown" must never read as
        # "safe to delete". A directory that is gone holds nothing to lose.
        # @return [Boolean]
        def uncommitted?(path)
          return false unless File.directory?(path)

          shell = run("git", "-C", path, "status", "--porcelain", "--untracked-files=all")
          !shell.exitstatus.zero? || !shell.stdout.empty?
        rescue StandardError
          true
        end

        # A compare-and-swap on the lock, through git's documented layout
        # (gitrepository-layout(5)): a linked worktree's lock is the file
        # `locked` in its admin directory, holding the reason and a newline.
        # Renaming it away is atomic, so the claim holds only when what was
        # taken is what was judged; a lock that changed meanwhile is put back
        # as it now is. A tree judged unlocked is claimed only while it has no
        # lock at all, and {#remove} refuses one that appears afterwards. A
        # second acquirer during a claim can move a live checkout into
        # `retained/`, which moves it whole, so nothing is lost.
        #
        # @param entry [Entry] the checkout as it was judged
        # @return [Boolean] whether its lock, if any, is now the caller's to drop
        def claim(entry)
          admin = admin(entry.path)
          return false if admin.empty?

          locked = File.join(admin, "locked")
          return !File.exist?(locked) if entry.lock.equal?(LeaseLock::UNLOCKED)

          taken = File.join(admin, "#{CLAIMED}#{SecureRandom.hex(6)}")
          File.rename(locked, taken)
          sealed?(taken, entry.seal) || restore(taken, locked)
        rescue SystemCallError
          false
        end

        # A crash between {#claim}'s rename and its put-back leaves the taken
        # lock under its claim name, and the tree reading as unlocked. Such a
        # tree is kept, never judged: the taken lock goes back only where no
        # lock stands -- a link, never an overwrite -- and otherwise both stay
        # for someone to look at.
        # @param path [String] a registered checkout
        # @return [String] why an interrupted claim holds it, or "" when none does
        def interrupted(path)
          admin = admin(path)
          strays = admin.empty? ? [] : Dir.glob(File.join(admin, "#{CLAIMED}*"))
          return "" if strays.empty?

          stray = strays.first
          "an interrupted lock claim (#{File.basename(stray)}) #{reinstate(stray, File.join(admin, "locked"))}"
        rescue SystemCallError => e
          "its lock files could not be read: #{e.message}"
        end

        # @param path [String] a registered checkout
        # @return [String] the branch a rebase in that checkout will rewrite, or "" for none
        def rebasing(path)
          shell = run("git", "-C", path, "rev-parse", "--absolute-git-dir")
          return "" unless shell.exitstatus.zero?

          REBASES.map { |kind| File.join(shell.stdout.strip, kind, "head-name") }
                 .select { |name| File.file?(name) }.map { |name| File.read(name).strip }.first.to_s
        end

        private

        def entry(lines)
          field = fields(lines)
          locked = field["locked"]
          Entry.new(path: -field.fetch("worktree"), head: -field["HEAD"].to_s, branch: -field["branch"].to_s,
                    lock: LeaseLock.parse(locked), seal: -locked.to_s)
        end

        # A key with no value (`detached`, a bare `locked`) reads as "".
        def fields(lines) = lines.to_h { |line| line.split(" ", 2).then { |key, value| [key, value.to_s] } }

        def sealed?(taken, seal)
          return false unless File.binread(taken).chomp.b == seal.b

          File.delete(taken)
          true
        end

        # A link, not a rename, so a newer lock that arrived in between is
        # never overwritten: it stands, and the one taken is discarded.
        def restore(taken, locked)
          File.link(taken, locked)
          File.delete(taken)
          false
        rescue Errno::EEXIST
          File.delete(taken)
          false
        end

        # @return [String] what became of an interrupted claim's taken lock
        def reinstate(stray, locked)
          File.link(stray, locked)
          File.delete(stray)
          "was put back as its lock"
        rescue Errno::EEXIST
          "sits beside a newer lock; both are left for someone to look at"
        end

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
          @common_dir ||= -git("rev-parse", "--path-format=absolute", "--git-common-dir").stdout.strip
        end

        def git(*) = run("git", "-C", @repo_root, *)

        def run(*)
          shell = @shell_out_factory.call(*, environment: GIT_CONTEXT_SCRUB)
          shell.run_command
          shell
        end
      end
    end
  end
end
