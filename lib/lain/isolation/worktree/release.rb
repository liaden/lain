# frozen_string_literal: true

module Lain
  module Isolation
    class Worktree
      # What becomes of a checkout when its lease ends. Nothing a worker made
      # is lost: a tree with uncommitted work, or one git cannot read, is
      # retained on disk under a retention lock; a clean one has any commit no
      # ref reaches anchored first and is then removed; and one whose anchor
      # cannot be written is retained instead.
      class Release
        ANCHORED = "lain: anchored a released checkout's unreached commit"

        # @param registry [Registry] the repository's worktree list
        # @param clock [#call] answers now, stamped into a retention lock
        def initialize(registry:, clock:)
          @registry = registry
          @clock = clock
        end

        # @param path [String] the checkout whose lease ended
        # @return [Symbol] `:retained` when it stays on disk, `:removed` when it went
        # @raise [Refused] when git will not remove a clean checkout
        def call(path)
          return retain(path) if @registry.uncommitted?(path)

          reclaim(path)
        end

        private

        def retain(path)
          @registry.unlock(path)
          @registry.lock(path, LeaseLock::Retained.at(@clock.call).reason)
          :retained
        end

        def reclaim(path)
          anchorage = @registry.anchorage
          @registry.entries.select { |entry| entry.path == path }
                           .each { |entry| anchorage.keep(entry, reason: ANCHORED) }
          remove(path)
          :removed
        rescue Anchorage::Unwritten
          retain(path)
        end

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
