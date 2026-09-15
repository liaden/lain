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
      # The exe's assembly seam. The session is resolved ONCE, here, and every
      # later read -- the recorded profile, the lineages -- is of that file.
      #
      # The backend runs under what the human typed over what the session under
      # review recorded, as a resumed chat's does. A typed field the recording
      # disagrees with still wins, and {Resume::MismatchNotices} says so ahead
      # of the report.
      #
      # It is built only when {#report} runs. A dry run builds no {Backend},
      # so no provider, no ollama tier and no credential lookup: a session
      # recorded on ollama-cloud dry-runs on a box with no OLLAMA_API_KEY. The
      # provider's NAME is still checked, since that needs neither.
      #
      # @param options [Hash] the invoked command's parsed flags
      # @param selector [String] the session under review
      # @param profile [RunProfile] what the model flag band resolved
      # @param paths [Paths] resolves the session dir
      # @option options [String] :provider the model flag band's provider, which
      #   the profile was resolved from
      # @option options [String] :model the model flag band's model id
      # @return [Consolidate]
      # @raise [SessionFile::SessionNotFound] before anything else is read
      def self.from_options(options, selector:, profile: RunProfile.from_options(options), paths: Paths.new)
        path = SessionFile.resolve(selector, paths:)
        mismatches = Resume::MismatchNotices.new(path:)
        resolved = profile.over(mismatches.recorded_profile)
        Backend.validated(resolved.provider)
        new(path:, profile: resolved, notices: mismatches.call(profile: resolved, model: resolved.model),
            consolidation: -> { clerk_over(Backend.new(options, profile: resolved)) })
      end

      def self.clerk_over(backend)
        Lain::Consolidation.new(provider: backend.provider, recorder: Memory::Recorder.new,
                                context: backend.context, slots: backend.slots)
      end
      private_class_method :clerk_over

      # @param path [String] the session file under review, already resolved
      # @param profile [RunProfile] the backend the pass runs on, which a dry
      #   run names
      # @param consolidation [#call] answers the pre-wired {Lain::Consolidation};
      #   called by {#report} only
      # @param notices [Array<String>] said ahead of either report
      def initialize(path:, profile:, consolidation:, notices: [])
        @path = path
        @profile = profile
        @consolidation = consolidation
        @notices = notices
      end

      # Run one court_clerk pass per completed subagent lineage.
      #
      # @return [String]
      # @raise [Bench::Session::Corrupt] naming the file and its damage
      def report
        outcomes = @consolidation.call.call(lineages)
        return said("consolidate: no completed subagent lineages found.") if outcomes.empty?

        said(["consolidate: ran a court_clerk pass over #{outcomes.size} lineage(s)",
              *outcomes.map { |outcome| "  - lineage #{outcome.spawn}: #{outcome.result}" }].join("\n"))
      end

      # Which lineages the pass WOULD clerk, and on what, spawning nothing.
      #
      # @return [String]
      # @raise [Bench::Session::Corrupt] naming the file and its damage
      def dry_report
        said("consolidate: would run on #{@profile.provider}, model #{@profile.model || "the provider's default"}",
             Lain::Consolidation.dry_run(lineages))
      end

      private

      def said(*report) = [*@notices, *report].join("\n")

      # Read whole, so a damaged session refuses by name rather than reporting
      # the lineages its damage left readable.
      def lineages = Bench::Session::Lineages.read(@path)
    end
  end
end
