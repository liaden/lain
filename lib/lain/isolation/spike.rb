# frozen_string_literal: true

require "fileutils"
require "mixlib/shellout"
require "pathname"
require "securerandom"
require "tmpdir"

module Lain
  module Isolation
    # Where plan scope confines a session in a git repository: a worktree cut
    # on a lain-owned `lain/plan/<key>` branch from a commit of the checkout's
    # tracked state, so an edit the human has not committed comes along and
    # nothing the spike does reaches the checkout.
    #
    # The commit is built through a temporary index seeded from HEAD, so the
    # checkout's own index, its stash list and its reflog are never written.
    # `add --update` takes only what HEAD already tracks: an untracked file, or
    # one merely staged as new, is not copied, and the workspace says so. A
    # clean tree cuts at HEAD itself, and anything else is one commit whose only
    # parent is HEAD.
    #
    # The checkout lives under the fleet's worktree root, so {Gc} judges it as
    # it judges every worker's, and one holding work is retained on release.
    # The branch is lain's, marked, and given back with the lease ({#release}):
    # a spike that committed nothing deletes it, since it holds only a copy of
    # what the checkout already has, and one that committed keeps it at those
    # commits and names it. Deleted only through lain's marker, and only at the
    # commit it was made at; moved only forward.
    class Spike
      BRANCH = "lain/plan"

      # lain made the commit, and a user's identity may be unset where it runs.
      IDENTITY = { "GIT_AUTHOR_NAME" => "lain", "GIT_AUTHOR_EMAIL" => "lain@localhost",
                   "GIT_COMMITTER_NAME" => "lain", "GIT_COMMITTER_EMAIL" => "lain@localhost" }.freeze

      MESSAGE = "lain plan: the checkout's tracked state as plan scope was entered"

      KEPT = "%<branch>s is kept at the spike's commits (%<head>s), which the checkout does not have"

      STRANDED = "%<branch>s is kept where it was cut: the spike's HEAD %<head>s does not descend from that " \
                 "commit, and the spike's own release keeps it"

      MOVED = "%<branch>s was moved since the spike was cut, so it was left where it is: the spike's HEAD " \
              "%<head>s is kept by the spike's own release"

      RETAINED = "the spike's uncommitted changes are kept in its worktree at %<path>s"

      UNDELETED = "%<branch>s could not be deleted, so it stays: %<reason>s"

      # The checkout's tracked state could not be committed, so no spike was cut.
      class Refused < Error; end

      # @param repo_root [String] the repository the spike is cut from
      # @param root [String] the worktree root its checkout is made under
      # @param cwd [String] the session's working directory, which the spike's
      #   own cwd mirrors
      # @param shell_out_factory [#call] builds the subprocess runner
      def initialize(repo_root:, root:, cwd:, shell_out_factory: Shell::Out.public_method(:new))
        @repo_root = File.expand_path(repo_root)
        @root = root
        @cwd = cwd
        @shell_out_factory = shell_out_factory
      end

      # @param key [String] names the branch and the checkout
      # @return [Lease] whose cwd is the session's cwd, inside the spike
      # @raise [Refused] when the tracked state cannot be committed
      # @raise [WorkingBranch::Refused, Worktree::Refused] when the branch or
      #   the checkout cannot be made
      def acquire(key = SecureRandom.hex(6))
        branch = WorkingBranch.owned("#{BRANCH}/#{key}", repo_root: @repo_root, from: snapshot,
                                                         shell_out_factory: @shell_out_factory)
        cut = Worktree.new(root: @root, repo_root: @repo_root, base: branch, shell_out_factory: @shell_out_factory)
                      .acquire("plan.#{key}")
        cwd = mirrored(cut.origin.path).tap { |dir| FileUtils.mkdir_p(dir) }
        on_release = ->(discard: false) { cut.release(discard:) }
        Lease.new(worker_env: cut.worker_env.with(cwd:), on_release:, origin: cut.origin)
      end

      # What the model is told about where it is.
      #
      # @param lease [Lease] one {#acquire} answered
      # @return [String]
      def reminder(lease)
        worker_env = lease.worker_env
        root = worker_env.checkout
        "Plan scope: your writes and commands are confined to #{root}, a spike worktree cut from the checkout's " \
          "tracked state, edits not yet committed included. Untracked files were not copied. Nothing written " \
          "here reaches the checkout, and a path outside #{root} is refused.#{made(worker_env)}"
      end

      # Gives the lease back, and the branch with it.
      #
      # @param lease [Lease] one {#acquire} answered
      # @return [String] what became of the branch, when it was kept; "" when
      #   it was deleted
      def release(lease)
        origin = lease.origin
        head = head_of(origin.path)
        kept = head == origin.base ? nil : keep(origin, head)
        lease.release
        [kept || discard(origin), retained(origin.path)].reject(&:empty?).join("; ")
      end

      private

      # Read before the release, which may remove the checkout.
      def head_of(checkout)
        shell = run("git", "-C", checkout, "rev-parse", "--verify", "HEAD^{commit}")
        shell.exitstatus.zero? ? shell.stdout.strip : ""
      end

      # Forward only, and only from the commit it was cut at.
      def keep(origin, head)
        words = { branch: origin.branch, head: head.empty? ? "unreadable" : head[0, 12] }
        return format(STRANDED, **words) unless git_ok?("merge-base", "--is-ancestor", origin.base, head)
        return format(KEPT, **words) if git_ok?("update-ref", "refs/heads/#{origin.branch}", head, origin.base)

        format(MOVED, **words)
      end

      def git_ok?(*) = run("git", "-C", @repo_root, *).exitstatus.zero?

      # A release removes a clean checkout, so one still on disk holds work.
      def retained(checkout) = File.directory?(checkout) ? format(RETAINED, path: checkout) : ""

      # One transaction deleting the branch together with lain's marker, each
      # only at the commit it was made at, so a branch lain did not mark, or one
      # moved since, is never deleted. Through mixlib, because a transaction is
      # read from stdin and {Shell::Out} gives its child none.
      def discard(origin)
        lines = "delete refs/heads/#{origin.branch} #{origin.base}\n" \
                "delete #{WorkingBranch::OWNED}/#{origin.branch} #{origin.base}\n"
        shell = Mixlib::ShellOut.new("git", "-C", @repo_root, "update-ref", "--stdin",
                                     input: lines, environment: Worktree::GIT_CONTEXT_SCRUB)
        shell.run_command
        shell.exitstatus.zero? ? "" : format(UNDELETED, branch: origin.branch, reason: said(shell))
      end

      def run(*argv) = @shell_out_factory.call(*argv, environment: Worktree::GIT_CONTEXT_SCRUB).tap(&:run_command)

      def said(shell) = shell.stderr.to_s.dup.force_encoding(Encoding::UTF_8).scrub.strip

      # The session's cwd holds nothing the snapshot carried, so it was made.
      def made(worker_env)
        relative = Pathname.new(worker_env.cwd).relative_path_from(worker_env.checkout).to_s
        return "" if relative == "." || !run("git", "-C", worker_env.checkout, "ls-files", "--", relative).stdout.empty?

        " Your working directory #{relative} holds nothing git tracks, so it was made empty in the spike."
      end

      def snapshot
        Dir.mktmpdir("lain-plan-index") do |tmp|
          env = Worktree::GIT_CONTEXT_SCRUB.merge(IDENTITY, "GIT_INDEX_FILE" => File.join(tmp, "index"))
          git(env, "read-tree", "HEAD")
          git(env, "add", "--update")
          tree = git(env, "write-tree")
          head = git(env, "rev-parse", "--verify", "HEAD^{commit}")
          tree == git(env, "rev-parse", "HEAD^{tree}") ? head : git(env, "commit-tree", tree, "-p", head, "-m", MESSAGE)
        end
      end

      def git(env, *args)
        shell = @shell_out_factory.call("git", "-C", @repo_root, *args, environment: env)
        shell.run_command
        return shell.stdout.strip if shell.exitstatus.zero?

        raise Refused, "plan scope could not commit #{@repo_root}'s tracked state (git #{args.first}): #{said(shell)}"
      end

      # The session's cwd, at the same place inside the spike, made when the
      # snapshot did not carry it. A cwd git does not place under the
      # repository starts the spike at its top.
      def mirrored(checkout)
        relative = Pathname.new(File.realpath(@cwd)).relative_path_from(File.realpath(@repo_root)).to_s
        relative.start_with?("..") ? checkout : File.expand_path(relative, checkout)
      rescue SystemCallError, ArgumentError
        checkout
      end
    end
  end
end
