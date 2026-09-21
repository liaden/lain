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
    # == What the pass leaves behind
    #
    # Two durable things, both assembled HERE rather than in the domain class,
    # because both are questions about this machine rather than about clerking.
    #
    # The clerk writes into the project's ONE memory store, so what it distills
    # is what the NEXT chat in this project opens its view on. A pass whose
    # memories lived and died inside its own process distilled nothing.
    #
    # The pass journals into its own state container, {JOURNAL_KIND}, keyed by
    # project -- a sibling of `sessions` and `status`, never `sessions` itself:
    # a clerk pass is not a chat, and a reader listing this project's chats
    # must not find one among them. Its turn usage, its memory roots and every
    # refusal and mask its guards record land there, where the run was
    # previously answering them to a Null channel.
    #
    # == Two methods, not one boolean
    #
    # {#report} runs the pass; {#dry_report} renders the scaffolds the clerks
    # WOULD have seen, masking and all. They are separate because
    # `report_for(dry_run: true)` was a flag that changed what the method
    # MEANT -- different work, different sentence, one signature covering
    # both. The exe's `--dry-run` picks the method, and the boolean stops at
    # the flag it came from. A dry run opens no journal and touches no memory
    # store for the same reason it builds no provider.
    class Consolidate
      # The segment under `$XDG_STATE_HOME/lain` this pass's journals live in.
      JOURNAL_KIND = "consolidation"

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
      # @param project_dir [ProjectDir] keyed to the PROJECT's root rather than
      #   to `Dir.pwd`, {CLI::Wiring#project_memory}'s invariant: consolidating
      #   from a subdirectory must write into the memory of the project it is
      #   in. It locates the memory store and this pass's own journal.
      # @option options [String] :provider the model flag band's provider, which
      #   the profile was resolved from
      # @option options [String] :model the model flag band's model id
      # @return [Consolidate]
      # @raise [SessionFile::SessionNotFound] before anything else is read
      def self.from_options(options, selector:, profile: RunProfile.from_options(options), paths: Paths.new,
                            project_dir: ProjectDir.new(root: Project::Resolver.default_project.root, paths:))
        path = SessionFile.resolve(selector, paths:)
        mismatches = Resume::MismatchNotices.new(path:)
        resolved = profile.over(mismatches.recorded_profile)
        Backend.validated(resolved.provider)
        new(path:, profile: resolved, project_dir:,
            notices: mismatches.call(profile: resolved, model: resolved.model),
            consolidation: lambda { |journal|
              backend = Backend.new(options, profile: resolved, root: project_dir.root)
              clerk_over(backend, journal, project_dir)
            })
      end

      def self.clerk_over(backend, journal, project_dir)
        Lain::Consolidation.new(provider: backend.provider, journal:,
                                recorder: Memory::ProjectStore.new(project_dir:).view,
                                context: backend.context, slots: backend.slots)
      end
      private_class_method :clerk_over

      # @param path [String] the session file under review, already resolved
      # @param profile [RunProfile] the backend the pass runs on, which a dry
      #   run names
      # @param project_dir [ProjectDir] where this pass's journal lands;
      #   REQUIRED, so a caller that forgot it is a loud ArgumentError here
      #   rather than a record written into whatever project this process
      #   happens to sit in
      # @param consolidation [#call] handed the pass's journal, answers the
      #   pre-wired {Lain::Consolidation}; called by {#report} only
      # @param notices [Array<String>] said ahead of either report
      def initialize(path:, profile:, project_dir:, consolidation:, notices: [])
        @path = path
        @profile = profile
        @project_dir = project_dir
        @consolidation = consolidation
        @notices = notices
      end

      # Run one court_clerk pass per completed subagent lineage.
      #
      # @return [String]
      # @raise [Bench::Session::Corrupt] naming the file and its damage
      def report
        journaled { |journal| said(rendered(@consolidation.call(journal).call(lineages))) }
      end

      # What the pass WOULD send, and on what, spawning nothing: the scaffolds
      # themselves, so a human reads the prompt rather than a promise of one.
      #
      # @return [String]
      # @raise [Bench::Session::Corrupt] naming the file and its damage
      def dry_report
        said("consolidate: would run on #{@profile.provider}, model #{@profile.model || "the provider's default"}",
             Lain::Consolidation.dry_run(lineages))
      end

      private

      # A Journal that created its file and wrote no record removes it on
      # close, so a pass that clerked nothing leaves the container empty
      # rather than littered with zero-byte files.
      def journaled(&block) = Journal.open(File.join(@project_dir.container(JOURNAL_KIND), Journal.stem), &block)

      def rendered(outcomes)
        return "consolidate: no completed subagent lineages found." if outcomes.empty?

        [summary(outcomes), *outcomes.map { |outcome| "  - lineage #{outcome.spawn}: #{outcome.result}" }].join("\n")
      end

      # A pass that clerked lineages and a pass that clerked lineages AND wrote
      # memories are different outcomes, and the words must say so: `outcomes`
      # not being empty only means the clerks ran, never that the store moved.
      def summary(outcomes)
        return "consolidate: ran a court_clerk pass over #{outcomes.size} lineage(s) and stored nothing" \
          unless outcomes.any?(&:wrote)

        "consolidate: ran a court_clerk pass over #{outcomes.size} lineage(s), writing memories"
      end

      def said(*report) = [*@notices, *report].join("\n")

      # Read whole, so a damaged session refuses by name rather than reporting
      # the lineages its damage left readable.
      def lineages = Bench::Session::Lineages.read(@path)
    end
  end
end
