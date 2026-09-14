# frozen_string_literal: true

require "fileutils"
require "securerandom"

module Lain
  module Isolation
    class Worktree
      # Whatever is registered at a path a new lease is about to take: a
      # crash's checkout, or one retained on release for its uncommitted work.
      # Neither is destroyed. It moves aside under {RETAINED}, locked as
      # retained from when it first became nobody's, and the path is free. A
      # leftover whose lock still holds -- a live process, another host, a
      # lock lain did not write -- is refused instead, since clearing it would
      # pull a checkout out from under whoever holds it.
      #
      # The lock is CLAIMED, never simply unlocked ({Registry#claim}): another
      # process may have changed it between this look and this act, and a lock
      # that changed is left exactly as it now is.
      #
      # A leftover moved aside holds a commit, never a branch name: the retry
      # of a crashed issue switches its fresh checkout onto the branch the
      # leftover had out, which git refuses while any checkout still has it.
      class Leftover
        DROPPED = "lain: anchored the commit of a checkout whose directory was gone"

        DETACHED = "lain: detached a leftover moved aside from its branch"

        # @param registry [Registry] the repository's worktree list
        # @param root [String] the worktree root the aside directory sits under
        # @param process_table [LeaseLock::ProcessTable] judges the leftover's lock
        # @param clock [#call] answers now, for a leftover with no retention stamp
        def initialize(registry:, root:, process_table:, clock:)
          @registry = registry
          @root = root
          @process_table = process_table
          @clock = clock
        end

        # @param path [String] the path about to be leased
        # @raise [Refused] when a held lock covers it, its lock changed while
        #   it was being cleared, or git will not move it
        def clear(path)
          @registry.entries.select { |entry| entry.path == path }.each { |entry| move_aside(entry) }
        end

        private

        def move_aside(entry)
          refuse_held(entry)
          raise Refused, "worktree path #{entry.path} changed while it was being cleared" unless @registry.claim(entry)
          return drop(entry) unless File.directory?(entry.path)

          detach(entry) unless entry.branch.empty?
          relocate(entry.path, LeaseLock::Retained.at(entry.lock.aged_from(@clock.call)))
        end

        def refuse_held(entry)
          interrupted = @registry.interrupted(entry.path)
          raise Refused, "worktree path #{entry.path} is held: #{interrupted}" unless interrupted.empty?

          lock = entry.lock
          return unless lock.held?(@process_table)

          raise Refused, "worktree path #{entry.path} is held: #{lock.why(@process_table)}"
        end

        # The directory is gone but git still records its HEAD, which may be
        # the only thing holding a crashed worker's commits: anchored before
        # the registration goes.
        def drop(entry)
          @registry.anchorage.keep(entry, reason: DROPPED)
          shell = @registry.remove(entry.path)
          raise Refused.from_git("remove", entry.path, shell) unless shell.exitstatus.zero?
        rescue Anchorage::Unwritten => e
          raise Refused, "worktree path #{entry.path} still holds a commit that could not be anchored: #{e.message}"
        end

        # Anchored first, so a HEAD no ref reaches is never left the commit's
        # only holder. The detach refuses when HEAD moved since it was read.
        def detach(entry)
          @registry.anchorage.keep(entry, reason: DETACHED)
          shell = @registry.detach(entry.path, entry.head, reason: DETACHED)
          return if shell.exitstatus.zero?

          raise Refused, "worktree path #{entry.path} could not be detached from #{entry.branch}: #{shell.stderr.strip}"
        rescue Anchorage::Unwritten => e
          raise Refused, "worktree path #{entry.path} holds a commit that could not be anchored: #{e.message}"
        end

        def relocate(path, retention)
          aside = File.join(@root, RETAINED, "#{File.basename(path)}-#{SecureRandom.hex(4)}")
          FileUtils.mkdir_p(File.dirname(aside))
          moved = @registry.move(path, aside)
          raise Refused.from_git("move", path, moved) unless moved.exitstatus.zero?

          @registry.lock(aside, retention.reason)
        end
      end
    end
  end
end
