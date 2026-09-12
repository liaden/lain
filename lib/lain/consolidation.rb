# frozen_string_literal: true

module Lain
  # The court-clerk consolidation pass: offline, it walks a session Journal's
  # COMPLETED SUBAGENT lineages -- turns whose chain root carries `spawned_from`
  # meta, grouped by that root -- and spawns the shipped `court_clerk` role once
  # per lineage to distill it into durable memory.
  #
  # FRESH-ROOT IS NOT NEGOTIABLE. The clerk READS a lineage's record; were it to
  # INHERIT the parent's prompt, "reading a record" would silently become
  # "continuing a conversation" and the premise collapses. Every spawn therefore
  # starts a FRESH Timeline root over a new Store, asserted here rather than
  # assumed of {Role#spawn_policy}'s default.
  #
  # THE GUARD DOES NOT COME FREE. The role-spawn seam builds a child's dispatch
  # WITHOUT tool middleware, so a credential-shaped `memory_write` would reach the
  # recorder unguarded -- and a memory, once indexed, replays into every future
  # context with no un-indexing it. This class therefore builds the clerk's OWN
  # dispatch chain over the stack a run with no chat builds for itself
  # ({CLI::ToolGuard.detached}, as {CLI::Improve} does): the write refusal, and a
  # credential region in a file the clerk reads left masked because nobody is at
  # a surface to release it. A refusal is contained -- the clerk's loop continues
  # on the error result, and so does the pass onto the next lineage.
  class Consolidation
    ROLE = :court_clerk

    # `root` is the evidence a memory cites.
    Outcome = Data.define(:root, :result)

    # Every spawn collaborator is REQUIRED, so a forgotten one is a loud
    # ArgumentError at the wiring site rather than a nil checked one spawn later.
    # That is affordable only because a dry pass has a real thing to pass:
    # {Provider::Unreachable}. When `provider:` was optional, four nils were
    # indistinguishable from a deliberate dry run.
    #
    # @param provider [Lain::Provider] the clerk's model; {Provider::Unreachable}
    #   for a `--dry-run`, which touches no provider and so needs no API key
    # @param recorder [Memory::Recorder] the shared index the clerk writes into
    # @param context [Lain::Context] the factory context the clerk persona
    #   reshapes (model/max_tokens ride through; its system is REPLACED by the
    #   role prelude)
    # @param slots [Prompt::Slots] the session slots the persona renders through
    # @param journal [#<<] where the clerk's turn usage, memory roots, and any
    #   {Telemetry::WriteRefused} land; the Null channel by default -- a real
    #   Null object, not a nil, so it stays a default rather than a mis-wire
    def initialize(provider:, recorder:, context:, slots:,
                   journal: Channel::Null.instance)
      @provider = provider
      @recorder = recorder
      @context = context
      @slots = slots
      @journal = journal
    end

    # Never spawns. The dry-run surface and the live pass share this, so "what
    # would run" and "what ran" can never disagree.
    #
    # @param entries [Enumerable<Hash, String>] the {Journal.records} duck
    # @return [Array<Lineage>] in journal (first-seen-root) order
    def lineages(entries)
      Lineage.from_records(Journal.records(entries, type: "turn").to_a)
    end

    # @return [Array<Outcome>] one per lineage, in journal order
    def call(entries)
      lineages(entries).map { |lineage| spawn_clerk(lineage) }
    end

    # The lineages the pass WOULD spawn, touching no provider.
    #
    # @return [String]
    def dry_run(entries)
      grouped = lineages(entries)
      return "consolidate: no completed subagent lineages found." if grouped.empty?

      ["consolidate: #{grouped.size} lineage(s) would each get one court_clerk pass",
       *grouped.map { |lineage| "  - lineage #{lineage.root} (#{lineage.turn_count} turns)" }].join("\n")
    end

    private

    # A reader, not `@recorder`, so the keyword shorthand reads at its senders.
    attr_reader :recorder

    def spawn_clerk(lineage)
      Outcome.new(root: lineage.root, result: build_clerk.ask(lineage.scaffold).text)
    end

    # The point of this class is the last argument: a tool-phase guard stack the
    # spawn seam would not have supplied.
    def build_clerk
      allowed = role.attenuate(clerk_union)
      Agent.new(
        provider: @provider, context: clerk_context, toolset: allowed,
        handler: Effect::Handler::Live.new(toolset: allowed),
        timeline: fresh_root, session: clerk_session, journal: clerk_journal, tool_middleware: guard_stack
      )
    end

    # Routed through the role's own policy so the fresh-root decision has one
    # owner, not a bare `Timeline.empty` that could drift from it.
    def fresh_root = role.spawn_policy(prefix: :fresh).prefix.base_timeline(store: Store.new)

    def clerk_session = Session.new(memory: recorder, worker_env: WorkerEnv.default)

    # Each clerk turn is paired with the recorder's memory root in force at it.
    def clerk_journal = Memory::JournalMemoryRoot.new(journal: @journal, recorder:)

    # A deliberate asymmetry: what the guards record lands on the RAW `@journal`
    # -- a refusal or a mask writes no memory, so neither has a root to pair --
    # while the clerk's TURNS ride the wrapped {#clerk_journal}.
    #
    # Detached, not layered: no chat lends this pass a board, so its listing
    # guard holds the Null filter, matching the gate it has -- none.
    def guard_stack = detached_guard.call(WorkerEnv.default)

    # {CLI::ToolGuard.detached} builds a BOARD, and says it is built ONCE: a pass
    # over N lineages is one run, however many clerks it spawns.
    def detached_guard = @detached_guard ||= CLI::ToolGuard.detached(journal: @journal)

    # The union the role attenuates FROM: it must hold every tool the clerk's
    # `only`-set names, or {Toolset#only} fails loudly. Both memory tools share the
    # ONE recorder, so the clerk's writes and its manifest see one index.
    def clerk_union
      Toolset.new([Tools::ReadFile.new, Tools::ListFiles.new,
                   Tools::MemoryRead.new(index: recorder), Tools::MemoryWrite.new(recorder:)])
    end

    def clerk_context = role.child_context(@context, slots: @slots)

    def role = @role ||= Role::Catalog.fetch(ROLE)
  end

  class Consolidation
    # Reopened rather than nested in a `Data.define ... do` block: a constant or
    # nested class declared inside that block scopes to the enclosing module, not
    # the Data class.

    # A completed subagent lineage, its turns in journal order.
    Lineage = Data.define(:root, :turns) do
      # The walk follows `parent`, never `spawned_from`, so grouping stays
      # unambiguous; `spawned_from` is consulted only to tell a subagent root from
      # a main-chain one.
      def self.from_records(records)
        by_digest = records.to_h { |record| [record["digest"], record] }
        # digest => its chain root, for THIS call only: every turn in a lineage
        # climbs the same edges, so without it an N-turn chain walks to the root
        # N times. An artifact of this record slice, never a cache outliving it.
        roots = {}
        records.group_by { |record| chain_root(record["digest"], by_digest, roots) }
               .filter_map { |root, turns| new(root:, turns:) if subagent_root?(by_digest[root]) }
      end

      # Three ways the walk ends: a `parent` of nil is a genuine chain root; a
      # `parent` naming a digest OUTSIDE this slice ends on a missing digest, so
      # {from_records} groups that lineage under a non-subagent root and DROPS it
      # (a headless tail from a partial journal is never spawned, rather than
      # crashing); and a digest an earlier walk resolved answers from `roots`.
      def self.chain_root(digest, by_digest, roots)
        walked = []
        while (parent = unresolved_parent(digest, by_digest, roots))
          walked << digest
          digest = parent
        end
        walked << digest # the terminal too, so a later walk stops here
        root = roots.fetch(digest, digest)
        walked.each { |step| roots[step] = root }
        root
      end
      private_class_method :chain_root

      # nil where the walk ends: an already resolved digest, a record outside this
      # slice, or a genuine root.
      def self.unresolved_parent(digest, by_digest, roots)
        record = by_digest[digest]
        record && !roots.key?(digest) ? record["parent"] : nil
      end
      private_class_method :unresolved_parent

      def self.subagent_root?(record)
        !record.nil? && !record.dig("meta", "spawned_from").nil?
      end
      private_class_method :subagent_root?

      def turn_count = turns.size

      # The per-lineage record the clerk reads; its ROLE supplies the persona.
      def scaffold
        <<~PROMPT
          You are consolidating one completed subagent lineage into durable memory.

          Lineage root (cite this as the evidence/source of every memory you write): #{root}
          Turns in this lineage: #{turn_count}

          Transcript:
          #{transcript}

          Write the memories worth keeping from this lineage, each sourced to the lineage root above.
        PROMPT
      end

      # Deterministic, one line per turn.
      def transcript
        turns.map { |turn| render_turn(turn) }.join("\n")
      end

      private

      def render_turn(turn)
        summaries = Array(turn["content"]).grep(Hash).filter_map { |block| summarize(block) }
        "[#{turn["role"]}] #{summaries.join(" ")}".rstrip
      end

      # A closed `case`: an unknown block kind summarizes to nil and `filter_map`
      # drops it, rather than a silent catch-all.
      def summarize(block)
        case block["type"]
        when "text" then block["text"]
        when "tool_use" then "called #{block["name"]}"
        end
      end
    end
  end
end
