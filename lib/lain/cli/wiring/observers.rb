# frozen_string_literal: true

module Lain
  module CLI
    class Wiring
      # The in-process folds a chat registers on its session's journal, so
      # each sees every record the chat writes, durable or teed.
      class Observers
        DEGRADED_NOTICE = "write records could not be read, so every user or project binary counts as changed this " \
                          "session and goes to the judge or to you; resume from an intact session to restore it"
        # @param chronicle [#observe, #durable_journal] registers each observer on every journal the chat
        #   writes, and takes the reason a lineage could not be read
        # @param paths [Paths] resolves the sessions directory a resume chains through
        # @param resumed [Resume::Result, nil] nil for a fresh chat
        # @return [Observers]
        def self.register(chronicle:, paths:, resumed:)
          new(fresh: lineage_fresh(paths, resumed, chronicle.durable_journal)).tap do |observers|
            observers.register(chronicle)
          end
        end

        # A chain that cannot be walked is one whose writes are unknown.
        def self.lineage_fresh(paths, resumed, faults)
          return Shell::Executable::Fresh.for_lineage([], faults:) if resumed.nil?

          dir = paths.sessions_dir
          Shell::Executable::Fresh.for_lineage(Resume::ChainWalk.new(dir:).paths(File.join(dir, resumed.file)), faults:)
        rescue Resume::Refusal, SystemCallError => e
          Shell::Executable::Fresh.unknown(e, faults:)
        end

        private_class_method :lineage_fresh

        # @return [Shell::Executable::Fresh] which files changed during this lineage
        attr_reader :fresh

        # @param fresh [Shell::Executable::Fresh]
        def initialize(fresh:)
          @fresh = fresh
        end

        # What the human should be told about the lineage, said once at startup.
        #
        # @return [Array<String>]
        def notices
          @fresh.degraded? ? [DEGRADED_NOTICE] : []
        end

        # @param chronicle [#observe]
        # @return [self]
        def register(chronicle)
          chronicle.observe(@fresh)
          self
        end
      end
    end
  end
end
