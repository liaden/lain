# frozen_string_literal: true

require "mixlib/shellout"

module Lain
  module Forge
    # Put one issue's anchored commit on the remote, as `epic/<slug>/<issue-id>`.
    #
    # This is the tier's one NON-gh action, and it is a plain `git push` of a sha
    # into a refspec: `git push origin <sha>:refs/heads/epic/<slug>/<issue>`.
    # Nothing local is branched. That is not a shortcut -- {Isolation::Worktree}
    # explains at length why a branch in `refs/heads/` is the thing that bleeds a
    # crashed worker's state into its successor, and a promotion that created one
    # locally would put that branch back for every issue that ever lands. The
    # commits come off {Isolation::Worktree::Handback}'s ref and go straight out.
    #
    # == Refuse, never force
    #
    # Re-promoting the SAME sha is an ok, `observed` answer with no push at all,
    # the `Handback#preserve` / `Salvage#already_committed?` doctrine that
    # idempotency is asked of the remote rather than remembered. A ref standing
    # at any OTHER sha is a refusal that names what the remote holds. There is no
    # `--force` and no `--force-with-lease` in this file, deliberately: deciding
    # that a remote branch may be overwritten is the cascade chunk's business,
    # and the outcome this produces is what a human or that chunk reads to make
    # the decision.
    #
    # THE REFUSAL IS NOT ATOMIC WITH THE PUSH, and this is a residual, not an
    # oversight. Reading the remote and pushing to it are two round trips, and a
    # bare `push` enforces only the non-fast-forward rule -- so an actor that
    # creates the ref or advances it to an ANCESTOR of this sha in between gets
    # the push accepted, silently advancing a branch that {#decide} would have
    # refused a moment earlier. Closing it means `--force-with-lease`, whose
    # semantics this chunk may not introduce; the window is the cascade chunk's
    # to shut. A non-fast-forward racer is refused by git itself, so what leaks
    # through is exactly the advance case.
    #
    # == Every refusal is a value; only a caller's own nonsense raises
    #
    # git refusing, a remote nobody can reach, a namespace already occupied --
    # each answers a not-ok {Gh::Answer} carrying the reason, because the answer is
    # journaled as a {Forge::Outcome} and a raise would be a second control path
    # the record never sees ({Gh}'s rule, for the same reason). The two things
    # that DO raise are the two that make an intent unjournalable: a slug or
    # issue id the filesystem grammar refuses (checked at construction, before
    # any subprocess), and a blank sha. Both would put an address in the journal
    # that no {Reconcile} could ever ask the world about.
    #
    # == The address is the whole address
    #
    # {Intent.id_for} digests the action and its params ALONE, so `params` must
    # identify the effect repo-wide. `ref` carries the epic and the issue and
    # `sha` carries the commit, which is exactly enough and exactly all: nothing
    # cosmetic belongs in there, or a reworded retry would address different work.
    class Promotion
      DEFAULT_REMOTE = "origin"

      # What the answer's `detail["reason"]` says, as constants rather than
      # sentences: a caller (T24's landing) branches on these, and a reworded
      # message must not silently change what it decided.
      PROMOTED = "promoted"
      ALREADY_PROMOTED = "already_promoted"
      DIVERGED = "diverged"
      NAMESPACE_CONFLICT = "namespace_conflict"
      MALFORMED_REF = "malformed_ref"
      UNKNOWN_COMMIT = "unknown_commit"
      INEXACT_SHA = "inexact_sha"
      PUSH_FAILED = "push_failed"
      REMOTE_UNREACHABLE = "remote_unreachable"

      # A promotion with no commit to promote. Named per the error-taxonomy
      # convention: a refusal subclasses {Lain::Error} next to the owner that
      # raises it.
      class Unanchored < Error; end

      # A refusal on its way to becoming a {Gh::Answer}. Private and internal: it is
      # raised wherever the fact is discovered -- several calls deep in {Remote}
      # -- and caught once at the boundary, which is {Reconcile::Unobservable}'s
      # shape and for the same reason. Nothing of this class ever escapes #call.
      class Denied < Error
        attr_reader :reason

        def initialize(reason, message)
          @reason = reason
          super(message)
        end
      end
      private_constant :Denied

      # The ref one issue's work belongs on, and the only place the naming rule
      # is written. Pure -- no shell, no state -- so the grammar can be reasoned
      # about without a repository, which is what lets the check happen before
      # any subprocess exists.
      class Branch
        # `epic/` rather than {Isolation::Worktree::Handback::Naming}'s
        # `refs/lain/worker/`: an anchor is deliberately invisible to `git
        # branch`, and a promotion is the opposite -- a branch a human reviews
        # and a pull request can be opened from.
        PREFIX = "refs/heads/epic"

        def initialize(epic_slug:, issue_id:)
          @epic_slug = Epic::Home.checked_name(epic_slug, "epic slug")
          @issue_id = Epic::Home.checked_name(issue_id, "issue id")
          @ref = "#{PREFIX}/#{@epic_slug}/#{@issue_id}".freeze
          # Three interned strings and nothing else, so the house rule for a
          # value object holds mechanically: `Ractor.shareable?` is false for an
          # unfrozen object however immutable its contents are.
          freeze
        end

        attr_reader :epic_slug, :issue_id, :ref

        # No local branch is created, so the sha IS the source side.
        def refspec(sha) = "#{sha}:#{@ref}"

        # Refs are paths in a directory tree, so `epic/demo` and `epic/demo/a1`
        # cannot both exist: one would have to be both a file and a directory.
        # Checked in BOTH directions -- an existing `epic/demo` blocks this ref,
        # and an existing `epic/demo/a1/rework` blocks it just as hard -- because
        # git's own error for the second reads as if the push were malformed.
        def blocked_by?(other) = other.start_with?("#{@ref}/") || @ref.start_with?("#{other}/")
      end

      # The remote, questioned from the local checkout. One invocation shape,
      # scrubbed exactly as {Isolation::Worktree#git} scrubs it, and every git
      # refusal converted at the point it happens into the reason the answer will
      # carry.
      class Remote
        # `<sha>\t<ref>`, which is all `ls-remote` writes. Anchored so a line of
        # something else (a warning git decided to print on stdout) is dropped
        # rather than read as a ref.
        LISTED = /\A(\h+)\s+(\S+)\s*\z/

        def initialize(repo_root:, remote:, shell_out_factory:)
          @repo_root = File.expand_path(repo_root)
          @remote = remote
          @shell_out_factory = shell_out_factory
        end

        # git's own opinion of the composed name. Unreachable while
        # {Epic::Home::NAME} stays narrower than git's rules, which is exactly
        # why it is here: it is the canary for the two grammars drifting apart,
        # and it costs one subprocess that never runs a push.
        def nameable!(ref)
          shell = run("check-ref-format", ref)
          raise Denied.new(MALFORMED_REF, "git refuses #{ref} as a refname") unless ok?(shell)
        end

        # The commit's FULL object name, and a refusal unless that is what the
        # caller already named. A branch, `HEAD`, or an abbreviation all resolve
        # here perfectly well and then poison the address: {Reconcile} confirms a
        # promotion by comparing `sha_of(ref)` to `params["sha"]`, and the remote
        # answers full object names only.
        def anchored!(sha)
          shell = run("rev-parse", "--verify", "--quiet", "#{sha}^{commit}")
          raise Denied.new(UNKNOWN_COMMIT, "#{sha} names no commit in #{@repo_root}") unless ok?(shell)

          resolved = shell.stdout.strip
          return if resolved == sha

          raise Denied.new(INEXACT_SHA, "#{sha} is not an object name -- it resolves to #{resolved}")
        end

        # Every head the remote holds, as `ref => sha`. One round trip answers
        # all three questions this promotion has (is it already there, is it
        # there at something else, is the namespace occupied), and asking them
        # separately would be three questions about a remote that can move
        # between them.
        def heads
          shell = run("ls-remote", "--heads", @remote)
          raise Denied.new(REMOTE_UNREACHABLE, failure("ls-remote", shell)) unless ok?(shell)

          shell.stdout.lines.filter_map { |line| LISTED.match(line) }.to_h { |line| [line[2], line[1]] }
        end

        def push!(refspec)
          shell = run("push", @remote, refspec)
          raise Denied.new(PUSH_FAILED, failure("push", shell)) unless ok?(shell)
        end

        private

        # The scrub set is READ here rather than pinned to a constant in this
        # file: `lain.rb` loads isolation AFTER forge, so a class-body reference
        # would be a load-time NameError. A parallel copy of the five vars would
        # be the worse fix -- it is one rule, and it lives with the class whose
        # class doc explains it.
        def run(*)
          shell = @shell_out_factory.call("git", "-C", @repo_root, *,
                                          environment: Isolation::Worktree::GIT_CONTEXT_SCRUB)
          shell.run_command
          shell
        end

        def ok?(shell) = shell.exitstatus.zero?

        def failure(operation, shell) = "git #{operation} failed (exit #{shell.exitstatus}): #{shell.stderr.strip}"
      end

      # @param epic_slug [String] the epic this promotion belongs to
      # @param issue_id [String] the issue it promotes the work of
      # @param journaled [#attempt] the intent/outcome bracket -- {Forge::Journaled}
      # @param repo_root [String] the checkout holding the anchored commit
      # @param remote [String] the remote the branch is pushed to
      # @param shell_out_factory [#call] builds the subprocess runner, injected as
      #   a factory exactly as {Isolation::Worktree} does
      #
      # `epic_slug` and `issue_id` are constructor state rather than per-call
      # arguments, matching {Forge::Journaled}, which holds the same two and
      # stamps them onto every record: one issue's promotion is one object, so
      # the two cannot be wired to disagree call by call.
      def initialize(epic_slug:, issue_id:, journaled:, repo_root: Dir.pwd, remote: DEFAULT_REMOTE,
                     shell_out_factory: Mixlib::ShellOut.public_method(:new))
        @branch = Branch.new(epic_slug:, issue_id:)
        @journaled = journaled
        @remote = Remote.new(repo_root:, remote:, shell_out_factory:)
      end

      # @param sha [String] the full object name of the anchored commit
      # @return [Gh::Answer] ok and not observed once pushed, ok and observed when
      #   the remote already stood there, not ok with a reason otherwise
      # @raise [Unanchored] if `sha` is blank -- an intent nothing could address
      def call(sha:)
        anchor = anchor_name(sha)
        @journaled.attempt(action: PROMOTE, params: { "ref" => @branch.ref, "sha" => anchor }) { settle(anchor) }
      end

      private

      def anchor_name(sha)
        anchor = sha.to_s.strip
        raise Unanchored, "promotion of #{@branch.ref} was handed no sha to promote" if anchor.empty?

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

      def unoccupied!(heads)
        blocker = heads.keys.find { |ref| @branch.blocked_by?(ref) }
        return if blocker.nil?

        raise Denied.new(NAMESPACE_CONFLICT, occupied(blocker))
      end

      # Both refusals name the state AND what follows from it, because the state
      # alone reads as a tool that failed rather than one that declined. They are
      # different kinds of dead end and say so: a divergence has several ways
      # forward and none of them are this object's to pick, while a ref that is
      # both a file and a directory has exactly one and no flag anywhere changes
      # that. The `reason` constants stay untouched -- a caller branches on
      # those, and a reworded sentence must never move a decision.
      def diverged(held, sha)
        "#{@branch.ref} stands at #{held}, not #{sha}; promotion never forces, so advancing or replacing " \
          "that ref is the cascade's decision -- `git log #{held}..#{sha}` shows what an advance would carry"
      end

      def occupied(blocker)
        "#{blocker} occupies the path #{@branch.ref} would need; a ref cannot be both a file and a " \
          "directory, so delete or rename #{blocker} on the remote before promoting this issue"
      end

      # {Gh::Answer}, not a value of this class's own, and the reason is a guard
      # rather than tidiness: {Gh::Guards::Answer} refuses a non-boolean flag and
      # refuses `ok: false, observed: true` outright, so the contradiction "a
      # refusal that claims the effect was already in place" is unrepresentable
      # here instead of merely never written. A promotion is not a gh call, but
      # the bracket both ride reads the same three messages off whatever the
      # block answered, so it is one value.
      #
      # THE ATTRIBUTION HERE CAN DISAGREE WITH THE JOURNAL'S. `epic_slug` and
      # `issue_id` are put on the answer so a caller can act on a refusal without
      # a trip to the journal -- but {Journaled#attempt} stamps its OWN copy onto
      # the {Outcome} it writes, and attribution wins that merge. Wire a
      # Promotion for one issue to a Journaled for another and the returned
      # answer and the journaled outcome describe one event two ways, with no
      # error anywhere. Neither object can check the other, so the wiring site
      # has to build both for one issue; there is a filed follow-up.
      # rubocop:disable Naming/MethodParameterName -- `ok` is {Outcome}'s field.
      def answer(sha, reason:, ok:, observed: false, message: "")
        Gh::Answer.new(ok:, observed:,
                       detail: { "epic_slug" => @branch.epic_slug, "issue_id" => @branch.issue_id,
                                 "ref" => @branch.ref, "sha" => sha, "reason" => reason, "message" => message })
      end
      # rubocop:enable Naming/MethodParameterName
    end
  end
end
