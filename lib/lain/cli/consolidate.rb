# frozen_string_literal: true

module Lain
  module CLI
    # `lain consolidate <session> [--dry-run]`: resolves a session identifier
    # through {CLI::SessionFile} -- the same three resolutions `lain friction`
    # and `lain improve` accept, and NOT `lain chat --resume`'s, which is a
    # different contract (see {CLI::SessionFile}) -- and runs the
    # {Lain::Consolidation} court-clerk pass over it. Returns a String; only the
    # frontend prints (output discipline, {CLI::Friction}'s precedent).
    #
    # == Two methods, not one boolean
    #
    # {#report} runs the pass; {#dry_report} names the lineages that WOULD be
    # clerked. They are separate because `report_for(dry_run: true)` was a flag
    # that changed what the method MEANT -- different work, different sentence,
    # one signature covering both. The exe's `--dry-run` picks the method, and
    # the boolean stops at the flag it came from.
    class Consolidate
      # The exe's assembly seam: build the pass from Thor options via {Backend}.
      # Under `--dry-run` the provider is {Provider::Unreachable} instead of
      # {Backend#provider}, so no API key is fetched and nothing can quietly
      # reach a model -- which is what lets {Lain::Consolidation} require every
      # collaborator, since "no model here" is now a thing this wiring SAYS.
      def self.from_options(options)
        backend = Backend.new(options)
        new(consolidation: Lain::Consolidation.new(
          provider: options[:dry_run] ? Provider::Unreachable.new : backend.provider,
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

      # Run one court_clerk pass per completed subagent lineage.
      #
      # @param selector [String] an explicit path, a bare filename, or a
      #   filename missing its ".ndjson" suffix
      # @return [String]
      # @raise [SessionFile::SessionNotFound]
      def report(selector)
        outcomes = @consolidation.call(entries(selector))
        return "consolidate: no completed subagent lineages found." if outcomes.empty?

        ["consolidate: ran a court_clerk pass over #{outcomes.size} lineage(s)",
         *outcomes.map { |outcome| "  - lineage #{outcome.root}: #{outcome.result}" }].join("\n")
      end

      # Which lineages the pass WOULD clerk, spawning nothing.
      #
      # @return [String]
      # @raise [SessionFile::SessionNotFound]
      def dry_report(selector) = @consolidation.dry_run(entries(selector))

      private

      def entries(selector) = Journal.records(File.foreach(SessionFile.resolve(selector, paths: @paths)))
    end
  end
end
