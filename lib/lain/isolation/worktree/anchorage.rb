# frozen_string_literal: true

module Lain
  module Isolation
    class Worktree
      # Pins a checkout's HEAD under `refs/lain/worker/` when nothing else
      # holds it, so the checkout can go without its commits going with it. A
      # detached HEAD is the only thing keeping a worker's commits alive; drop
      # the checkout or its registration and git collects them.
      class Anchorage
        # The anchor could not be written, so the checkout must stay.
        class Unwritten < Error; end

        # @param repo_root [String] any checkout of the repository
        # @param shell_out_factory [#call] builds the subprocess runner
        def initialize(repo_root:, shell_out_factory:)
          @repo = Checkout.new(repo_root, shell_out_factory:)
        end

        # Created against "must not exist" and named for the checkout and the
        # commit, so a second call over the same checkout finds its own anchor.
        # @param entry [Registry::Entry] the checkout, with the HEAD git recorded for it
        # @param reason [String] stamped into the anchor's reflog
        # @return [String] the anchor written, or "" when a ref already reaches HEAD
        # @raise [Unwritten]
        def keep(entry, reason:)
          commit = entry.head
          return "" if reached?(commit)

          ref = Handback::Naming.new("#{File.basename(entry.path)} #{commit}").ref
          return ref if @repo.update_ref(ref, commit, "", reason:).exitstatus.zero? || @repo.target(ref) == commit

          raise Unwritten, "#{ref} could not be written for #{entry.path}"
        end

        private

        # A branch or anything lain keeps under `refs/lain/` both count: either
        # one stops git collecting the commit.
        def reached?(commit)
          found = @repo.run("for-each-ref", "--count=1", "--format=%(refname)", "--contains", commit,
                            "refs/heads/", "refs/lain/")
          found.exitstatus.zero? && !found.stdout.strip.empty?
        end
      end
    end
  end
end
