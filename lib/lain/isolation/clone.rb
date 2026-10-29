# frozen_string_literal: true

module Lain
  module Isolation
    # Isolation by `git clone --shared`: each worker leases a repository of its
    # own, reading upstream's objects through alternates, rather than a linked
    # worktree of upstream. Everything {Worktree} promises holds -- detached at
    # a SHA from the base, locked while leased, nothing a worker made discarded,
    # leftovers moved aside -- through a {Registry} that answers the same
    # messages.
    #
    # Why a clone: a linked worktree's git dir is upstream's, so a sandboxed
    # call there must be granted upstream's objects, refs and logs, which let it
    # plant refs and corrupt packs, while packed-refs stays read-only and every
    # ref deletion fails. A clone's whole git dir is under the lease, and no
    # upstream byte is writable. The price is that a lease's commits reach
    # upstream only when fetched, which {Checkout#fold_in} does before any ref
    # names one.
    class Clone < Worktree
      # @param root [String] the lease root the clones live under
      # @param repo_root [String] upstream
      # @param shell_out_factory [#call] builds the subprocess runner
      # @param paths [Paths] keys each worker's clone and this root's pins
      # The rest of the keywords are what {Worktree#initialize} takes.
      def initialize(root:, repo_root:, shell_out_factory: Shell::Out.public_method(:new), paths: Paths.new,
                     **)
        registry = Registry.new(repo_root: File.expand_path(repo_root), root: File.expand_path(root),
                                shell_out_factory:, paths:)
        super(root:, repo_root:, shell_out_factory:, paths:, registry:, **)
      end
    end
  end
end
