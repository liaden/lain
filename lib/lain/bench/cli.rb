# frozen_string_literal: true

require_relative "../agent"
require_relative "../context"
require_relative "../error"
require_relative "../journal"
require_relative "../middleware"
require_relative "../price_book"
require_relative "../provider/anthropic_raw"
require_relative "../toolset"
require_relative "session"
require_relative "variance"

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
      # @param provider [Lain::Provider, nil] injected in specs; nil builds the
      #   real {Provider::AnthropicRaw}, which is key-gated
      # @return [Array<String>] the written session paths, in run order
      def record(taskfile:, out:, runs: RECORD_DEFAULTS.fetch(:runs),
                 model: RECORD_DEFAULTS.fetch(:model), max_tokens: RECORD_DEFAULTS.fetch(:max_tokens),
                 system: nil, provider: nil)
        runs = check_runs(runs)
        prompts = prompts_from(taskfile)
        provider ||= build_provider
        context = Context.new(model: model, max_tokens: max_tokens, system: system)
        (1..runs).map { |index| record_run(provider, context, prompts, File.join(out, "#{index}.ndjson")) }
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
        Variance.new(recordings: recordings, price_book: price_book)
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

      def build_provider
        if ENV["ANTHROPIC_API_KEY"].to_s.empty?
          raise MissingAPIKey, "bench record calls the real API and spends money; set ANTHROPIC_API_KEY to run it"
        end

        Provider::AnthropicRaw.new
      end

      # One run, one journal, one file (Session's format contract), with
      # JournalRequests INNERMOST so the baseline is the bytes the provider
      # actually received. An occupied path REFUSES rather than replaces:
      # Journal.open appends, a second header in one file would destroy both
      # sweeps' loadability, and the existing bytes cost real money.
      def record_run(provider, context, prompts, path)
        raise Refusal, "#{path} already exists; refusing to overwrite a recorded session" if
          File.exist?(path)

        journal = Journal.open(path)
        begin
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
        Session.write(journal, timeline: agent.timeline, context: context, toolset: agent.toolset)
      end

      def build_agent(provider, context, journal)
        Agent.new(provider: provider, toolset: Toolset.new([]), context: context, journal: journal,
                  model_middleware: Middleware::Stack.new([Middleware::JournalRequests.new(journal: journal)]))
      end
    end
  end
end
