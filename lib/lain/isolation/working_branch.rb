# frozen_string_literal: true

require "mixlib/shellout"

module Lain
  module Isolation
    # The named branch workers are cut from and handed back to: the branch a
    # chat launched on, or an epic's local `epic/<slug>`.
    #
    # A NAME, RESOLVED PER READ. {#tip} asks git for `refs/heads/<name>` every
    # time, so a lease taken after a commit lands sees the moved tip, and a
    # human switching the parent checkout later does not re-point the workers.
    # The answer is always a full SHA, so a name never reaches `worktree add`,
    # where git's DWIM would turn it into a branch checkout.
    #
    # NEVER FORCE-MOVED. An epic branch is created with git's compare-and-swap
    # against "must not exist", and an existing one is left exactly where it is.
    # One lain created carries a marker under {OWNED}, which is the only
    # licence anything has to delete it later; a branch a human made never gets
    # one.
    class WorkingBranch
      OWNED = "refs/lain/owned/heads"

      TRUNK = "main"

      # The prefix an epic's branch takes. Held as a name a caller can ask for
      # without creating anything: a prompt telling an actor where to rebase
      # needs the word, not the branch.
      EPIC = "epic"

      # SHA-1 or SHA-256, and nothing else: a name that slipped through here
      # would reach `worktree add` as a branch to check out.
      FULL_SHA = /\A(?:\h{40}|\h{64})\z/

      # Stamped into the reflog because git's default `core.logAllRefUpdates`
      # does not log the `refs/lain/` namespace at all.
      CREATED = "lain: created this working branch"

      # Stamped into the reflog of the anchor a deleted branch's tip is kept on.
      DISCARDED = "lain: kept this working branch's tip before deleting it"

      # A working branch that cannot be resolved or created. A {Lain::Error},
      # so `exe/lain` renders it as a message naming the fix.
      class Refused < Error; end

      # The base held when none was given. Every lease refuses, rather than
      # silently cutting from whatever HEAD happens to be. A handback enforces
      # no target, merging into whatever the parent has checked out -- what
      # every caller did before a working branch existed, and all one with no
      # branch to name can do.
      NONE = Class.new do
        def name = ""

        def tip
          raise Refused, "no working branch was given to cut workers from; build the backend with a base"
        end

        def current_in?(_checkout) = true
      end.new.freeze

      # @param repo_root [String] the checkout whose HEAD names the branch
      # @param shell_out_factory [#call] builds the subprocess runner
      # @return [WorkingBranch] the branch HEAD is on right now
      # @raise [Refused] on a detached HEAD
      def self.checked_out(repo_root:, shell_out_factory: Shell::Out.public_method(:new))
        git = checkout(repo_root, shell_out_factory)
        symbolic = git.symbolic_head
        return new(symbolic.delete_prefix("refs/heads/"), repo_root:, git:) if symbolic.start_with?("refs/heads/")

        raise Refused, "#{repo_root} is on a detached HEAD, and lain cuts workers from a named branch so " \
                       "their work has somewhere to land; run `git switch <branch>` there first"
      end

      # @param slug [String] the epic's slug; the branch is `epic/<slug>`
      # @param repo_root [String] the repository the branch lives in
      # @param trunk [String] the branch a new epic branch starts from
      # @param shell_out_factory [#call] builds the subprocess runner
      # @return [WorkingBranch] `epic/<slug>`, created from the trunk's tip if absent
      # @raise [Refused] when the name is not a legal branch, per-issue branches
      #   already occupy it, the trunk is missing, or a sibling created it first
      def self.epic(slug, repo_root:, trunk: TRUNK, shell_out_factory: Shell::Out.public_method(:new))
        new(epic_name(slug), repo_root:, git: checkout(repo_root, shell_out_factory)).establish(from: trunk)
      end

      # @param slug [String] the epic's slug; the branch is `epic/<slug>`
      # @return [String] that branch's name, whether or not it exists
      def self.epic_name(slug) = "#{EPIC}/#{slug}"

      # Any branch lain owns, not only an epic's: an issue's, a future
      # scheduler's. Created at `from` and marked when absent; where one is
      # already standing, it is REUSED only if lain's marker says lain made it,
      # because that marker is the one licence anything has to delete it later.
      #
      # @param name [String] the branch, without `refs/heads/`
      # @param repo_root [String] the repository the branch lives in
      # @param from [String] where a new branch starts: a full SHA, or the name
      #   of a branch whose tip to take
      # @param shell_out_factory [#call] builds the subprocess runner
      # @return [WorkingBranch]
      # @raise [Refused] when the name is not a legal branch, branches nest
      #   against it, the base names no commit, or a branch stands there that
      #   lain did not create
      def self.owned(name, repo_root:, from:, shell_out_factory: Shell::Out.public_method(:new))
        new(name, repo_root:, git: checkout(repo_root, shell_out_factory)).establish(from:, owned_only: true)
      end

      # @param prefix [String] a branch-name prefix, without `refs/heads/` or a
      #   trailing slash
      # @param repo_root [String] the repository the branches live in
      # @param shell_out_factory [#call] builds the subprocess runner
      # @return [Array<WorkingBranch>] every branch under the prefix that lain
      #   created and still marks, or began deleting and never finished
      def self.owned_under(prefix, repo_root:, shell_out_factory: Shell::Out.public_method(:new))
        git = checkout(repo_root, shell_out_factory)
        git.run("for-each-ref", "--format=%(refname)", "refs/heads/#{prefix}/").stdout.split("\n")
           .map { |branch| new(branch.delete_prefix("refs/heads/"), repo_root:, git:) }
           .select { |branch| branch.owned? || branch.unfinished? }
      end

      # The anchor a delete keeps a branch's tip on. Derived from the branch
      # name and the tip, so a branch standing unmarked at that tip can be
      # recognised as mid-delete from the two refs alone.
      #
      # @param name [String] the branch, without `refs/heads/`
      # @param tip [String] the commit being kept
      # @return [String] the anchor ref
      def self.anchor_for(name, tip) = Worktree::Handback::Naming.new("#{name} #{tip}").ref

      # @param anchor [String] a ref under `refs/lain/worker/`
      # @param commit [String] the commit it holds
      # @param repo [#refs, #tip] answers `refs(prefix)` as `[ref, commit]`
      #   pairs, and `tip(ref)` as a SHA or ""
      # @return [String] the unmarked branch still standing at `commit` whose
      #   unfinished delete `anchor` belongs to, or "" when there is none
      def self.unfinished_at(anchor, commit, repo:)
        standing = repo.refs("refs/heads").filter_map { |ref, at| ref.delete_prefix("refs/heads/") if at == commit }
        standing.find { |name| repo.tip("#{OWNED}/#{name}").empty? && anchor_for(name, commit) == anchor }.to_s
      end

      def self.checkout(repo_root, shell_out_factory)
        Checkout.new(File.expand_path(repo_root), shell_out_factory:)
      end
      private_class_method :checkout

      attr_reader :name

      # @param name [String] the branch, without `refs/heads/`
      # @param repo_root [String] the repository, named in every refusal
      # @param git [Checkout] over the repository
      def initialize(name, repo_root:, git:)
        @name = -name.to_s
        @repo_root = repo_root
        @git = git
      end

      def ref = "refs/heads/#{name}"

      def owned_ref = "#{OWNED}/#{name}"

      # @param checkout [Checkout] a working tree, usually the parent's
      # @return [Boolean] whether that checkout's HEAD is on this branch
      def current_in?(checkout) = checkout.symbolic_head == ref

      # @return [String] the branch's commit, as a full SHA
      # @raise [Refused] when the branch names no commit
      def tip
        shell = @git.run("rev-parse", "--verify", "--quiet", "#{ref}^{commit}")
        sha = shell.stdout.strip
        return sha if shell.exitstatus.zero? && FULL_SHA.match?(sha)

        raise Refused, "#{ref} names no commit in #{@repo_root} to cut a worker from"
      end

      # Idempotent: creates the branch and its owned marker when absent, and
      # writes nothing when the branch already exists.
      #
      # A caller passing `owned_only` reuses a standing branch only when lain's
      # marker says lain created it. An epic's branch does not ask for that --
      # a human may make `epic/<slug>` themselves and lain works on it, unmarked
      # and never reaped.
      #
      # @param from [String] a full SHA, or the name of a branch whose tip to take
      # @param owned_only [Boolean] refuse a standing branch lain did not create
      # @return [self]
      # @raise [Refused]
      def establish(from:, owned_only: false)
        refuse_unholdable
        refuse_nesting_clash
        exists? ? standing(owned_only) : create(from)
        self
      end

      # @param registry [Worktree::Registry] the repository's checkouts
      # @return [Hash{String=>Array<String>}] each branch ref a checkout has out
      #   or is rebasing, and those checkouts' paths. Read once for a batch of
      #   deletes rather than once per branch: every rebase probe is a process.
      def self.holders(registry)
        held = registry.entries.flat_map do |entry|
          [entry.branch, registry.rebasing(entry.path)].reject(&:empty?).uniq.product([entry.path])
        end
        held.group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
      end

      # Everything that could refuse {#discard}, answered before anything
      # moves, so a caller deleting several branches can judge them all first.
      #
      # @param holders [Hash{String=>Array<String>}] from {.holders}
      # @return [String] the tip {#discard} deletes the branch at
      # @raise [Refused] when lain did not create the branch, a checkout has it
      #   out or is rebasing it, or the anchor its tip would take holds
      #   another commit
      def discardable!(holders)
        unowned! unless owned? || unfinished?
        unheld!(holders.fetch(ref, []))
        held = tip
        anchor = anchor_for(held)
        standing = @git.target(anchor)
        return held if standing.empty? || standing == held

        raise Refused, "#{anchor} already holds #{standing}, not #{ref}'s tip #{held}, so the branch was not deleted"
      end

      # Deletes a branch lain created once its tip stands on an anchor under
      # `refs/lain/worker/`, so nothing it held can be collected. Nothing is
      # moved: the anchor is created against "must not exist", and the marker
      # and the branch are each deleted only at the value judged.
      #
      # A SIBLING RUN MAY REACH THE BRANCH AT ANY POINT, so the marker is the
      # token both sides read:
      # - the marker goes first, so a sibling cutting the branch afresh after
      #   the delete keeps its own marker;
      # - checkouts are read again once the marker is gone, so a sibling that
      #   leased the branch earlier keeps it and this delete refuses;
      # - the branch goes in one git transaction that also verifies no marker
      #   has come back, so a sibling that reclaimed it meanwhile keeps it;
      # - a sibling that leases it after the checkouts were read finds the
      #   marker gone ({#still_owned!}) and stops before any work.
      # A crash after the marker leaves exactly what {#unfinished?} recognises.
      #
      # @param at [String] the tip {#discardable!} answered
      # @param registry [Worktree::Registry] the repository's checkouts, read
      #   again after the marker goes
      # @return [String] the anchor the tip now stands on
      # @raise [Refused] when git refuses the anchor, a sibling leased or
      #   reclaimed the branch, or the branch is no longer where it was judged
      def discard(at:, registry:)
        anchor = anchored(at)
        marked = @git.target(owned_ref)
        unmarked!(marked) unless marked.empty?
        unleased!(registry, marked)
        deleted!(at, marked)
        anchor
      end

      # Asked by a run that has just checked the branch out. A delete reads
      # checkouts once its marker is gone, so a lease taken after that read is
      # one it cannot see: the leasing run is the one that has to stop.
      #
      # @return [void]
      # @raise [Refused] when lain's marker is gone
      def still_owned!
        return if owned?

        raise Refused, "#{ref} lost lain's marker as this run checked it out: another run is deleting it, so this " \
                       "run will not work on it -- run /implement-epic again once that delete has finished"
      end

      def exists? = resolves?(ref)

      def owned? = resolves?(owned_ref)

      # A delete that stopped after the marker went and before the branch did:
      # the branch stands unmarked at exactly the tip its own delete anchor
      # holds. Such a branch is still lain's -- to finish deleting, or to keep.
      def unfinished?
        held = @git.target(ref)
        !owned? && !held.empty? && @git.target(WorkingBranch.anchor_for(name, held)) == held
      end

      private

      def unowned!
        raise Refused, "#{ref} is a branch lain did not create (nothing marks it at #{owned_ref}), so lain will " \
                       "not delete it"
      end

      # update-ref, unlike git's own branch delete, never asks whether a
      # checkout has the branch out; and a rebase in progress detaches its
      # checkout, yet finishing it rewrites the branch by name.
      def unheld!(paths)
        return if paths.empty?

        raise Refused, "#{ref} is checked out or being rebased at #{paths.join(", ")}, so lain will not delete " \
                       "it from under that checkout: finish or remove it there first"
      end

      def anchor_for(held) = WorkingBranch.anchor_for(name, held)

      def anchored(held)
        anchor = anchor_for(held)
        return anchor if @git.update_ref(anchor, held, "", reason: DISCARDED).exitstatus.zero?
        return anchor if @git.target(anchor) == held

        raise Refused, "#{anchor} could not be written to keep #{ref}'s tip #{held}, so the branch was not deleted"
      end

      def unleased!(registry, marked)
        paths = WorkingBranch.holders(registry).fetch(ref, [])
        return if paths.empty?

        raise Refused, "another run took #{ref} at #{paths.join(", ")} while lain was deleting it, so the delete " \
                       "stopped and the branch stays#{remarked(marked)}"
      end

      def unmarked!(marked)
        gone = @git.run("update-ref", "-d", owned_ref, marked)
        return if gone.exitstatus.zero?

        raise Refused, "#{owned_ref} changed while lain was deleting #{ref}, so the branch was not deleted: " \
                       "#{said(gone)}"
      end

      def deleted!(held, marked)
        gone = transacted("verify #{owned_ref}", "delete #{ref} #{held}")
        return if gone.exitstatus.zero?
        raise Refused, "another run reclaimed #{ref} while lain was deleting it, so it stays, marked" if owned?

        raise Refused, "#{ref} could not be deleted at #{held}, where its tip was anchored, so it stays where it " \
                       "now is#{remarked(marked)}: #{said(gone)}"
      end

      # An unfinished delete had no marker to put back. The marker comes back
      # only onto a branch still standing, so none is left naming nothing.
      def remarked(marked)
        return "" if marked.empty?
        return ", still marked" if owned? || restored?(marked)

        ", but its marker could not be put back at #{owned_ref}"
      end

      def restored?(marked)
        standing = @git.target(ref)
        !standing.empty? && transacted("verify #{ref} #{standing}", "create #{owned_ref} #{marked}").exitstatus.zero?
      end

      # git applies every line or none. Through mixlib rather than {Checkout},
      # because a transaction is read from stdin and {Shell::Out} gives its
      # child none.
      def transacted(*lines)
        Mixlib::ShellOut.new("git", "-C", File.expand_path(@repo_root), "update-ref", "--stdin",
                             input: lines.map { |line| "#{line}\n" }.join,
                             environment: Worktree::GIT_CONTEXT_SCRUB).run_command
      end

      def standing(owned_only)
        return if !owned_only || owned?
        return remark if unfinished?

        raise Refused, "#{ref} is already there and lain did not create it (nothing marks it at " \
                       "#{owned_ref}), so lain will not claim a branch it may not later delete: " \
                       "rename or remove it, or let whoever owns it finish with it"
      end

      # Kept, a branch lain left mid-delete is lain's again. Its creation base
      # is gone with the marker, so the tip it stands at is the base recorded:
      # gc then reads it as a branch nothing has landed on yet. Marked only in
      # one transaction with the branch still at that tip, so a delete landing
      # first leaves no marker naming nothing.
      def remark
        held = @git.target(ref)
        return if !held.empty? && transacted("verify #{ref} #{held}", "create #{owned_ref} #{held}").exitstatus.zero?
        return if owned?

        raise Refused, "#{ref} was a delete lain left unfinished, and another run deleted it while this one " \
                       "reclaimed it: run /implement-epic again to cut the issue afresh"
      end

      def resolves?(candidate) = @git.run("rev-parse", "--verify", "--quiet", candidate).exitstatus.zero?

      def refuse_unholdable
        return if @git.run("check-ref-format", ref).exitstatus.zero?

        raise Refused, "#{name.inspect} cannot be held in a branch name (#{ref} is not a legal refname)"
      end

      # git holds a ref or a directory of refs at one name, never both: the old
      # promotion model wrote per-issue branches beneath this one, and a branch
      # named `epic` sits above every one. Deleting either would destroy work
      # nobody asked lain to touch.
      def refuse_nesting_clash
        clashes = above + beneath
        return if clashes.empty?

        raise Refused, "#{ref} clashes with #{clashes.join(", ")}: git cannot hold a branch and a branch " \
                       "nested under it at one name. lain deletes none of them; rename or remove them first"
      end

      def beneath = @git.run("for-each-ref", "--format=%(refname)", "#{ref}/").stdout.split("\n")

      # Every shorter name this one would nest under: `epic` for `epic/demo`.
      def above
        parts = name.split("/")
        (1...parts.size).map { |count| "refs/heads/#{parts.first(count).join("/")}" }
                        .select { |candidate| resolves?(candidate) }
      end

      # The branch first, then the marker: a crash between the two leaves an
      # unmarked branch, which is treated as a human's and never deleted. A
      # lost swap is a sibling that created it first -- that sibling marks it,
      # and this resolve answers the branch as it found it.
      def create(from)
        base = FULL_SHA.match?(from) ? from : trunk_tip(from)
        made = @git.update_ref(ref, base, "", reason: CREATED)
        return mark(base) if made.exitstatus.zero?
        return if exists?

        raise Refused, "#{ref} could not be created at #{from}, and lain never force-moves a " \
                       "working branch: #{said(made)}"
      end

      # git's stderr arrives as ASCII-8BIT, so interpolating it raw into a
      # refusal raises Encoding::CompatibilityError the moment git says
      # anything non-ASCII -- and the named refusal a caller rescues never
      # arrives. {Checkout#unmerged} re-tags for the same reason.
      def said(shell) = shell.stderr.to_s.dup.force_encoding(Encoding::UTF_8).scrub.strip

      def trunk_tip(trunk)
        WorkingBranch.new(trunk, repo_root: @repo_root, git: @git).tip
      rescue Refused
        raise Refused, "#{ref} is created from #{trunk}, and #{@repo_root} has no #{trunk} branch to start it from"
      end

      # Unconditional rather than compare-and-swapped: the namespace is lain's
      # own, the branch was created a moment ago, and a stale marker left by a
      # branch a human deleted is exactly what should be overwritten.
      def mark(base)
        marked = @git.update_ref(owned_ref, base, reason: CREATED)
        raise Refused, "#{owned_ref} could not be written: #{said(marked)}" unless marked.exitstatus.zero?
      end
    end
  end
end
