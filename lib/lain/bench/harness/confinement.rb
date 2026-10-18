# frozen_string_literal: true

module Lain
  module Bench
    module Harness
      # What `--confine reader` gives a bench run: the sandbox under each agent's bash, and the read-only
      # rung ahead of the guard's approve-all gate that makes a read-only command earn the reader profile.
      # Both are built as a chat builds them, from the same classes, and the parts that do not depend on
      # the agent (the probe, the mask list, the classifiers) are built once for the whole run.
      class Confinement
        LACKING = "the box lacks %<layers>s"

        # Serialises the one mask list the run's agents share.
        class Shared
          def initialize(masks)
            @masks = masks
            @lock = Mutex.new
          end

          def masks = @lock.synchronize { @masks.masks }

          def prime
            @masks.prime
            self
          end
        end
        private_constant :Shared

        # Passes on each distinct record once, so a note every agent would repeat is made once per run.
        class Once
          def initialize(sink)
            @sink = sink
            @seen = []
            @lock = Mutex.new
          end

          def <<(record)
            @lock.synchronize { @seen.include?(record) ? self : (@seen << record) && (@sink << record) }
            self
          end
        end
        private_constant :Once

        # What a run with `--confine off` is given: its tools and its guard as they always were, and no
        # field in the report.
        module Off
          def self.apply(spawn_options) = spawn_options
          def self.state = nil
        end

        # @param project [Lain::Project] whose root the sandbox falls back to and the classifiers anchor on
        # @param paths [Lain::Paths] the state home
        # @param journal [#<<] the run's journal, where the box's own degraded records land
        # @param probe [#call] `call(journal:, fence:) -> Confine::Probe`
        # @raise [Lain::Config::Refusal] when the project's sensitivity table is malformed
        def initialize(project:, paths:, journal:, probe: PROBE)
          @project = project
          @paths = paths
          @fence = Confine::Bwrap.fence_binary
          @notes = Once.new(journal)
          @probe = probe.call(journal:, fence: @fence)
          @lacking = Confine::Sandbox.lacking(@probe)
          @masks = Shared.new(Confine::MaskList.new(root: project.root, policy: -> { policy }))
          @resolver = Shell::Executable::Resolver.new(root: project.root, fresh: Shell::Executable::Fresh.for_lineage([]))
          @classifiers = board.classifiers(project:, paths:, table: board.rules(project:, paths:), resolver: @resolver)
          @ruling_tools = TOOLS.call(recorder: Memory::Recorder.new, resolver: @resolver)
        end

        # @param spawn_options [Hash] what {SpawnSeam} is built with
        # @return [Hash] the same, with its tools' bash over the sandbox and its guard gated by the read-only rung
        # @raise [ArgumentError] when the caller brought a guard of its own, which this would replace
        def apply(spawn_options)
          raise ArgumentError, "--confine builds the arms' guard; an injected instrumentation would be lost" if
            spawn_options.key?(:instrumentation)

          spawn_options.merge(tools: tools(spawn_options.fetch(:tools, TOOLS)), instrumentation:)
        end

        # @param factory [#call] `call(recorder:, journal:, exec:, resolver:) -> Toolset`
        # @return [#call] `call(recorder:, journal:) -> Toolset`, bash over the sandbox
        def tools(factory)
          lambda { |recorder:, journal:|
            exec = sandbox(journal).wrap(Exec::Local.new, requirer: Harness.name)
            factory.call(recorder:, journal:, exec:, resolver: @resolver)
          }
        end

        # @return [#call] `call(journal:, recorder:, worker_env:) -> Agent::Instrumentation` whose gate lets a
        #   read-only command through to the reader profile and approves the rest
        def instrumentation
          lambda { |journal:, recorder:, worker_env:|
            guard = ::Lain::CLI::ToolGuard.detached(journal:, policy_for: ladder_for(journal))
            INSTRUMENTATION.call(journal:, recorder:, worker_env:, guard:)
          }
        end

        # @return [String] what the report says the arm is, naming what the box lacks when it lacks anything
        def state
          return "reader" if @lacking.empty?

          "reader (degraded: #{format(LACKING, layers: @lacking.join(" and "))})"
        end

        private

        def board = ::Lain::CLI::Wiring::BoardBuild

        def policy
          @policy ||= board.policy(project: @project, paths: @paths,
                                   table: board.rules(project: @project, paths: @paths))
        end

        def sandbox(journal)
          Confine::Sandbox.new(root: @project.root, home: @paths.home, masks: @masks, probe: @probe, fence: @fence,
                               journal:, notes: @notes)
        end

        # `bypass` approves what the read-only rung and the rules leave open, as the guard's own gate did.
        def ladder_for(journal)
          lambda { |worker_env|
            rules = board.approving([], @classifiers.for(worker_env), classes: true)
            Approval::Escalation.bypass(tools: @ruling_tools, journal:, rules:)
          }
        end
      end
    end
  end
end
