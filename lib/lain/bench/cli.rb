# frozen_string_literal: true

module Lain
  module Bench
    # All of `exe/lain bench`'s assembly, behind returned values: the exe
    # parses flags, calls these methods, and `say`s the Strings -- nothing
    # here prints (output discipline). Every refused input is a {Lain::Error}
    # -- {Refusal} with the path context only this layer still holds,
    # {Session::Corrupt} on a bad file, {MissingAPIKey} from the key gate --
    # so the exe rescues Lain::Error ALONE (message, nonzero exit, no
    # backtrace) and a programmer bug's ArgumentError stays a loud crash.
    class CLI
      # The user's own input turned away: a missing file, a directory with no
      # sessions, a zero or fractional run count, an occupied output path, a
      # set of recordings {Variance} cannot compare.
      class Refusal < Error; end

      # `bench record` spends real money by construction; refusing keyless up
      # front beats a transport error n prompts in.
      class MissingAPIKey < Error; end

      # One source for the record defaults: {#record}'s keyword defaults and
      # exe/lain's method_options both read from here, so the flag help and
      # the library behavior cannot drift.
      RECORD_DEFAULTS = {
        runs: 2, model: Provider::AnthropicRaw::DEFAULT_MODEL, max_tokens: 1024
      }.freeze

      # The three-section {Variance} report over recorded session files.
      #
      # @param sources [Array<String>] paths; a directory means every
      #   `*.ndjson` under it, in sorted filename order
      # @param price_book [Lain::PriceBook]
      # @return [String] never printed here
      # @raise [Refusal] on a missing or empty source, a recording that cannot
      #   replay, or fewer than two recordings
      def variance_report(sources, price_book: PriceBook.default)
        paths = session_paths(sources)
        recordings = paths.map { |path| load_session(path) }
        build_variance(recordings, paths, price_book).report
      end

      # Record `runs` fresh live sessions of one task file (user prompts, one
      # per line, blank lines skipped) into `out/<i>.ndjson`, each a full
      # Session a later {#variance_report} can load.
      #
      # Tools are deliberately absent: the synthetic echo tasks this records
      # need none, and an empty Toolset keeps the recorded schema trivial.
      # Tool-bearing task files are future work.
      #
      # Provider and Context resolve through the SAME {Lain::CLI::Backend} the
      # chat path uses, so `--provider`/`--temperature`/`--seed` mean one thing
      # across commands and an unknown provider name raises the one
      # {Lain::CLI::UnknownProvider} from either. `model` defaults to the selected
      # provider's own default (nil here, resolved in Backend); the sampler flags
      # ride the Context into Request#extra, and the recorded HEADER carries them.
      #
      # `provider_name` is the `--provider` FLAG; `provider` is the injected
      # Provider OBJECT the specs pass (nil resolves the real, money-gated
      # recording client). Two distinct seams: a name to resolve, and an object
      # to stub.
      #
      # @param provider [Lain::Provider, nil] injected in specs; nil resolves the
      #   real recording provider (AnthropicRaw is key-gated; ollama/bedrock come
      #   from {Lain::CLI::Backend})
      # @return [Array<String>] the written session paths, in run order
      def record(taskfile:, out:, runs: RECORD_DEFAULTS.fetch(:runs),
                 model: nil, max_tokens: RECORD_DEFAULTS.fetch(:max_tokens),
                 system: nil, provider_name: "anthropic", api_base: nil,
                 temperature: nil, seed: nil, provider: nil)
        runs = check_runs(runs)
        prompts = prompts_from(taskfile)
        backend = Lain::CLI::Backend.new(provider: provider_name, api_base:, model:,
                                         max_tokens:, temperature:, seed:)
        provider ||= resolve_provider(backend, provider_name)
        context = backend.context(system_override: system)
        # PS-2 must attribute what ACTUALLY rendered: `--system` renders
        # instead of the slots, and SlotFills.from owns that distinction.
        attribution = Telemetry::SlotFills.from(backend.slots, override: system)
        (1..runs).map do |index|
          record_run(provider, context, attribution, prompts, File.join(out, "#{index}.ndjson"))
        end
      end

      private

      def session_paths(sources)
        Array(sources).flat_map do |source|
          File.directory?(source) ? directory_sessions(source) : [checked_path(source)]
        end
      end

      # Dir.children, not Dir.glob: a directory name carrying glob
      # metacharacters ("run[1]") must not be parsed as a pattern. Sorted, so
      # the report's 1..n ordinals stay deterministic. An empty directory is
      # its own refusal -- falling through to Variance's "at least two" would
      # hide the typo'd path.
      def directory_sessions(dir)
        names = Dir.children(dir).select { |name| name.end_with?(".ndjson") }.sort
        raise Refusal, "no *.ndjson session files under #{dir}" if names.empty?

        names.map { |name| File.join(dir, name) }
      end

      def checked_path(source)
        raise Refusal, "no session file at #{source}" unless File.file?(source)

        source
      end

      # Corrupt's own message names a digest, but only this layer still holds
      # the path -- and an experimenter with a directory of n sessions needs
      # to know WHICH file to regenerate.
      def load_session(path)
        replayable(Session.load(path), path)
      rescue Session::Corrupt => e
        raise Session::Corrupt, "#{path}: #{e.message}"
      end

      # DryReplay's 1:1 guard (an orphan request_sent) otherwise fires while
      # Variance constructs, after the paths are gone; probing here converts
      # it to a Refusal naming the ONE file to regenerate.
      def replayable(recording, path)
        recording.dry_replay
        recording
      rescue ArgumentError => e
        raise Refusal, "#{path}: #{e.message}"
      end

      # Variance's construction-time guards (n>=2) speak in recordings; the
      # experimenter typed paths, so restore them to the message.
      def build_variance(recordings, paths, price_book)
        Variance.new(recordings:, price_book:)
      rescue ArgumentError => e
        raise Refusal, "#{paths.join(", ")}: #{e.message}"
      end

      # This command spends money per run: a sweep of zero must not read as
      # instant success, and a fractional count must refuse rather than
      # truncate (Integer(2.5) quietly books 2). Integer(runs.to_s) accepts
      # only whole numbers, whatever type the flag parser produced.
      def check_runs(runs)
        count = Integer(runs.to_s, exception: false)
        raise Refusal, "the run count must be a whole number, got #{runs}" if count.nil?
        raise Refusal, "record needs at least one run; a sweep of #{count} records nothing" if count < 1

        count
      end

      def prompts_from(taskfile)
        raise Refusal, "no task file at #{taskfile}" unless File.file?(taskfile)

        prompts = File.readlines(taskfile, chomp: true).map(&:strip).reject(&:empty?)
        raise Refusal, "task file #{taskfile} holds no prompts" if prompts.empty?

        prompts
      end

      # The recording provider for a KNOWN name. ollama and bedrock come from the
      # SAME {Lain::CLI::Backend} chat uses; an unknown name never reaches here as
      # `anthropic`, so it falls to {Lain::CLI::Backend#provider}, whose own guard
      # raises {Lain::CLI::UnknownProvider} -- one error, both paths. The default
      # `anthropic` arm is the RAW client (lossless HTTP recording) behind the
      # money gate: refusing keyless up front beats a transport error n prompts in.
      def resolve_provider(backend, provider_name)
        return backend.provider unless provider_name == "anthropic"

        raise MissingAPIKey, "bench record calls the real API and spends money; set ANTHROPIC_API_KEY to run it" \
          if ENV["ANTHROPIC_API_KEY"].to_s.empty?

        Provider::AnthropicRaw.new
      end

      # One run, one journal, one file (Session's format contract), with
      # JournalRequests INNERMOST so the baseline is the bytes the provider
      # actually received. An occupied path REFUSES rather than replaces:
      # Journal.open appends, a second header in one file would destroy both
      # sweeps' loadability, and the existing bytes cost real money.
      def record_run(provider, context, attribution, prompts, path)
        raise Refusal, "#{path} already exists; refusing to overwrite a recorded session" if
          File.exist?(path)

        journal = Journal.open(path)
        begin
          # One slot_fills record per session, at session start (Loader reads
          # by record TYPE, not file position, so leading with it reorders
          # nothing downstream).
          journal << attribution
          run_and_write(provider, context, prompts, journal)
        ensure
          journal.close
        end
        path
      end

      # A fresh Agent per run, so no Timeline state leaks between samples.
      def run_and_write(provider, context, prompts, journal)
        agent = build_agent(provider, context, journal)
        prompts.each { |prompt| agent.ask(prompt) }
        Session.write(journal, timeline: agent.timeline, context:, toolset: agent.toolset)
      end

      # The memory stack the chunk built, wired even though these synthetic
      # tasks carry no memory_write tool yet: a Recorder holds the live root,
      # JournalMemoryRoot pairs each turn's digest with the root in force when
      # it rendered (so a later run's recall replays against the exact
      # snapshot), and RefuseSecretWrites guards the write seam. The raw
      # `journal` -- not the wrapped one -- backs JournalRequests and
      # WriteRefused, so those land unpaired; JournalMemoryRoot only decorates
      # the Agent's own turn_usage stream.
      def build_agent(provider, context, journal)
        recorder = Memory::Recorder.new
        Agent.new(provider:, toolset: Toolset.new([]), context:,
                  journal: Memory::JournalMemoryRoot.new(journal:, recorder:),
                  model_middleware: Middleware::Stack.new([Middleware::JournalRequests.new(journal:)]),
                  tool_middleware: Middleware::Stack.new([Middleware::RefuseSecretWrites.new(journal:)]))
      end
    end
  end
end
