# frozen_string_literal: true

require "mixlib/shellout"

module Lain
  module Forge
    # Put an epic's working branch on the remote as `epic/<slug>`, and delete it
    # there once the epic's pull request has merged.
    #
    # The tier's NON-gh actions: plain `git push`es, of a sha into a refspec and
    # of a deletion. Nothing local is branched or moved -- the local
    # `epic/<slug>` is the working branch issues landed onto, and worktree gc
    # reaps it once main holds it.
    #
    # == Refuse, never force
    #
    # Re-promoting the SAME sha is an ok, `observed` answer with no push at all --
    # the doctrine that idempotency is asked of the remote rather than remembered.
    # A ref standing at any OTHER sha is a refusal that names what the remote
    # holds, and so is a delete of a branch that moved after its merge. There is
    # no `--force` and no `--force-with-lease` here, deliberately.
    #
    # THE REFUSAL IS NOT ATOMIC WITH THE PUSH, a residual rather than an
    # oversight. Reading the remote and pushing to it are two round trips, so an
    # actor that creates the ref or advances it to an ANCESTOR of this sha in
    # between gets the push accepted, and one that moves the branch between the
    # read and a delete loses its push. Closing either means
    # `--force-with-lease`, whose semantics this tier does not introduce.
    #
    # == A branch the remote cannot hold
    #
    # git holds a ref or a directory of refs at one name, never both. The
    # promotion this replaced pushed one branch per issue beneath the epic's
    # name, so those branches make `epic/<slug>` unpushable. Every one is named
    # in the refusal, and none is deleted: they may still be somebody's work.
    #
    # == Every refusal is a value; only a caller's own nonsense raises
    #
    # git refusing, an unreachable remote, an occupied namespace -- each answers
    # a not-ok {Gh::Answer} carrying the reason, because the answer is journaled
    # as a {Forge::Outcome} and a raise would be a second control path the record
    # never sees. What DOES raise makes an intent unjournalable: a slug the
    # filesystem grammar refuses, checked at construction, and a blank sha.
    class Promotion
      DEFAULT_REMOTE = "origin"

      # What the answer's `detail["reason"]` says, as constants rather than
      # sentences: a caller branches on these.
      PROMOTED = "promoted"
      ALREADY_PROMOTED = "already_promoted"
      DIVERGED = "diverged"
      NAMESPACE_CONFLICT = "namespace_conflict"
      MALFORMED_REF = "malformed_ref"
      UNKNOWN_COMMIT = "unknown_commit"
      INEXACT_SHA = "inexact_sha"
      PUSH_FAILED = "push_failed"
      REMOTE_UNREACHABLE = "remote_unreachable"
      DELETED = "deleted"
      ALREADY_DELETED = "already_deleted"
      DELETE_FAILED = "delete_failed"

      # A promotion with no commit to promote.
      class Unanchored < Error; end

      # A refusal on its way to becoming a {Gh::Answer}: raised wherever the fact
      # is discovered, several calls deep in {Remote}, and caught once at the
      # boundary. Nothing of this class ever escapes a public method.
      class Denied < Error
        attr_reader :reason

        def initialize(reason, message)
          @reason = reason
          super(message)
        end
      end
      private_constant :Denied

      # The ref an epic's work goes to the remote on, and the only place the
      # naming rule is written. Pure, so the grammar is checked before any
      # subprocess exists.
      class Branch
        # `epic/` rather than {Isolation::Worktree::Handback::Naming}'s
        # `refs/lain/worker/`: an anchor is deliberately invisible to `git
        # branch`, and this is a branch a pull request is opened from.
        PREFIX = "refs/heads/epic"

        def initialize(epic_slug:)
          @epic_slug = Epic::Home.checked_name(epic_slug, "epic slug")
          @ref = "#{PREFIX}/#{@epic_slug}".freeze
          # `Ractor.shareable?` is false for an unfrozen object however immutable
          # its contents are.
          freeze
        end

        attr_reader :epic_slug, :ref

        # No local branch is pushed by name, so the sha IS the source side.
        def refspec(sha) = "#{sha}:#{@ref}"

        # Checked in BOTH directions -- `refs/heads/epic` above this ref and
        # `refs/heads/epic/<slug>/<issue>` beneath it block it equally -- because
        # git's own error for the second reads as if the push were malformed.
        def blocked_by?(other) = other.start_with?("#{@ref}/") || @ref.start_with?("#{other}/")
      end

      # The remote, questioned from the local checkout, with every git refusal
      # converted where it happens into the reason the answer will carry.
      class Remote
        # `<sha>\t<ref>`, which is all `ls-remote` writes. Anchored so a line of
        # something else is dropped rather than read as a ref.
        LISTED = /\A(\h+)\s+(\S+)\s*\z/

        def initialize(repo_root:, remote:, shell_out_factory:)
          @repo_root = File.expand_path(repo_root)
          @remote = remote
          @shell_out_factory = shell_out_factory
        end

        # git's own opinion of the composed name: the canary for {Epic::Home::NAME}
        # and git's rules drifting apart, at the cost of one subprocess.
        def nameable!(ref)
          shell = run("check-ref-format", ref)
          raise Denied.new(MALFORMED_REF, "git refuses #{ref} as a refname") unless ok?(shell)
        end

        # The commit's FULL object name, and a refusal unless that is what the
        # caller already named: {Reconcile} confirms a promotion by comparing
        # `sha_of(ref)` to `params["sha"]`, and the remote answers full names only.
        def anchored!(sha)
          shell = run("rev-parse", "--verify", "--quiet", "#{sha}^{commit}")
          raise Denied.new(UNKNOWN_COMMIT, "#{sha} names no commit in #{@repo_root}") unless ok?(shell)

          resolved = shell.stdout.strip
          return if resolved == sha

          raise Denied.new(INEXACT_SHA, "#{sha} is not an object name -- it resolves to #{resolved}")
        end

        # Every head the remote holds, as `ref => sha`: one round trip for every
        # question a promotion or a delete has.
        def heads
          shell = run("ls-remote", "--heads", @remote)
          raise Denied.new(REMOTE_UNREACHABLE, failure("ls-remote", shell)) unless ok?(shell)

          shell.stdout.lines.filter_map { |line| LISTED.match(line) }.to_h { |line| [line[2], line[1]] }
        end

        def push!(refspec)
          shell = run("push", @remote, refspec)
          raise Denied.new(PUSH_FAILED, failure("push", shell)) unless ok?(shell)
        end

        def delete!(ref)
          shell = run("push", @remote, "--delete", ref)
          raise Denied.new(DELETE_FAILED, failure("push --delete", shell)) unless ok?(shell)
        end

        private

        # {Isolation::Worktree}'s pinned scrub set, not a parallel copy: an
        # ambient GIT_DIR (a pre-commit hook sets one) would otherwise point
        # every call at the hook's repository -- {Review::Source::LocalBranch#git}
        # states the same rule at its own door.
        def run(*)
          shell = @shell_out_factory.call("git", "-C", @repo_root, *,
                                          environment: Isolation::Worktree::GIT_CONTEXT_SCRUB)
          shell.run_command
          shell
        end

        def ok?(shell) = shell.exitstatus.zero?

        def failure(operation, shell) = "git #{operation} failed (exit #{shell.exitstatus}): #{shell.stderr.strip}"
      end

      # @param epic_slug [String] the epic whose working branch this promotes
      # @param journaled [#attempt] the intent/outcome bracket -- {Forge::Journaled}
      # @param repo_root [String] the checkout holding the epic branch's commits
      # @param remote [String] the remote the branch is pushed to
      # @param shell_out_factory [#call] builds the subprocess runner
      def initialize(epic_slug:, journaled:, repo_root: Dir.pwd, remote: DEFAULT_REMOTE,
                     shell_out_factory: Mixlib::ShellOut.public_method(:new))
        @branch = Branch.new(epic_slug:)
        @journaled = journaled
        @remote = Remote.new(repo_root:, remote:, shell_out_factory:)
      end

      # @param sha [String] the full object name of the epic branch's tip
      # @return [Gh::Answer] ok and not observed once pushed, ok and observed when
      #   the remote already stood there, not ok with a reason otherwise
      # @raise [Unanchored] if `sha` is blank
      def call(sha:)
        anchor = anchor_name(sha)
        @journaled.attempt(action: PROMOTE, params: { "ref" => @branch.ref, "sha" => anchor }) { settle(anchor) }
      end

      # Delete the remote branch the pull request merged from, if it still
      # stands at the sha that was promoted.
      #
      # @param sha [String] the full object name the branch was promoted at
      # @return [Gh::Answer] ok once deleted, ok and observed when the remote
      #   holds no such branch any more, not ok with a reason otherwise
      # @raise [Unanchored] if `sha` is blank
      def delete(sha:)
        anchor = anchor_name(sha)
        @journaled.attempt(action: BRANCH_DELETE, params: { "ref" => @branch.ref, "sha" => anchor }) { retire(anchor) }
      end

      private

      def anchor_name(sha)
        anchor = sha.to_s.strip
        raise Unanchored, "#{@branch.ref} was handed no sha" if anchor.empty?

        anchor
      end

      def settle(sha)
        @remote.nameable!(@branch.ref)
        @remote.anchored!(sha)
        decide(sha, @remote.heads)
      rescue Denied => e
        answer(sha, ok: false, reason: e.reason, message: e.message)
      end

      # Already there, somewhere else, or nowhere -- in that order, because the
      # first is the only one that must never be mistaken for the second.
      def decide(sha, heads)
        held = heads.fetch(@branch.ref, "")
        return answer(sha, ok: true, observed: true, reason: ALREADY_PROMOTED) if held == sha

        raise Denied.new(DIVERGED, diverged(held, sha)) unless held.empty?

        unoccupied!(heads)
        @remote.push!(@branch.refspec(sha))
        answer(sha, ok: true, reason: PROMOTED)
      end

      def retire(sha)
        held = @remote.heads.fetch(@branch.ref, "")
        return answer(sha, ok: true, observed: true, reason: ALREADY_DELETED) if held.empty?
        raise Denied.new(DIVERGED, moved_on(held, sha)) unless held == sha

        @remote.delete!(@branch.ref)
        answer(sha, ok: true, reason: DELETED)
      rescue Denied => e
        answer(sha, ok: false, reason: e.reason, message: e.message)
      end

      def unoccupied!(heads)
        blockers = heads.keys.select { |ref| @branch.blocked_by?(ref) }.sort
        raise Denied.new(NAMESPACE_CONFLICT, occupied(blockers)) unless blockers.empty?
      end

      def diverged(held, sha)
        "#{@branch.ref} stands at #{held}, not #{sha}; promotion never forces, so advancing or replacing " \
          "that ref is a human's decision -- `git log #{held}..#{sha}` shows what an advance would carry"
      end

      def moved_on(held, sha)
        "#{@branch.ref} stands at #{held}, not the merged #{sha}: something pushed to it after the merge, " \
          "and a delete never forces, so the branch is left where it is"
      end

      def occupied(blockers)
        "#{blockers.join(", ")} occupy the path #{@branch.ref} would need; a ref cannot be both a file and a " \
          "directory, so delete or rename them on the remote before finishing this epic -- lain deletes none of them"
      end

      # {Gh::Answer}, not a value of this class's own: {Gh::Contracts::Answer}
      # refuses `ok: false, observed: true`, so "a refusal that claims the effect
      # was already in place" is unrepresentable rather than merely never written.
      # rubocop:disable Naming/MethodParameterName -- `ok` is {Outcome}'s field.
      def answer(sha, reason:, ok:, observed: false, message: "")
        Gh::Answer.new(ok:, observed:,
                       detail: { "epic_slug" => @branch.epic_slug, "ref" => @branch.ref, "sha" => sha,
                                 "reason" => reason, "message" => message })
      end
      # rubocop:enable Naming/MethodParameterName
    end
  end
end
