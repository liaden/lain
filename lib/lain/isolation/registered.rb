# frozen_string_literal: true

require "securerandom"

module Lain
  module Isolation
    # What every checkout registry answers about a checkout it listed, over
    # two things the includer supplies: `lock_file(path)`, where that
    # checkout's lock lives, and `at(path)`, the {Checkout} lain runs git
    # through there. Shared by {Worktree::Registry} and {Clone::Registry}.
    module Registered
      # The two places git keeps a rebase in progress, each naming the
      # branch it will rewrite when it finishes.
      REBASES = %w[rebase-merge rebase-apply].freeze

      # What {#claim} appends to a lock's name while it holds it.
      CLAIM = ".lain-claim-"

      # Rewrites HEAD alone, never the index or a file, so a tree holding
      # uncommitted work or an index git cannot read detaches all the same.
      # Compare-and-swapped against `commit`: pointing a HEAD that has moved
      # on back at it would leave the newer commit's changes reading as
      # staged, work nobody made.
      # @param path [String] a registered checkout
      # @param commit [String] the commit HEAD resolved to when it was read
      # @param reason [String] stamped into HEAD's reflog
      def detach(path, commit, reason:)
        at(path).run("update-ref", "--no-deref", "-m", reason, "HEAD", commit, commit)
      end

      # @return [Anchorage] over this repository
      def anchorage = Worktree::Anchorage.new(repo_root: @repo_root, shell_out_factory: @shell_out_factory)

      # Untracked files count: a file a worker wrote and never added is
      # uncommitted work too. Ignored ones do not, being regenerable by
      # definition. Anything that stops git answering -- a corrupt index, a
      # timeout -- counts as uncommitted, since "unknown" must never read as
      # "safe to delete". A directory that is gone holds nothing to lose.
      # @return [Boolean]
      def uncommitted?(path)
        return false unless File.directory?(path)

        shell = at(path).run("status", "--porcelain", "--untracked-files=all")
        !Shell::Out.ok?(shell) || !shell.stdout.empty?
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
        locked = lock_file(entry.path)
        return false if locked.empty?
        return !File.exist?(locked) if entry.lock.equal?(LeaseLock::UNLOCKED)

        taken = "#{locked}#{CLAIM}#{SecureRandom.hex(6)}"
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
        locked = lock_file(path)
        strays = locked.empty? ? [] : Dir.glob("#{locked}#{CLAIM}*")
        return "" if strays.empty?

        stray = strays.first
        "an interrupted lock claim (#{File.basename(stray)}) #{reinstate(stray, locked)}"
      rescue SystemCallError => e
        "its lock files could not be read: #{e.message}"
      end

      # @param path [String] a registered checkout
      # @return [String] the branch a rebase in that checkout will rewrite, or "" for none
      def rebasing(path)
        shell = at(path).run("rev-parse", "--absolute-git-dir")
        return "" unless Shell::Out.ok?(shell)

        REBASES.map { |kind| File.join(shell.stdout.strip, kind, "head-name") }
               .select { |name| File.file?(name) }.map { |name| File.read(name).strip }.first.to_s
      end

      # Whether lain must run no git in the checkout at all.
      def tampered?(_path) = false

      private

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
    end
  end
end
