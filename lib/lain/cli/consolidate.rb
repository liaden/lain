# frozen_string_literal: true

module Lain
  module CLI
    # `lain consolidate <session> [--dry-run]`: resolves a session identifier
    # the same way {CLI::Friction} and `lain chat --resume` do -- an explicit
    # path, or a bare filename under this project's session dir -- and runs the
    # {Lain::Consolidation} court-clerk pass over it. `--dry-run` reports which
    # lineages WOULD be clerked without touching the provider. Returns a String;
    # only the frontend prints (output discipline, {CLI::Friction}'s precedent).
    class Consolidate
      # No file on disk answers to the given selector, under any resolution.
      class SessionNotFound < Error; end

      # The exe's assembly seam: build the pass from Thor options via {Backend}.
      # Only `provider` reaches the network, and under --dry-run it is skipped
      # entirely, so a dry pass needs no API key -- a live run without one
      # fails loudly at Consolidation's own MissingCollaborator, never silently.
      def self.from_options(options)
        backend = Backend.new(options)
        new(consolidation: Lain::Consolidation.new(
          provider: (backend.provider unless options[:dry_run]),
          recorder: Memory::Recorder.new,
          context: backend.context, slots: backend.slots
        ))
      end

      # @param consolidation [Lain::Consolidation] the pre-wired pass (provider,
      #   recorder, slots, context); {.from_options} assembles it, an instance
      #   only resolves the session file and renders the outcome
      # @param paths [Paths] resolves the session dir; injectable for specs
      def initialize(consolidation:, paths: Paths.new)
        @consolidation = consolidation
        @paths = paths
      end

      # @param selector [String] an explicit path, a bare filename, or a
      #   filename missing its ".ndjson" suffix
      # @param dry_run [Boolean] report what would run instead of running it
      # @return [String]
      # @raise [SessionNotFound]
      def report_for(selector, dry_run: false)
        entries = Journal.records(File.foreach(resolve(selector)))
        dry_run ? @consolidation.dry_run(entries) : render_run(entries)
      end

      private

      def render_run(entries)
        outcomes = @consolidation.call(entries)
        return "consolidate: no completed subagent lineages found." if outcomes.empty?

        ["consolidate: ran a court_clerk pass over #{outcomes.size} lineage(s)",
         *outcomes.map { |outcome| "  - lineage #{outcome.root}: #{outcome.result}" }].join("\n")
      end

      def dir = @dir ||= @paths.sessions_dir

      def resolve(selector)
        candidates = [selector, File.join(dir, selector), File.join(dir, "#{selector}.ndjson")]
        candidates.find { |path| File.file?(path) } ||
          raise(SessionNotFound, "no session found for #{selector.inspect} -- looked at #{candidates.join(", ")}")
      end
    end
  end
end
