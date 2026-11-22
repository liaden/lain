# frozen_string_literal: true

require "fileutils"
require "securerandom"

module Lain
  module Isolation
    class Worktree
      # Whatever is registered at a path a new lease is about to take: a
      # crash's checkout, or one retained on release for its uncommitted work.
      # Neither is destroyed. It moves aside under {RETAINED}, locked as
      # retained from when it first became nobody's -- a crash's from when it
      # was cut, never from the move -- and the path is free. A
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
      #
      # The lease that moved it aside may read it, so until {#restore} it is
      # locked as held by this process, carrying its retention's age.
      class Leftover
        DROPPED = "lain: anchored the commit of a checkout whose directory was gone"

        DETACHED = "lain: detached a leftover moved aside from its branch"

        # A leftover moved aside, and the hold its lock names until {#restore}.
        Aside = Data.define(:path, :hold)

        # @param registry [Registry] the repository's worktree list
        # @param root [String] the worktree root the aside directory sits under
        # @param process_table [LeaseLock::ProcessTable] judges the leftover's lock
        # @param clock [#call] answers now, for a leftover whose cut cannot be read
        def initialize(registry:, root:, process_table:, clock:)
          @registry = registry
          @root = root
          @process_table = process_table
          @clock = clock
        end

        # @param path [String] the path about to be leased
        # @return [Array<Aside>] each leftover moved aside, held by this process
        # @raise [Refused] when a held lock covers it, its lock changed while
        #   it was being cleared, or git will not move it
        def clear(path)
          @registry.entries.select { |entry| entry.path == path }.filter_map { |entry| move_aside(entry) }
        rescue Registry::Unlisted => e
          raise Refused, "#{@registry.label} could not be listed to clear #{path}: #{e.message}"
        end

        # The first of `paths` that a release retained in place, held by this
        # process for a new lease to read, as {#clear} holds a tree it moves.
        # @param paths [Array<String>] earlier checkouts, newest first
        # @return [Array<Aside>] the one held, or none
        def hold(paths)
          entries = @registry.entries
          held = paths.lazy.filter_map { |path| entries.find { _1.path == path && retained?(_1) } }
                      .filter_map { |entry| held_in_place(entry) }.first
          held ? [held] : []
        rescue Registry::Unlisted
          []
        end

        # Locks a leftover moved aside as retained again, from its first
        # retention. A lock that changed since it was held is left as it is,
        # and a list git cannot give leaves the hold, which ages as retained
        # once this process is gone.
        # @param aside [Aside]
        def restore(aside)
          @registry.entries.select { |entry| entry.path == aside.path && entry.lock == aside.hold }
                   .select { |entry| @registry.claim(entry) }
                   .each { @registry.lock(aside.path, aside.hold.retained.reason) }
        rescue Registry::Unlisted
          nil
        end

        private

        def retained?(entry) = entry.lock.is_a?(LeaseLock::Retained) && File.directory?(entry.path)

        def held_in_place(entry)
          return unless @registry.claim(entry)

          held(entry.path, @process_table.current.holding(entry.lock), entry.lock)
        end

        def named(entry) = "#{@registry.label} at #{entry.path}"

        def move_aside(entry)
          refuse_held(entry)
          unless @registry.claim(entry)
            raise Refused,
                  "#{named(entry)} changed while it was cleared"
          end
          return drop(entry) unless File.directory?(entry.path)

          detach(entry) unless entry.branch.empty?
          relocate(entry.path, LeaseLock::Retained.at(entry.lock.aged_from(@registry.cut_at(entry.path, @clock))))
        end

        def refuse_held(entry)
          interrupted = @registry.interrupted(entry.path)
          raise Refused, "#{named(entry)} is held: #{interrupted}" unless interrupted.empty?

          lock = entry.lock
          return unless lock.held?(@process_table)

          raise Refused, "#{named(entry)} is held: #{lock.why(@process_table)}"
        end

        # The directory is gone but git still records its HEAD, which may be
        # the only thing holding a crashed worker's commits: anchored before
        # the registration goes.
        def drop(entry)
          @registry.anchorage.keep(entry, reason: DROPPED)
          shell = @registry.remove(entry.path)
          raise Refused.from_git("remove", entry.path, shell, label: @registry.label) unless Shell::Out.ok?(shell)
        rescue Anchorage::Unwritten => e
          raise Refused,
                "#{named(entry)} still holds a commit that could not be anchored: #{e.message}"
        end

        # Anchored first, so a HEAD no ref reaches is never left the commit's
        # only holder. The detach refuses when HEAD moved since it was read.
        def detach(entry)
          @registry.anchorage.keep(entry, reason: DETACHED)
          shell = @registry.detach(entry.path, entry.head, reason: DETACHED)
          return if Shell::Out.ok?(shell)

          raise Refused,
                "#{named(entry)} could not be detached from #{entry.branch}: #{shell.stderr.strip}"
        rescue Anchorage::Unwritten => e
          raise Refused, "#{named(entry)} holds a commit that could not be anchored: #{e.message}"
        end

        def relocate(path, retention)
          aside = File.join(@root, RETAINED, "#{File.basename(path)}-#{SecureRandom.hex(4)}")
          FileUtils.mkdir_p(File.dirname(aside))
          moved = @registry.move(path, aside)
          raise Refused.from_git("move", path, moved, label: @registry.label) unless Shell::Out.ok?(moved)

          held(aside, @process_table.current.holding(retention), retention)
        end

        # A hold git will not write leaves the tree as retained as it was, and
        # nothing for the lease to read.
        def held(path, hold, retention)
          return Aside.new(path:, hold:) if Shell::Out.ok?(@registry.lock(path, hold.reason))

          @registry.lock(path, retention.reason)
          nil
        end
      end
    end
  end
end
