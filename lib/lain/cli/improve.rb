# frozen_string_literal: true

module Lain
  module CLI
    # `lain improve <session> [--dry-run]`: the harness-improver pass. It
    # resolves a session file through {CLI::SessionFile} -- the one resolver
    # {CLI::Friction} and {CLI::Consolidate} also read through, so all three
    # accept the same shorthands and raise the same refusal -- renders that
    # session's {Friction::Report} plus a per-turn digest summary into the
    # `harness_improver` role scaffold, and spawns the role ONCE. The notes
    # land in the cross-project {Improvement::Sink}, NOT in user-facing memory.
    # Returns a String; only the frontend prints.
    #
    # == Distinct from {CLI::Friction} by AUDIENCE
    #
    # {Friction::Report} tells the USER which existing knob to turn; this pass
    # tells the lain DEV what lain should GROW -- a knob that was missing, a
    # tool that fought the model, a doc that lied. Same mechanical signals feed
    # both, framed for a different reader by the role persona.
    #
    # == The guard is self-built
    #
    # The improver is built here rather than spawned, and no chat lends it a
    # guard, so it runs the stack a detached run builds for itself
    # ({ToolGuard.detached}): an `improvement_write` whose input looked like a
    # credential is refused before the durable, cross-project sink, and a
    # credential region in a file it reads stays masked, since nobody is there
    # to release it. A refusal is contained: the improver's loop continues on
    # the error result.
    #
    # == Fresh-root
    #
    # The improver READS the session's record; it must never INHERIT the
    # parent's prompt, so it spawns over a FRESH Timeline root
    # ({Role#spawn_policy}'s default `:fresh` prefix).
    #
    # == What the pass leaves behind
    #
    # The notes, and a journal of its own under {JOURNAL_KIND}, keyed by
    # project -- a sibling of `sessions`, never `sessions` itself: an improver
    # pass is not a chat, and a reader listing this project's chats must not
    # find one among them. {CLI::Consolidate} journals the same way, for the
    # same reason.
    #
    # == Two methods, not one boolean
    #
    # {#report} spawns the improver; {#dry_report} renders the scaffold it
    # WOULD have seen. Separate methods, because `report_for(dry_run: true)`
    # was a flag that changed what the method MEANT. Both read the session
    # ONCE, through the same private {Review}. A dry run opens no journal for
    # the same reason it builds no backend.
    class Improve
      # The role every session is handed to: read_file/list_files/glob/grep/
      # improvement_write, and no memory tools, by design.
      ROLE = :harness_improver

      # The segment under `$XDG_STATE_HOME/lain` this pass's journals live in.
      JOURNAL_KIND = "improve"

      # The session's {Friction::Report} beside a per-turn digest summary. A
      # pure function of the session's record -- no provider is touched -- so
      # the dry-run surface and the live spawn render the SAME scaffold, and
      # "what it would see" cannot disagree with "what it saw".
      #
      # A subagent's turns are summarized under the parent turn that spawned
      # them. They are no `turn` records, so without `lineages` a session whose
      # real work happened in children read as a parent that only delegated.
      Scaffold = Data.define(:records, :lineages) do
        def render
          <<~PROMPT
            You are reviewing one completed lain session to find what would make lain ITSELF better.
            The evidence below is mechanical; your job is to turn it into notes lain's own
            maintainers can act on -- a missing knob, a tool that fought the model, a doc that lied.

            Friction report (mechanical signals and the knob each already points at):
            #{friction}

            Session digest summary (#{turn_count} turn(s) -- cite these digests as the evidence behind any note):
            #{summary}

            Record one improvement_write per finding, each citing the digests above. Prefer nothing
            over a vague note: if the session surfaced nothing worth a maintainer's time, write nothing.
          PROMPT
        end

        private

        # Fully qualified: a bare `Friction` resolves in this lexical scope to
        # {CLI::Friction}, the USER-facing report command, not the domain
        # {Lain::Friction::Report} this pass reasons from.
        def friction = Lain::Friction::Report.new(records, lineages:).render

        def turns = records.select { |record| record["type"].to_s == "turn" }

        def turn_count = turns.size + lineages.sum { |lineage| lineage.child_turns.size }

        # The ordinals run across the whole summary rather than per turn, so
        # two withheld regions two turns apart are two numbers and a reader can
        # count them.
        def summary
          ordinals = (1..).each
          (turns.map { |turn| line(turn["role"], turn["digest"], turn["content"], ordinals) } +
            lineages.flat_map { |lineage| lineage_lines(lineage, ordinals) }).join("\n")
        end

        def lineage_lines(lineage, ordinals)
          ["subagent #{lineage.spawn.digest}, spawned from #{lineage.spawned_from}:",
           *lineage.child_turns.map { |turn| "  #{line(turn.role, turn.digest, turn.content, ordinals)}" }]
        end

        def line(role, digest, content, ordinals)
          "[#{role}] #{digest} #{trace(content, ordinals)}".rstrip
        end

        # A release put real bytes on the record for the model of the session
        # that asked for it. This pass is a SECOND reader, out of chat, and
        # nobody is at a surface to release anything to it -- so every region
        # the detector finds is withheld, the answer {ToolGuard::Unreleased}
        # already gives the improver's own tool phase.
        #
        # Only the record's own bytes go through it. A turn digest is a
        # high-entropy token the detector would withhold, and the improver is
        # asked to cite those digests; the friction render beside them is
        # mechanical signals and digests too, and carries no turn text at all.
        def trace(content, ordinals)
          text = Array(content).grep(Hash).filter_map { |block| summarize(block) }.join(" ")
          Sensitivity::Masking.render(text, Sensitivity::Regions.detect(text), ordinals:)
        end

        # An unknown block kind summarizes to nil and `filter_map` drops it,
        # rather than a silent catch-all.
        def summarize(block)
          case block["type"]
          when "text" then block["text"]
          when "tool_use" then "called #{block["name"]}"
          end
        end
      end

      # One object rather than a pair, so {#report} and {#dry_report} each read
      # the session once and cannot disagree about which session they describe.
      Review = Data.define(:session, :prompt)

      # The exe's assembly seam. The session is resolved ONCE, here, and both
      # the recorded profile and the scaffold are read from that file. The
      # assembly lives here, not in the exe, so it carries specs.
      #
      # The backend defaults to what the session under review recorded, and a
      # typed field that disagrees wins aloud, as {Consolidate.from_options}'s
      # does. It is built only when {#report} spawns, so a dry run builds no
      # provider and looks up no credential; the provider's name is still
      # checked, since that needs neither.
      #
      # @param options [Hash] the invoked command's parsed flags
      # @param selector [String] the session under review
      # @param profile [RunProfile] what the model flag band resolved
      # @param paths [Paths] resolves the session dir and the improvements sink
      # @param project_dir [ProjectDir] keyed to the PROJECT's root rather than
      #   to `Dir.pwd`, so a pass run from a subdirectory journals under the
      #   project it is in
      # @option options [String] :provider the model flag band's provider, which
      #   the profile was resolved from
      # @option options [String] :model the model flag band's model id
      # @return [Improve]
      # @raise [SessionFile::SessionNotFound] before anything else is read
      def self.from_options(options, selector:, profile: RunProfile.from_options(options), paths: Paths.new,
                            project_dir: ProjectDir.new(root: Project::Resolver.default_project.root, paths:))
        path = SessionFile.resolve(selector, paths:)
        mismatches = Resume::MismatchNotices.new(path:)
        resolved = profile.over(mismatches.recorded_profile)
        Backend.validated(resolved.provider)
        new(path:, profile: resolved, paths:, project_dir:,
            backend: -> { Backend.new(options, profile: resolved, root: project_dir.root) },
            notices: mismatches.call(profile: resolved, model: resolved.model))
      end

      # The spawn collaborators are REQUIRED: a forgotten one is a loud
      # ArgumentError here rather than a nil checked at the spawn.
      #
      # @param path [String] the session file under review, already resolved
      # @param profile [RunProfile] the backend the improver runs on, which a
      #   dry run names
      # @param backend [#call] answers what the spawn reads -- `#provider`,
      #   `#context` and `#slots` -- and is called by {#report} only
      # @param project_dir [ProjectDir] where this pass's journal lands;
      #   REQUIRED, so a caller that forgot it is a loud ArgumentError here
      #   rather than a record written into whatever project this process
      #   happens to sit in
      # @param paths [Paths] resolves the improvements sink's destination and
      #   project hash; injectable for specs
      # @param notices [Array<String>] said ahead of either report
      def initialize(path:, profile:, backend:, project_dir:, paths: Paths.new, notices: [])
        @path = path
        @profile = profile
        @backend = backend
        @project_dir = project_dir
        @paths = paths
        @notices = notices
      end

      # Spawn the improver once over the session's record.
      #
      # @return [String]
      # @raise [Bench::Session::Corrupt] naming the file and its damage
      def report
        review = session_review
        sink = Improvement::Sink.new(session: review.session, paths: @paths)
        journaled do |journal|
          result = build_improver(sink, @backend.call, journal).ask(review.prompt).text
          said("improve: ran a harness_improver pass over session #{review.session}, #{stored(sink)}\n#{result}")
        end
      end

      # The scaffold the improver WOULD see, and what it would run on,
      # spawning nothing.
      #
      # @return [String]
      # @raise [Bench::Session::Corrupt] naming the file and its damage
      def dry_report
        review = session_review
        said("improve: harness_improver would review session #{review.session} on #{@profile.provider}, " \
             "model #{@profile.model || "the provider's default"} (provider untouched)\n\n#{review.prompt}")
      end

      private

      def stored(sink)
        return "stored nothing" if sink.appended.zero?

        "stored #{sink.appended} #{sink.appended == 1 ? "note" : "notes"}"
      end

      def said(report) = [*@notices, report].join("\n")

      # A pure function of the session file -- no provider touched -- so the
      # dry surface and the live spawn read the SAME session id and scaffold.
      # The lineages are read whole, so a damaged session refuses by name.
      def session_review
        lineages = Bench::Session::Lineages.read(@path).to_a
        Review.new(session: File.basename(@path, ".ndjson"), prompt: prompt_for(@path, lineages))
      end

      # Rendered here, where the path is still known. {Bench::Session::Lineages.read}
      # names the file in its own refusals; this names it in the graders'.
      def prompt_for(path, lineages)
        Scaffold.new(records: Journal.records(File.foreach(path)).to_a, lineages:).render
      rescue Lain::Error => e
        raise Lain::Error, "#{path}: #{e.message}"
      end

      # A Journal that created its file and wrote no record removes it on
      # close, so a pass that noted nothing leaves the container empty rather
      # than littered with zero-byte files.
      def journaled(&block) = Journal.open(File.join(@project_dir.container(JOURNAL_KIND), Journal.stem), &block)

      def build_improver(sink, backend, journal)
        allowed = role.attenuate(improver_union(sink))
        Agent.new(
          provider: backend.provider, context: role.child_context(backend.context, slots: backend.slots),
          toolset: allowed,
          handler: Effect::Handler::Live.new, timeline: fresh_root,
          session: Session.new(worker_env: WorkerEnv.default), journal:, tool_middleware: guard_stack(journal)
        )
      end

      # The union the role attenuates FROM: it must hold every tool the role's
      # `only`-set names, or {Toolset#only} fails loudly.
      def improver_union(sink)
        Toolset.new([Tools::ReadFile.new, Tools::ListFiles.new, Tools::Glob.new, Tools::Grep.new,
                     Tools::ImprovementWrite.new(sink:)])
      end

      # Routed through the role's own policy so the fresh-root decision has one
      # owner ({Role#spawn_policy}'s default), not a bare `Timeline.empty` that
      # could drift from it.
      def fresh_root = role.spawn_policy(prefix: :fresh).prefix.base_timeline(store: Store.new)

      # Refusals and masks are recorded into the pass's own journal.
      def guard_stack(journal) = ToolGuard.detached(journal:).call(WorkerEnv.default)

      def role = @role ||= Role::Catalog.fetch(ROLE)
    end
  end
end
