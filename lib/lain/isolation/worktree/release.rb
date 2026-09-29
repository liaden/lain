# frozen_string_literal: true

module Lain
  module Isolation
    class Worktree
      # What becomes of a checkout when its lease ends. Nothing a worker made
      # is lost: a tree with uncommitted work, or one git cannot read, is
      # retained on disk under a retention lock; a clean one has any commit no
      # ref reaches anchored first and is then removed; and one whose anchor
      # cannot be written is retained instead.
      #
      # A retained tree holds a commit, never a branch name. An issue's retry
      # switches a new checkout onto the branch this one had out, and git
      # refuses that while any checkout still has it, so retention anchors
      # HEAD and then detaches it, leaving every file where the worker left it.
      class Release
        ANCHORED = "lain: anchored a released checkout's unreached commit"

        DETACHED = "lain: detached a retained checkout from its branch"

        # @param registry [Registry] the repository's worktree list
        # @param clock [#call] answers now, stamped into a retention lock
        def initialize(registry:, clock:)
          @registry = registry
          @clock = clock
        end

        # @param path [String] the checkout whose lease ended
        # @param discard [Boolean] reclaim the checkout even with uncommitted work,
        #   for a caller whose result is already recorded elsewhere
        # @return [Symbol] `:retained` when it stays on disk, `:removed` when it went
        # @raise [Refused] when git will not remove a clean checkout
        def call(path, discard: false)
          return retain(path) if !discard && @registry.uncommitted?(path)

          reclaim(path)
        end

        private

        def retain(path)
          @registry.unlock(path)
          @registry.lock(path, LeaseLock::Retained.at(@clock.call).reason)
          registered(path).reject { |entry| entry.branch.empty? }.each { |entry| detach(entry) }
          :retained
        end

        # Anchored first, so a HEAD no ref reaches is never left the commit's
        # only holder. A branch left checked out still holds the commit, so an
        # anchor that cannot be written, or a detach refused because HEAD moved
        # since it was read, leaves the tree as it is, and the retry's own
        # refused switch names this checkout.
        def detach(entry)
          @registry.anchorage.keep(entry, reason: ANCHORED)
          @registry.detach(entry.path, entry.head, reason: DETACHED)
        rescue Anchorage::Unwritten
          :attached
        end

        def reclaim(path)
          anchorage = @registry.anchorage
          registered(path).each { |entry| anchorage.keep(entry, reason: ANCHORED) }
          remove(path)
          :removed
        rescue Anchorage::Unwritten
          retain(path)
        end

        def registered(path) = @registry.entries.select { |entry| entry.path == path }

        # `--force` reliably removes a dirty tree; a retry clears a stale
        # registration whose directory is already gone. A failure to reclaim is
        # a real leak, so it is raised rather than swallowed.
        def remove(path)
          @registry.unlock(path)
          return if @registry.remove(path).exitstatus.zero?

          @registry.prune
          return unless File.exist?(path)

          shell = @registry.remove(path)
          raise Refused.from_git("remove", path, shell) unless shell.exitstatus.zero?
        end
      end
    end
  end
end
