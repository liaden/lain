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

      # The positional arguments are the git subcommand and its arguments.
      # @param env [Hash] merged over the scrub, so a caller adds to it and never
      #   replaces it: a bare `GIT_INDEX_FILE` is the one trap this class exists
      #   to keep shut
      # @param timeout [Numeric, nil] seconds, passed on only when given
      # @param input [String, nil] the child's stdin, passed on only when given
      # @param pins [Array<String>] `key=value` config, each spelled `-c key=value`
      # @return [Shell::Out] the finished command; its status is the caller's to read
      def run(*, env: {}, timeout: nil, input: nil, pins: [])
        options = { environment: Worktree::GIT_CONTEXT_SCRUB.merge(env), timeout:, input: }.compact
        shell = @shell_out_factory.call("git", "-C", @dir, *pins.flat_map { |pin| ["-c", pin] }, *, **options)
        shell.run_command
        shell
      end

      # {#run} for the caller that cannot go on without the answer.
      # @param args [Array<String>] as for {#run}
      # @param error [Class] raised on a non-zero exit, so each caller keeps its own refusal
      # @yieldparam shell [Shell::Out] the failed command, to word the message from
      # @raise [Class] `error`
      def run!(*args, error:, **)
        shell = run(*args, **)
        return shell if Shell::Out.ok?(shell)

        raise error, (block_given? ? yield(shell) : failure(args, shell))
      end

      def head = run("rev-parse", "HEAD")

      # @return [String] the ref HEAD points at, or "" on a detached HEAD
      def symbolic_head
        shell = run("symbolic-ref", "--quiet", "HEAD")
        Shell::Out.ok?(shell) ? shell.stdout.strip : ""
      end

      # The branch landed work is judged against. A repo that never had a
      # `main` is not one lain should silently reap nothing from, so the
      # remote's HEAD and the configured default come first, then the two
      # conventional names; with none of them present the answer is
      # {WorkingBranch::TRUNK}, which matches nothing and so reaps nothing.
      # @return [String]
      def trunk
        candidates = [remote_head, configured_default, WorkingBranch::TRUNK, "master"].reject(&:empty?)
        candidates.find { |name| !target("refs/heads/#{name}").empty? } || WorkingBranch::TRUNK
      end

      # Every shape of "git is half way through something", which is not the
      # same question as {#merging?} and was measured not to be: a conflicted
      # rebase, a cherry-pick, a revert and a bisect all answer `false` there,
      # and so does a rebase stopped at a `break`, which leaves no pseudo-ref
      # at ALL and parks HEAD behind the work. A reader that diffs such a tree
      # gets a partial answer, or an empty one, with nothing to say it is not
      # the truth. A merely DIRTY tree is not one of these: it has no operation
      # to finish, and a commit-to-commit question cannot see it.
      #
      # `--git-path` in one call rather than six stats, for {#merging?}'s
      # reason -- a linked worktree keeps these somewhere `.git/` is not -- and
      # it answers relative to the working dir, so an absolute reply is left
      # alone by `expand_path`.
      IN_PROGRESS = %w[MERGE_HEAD rebase-merge rebase-apply CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG].freeze

      def operation_in_progress?
        asked = IN_PROGRESS.flat_map { |marker| ["--git-path", marker] }
        run("rev-parse", *asked).stdout.split("\n").any? { |path| File.exist?(File.expand_path(path, @dir)) }
      end

      # MERGE_HEAD is git's own record that a merge is under way. Asked of git
      # rather than stat'ed on disk, because a LINKED worktree keeps it
      # somewhere `.git/MERGE_HEAD` is not.
      def merging? = Shell::Out.ok?(run("rev-parse", "--verify", "--quiet", "MERGE_HEAD"))

      # Whether `commit` is reachable from `of`. `of` defaults to HEAD because
      # that is the common question, but it is a PARAMETER: pinning it meant
      # every caller asking about a branch, a tip or another commit re-spelled
      # the invocation, and five such spellings had accumulated around this one.
      # @param commit [String] the possible ancestor
      # @param of [String] what it would be an ancestor of
      def ancestor?(commit, of = "HEAD") = Shell::Out.ok?(run("merge-base", "--is-ancestor", commit, of))

      # What `ref` points at, or "" when it points at nothing. "No ref yet" and
      # "a ref on some other commit" both mean the same write is still owed,
      # and no commit is ever "", so no caller writes a nil guard.
      def target(ref)
        shell = run("rev-parse", "--verify", "--quiet", ref)
        Shell::Out.ok?(shell) ? shell.stdout.strip : ""
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

      def remote_head
        shell = run("symbolic-ref", "--quiet", "refs/remotes/origin/HEAD")
        Shell::Out.ok?(shell) ? shell.stdout.strip.delete_prefix("refs/remotes/origin/") : ""
      end

      def configured_default
        shell = run("config", "--get", "init.defaultBranch")
        Shell::Out.ok?(shell) ? shell.stdout.strip : ""
      end

      def failure(args, shell)
        "git #{args.first} failed in #{@dir} (exit #{shell.exitstatus}): #{shell.stderr.strip}"
      end

      # Binary, because a conflicted file may hold anything and a regex
      # against invalid bytes raises. "" when there is nothing readable there
      # (a delete/modify conflict leaves no file to scan).
      def read(path)
        File.binread(File.join(@dir, path))
      rescue SystemCallError
        ""
      end
    end
  end
end
