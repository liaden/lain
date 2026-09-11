# frozen_string_literal: true

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

      # SHA-1 or SHA-256, and nothing else: a name that slipped through here
      # would reach `worktree add` as a branch to check out.
      FULL_SHA = /\A(?:\h{40}|\h{64})\z/

      # Stamped into the reflog because git's default `core.logAllRefUpdates`
      # does not log the `refs/lain/` namespace at all.
      CREATED = "lain: created this working branch"

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
        new("epic/#{slug}", repo_root:, git: checkout(repo_root, shell_out_factory)).establish(from: trunk)
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
      # @return [self]
      def establish(from:)
        refuse_unholdable
        refuse_nesting_clash
        create(from) unless exists?
        self
      end

      private

      def exists? = resolves?(ref)

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
      def create(trunk)
        base = trunk_tip(trunk)
        made = @git.update_ref(ref, base, "", reason: CREATED)
        return mark(base) if made.exitstatus.zero?
        return if exists?

        raise Refused, "#{ref} could not be created at #{trunk}'s tip, and lain never force-moves a " \
                       "working branch: #{made.stderr.strip}"
      end

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
        raise Refused, "#{owned_ref} could not be written: #{marked.stderr.strip}" unless marked.exitstatus.zero?
      end
    end
  end
end
