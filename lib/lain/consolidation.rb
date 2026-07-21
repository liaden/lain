# frozen_string_literal: true

module Lain
  # The court-clerk consolidation pass (M5): offline, it walks a session
  # Journal's COMPLETED SUBAGENT lineages -- turns whose chain root carries
  # `spawned_from` meta, grouped by that root -- and spawns the shipped
  # {Role::Catalog} `court_clerk` role once per lineage to distill it into
  # durable memory.
  #
  # == Fresh-root, and why it is not negotiable
  #
  # The clerk READS a lineage's record; it must never INHERIT the parent's
  # prompt, or "reading a record" silently becomes "continuing a conversation"
  # and the premise collapses. So every spawn starts a FRESH Timeline root over
  # a new Store -- {Role#spawn_policy}'s default prefix, asserted here rather
  # than assumed (the escalation the card names).
  #
  # == The guard does not come free
  #
  # The role-spawn seam builds a child's dispatch WITHOUT tool middleware, so a
  # credential-shaped `memory_write` would reach the recorder unguarded -- and a
  # memory, once indexed, replays into every future context with no un-indexing
  # it. This class therefore builds the clerk's OWN dispatch chain and mounts
  # {Middleware::RefuseSecretWrites} in its tool phase: the same guard the main
  # agent runs, producing the same {Telemetry::WriteRefused} record. A refusal
  # is contained -- the clerk's loop continues on the error result, and so does
  # the pass onto the next lineage. The guard's `oracle:` stays the NullOracle
  # default ({Oracle::MemorySave::Gate} is deliberately unwired, per the plan).
  #
  # Memory roots advance through the existing {Memory::JournalMemoryRoot}
  # pairing: the clerk's journal is decorated so each of its turns is paired with
  # the recorder's root in force at that turn.
  class Consolidation
    # The role every lineage is handed to (shipped: read_file/list_files/
    # memory_read/memory_write).
    ROLE = :court_clerk

    # A spawn collaborator was needed but never injected -- loud, naming which.
    class MissingCollaborator < Error; end

    # One lineage's outcome: its root (the evidence a memory cites) and the
    # clerk's final text.
    Outcome = Data.define(:root, :result)

    # @param provider [Lain::Provider] the clerk's model; required for {#call},
    #   untouched by {#dry_run} (so `--dry-run` runs with no API key)
    # @param recorder [Memory::Recorder] the shared index the clerk writes into
    # @param context [Lain::Context] the factory context the clerk persona
    #   reshapes (model/max_tokens ride through; its system is REPLACED by the
    #   role prelude)
    # @param slots [Prompt::Slots] the session slots the persona renders through
    # @param journal [#<<] where the clerk's turn usage, memory roots, and any
    #   {Telemetry::WriteRefused} land; the Null channel by default
    def initialize(provider: nil, recorder: nil, context: nil, slots: nil,
                   journal: Channel::Null.instance)
      @provider = provider
      @recorder = recorder
      @context = context
      @slots = slots
      @journal = journal
    end

    # Group `entries` into completed subagent lineages -- never spawning. The
    # dry-run surface and the live pass share this, so "what would run" and
    # "what ran" can never disagree.
    #
    # @param entries [Enumerable<Hash, String>] the {Journal.records} duck
    # @return [Array<Lineage>] in journal (first-seen-root) order
    def lineages(entries)
      Lineage.from_records(Journal.records(entries, type: "turn").to_a)
    end

    # Spawn one clerk per lineage, in journal order.
    #
    # @return [Array<Outcome>] one per lineage
    def call(entries)
      lineages(entries).map { |lineage| spawn_clerk(lineage) }
    end

    # A human report of the lineages the pass WOULD spawn, touching no provider.
    #
    # @return [String]
    def dry_run(entries)
      grouped = lineages(entries)
      return "consolidate: no completed subagent lineages found." if grouped.empty?

      ["consolidate: #{grouped.size} lineage(s) would each get one court_clerk pass",
       *grouped.map { |lineage| "  - lineage #{lineage.root} (#{lineage.turn_count} turns)" }].join("\n")
    end

    private

    def spawn_clerk(lineage)
      Outcome.new(root: lineage.root, result: build_clerk.ask(lineage.scaffold).text)
    end

    # The clerk's own Agent: a fresh root, the role persona for a system, the
    # attenuated toolset, and -- the point of this class -- a tool-phase
    # {Middleware::RefuseSecretWrites} the spawn seam would not have supplied.
    def build_clerk
      allowed = role.attenuate(clerk_union)
      Agent.new(
        provider: require!(@provider, "provider"), context: clerk_context, toolset: allowed,
        handler: Effect::Handler::Live.new(toolset: allowed),
        timeline: fresh_root, session: clerk_session, journal: clerk_journal, tool_middleware: guard_stack
      )
    end

    # Fresh-root over a NEW Store: the clerk reads the record, never inherits the
    # parent's prompt. Routed through the role's own policy so the fresh-root
    # decision has one owner ({Role#spawn_policy}'s default), not a bare
    # `Timeline.empty` that could drift from it.
    def fresh_root = role.spawn_policy(prefix: :fresh).prefix.base_timeline(store: Store.new)

    def clerk_session = Session.new(memory: recorder, worker_env: WorkerEnv.default)

    # Memory roots advance via the existing pairing: each clerk turn is paired
    # with the recorder's root in force at that turn.
    def clerk_journal = Memory::JournalMemoryRoot.new(journal: @journal, recorder:)

    # The point of this class: the tool-phase guard the spawn seam omits. A
    # deliberate asymmetry -- the guard journals {Telemetry::WriteRefused} to the
    # RAW `@journal` (a refusal writes nothing, so there is no memory root to
    # pair), while the clerk's TURNS ride {#clerk_journal}, the
    # JournalMemoryRoot-wrapped duck that does pair each turn with the root in
    # force.
    def guard_stack = Middleware::Stack.new([Middleware::RefuseSecretWrites.new(journal: @journal)])

    # The union the role attenuates FROM: it must hold every tool the clerk's
    # `only`-set names, or {Toolset#only} fails loudly. Both memory tools share
    # the ONE recorder, so the clerk's writes and its manifest see one index.
    def clerk_union
      Toolset.new([Tools::ReadFile.new, Tools::ListFiles.new,
                   Tools::MemoryRead.new(index: recorder), Tools::MemoryWrite.new(recorder:)])
    end

    def clerk_context
      role.child_context(require!(@context, "context"), slots: require!(@slots, "slots"))
    end

    def recorder = require!(@recorder, "recorder")

    def role = @role ||= Role::Catalog.fetch(ROLE)

    def require!(value, name)
      value || raise(MissingCollaborator, "Consolidation#call needs #{name}:; none was injected")
    end
  end

  # Reopened rather than nested in a `Data.define ... do` block: a constant or
  # nested class declared inside that block scopes to the enclosing module, not
  # the Data class (the {Request::SYSTEM_PREFIX} trap). Consolidation is a plain
  # class, so this nests cleanly as {Consolidation::Lineage}.
  class Consolidation
    # A completed subagent lineage: its chain root (the evidence digest) and the
    # turn records that belong to it, in journal order.
    Lineage = Data.define(:root, :turns) do
      # Group turn records into lineages: bucket every turn under its chain root
      # (the single render-parent edge walked to the top), then keep only roots
      # that a subagent left `spawned_from` on. Correlation-grain provenance is
      # untouched here -- the walk follows `parent`, never `spawned_from`, so
      # grouping is unambiguous and the classification uses `spawned_from` only
      # to tell a subagent root from a main-chain one.
      def self.from_records(records)
        by_digest = records.to_h { |record| [record["digest"], record] }
        records.group_by { |record| chain_root(record["digest"], by_digest) }
               .filter_map { |root, turns| new(root:, turns:) if subagent_root?(by_digest[root]) }
      end

      # Walk the single render-parent edge to the chain's root. Two ways the
      # walk ends: a MID-walk record whose `parent` is nil is a genuine chain
      # root; a record whose `parent` names a digest OUTSIDE this slice ends the
      # walk on that missing digest, whose `by_digest` lookup is nil -- so
      # {from_records} groups the lineage under a root that is not
      # {subagent_root?} and DROPS it (a headless tail from a partial journal is
      # never spawned, rather than crashing).
      def self.chain_root(digest, by_digest)
        record = by_digest[digest]
        while record && record["parent"]
          digest = record["parent"]
          record = by_digest[digest]
        end
        digest
      end
      private_class_method :chain_root

      def self.subagent_root?(record)
        !record.nil? && !record.dig("meta", "spawned_from").nil?
      end
      private_class_method :subagent_root?

      def turn_count = turns.size

      # The court-clerk scaffold: the transcript summary framed as a
      # consolidation task, with the lineage root named as the evidence each
      # memory must cite. The clerk's ROLE (system) supplies the persona; this
      # is the per-lineage record it reads.
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

      # A deterministic one-line-per-turn rendering: the role, its text, and the
      # names of any tools it called.
      def transcript
        turns.map { |turn| render_turn(turn) }.join("\n")
      end

      private

      def render_turn(turn)
        summaries = Array(turn["content"]).grep(Hash).filter_map { |block| summarize(block) }
        "[#{turn["role"]}] #{summaries.join(" ")}".rstrip
      end

      # A content block's one-line trace: its text, or the name of the tool it
      # called. A closed `case` -- an unknown block kind summarizes to nil and
      # `filter_map` drops it, rather than a silent catch-all.
      def summarize(block)
        case block["type"]
        when "text" then block["text"]
        when "tool_use" then "called #{block["name"]}"
        end
      end
    end
  end
end
