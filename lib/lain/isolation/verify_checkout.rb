# frozen_string_literal: true

module Lain
  module Isolation
    # One scratch worktree per coordinated branch, where a candidate commit is
    # verified. Detached and locked, and never on a branch name, so it cannot
    # collide with the branch checked out anywhere else. It is reused across
    # candidates: `clean` keeps the paths named in `keep`, which is what lets a
    # build cache survive from one verification to the next. Callers hold the
    # branch's drain lock around {#at}, because the relock takes over any lock
    # it reads, live or not.
    class VerifyCheckout
      # @param repo_root [String] any checkout of the repository
      # @param branch [String] the branch whose candidates are verified here
      # @param paths [Paths] locates the worktree root
      # @param keep [Array<String>] untracked paths a reset leaves alone
      # @param shell_out_factory [#call] builds the git subprocess runner
      def self.for(repo_root:, branch:, paths:, keep:, shell_out_factory: Shell::Out.public_method(:new))
        # The ref's last segment is fingerprinted, so path-safe and injective; Naming#key is neither.
        key = File.basename(Worktree::Handback::Naming.new(branch).ref)
        path = File.join(CLI::IsolationBackend.worktree_root(repo_root, paths:), "verify", key)
        new(repo_root:, path:, keep:, shell_out_factory:)
      end

      # @return [String] where the scratch worktree stands
      attr_reader :path

      def initialize(repo_root:, path:, keep:, shell_out_factory:,
                     process_table: LeaseLock::ProcessTable.new)
        @path = path
        @keep = keep
        @registry = Worktree::Registry.new(repo_root:, shell_out_factory:)
        @tree = Checkout.new(path, shell_out_factory:)
        @process_table = process_table
      end

      # @param sha [String] the commit to stand on
      # @return [Candidate]
      # @raise [Error] when git will not add the worktree or reset it
      def at(sha)
        standing? ? reuse(sha) : add(sha)
        Candidate.new(sha:, path: @path)
      end

      private

      def standing? = Dir.exist?(@path) && entry

      def entry
        @registry.entries.find { |registered| spellings(registered.path).intersect?(spellings(@path)) }
      end

      def spellings(path) = Project::Resolver.spellings(path, File)

      # A directory deleted under a live lock stays registered, and git
      # refuses to prune a locked registration.
      def add(sha)
        FileUtils.mkdir_p(File.dirname(@path))
        @registry.unlock(@path)
        @registry.prune
        refused!(@registry.add(@path, sha, reason:), "add its worktree")
      end

      # The first drainer's lock may name a dead process, which gc would read
      # as an abandoned tree under this one.
      def reuse(sha)
        relock(entry)
        reset(sha)
      end

      def relock(held)
        return if held.seal == reason

        raise Error, "lain's verify worktree at #{@path} was taken by another run" unless @registry.claim(held)

        refused!(@registry.lock(@path, reason), "lock its worktree")
      end

      def reason = @process_table.current.reason

      # `-f` so a tracked file edited in the scratch tree cannot block the reset.
      def reset(sha)
        refused!(@tree.run("checkout", "-f", "--detach", sha), "reset to #{sha}")
        refused!(@tree.run("clean", "-ffdx", *@keep.flat_map { |kept| ["-e", kept] }), "clean its worktree")
      end

      def refused!(shell, what)
        return if Shell::Out.ok?(shell)

        raise Error, "lain could not #{what} at #{@path} to verify in: #{shell.stderr.to_s.strip}"
      end
    end
  end
end
