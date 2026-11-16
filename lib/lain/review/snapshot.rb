# frozen_string_literal: true

require "tmpdir"

module Lain
  module Review
    # A dirty work tree as 1 commit on top of HEAD, so a review of uncommitted
    # work reads like any other commit range. It is built in a throwaway index
    # and no ref is written, so the repository's own index, HEAD and refs are
    # untouched; the commit is reachable only by its sha.
    class Snapshot
      MESSAGE = "lain review: the uncommitted state of the work tree"
      private_constant :MESSAGE

      # @param repo_root [String] the work tree to snapshot
      # @param shell_out_factory [#call] builds the subprocess runner
      def initialize(repo_root:, shell_out_factory: Shell::Out.public_method(:new))
        @git = Isolation::Checkout.of(File.expand_path(repo_root), shell_out_factory:)
      end

      # Tracked changes and new untracked files, ignored files excluded.
      # @return [String, nil] the commit sha, or nil when the work tree is clean
      # @raise [Isolation::Checkout::Failed] when git cannot build the commit
      def take
        Dir.mktmpdir("lain-review-index") do |tmp|
          env = Isolation::Gc::Snapshot::IDENTITY.merge("GIT_INDEX_FILE" => File.join(tmp, "index"))
          step(env, "read-tree", "HEAD")
          step(env, "add", "--all")
          tree = step(env, "write-tree")
          step(env, "commit-tree", tree, "-p", "HEAD", "-m", MESSAGE) unless tree == head_tree(env)
        end
      end

      private

      def head_tree(env) = step(env, "rev-parse", "HEAD^{tree}")

      def step(env, *) = @git.out(*, env:).strip
    end
  end
end
