# frozen_string_literal: true

module Lain
  module Isolation
    # One git working tree, questioned: a parent checkout and a leased worktree
    # are the same kind of thing here, so they are one object. One invocation
    # shape, scrubbed exactly as {Worktree} scrubs, always answering with the
    # shell instead of raising -- {Worktree::Handback} lives inside a promise
    # that nothing escapes it, and {WorkingBranch} names its own refusals.
    class Checkout
      # All three marker shapes, in order, is what tells a real unresolved
      # hunk from a line of prose (or a diff fixture) that merely starts like
      # one. A false positive costs one round trip and a handback can always be
      # abandoned; a false negative commits `<<<<<<<` into the parent's history
      # under a `:merged` outcome, which is the one thing an LLM resolver
      # cannot check for itself.
      CONFLICTED = /^<<<<<<< .*^=======$.*^>>>>>>> /m

      # @param dir [String] the working tree every command runs in
      # @param shell_out_factory [#call] builds the subprocess runner
      def initialize(dir, shell_out_factory: Shell::Out.public_method(:new))
        @dir = dir
        @shell_out_factory = shell_out_factory
      end

      def run(*)
        shell = @shell_out_factory.call("git", "-C", @dir, *, environment: Worktree::GIT_CONTEXT_SCRUB)
        shell.run_command
        shell
      end

      def head = run("rev-parse", "HEAD")

      # @return [String] the ref HEAD points at, or "" on a detached HEAD
      def symbolic_head
        shell = run("symbolic-ref", "--quiet", "HEAD")
        ok?(shell) ? shell.stdout.strip : ""
      end

      # MERGE_HEAD is git's own record that a merge is under way. Asked of git
      # rather than stat'ed on disk, because a LINKED worktree keeps it
      # somewhere `.git/MERGE_HEAD` is not.
      def merging? = ok?(run("rev-parse", "--verify", "--quiet", "MERGE_HEAD"))

      # Whether `commit` is reachable from `of`. `of` defaults to HEAD because
      # that is the common question, but it is a PARAMETER: pinning it meant
      # every caller asking about a branch, a tip or another commit re-spelled
      # the invocation, and five such spellings had accumulated around this one.
      # @param commit [String] the possible ancestor
      # @param of [String] what it would be an ancestor of
      def ancestor?(commit, of = "HEAD") = ok?(run("merge-base", "--is-ancestor", commit, of))

      # What `ref` points at, or "" when it points at nothing. "No ref yet" and
      # "a ref on some other commit" both mean the same write is still owed,
      # and no commit is ever "", so no caller writes a nil guard.
      def target(ref)
        shell = run("rev-parse", "--verify", "--quiet", ref)
        ok?(shell) ? shell.stdout.strip : ""
      end

      # Git's own compare-and-swap: with `held`, `update-ref` refuses unless
      # the ref still holds it, where "" means it must not exist at all, so the
      # loser of a race fails loudly instead of overwriting. With no `held` the
      # write is unconditional.
      #
      # `--create-reflog` is not decoration: git's default
      # `core.logAllRefUpdates` logs only refs/heads, refs/remotes, refs/notes
      # and HEAD, so for `refs/lain/` a bare `-m` is accepted and silently
      # dropped (measured, git 2.43).
      def update_ref(ref, commit, held = nil, reason:)
        run("update-ref", "--create-reflog", "-m", reason, ref, commit, *held)
      end

      # `-z`, because the default output runs every path through
      # `core.quotePath`: a conflict on `föö.txt` is reported as
      # `"f\303\266\303\266.txt"`, which no resolver can open and no `git add
      # --` pathspec matches. NUL termination also keeps a filename holding a
      # newline in one piece. The bytes then need re-TAGGING, not converting.
      def unmerged
        paths = run("diff", "--name-only", "--diff-filter=U", "-z").stdout.split("\0")
        paths.map { |path| path.force_encoding(FILESYSTEM) }
      end

      # Which of `paths` are still not actually resolved. Only the paths asked
      # about are scanned: a marker-shaped line anywhere else in the checkout
      # is none of this operation's business.
      def unresolved(paths) = paths.select { |path| read(path).match?(CONFLICTED) }

      private

      # Binary, because a conflicted file may hold anything and a regex
      # against invalid bytes raises. "" when there is nothing readable there
      # (a delete/modify conflict leaves no file to scan).
      def read(path)
        File.binread(File.join(@dir, path))
      rescue SystemCallError
        ""
      end

      def ok?(shell) = shell.exitstatus.zero?
    end
  end
end
