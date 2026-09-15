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
    # == Two methods, not one boolean
    #
    # {#report} spawns the improver; {#dry_report} renders the scaffold it
    # WOULD have seen. Separate methods, because `report_for(dry_run: true)`
    # was a flag that changed what the method MEANT. Both read the session
    # ONCE, through the same private {Review}.
    class Improve
      # The role every session is handed to: read_file/list_files/glob/grep/
      # improvement_write, and no memory tools, by design.
      ROLE = :harness_improver

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

        def summary
          (turns.map { |turn| line(turn["role"], turn["digest"], turn["content"]) } +
            lineages.flat_map { |lineage| lineage_lines(lineage) }).join("\n")
        end

        def lineage_lines(lineage)
          ["subagent #{lineage.spawn.digest}, spawned from #{lineage.spawned_from}:",
           *lineage.child_turns.map { |turn| "  #{line(turn.role, turn.digest, turn.content)}" }]
        end

        def line(role, digest, content)
          "[#{role}] #{digest} #{trace(content)}".rstrip
        end

        def trace(content)
          Array(content).grep(Hash).filter_map { |block| summarize(block) }.join(" ")
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

      # The exe's assembly seam. Under `--dry-run` the provider is
      # {Provider::Unreachable}, so no API key is fetched and nothing can
      # quietly reach a model -- which is what lets every collaborator below be
      # required. The assembly lives here, not in the exe, so it carries specs.
      #
      # @param options [Hash] the invoked command's parsed flags
      # @option options [Boolean] :dry_run swaps the provider for an unreachable one
      # @return [Improve]
      def self.from_options(options)
        backend = Backend.new(options)
        new(provider: options[:dry_run] ? Provider::Unreachable.new : backend.provider,
            context: backend.context, slots: backend.slots)
      end

      # The spawn collaborators are REQUIRED: a forgotten one is a loud
      # ArgumentError here rather than a nil checked at the spawn, and a dry
      # run has a real thing to pass ({Provider::Unreachable}).
      #
      # @param provider [Lain::Provider] the improver's model;
      #   {Provider::Unreachable} for a `--dry-run`, which touches no provider
      # @param context [Lain::Context] the factory context the persona reshapes
      #   (model/max_tokens ride through; its system is REPLACED by the role
      #   prelude)
      # @param slots [Prompt::Slots] the session slots the persona renders through
      # @param journal [#<<] where the improver's turn usage and any
      #   {Telemetry::WriteRefused} land; the Null channel by default -- a real
      #   Null object, not a nil, so it stays a default rather than a mis-wire
      # @param paths [Paths] resolves the session dir AND the improvements sink's
      #   destination/project hash; injectable for specs
      def initialize(provider:, context:, slots:, journal: Channel::Null.instance, paths: Paths.new)
        @provider = provider
        @context = context
        @slots = slots
        @journal = journal
        @paths = paths
      end

      # Spawn the improver once over one session's record.
      #
      # @param selector [String] an explicit path, a bare filename, or a
      #   filename missing its ".ndjson" suffix
      # @return [String]
      # @raise [SessionFile::SessionNotFound]
      # @raise [Bench::Session::Corrupt] naming the file and its damage
      def report(selector)
        review = review_of(selector)
        result = build_improver(review.session).ask(review.prompt).text
        "improve: ran a harness_improver pass over session #{review.session}\n#{result}"
      end

      # The scaffold the improver WOULD see, spawning nothing.
      #
      # @return [String]
      # @raise [SessionFile::SessionNotFound]
      def dry_report(selector)
        review = review_of(selector)
        "improve: harness_improver would review session #{review.session} " \
          "(provider untouched)\n\n#{review.prompt}"
      end

      private

      # A pure function of the session file -- no provider touched -- so the
      # dry surface and the live spawn read the SAME session id and scaffold.
      # The lineages are read whole, so a damaged session refuses by name.
      def review_of(selector)
        path = SessionFile.resolve(selector, paths: @paths)
        lineages = Bench::Session::Lineages.read(path).to_a
        Review.new(session: File.basename(path, ".ndjson"), prompt: prompt_for(path, lineages))
      end

      # Rendered here, where the path is still known. {Bench::Session::Lineages.read}
      # names the file in its own refusals; this names it in the graders'.
      def prompt_for(path, lineages)
        Scaffold.new(records: Journal.records(File.foreach(path)).to_a, lineages:).render
      rescue Lain::Error => e
        raise Lain::Error, "#{path}: #{e.message}"
      end

      def build_improver(session)
        allowed = role.attenuate(improver_union(session))
        Agent.new(
          provider: @provider, context: improver_context, toolset: allowed,
          handler: Effect::Handler::Live.new, timeline: fresh_root,
          session: Session.new(worker_env: WorkerEnv.default), journal: @journal, tool_middleware: guard_stack
        )
      end

      # The union the role attenuates FROM: it must hold every tool the role's
      # `only`-set names, or {Toolset#only} fails loudly.
      def improver_union(session)
        Toolset.new([Tools::ReadFile.new, Tools::ListFiles.new, Tools::Glob.new, Tools::Grep.new,
                     Tools::ImprovementWrite.new(sink: Improvement::Sink.new(session:, paths: @paths))])
      end

      # Routed through the role's own policy so the fresh-root decision has one
      # owner ({Role#spawn_policy}'s default), not a bare `Timeline.empty` that
      # could drift from it.
      def fresh_root = role.spawn_policy(prefix: :fresh).prefix.base_timeline(store: Store.new)

      def improver_context = role.child_context(@context, slots: @slots)

      # Refusals and masks are recorded into the raw `@journal`.
      def guard_stack = ToolGuard.detached(journal: @journal).call(WorkerEnv.default)

      def role = @role ||= Role::Catalog.fetch(ROLE)
    end
  end
end
