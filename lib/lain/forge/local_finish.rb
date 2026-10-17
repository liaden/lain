# frozen_string_literal: true

module Lain
  module Forge
    # A finished epic's working branch merged into the default branch of this
    # repository, with no remote and no pull request: {Landing}'s job for a
    # project that has nowhere to push. {LocalLanding} lands an issue onto the
    # epic branch; this lands the epic branch onto the default one.
    #
    # The merge is computed in the object store (`merge-tree`, then
    # `commit-tree`) and the default branch is then fast-forwarded to it, so a
    # conflict is found without touching anybody's checkout: the default
    # branch's head, index and working tree never moved.
    #
    # Idempotent by observation: a default branch that already holds the epic
    # tip answers an observed success and merges nothing.
    class LocalFinish
      # The checkout cannot take a merge as it stands. Raised before anything merges.
      class Refused < Error
        include RefusedBeforeActing
      end

      # The merge stopped on conflicting paths.
      CONFLICTED = "conflicted"

      # The default branch moved while the merge was being made.
      NOT_FAST_FORWARD = "not_fast_forward"

      # @param root [String] the checkout with the default branch checked out
      # @param shell_out_factory [#call] every git subprocess
      def initialize(root:, shell_out_factory: Shell::Out.public_method(:new))
        @root = root
        @checkout = Isolation::Checkout.new(root, shell_out_factory:)
      end

      # @param slug [String] the epic whose `epic/<slug>` merges
      # @param base [String] the default branch, which must be checked out and clean
      # @param sha [String] the epic tip to merge, exactly as the caller journaled it
      # @return [Gh::Answer] ok carrying the default branch's new head, or
      #   not-ok carrying why; `detail["remote"]` is always false
      # @raise [Refused] when the base is not checked out, the checkout has
      #   uncommitted changes, or untracked files stand where the merge writes
      def call(slug:, base:, sha:)
        about = { "remote" => false, "base" => base, "head" => Isolation::WorkingBranch.epic_name(slug), "sha" => sha }
        checked_out!(base)
        clean!
        at = @checkout.target(base)
        return succeeded(about, at, observed: true) if @checkout.ancestor?(sha, at)

        tree, conflicts = merge_tree(at, sha)
        return conflicted(about, conflicts) unless conflicts.empty?

        unshadowed!(at, tree)
        forwarded(committed(tree, at, about), about)
      end

      private

      def checked_out!(base)
        current = @checkout.symbolic_head.delete_prefix("refs/heads/")
        return if current == base

        raise Refused, "#{base} must be checked out in #{@root} to finish locally, and " \
                       "#{current.empty? ? "a detached HEAD" : current} is -- nothing merged"
      end

      def clean!
        changed = uncommitted
        return if changed.empty?

        raise Refused, "#{@root} has uncommitted changes (#{changed.join(", ")}) -- commit or stash them; " \
                       "nothing merged"
      end

      def uncommitted
        @checkout.run("status", "--porcelain", "--untracked-files=no").stdout.lines.map { |line| line[3..].strip }
      end

      # @return [Array(String, Array<String>)] the merged tree and the conflicted paths
      def merge_tree(at, sha)
        merge = @checkout.run("merge-tree", "--write-tree", "--name-only", "-z", at, sha)
        raise Error, "git merge-tree failed: #{merge.stderr.strip}" unless [0, 1].include?(merge.exitstatus)

        tree, *conflicts = merge.stdout.split("\0\0", 2).first.split("\0")
        [tree, conflicts.map { |path| path.force_encoding(FILESYSTEM) }]
      end

      # The fast-forward would refuse these as a bare not_fast_forward, after
      # the merge commit was made, so they are named first.
      def unshadowed!(at, tree)
        written = listed("diff", "--name-only", "-z", at, tree)
        shadowed = listed("ls-files", "--others", "--exclude-standard", "-z", "--full-name", "--", ":/") & written
        return if shadowed.empty?

        raise Refused, "untracked files in #{@root} stand where the epic writes (#{shadowed.join(", ")}) -- " \
                       "move them aside; nothing merged"
      end

      def listed(*args) = @checkout.run(*args).stdout.split("\0").map { |path| path.force_encoding(FILESYSTEM) }

      # commit-tree runs no merge hooks and applies no signing default, so this
      # commit is unsigned whatever `commit.gpgSign` says.
      def committed(tree, at, about)
        made = @checkout.run("commit-tree", tree, "-p", at, "-p", about["sha"],
                             "-m", "Merge #{about["head"]} into #{about["base"]}")
        raise Error, "git commit-tree failed: #{made.stderr.strip}" unless Shell::Out.ok?(made)

        made.stdout.strip
      end

      def forwarded(commit, about)
        moved = @checkout.run("merge", "--ff-only", "--quiet", commit)
        return succeeded(about, commit) if Shell::Out.ok?(moved)

        refused(about, NOT_FAST_FORWARD, "#{about["base"]} could not fast-forward to the merge: #{moved.stderr.strip}")
      end

      def conflicted(about, paths)
        refused(about, CONFLICTED, "#{about["head"]} conflicts with #{about["base"]} in #{paths.join(", ")}; " \
                                   "#{about["base"]} did not move", "paths" => paths)
      end

      def succeeded(about, value, observed: false)
        Gh::Answer.new(ok: true, observed:, detail: about.merge("value" => value))
      end

      def refused(about, reason, message, extra = {})
        Gh::Answer.new(ok: false, detail: about.merge(extra, "reason" => reason, "message" => message))
      end
    end
  end
end
