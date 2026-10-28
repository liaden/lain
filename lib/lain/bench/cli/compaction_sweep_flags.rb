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
        # @param live [String, nil] the model to send every arm to, which spends money
        # @param sending [Hash] under `live`, the `live_backend:` it sends through, the `confirm:` asked
        #   before it does, and the `provider:` that builds its provider over a journal
        def initialize(arms: CompactionSweep::DEFAULT_ARMS.join(","), placements: "framed",
                       price_as: CompactionSweep::DEFAULT_PRICE_AS, summarizer: "recorded",
                       budget: CompactionSweep::DEFAULT_BUDGET, planted: nil, backend: nil, journal: nil,
                       recorded: nil, state: Paths.new, live: nil, **sending)
          @live = live && Sending.new(model: live, summarizer:, **sending)
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
          return sweep(paths, fixtures).report unless @local || @live

          file = @journal || default_journal
          "#{asked(file) { |sink| journaled(paths, fixtures, sink) }}\njournal: #{file}"
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

        def journaled(paths, fixtures, sink)
          sweep = @local ? sweep(paths, fixtures, summarizer: tier(sink), journal: sink) : sweep(paths, fixtures)
          @live ? @live.run(sweep, sink) : sweep.report
        end

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
          Journals.stamped(@state, "compaction-sweep", ext: ".ndjson")
        end

        # `--live`: the backend whose provider, price-tier guard included, sends every arm. The
        # preflight renders every lane before anyone confirms a price, and a summarizer is asked while
        # it does, so only recorded answers are taken: even a loopback ollama bills through a cloud tag.
        class Sending
          KEYLESS = "bench compaction-sweep --live sends every arm to the real API and spends money; " \
                    "set ANTHROPIC_API_KEY to run it"
          SUMMARIZED = "--live takes only --summarizer recorded, since a summarizer is asked before the price is " \
                       "confirmed: record its answers offline with --summarizer local --journal FILE, then replay " \
                       "them live with --recorded FILE"

          def initialize(model:, summarizer:, live_backend: nil, confirm: nil, provider: nil)
            refuse_billing_summarizer!(summarizer)
            raise Refusal, "--live needs an Anthropic backend to send through" if live_backend.nil? || provider.nil?
            raise Refusal, "--live needs a confirmation to ask before it spends" if confirm.nil?

            @model = model
            @backend = live_backend
            @confirm = confirm
            @provider = provider
          end

          def run(sweep, sink)
            CompactionSweep::Live.new(sweep:, provider: sent_through(sink), confirm: @confirm, model: @model,
                                      hold: @backend.price_tier_hold, journal: sink).run
          end

          private

          def refuse_billing_summarizer!(summarizer)
            raise Refusal, SUMMARIZED unless summarizer == "recorded"
          end

          def sent_through(sink)
            @provider.call(@backend, sink)
          rescue CLI::MissingAPIKey
            raise CLI::MissingAPIKey, KEYLESS
          end
        end
        private_constant :Sending
      end
    end
  end
end
