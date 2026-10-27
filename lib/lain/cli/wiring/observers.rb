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
        # still names the confine arm, so the human must hear what bash really runs in.
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
             ("bash runs in the docker container, not in the bash sandbox" if @contained)].compact
          end

          private

          def degraded?(event, capability)
            event.is_a?(Telemetry::CapabilityDegraded) && event.capability == capability
          end
        end

        # A project with a link on the way to a persistence file cannot run a workspace call at all, so under
        # that arm the human hears it once at start rather than from each refused call.
        class Unsealed
          NOTICE = "%<link>s is a link inside the project, so the workspace sandbox refuses every bash call the " \
                   "judge, a rule or bypass approves; replace the link with its file, or restart with --confine reader"

          # Asks nothing of a chat whose arm writes no project.
          module Unasked
            def self.notices = []
          end

          # @param arms [Arms]
          # @param project [#root]
          # @return [Unsealed, Unasked]
          def self.for(arms:, project:) = arms.confine == :workspace ? new(project.root) : Unasked

          # @param root [String]
          def initialize(root)
            @root = root
          end

          # @return [Array<String>]
          def notices
            Confine::Profile.seals(root: @root, tmpdir: Dir.tmpdir)
            []
          rescue Confine::Profile::Unsealable => e
            [format(NOTICE, link: e.link)]
          end
        end

        # @param chronicle [#observe, #durable_journal] registers each observer on every journal the chat
        #   writes, and takes the reason a lineage could not be read
        # @param paths [Paths] resolves the sessions directory a resume chains through
        # @param project [Project] the chat's own, whose directories hold the sessions
        # @param resumed [Resume::Result, nil] nil for a fresh chat
        # @param arms [Arms] under `tripwire: :observe` or `:stop` a {Tripwire::Ledger} folds the journal too,
        #   and under `:stop` it trips the {Tripwire::Stops} the observers hold
        # @return [Observers]
        def self.register(chronicle:, paths:, project:, resumed:, arms:)
          stops = Tripwire::Stops.new if arms.tripwire == :stop
          new(fresh: lineage_fresh(paths, project, resumed, chronicle.durable_journal),
              unsealed: Unsealed.for(arms:, project:), stops: stops || Tripwire::Stops::None).tap do |observers|
            observers.register(chronicle)
            chronicle.observe(Tripwire::Ledger.new(journal: chronicle.durable_journal, stops:)) unless
              arms.tripwire == :off
          end
        end

        # A chain that cannot be walked is one whose writes are unknown.
        def self.lineage_fresh(paths, project, resumed, faults)
          return Shell::Executable::Fresh.for_lineage([], faults:) if resumed.nil?

          dirs = paths.session_dirs(project)
          chain = Resume::ChainWalk.new(paths:, dirs:).paths(Paths.session_file(resumed.file, dirs:))
          Shell::Executable::Fresh.for_lineage(chain, faults:)
        rescue Resume::Refusal, SystemCallError => e
          Shell::Executable::Fresh.unknown(e, faults:)
        end

        private_class_method :lineage_fresh

        # @return [Shell::Executable::Fresh] which files changed during this lineage
        attr_reader :fresh

        # @return [Tripwire::Stops, Tripwire::Stops::None] who the tripwire has stopped
        attr_reader :stops

        # @param fresh [Shell::Executable::Fresh]
        # @param unconfined [Unconfined] hears the sandbox degrade while the toolset is built
        # @param unsealed [#notices] whether the project can run a workspace call
        # @param stops [Tripwire::Stops, Tripwire::Stops::None]
        def initialize(fresh:, unconfined: Unconfined.new, unsealed: Unsealed::Unasked, stops: Tripwire::Stops::None)
          @fresh = fresh
          @unconfined = unconfined
          @unsealed = unsealed
          @stops = stops
        end

        # What the human should be told about the lineage and the sandbox, said once at startup. A sandbox
        # that was never built refuses nothing, so the seal is asked about only when bash is confined.
        #
        # @return [Array<String>]
        def notices
          unconfined = @unconfined.notices
          [*(DEGRADED_NOTICE if @fresh.degraded?), *unconfined, *(@unsealed.notices if unconfined.empty?)]
        end

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
