# frozen_string_literal: true

module Lain
  module Isolation
    # The baseline backend: no isolation at all. Every worker leases the shared
    # process environment, and releasing is a no-op because nothing was
    # provisioned to reclaim.
    #
    # {WorkerEnv.default} is recomputed per `acquire`, never a frozen constant,
    # so a lease taken after a `Dir.chdir` still names the current directory.
    class Null
      # `root:` has no default -- the root-defaults discipline
      # (`spec/lain/project/root_defaults_spec.rb`) exists precisely to stop a
      # root being inferred from the process cwd, and every zero-arg
      # `Null.new` call site in `lib/` never asks {#repo_root} a question, so
      # there is nothing for a default here to serve.
      # @param root [String, nil] where {#repo_root}'s search starts; nil
      #   means this backend was built with no root to search from
      # @param paths [Paths] supplies the XDG bases {#repo_root}'s search stops at
      # @param home [String, nil] the user's home directory, bounding that search
      def initialize(root: nil, paths: Paths.new, home: paths.home_or_nil)
        @root = root
        @paths = paths
        @home = home
      end

      # @param _worker_id [Object] ignored -- every worker shares one env
      # @return [Lease] a lease over the shared process env; release is a no-op
      def acquire(_worker_id = nil) = Lease.new(worker_env: WorkerEnv.default)

      # No checkout is cut, so there is no branch to hand work back to.
      # @return [WorkingBranch::NONE]
      def base = WorkingBranch::NONE

      # No checkout is cut, so none is ever kept back on release.
      # @return [false]
      def retained?(_path) = false

      # No checkout was cut FROM anywhere, so this answers the repository
      # through {Project::Repository} -- the one search, the one stop rule every
      # layer asks -- rather than a second walk that could disagree with it. A
      # handback built over `--isolation none` still needs a real repository to
      # merge a worker's commits into.
      # @return [String] the nearest repository at or above the root this
      #   backend was built with
      # @raise [Error] when this backend was built with no root, or the
      #   search from it finds no repository
      # @raise [Project::Resolver::UnusableHome] when `home` cannot bound the search
      def repo_root
        # {#repo_root} either has no root to search from, or finds no repository
        # above the one it was built with. Raised rather than answering nil or
        # the cwd -- either would let a caller mistake "this backend cuts no
        # checkouts" for "there is nothing to merge into".
        raise Error, "this Isolation::Null was built with no root to search from" unless @root

        resolved = Project::Resolver.resolved(File.expand_path(@root), File)
        nearest = Project::Repository.nearest(resolved, paths: @paths, home: @home)
        return nearest.path if nearest.found?

        raise Error, "--isolation none has no checkout to answer with, and #{nearest.searched(resolved)}"
      end
    end
  end
end
