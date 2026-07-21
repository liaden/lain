# frozen_string_literal: true

module Lain
  module CLI
    # `lain improve <session> [--dry-run]`: the harness-improver pass (M6).
    # Offline, it resolves a session file the same way {CLI::Friction} and
    # {CLI::Consolidate} do, renders that session's {Friction::Report} plus a
    # per-turn digest summary into the `harness_improver` role scaffold, and
    # spawns the role ONCE (a one-shot, not one-per-lineage like the court
    # clerk). The improver's notes land in M2's cross-project {Improvement::Sink},
    # NOT in user-facing memory. Returns a String; only the frontend prints
    # (output discipline, {CLI::Friction}'s precedent).
    #
    # == Distinct from {CLI::Friction} by AUDIENCE
    #
    # {Friction::Report} tells the USER which existing knob to turn; this pass
    # tells the lain DEV what lain should GROW -- a knob that was missing, a tool
    # that fought the model, a doc that lied. Same mechanical signals feed both;
    # the report is the evidence this pass reasons from, framed for a different
    # reader by the role persona.
    #
    # == The guard is self-built (Consolidation's precedent)
    #
    # The role-spawn seam builds a child's dispatch WITHOUT tool middleware, so an
    # `improvement_write` whose input looked like a credential would reach the
    # sink unguarded -- and the improvements file is durable and cross-project.
    # This class therefore builds the improver's OWN dispatch chain and mounts
    # {Middleware::RefuseSecretWrites} in its tool phase, exactly as
    # {Lain::Consolidation} does for the clerk (RoleSpawn has no tool_middleware
    # seam of its own). A refusal is contained: the improver's loop continues on
    # the error result.
    #
    # == Fresh-root
    #
    # The improver READS the session's record; it must never INHERIT the parent's
    # prompt, so it spawns over a FRESH Timeline root ({Role#spawn_policy}'s
    # default `:fresh` prefix), the same non-negotiable the clerk holds.
    class Improve
      # No file on disk answers to the given selector, under any resolution.
      class SessionNotFound < Error; end

      # A spawn collaborator was needed for a live run but never injected -- loud,
      # naming which. A `--dry-run` needs none of them (no provider is touched).
      class MissingCollaborator < Error; end

      # The role every session is handed to (shipped: read_file/list_files/glob/
      # grep/improvement_write -- no memory tools, by design).
      ROLE = :harness_improver

      # The one-shot record the improver reads: the session's {Friction::Report}
      # (the mechanical evidence) beside a per-turn digest summary (the digests a
      # note cites). A pure function of the journal records -- no provider is
      # touched -- so the dry-run surface and the live spawn render the SAME
      # scaffold, and "what it would see" cannot disagree with "what it saw".
      Scaffold = Data.define(:records) do
        def render
          <<~PROMPT
            You are reviewing one completed lain session to find what would make lain ITSELF better.
            The evidence below is mechanical; your job is to turn it into notes lain's own
            maintainers can act on -- a missing knob, a tool that fought the model, a doc that lied.

            Friction report (mechanical signals and the knob each already points at):
            #{friction}

            Session digest summary (#{turns.size} turn(s) -- cite these digests as the evidence behind any note):
            #{summary}

            Record one improvement_write per finding, each citing the digests above. Prefer nothing
            over a vague note: if the session surfaced nothing worth a maintainer's time, write nothing.
          PROMPT
        end

        private

        # Fully qualified: bare `Friction` would resolve to {CLI::Friction} (the
        # USER-facing report command) in this lexical scope, not the domain
        # {Lain::Friction::Report} this pass reasons from.
        def friction = Lain::Friction::Report.new(records).render

        def turns = records.select { |record| record["type"].to_s == "turn" }

        def summary = turns.map { |turn| render_turn(turn) }.join("\n")

        def render_turn(turn)
          "[#{turn["role"]}] #{turn["digest"]} #{trace(turn)}".rstrip
        end

        def trace(turn)
          Array(turn["content"]).grep(Hash).filter_map { |block| summarize(block) }.join(" ")
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

      # The exe's assembly seam: build the pass from Thor options via {Backend}.
      # Only `provider` reaches the network, and under --dry-run it is skipped
      # entirely, so a dry pass needs no API key -- a live run without one fails
      # loudly at {MissingCollaborator}, never silently. Mirrors
      # {CLI::Consolidate.from_options}; the assembly lives here (not in the exe)
      # so it carries specs.
      def self.from_options(options)
        backend = Backend.new(options)
        new(provider: (backend.provider unless options[:dry_run]),
            context: backend.context, slots: backend.slots)
      end

      # @param provider [Lain::Provider] the improver's model; required for a live
      #   {#report_for}, untouched by a dry run (so `--dry-run` needs no API key)
      # @param context [Lain::Context] the factory context the persona reshapes
      #   (model/max_tokens ride through; its system is REPLACED by the role
      #   prelude)
      # @param slots [Prompt::Slots] the session slots the persona renders through
      # @param journal [#<<] where the improver's turn usage and any
      #   {Telemetry::WriteRefused} land; the Null channel by default
      # @param paths [Paths] resolves the session dir AND the improvements sink's
      #   destination/project hash; injectable for specs
      def initialize(provider: nil, context: nil, slots: nil,
                     journal: Channel::Null.instance, paths: Paths.new)
        @provider = provider
        @context = context
        @slots = slots
        @journal = journal
        @paths = paths
      end

      # @param selector [String] an explicit path, a bare filename, or a
      #   filename missing its ".ndjson" suffix
      # @param dry_run [Boolean] render the scaffold the improver WOULD see
      #   instead of spawning it (no provider touched)
      # @return [String]
      # @raise [SessionNotFound]
      def report_for(selector, dry_run: false)
        path = resolve(selector)
        session = File.basename(path, ".ndjson")
        scaffold = Scaffold.new(Journal.records(File.foreach(path)).to_a)
        dry_run ? dry_render(session, scaffold) : render_run(session, scaffold)
      end

      private

      def render_run(session, scaffold)
        result = build_improver(session).ask(scaffold.render).text
        "improve: ran a harness_improver pass over session #{session}\n#{result}"
      end

      def dry_render(session, scaffold)
        "improve: harness_improver would review session #{session} (provider untouched)\n\n#{scaffold.render}"
      end

      # The improver's own Agent: a fresh root, the role persona for a system, the
      # attenuated toolset, and -- the point of this class -- a tool-phase
      # {Middleware::RefuseSecretWrites} the spawn seam would not have supplied.
      def build_improver(session)
        allowed = role.attenuate(improver_union(session))
        Agent.new(
          provider: require!(@provider, "provider"), context: improver_context, toolset: allowed,
          handler: Effect::Handler::Live.new(toolset: allowed), timeline: fresh_root,
          session: Session.new(worker_env: WorkerEnv.default), journal: @journal, tool_middleware: guard_stack
        )
      end

      # The union the role attenuates FROM: it must hold every tool the role's
      # `only`-set names, or {Toolset#only} fails loudly. The `improvement_write`
      # tool is wired to a per-session {Improvement::Sink}, which already knows
      # WHERE the file lives and WHO (project_hash/session) is writing.
      def improver_union(session)
        Toolset.new([Tools::ReadFile.new, Tools::ListFiles.new, Tools::Glob.new, Tools::Grep.new,
                     Tools::ImprovementWrite.new(sink: Improvement::Sink.new(session:, paths: @paths))])
      end

      # Fresh-root over a NEW Store: the improver reads the record, never inherits
      # a parent's prompt. Routed through the role's own policy so the fresh-root
      # decision has one owner ({Role#spawn_policy}'s default), not a bare
      # `Timeline.empty` that could drift from it.
      def fresh_root = role.spawn_policy(prefix: :fresh).prefix.base_timeline(store: Store.new)

      def improver_context
        role.child_context(require!(@context, "context"), slots: require!(@slots, "slots"))
      end

      # The point of this class: the tool-phase guard the spawn seam omits. It
      # journals {Telemetry::WriteRefused} to the raw `@journal`.
      def guard_stack = Middleware::Stack.new([Middleware::RefuseSecretWrites.new(journal: @journal)])

      def role = @role ||= Role::Catalog.fetch(ROLE)

      def dir = @dir ||= @paths.sessions_dir

      def resolve(selector)
        candidates = [selector, File.join(dir, selector), File.join(dir, "#{selector}.ndjson")]
        candidates.find { |path| File.file?(path) } ||
          raise(SessionNotFound, "no session found for #{selector.inspect} -- looked at #{candidates.join(", ")}")
      end

      def require!(value, name)
        value || raise(MissingCollaborator,
                       "Improve#report_for needs #{name}:; none was injected (a live run, not --dry-run)")
      end
    end
  end
end
