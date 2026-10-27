# frozen_string_literal: true

module Lain
  module Bench
    class JudgeScale
      # Where each scale's verdicts come from: a directory of journals, one `<scale>.ndjson` of
      # {Telemetry::Verdict} records per scale, or a live judge that writes that same directory as it
      # goes. One file per scale because a verdict record is keyed by the finding alone, so two scales
      # judging one finding would otherwise share a queue.
      module Source
        # @param dir [String] a directory of `<scale>.ndjson` journals
        # @return [#call] scale => a {Grader::Refuter::Recorded}
        # @raise [CLI::Refusal] when a scale has no journal there, or its records name another scale
        def self.recorded(dir)
          lambda do |scale|
            file = File.join(dir, "#{scale}.ndjson")
            raise CLI::Refusal, "no recording for the #{scale} scale at #{file}" unless File.file?(file)

            lines = File.readlines(file)
            named = named_scales(lines).reject { _1 == scale.to_s }.first
            raise CLI::Refusal, "#{file} is read as the #{scale} scale but its records name the #{named} scale" if named

            Grader::Refuter::Recorded.from_journal(lines)
          end
        end

        # Yields a refuter factory whose judges journal every verdict under `dir`; the journals are
        # closed however the block ends. An existing journal for a requested scale is refused, since
        # appending would leave {.recorded} replaying the first run.
        #
        # @param provider [Lain::Provider]
        # @param model [String]
        # @param dir [String]
        # @param scales [Array<Symbol>] the scales this run will judge
        # @param state [Lain::Paths]
        # @yieldparam refuter_for [#call] scale => a live refuter
        # @return [Object] the block's value
        # @raise [CLI::Refusal] on an occupied journal, or a judge that fails partway (the journal is partial)
        def self.live(provider:, model:, dir:, scales:, state:)
          refuse_occupied!(dir, scales)
          journals = []
          factory = lambda do |scale|
            journal = Journal.open(File.join(dir, "#{scale}.ndjson"), paths: state).tap { journals << _1 }
            Journaling.new(Grader::Refuter.new(provider:, model:, scale:), journal, scale:, dir:)
          end
          yield factory
        ensure
          journals&.each(&:close)
        end

        def self.named_scales(lines)
          Journal.records(lines, type: "verdict").filter_map { _1["scale"] }.uniq
        end

        def self.refuse_occupied!(dir, scales)
          taken = scales.map { File.join(dir, "#{_1}.ndjson") }.select { File.exist?(_1) }
          return if taken.empty?

          raise CLI::Refusal, "#{taken.join(", ")} already exists; a live run appends, so --recorded would replay " \
                              "the first run. Use a new --journal directory"
        end

        private_class_method :named_scales, :refuse_occupied!

        # @param state [Lain::Paths]
        # @return [String] a timestamped directory under the state home's `bench` directory
        def self.default_dir(state)
          stamp = Time.now.utc.strftime("%Y%m%dT%H%M%S")
          File.join(state.state_home, "bench", "judge-scale-#{stamp}-#{Process.pid}")
        end

        # Records what the wrapped refuter decided, the way {Grader::Verified} does, and turns a failure
        # into a refusal that says the journal is partial and where it stopped.
        class Journaling
          SHOWN = 80

          def initialize(refuter, journal, scale:, dir:)
            @refuter = refuter
            @journal = journal
            @scale = scale
            @dir = dir
          end

          # @param finding [#to_s]
          # @return [Grader::Grade]
          # @raise [CLI::Refusal] when the judge or provider fails
          def refute(finding)
            grade = judged(finding)
            @journal << Telemetry::Verdict.new(digest: Canonical.digest(finding.to_s), survived: grade.pass?,
                                               score: grade.score, why: grade.why, scale: @scale)
            grade
          end

          private

          def judged(finding)
            @refuter.refute(finding)
          rescue StandardError => e
            raise CLI::Refusal, "the journal in #{@dir} is partial: stopped on the #{@scale} scale at finding " \
                                "#{finding.to_s[0, SHOWN].inspect} (#{e.class}: #{e.message})"
          end
        end
      end
    end
  end
end
