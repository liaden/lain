# frozen_string_literal: true

module Lain
  module CLI
    class Wiring
      # The in-process folds a chat registers on its session's journal, so
      # each sees every record the chat writes, durable or teed.
      class Observers
        DEGRADED_NOTICE = "write records could not be read, so every user or project binary counts as changed this " \
                          "session and goes to the judge or to you; resume from an intact session to restore it"

        # Remembers why the bash sandbox could not be built, or that docker holds bash instead: the header
        # still says `confine: reader`, so the human must hear what bash really runs in.
        class Unconfined
          def initialize
            @because = nil
            @contained = false
          end

          # @param event [Hash, #to_journal] a journal record
          # @return [self]
          def <<(event)
            @because ||= event.provider if degraded?(event, :sandbox)
            @contained ||= degraded?(event, :container)
            self
          end

          # @return [Array<String>]
          def notices
            [("the bash sandbox could not be built (#{@because}), so bash runs unconfined" if @because),
             ("bash runs in the docker container, not in the reader sandbox" if @contained)].compact
          end

          private

          def degraded?(event, capability)
            event.is_a?(Telemetry::CapabilityDegraded) && event.capability == capability
          end
        end

        # @param chronicle [#observe, #durable_journal] registers each observer on every journal the chat
        #   writes, and takes the reason a lineage could not be read
        # @param paths [Paths] resolves the sessions directory a resume chains through
        # @param project [Project] the chat's own, whose directories hold the sessions
        # @param resumed [Resume::Result, nil] nil for a fresh chat
        # @param arms [Arms] under `tripwire: :observe` a {Tripwire::Ledger} folds the journal too
        # @return [Observers]
        def self.register(chronicle:, paths:, project:, resumed:, arms:)
          new(fresh: lineage_fresh(paths, project, resumed, chronicle.durable_journal)).tap do |observers|
            observers.register(chronicle)
            chronicle.observe(Tripwire::Ledger.new(journal: chronicle.durable_journal)) if arms.tripwire == :observe
          end
        end

        # A chain that cannot be walked is one whose writes are unknown.
        def self.lineage_fresh(paths, project, resumed, faults)
          return Shell::Executable::Fresh.for_lineage([], faults:) if resumed.nil?

          dirs = paths.session_dirs(root: project.root, cwd: project.cwd)
          chain = Resume::ChainWalk.new(paths:, dirs:).paths(Paths.session_file(resumed.file, dirs:))
          Shell::Executable::Fresh.for_lineage(chain, faults:)
        rescue Resume::Refusal, SystemCallError => e
          Shell::Executable::Fresh.unknown(e, faults:)
        end

        private_class_method :lineage_fresh

        # @return [Shell::Executable::Fresh] which files changed during this lineage
        attr_reader :fresh

        # @param fresh [Shell::Executable::Fresh]
        # @param unconfined [Unconfined] hears the sandbox degrade while the toolset is built
        def initialize(fresh:, unconfined: Unconfined.new)
          @fresh = fresh
          @unconfined = unconfined
        end

        # What the human should be told about the lineage and the sandbox, said once at startup.
        #
        # @return [Array<String>]
        def notices = [*(DEGRADED_NOTICE if @fresh.degraded?), *@unconfined.notices]

        # @param chronicle [#observe]
        # @return [self]
        def register(chronicle)
          chronicle.observe(@fresh)
          chronicle.observe(@unconfined)
          self
        end
      end
    end
  end
end
