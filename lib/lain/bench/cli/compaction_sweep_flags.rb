# frozen_string_literal: true

module Lain
  module Bench
    class CLI
      # `bench compaction-sweep`'s flags turned into a {CompactionSweep}. {CLI} checks the session
      # files; this refuses everything else the user typed, and owns the journal a local summarizer
      # writes its answers into.
      class CompactionSweepFlags
        SUMMARIZERS = %w[recorded local].freeze

        # @param arms [String] comma-separated names from {CompactionSweep::DEFAULT_ARMS}
        # @param placements [String] comma-separated, framed or bare
        # @param price_as [String] the model each simulated cache write is priced as
        # @param summarizer [String] "recorded" (journaled answers only) or "local" (asks the backend)
        # @param budget [Integer] head bytes that fire a cut
        # @param planted [String, nil] a directory {PlantedClaims.generate} wrote; its sessions are swept too
        # @param backend [Lain::CLI::Backend, nil] the summarizer's provider, for a local run
        # @param journal [String, nil] where a local run writes its answers, for `recorded` to replay;
        #   a timestamped file under the state home's `bench` directory by default
        # @param recorded [String, nil] comma-separated journals whose answers the recorded summarizer
        #   also replays, such as a local run's `journal`
        # @param state [Lain::Paths] the state home the default journal lives under
        def initialize(arms: CompactionSweep::DEFAULT_ARMS.join(","), placements: "framed",
                       price_as: CompactionSweep::DEFAULT_PRICE_AS, summarizer: "recorded",
                       budget: CompactionSweep::DEFAULT_BUDGET, planted: nil, backend: nil, journal: nil,
                       recorded: nil, state: Paths.new)
          @options = { arms: listed(arms, "arm", CompactionSweep::DEFAULT_ARMS),
                       placements: listed(placements, "placement", Compaction::Recap::PLACEMENTS),
                       price_as:, budget: whole_bytes(budget), recorded: recordings(recorded) }
          @local = local?(summarizer, backend, @options[:recorded])
          @backend = backend
          @planted = planted && PlantedClaims.in(existing_dir(planted))
          @journal = journal
          @state = state
        end

        # @param journals [Array<String>] session files the caller has checked exist
        # @return [String] the report; a local run's ends with its journal's path
        # @raise [Refusal] when there is nothing to sweep
        def report(journals)
          fixtures = @planted || []
          paths = journals + fixtures.map(&:path)
          raise Refusal, "no journals to sweep; name session files or a --planted DIR" if paths.empty?
          return sweep(paths, fixtures).report unless @local

          file = @journal || default_journal
          "#{asked(file) { |sink| sweep(paths, fixtures, summarizer: tier(sink), journal: sink).report }}\n" \
            "journal: #{file}"
        end

        private

        # A failed run says where its partial answers are, so they are not lost with the error.
        def asked(file)
          Journal.open(file, paths: @state) { |sink| Sync { yield sink } }
        rescue Error => e
          kept = File.exist?(file) ? "journal: #{file}" : "no journal was written"
          raise e.exception("#{e.message} (#{kept})")
        end

        def sweep(paths, fixtures, **) = CompactionSweep.new(journals: paths, planted: fixtures, **@options, **)

        def listed(names, what, valid)
          listed = names.to_s.split(",").map(&:strip).reject(&:empty?).uniq
          raise Refusal, "no #{what} named; the #{what}s are #{valid.join(", ")}" if listed.empty?

          unknown = listed - valid
          return listed if unknown.empty?

          raise Refusal, "unknown #{what} #{unknown.first.inspect}; the #{what}s are #{valid.join(", ")}"
        end

        def local?(name, backend, recorded)
          raise Refusal, "--summarizer is recorded or local, not #{name.inspect}" unless SUMMARIZERS.include?(name)
          return false if name == "recorded"
          raise Refusal, "--recorded replays answers; drop it or use --summarizer recorded" unless recorded.empty?
          raise Refusal, "--summarizer local needs a model backend to ask" if backend.nil?

          true
        end

        def recordings(names)
          names.to_s.split(",").map(&:strip).reject(&:empty?).each do |path|
            raise Refusal, "no recording at #{path}" unless File.file?(path)
          end
        end

        def existing_dir(path)
          return path if File.directory?(path)

          raise Refusal, "no planted corpus at #{path}"
        end

        def whole_bytes(budget)
          bytes = Integer(budget, exception: false)
          return bytes if bytes&.positive? && bytes == budget

          raise Refusal, "--budget takes a positive whole number of bytes, got #{budget.inspect}"
        end

        # Built over the definition it is handed, with every round trip on the run's journal, as the
        # chat's span summarizer is.
        def tier(sink)
          lambda do |definition|
            provider = Provider::Journaled.new(provider: @backend.summarizer_provider, journal: sink,
                                               requester: :summarizer)
            Oracle::Model.new(definition:, provider:, model: @backend.summarizer_model,
                              max_tokens: @backend.summarizer_max_tokens, extra: @backend.summarizer_options)
          end
        end

        def default_journal
          stamp = Time.now.utc.strftime("%Y%m%dT%H%M%S")
          File.join(@state.state_home, "bench", "compaction-sweep-#{stamp}-#{Process.pid}.ndjson")
        end
      end
    end
  end
end
