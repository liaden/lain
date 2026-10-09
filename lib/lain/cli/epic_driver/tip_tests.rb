# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module Lain
  module CLI
    module EpicDriver
      # The project's whole suite, run on the sha an implementation gate is
      # about to name, and journaled as a {Telemetry::TestsRan}.
      #
      # The sha is checked out detached in a worktree of its own, because the
      # checkout the actor held was rebased by retirement and then released: no
      # tree but this one is the gated sha. The worktree goes on every path.
      #
      # A harness that refuses (a timeout, a result it cannot parse) is
      # journaled as a run that did not happen, never raised: the gate reports
      # what the tests did and the human decides, so a suite that could not run
      # must not keep the question from being asked.
      class TipTests
        # @param repo_root [String] the repository the sha is in
        # @param harness [#call] `root -> #run`, the suite runner over a
        #   checkout, raising {Lain::Error} when there is none to run
        # @param journal [#<<] where the record goes
        # @param tmp [String] the directory the throwaway worktree is cut under
        # @param shell_out_factory [#call] builds the git subprocess runner
        def initialize(repo_root:, harness:, journal:, tmp:, shell_out_factory: Lain::Shell::Out.public_method(:new))
          @git = Lain::Isolation::Checkout.new(repo_root, shell_out_factory:)
          @harness = harness
          @journal = journal
          @tmp = tmp
        end

        # @param issue_id [String]
        # @param sha [String] the commit the gate will name
        # @return [Telemetry::TestsRan] already journaled
        def call(issue_id, sha)
          ran(issue_id, sha).tap { |record| @journal << record }
        end

        private

        def ran(issue_id, sha)
          detached(sha) { |root| Telemetry::TestsRan.from(suite(root), issue_id:, sha:) }
        rescue Lain::Error => e
          Telemetry::TestsRan.unrun(issue_id:, sha:, why: e.message)
        end

        # The caller's git context (a commit hook's GIT_INDEX_FILE) names
        # another repository than the one under test.
        def suite(root)
          env = Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB
          @harness.call(root).run(Lain::WorkerEnv.new(cwd: root, env:, checkout: root))
        end

        def detached(sha)
          FileUtils.mkdir_p(@tmp)
          root = Dir.mktmpdir("tip-", @tmp)
          added!(@git.run("worktree", "add", "-q", "--detach", root, sha), sha)
          yield root
        ensure
          removed(root)
        end

        def added!(shell, sha)
          return if shell.exitstatus.zero?

          raise Lain::Error, "git could not check out #{sha} to test it: #{shell.stderr.strip}"
        end

        # Never `worktree prune`: it drops every registration whose directory is
        # gone, a human's included, and the commits only that tree held.
        def removed(root)
          return if root.nil?

          FileUtils.rm_rf(root)
          @git.run("worktree", "remove", "--force", root)
        end
      end
    end
  end
end
