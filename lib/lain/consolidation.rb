# frozen_string_literal: true

module Lain
  # The court-clerk consolidation pass: offline, it takes a session's COMPLETED
  # SUBAGENT lineages, as {Bench::Session::Lineages} reads them off the record,
  # and spawns the shipped `court_clerk` role once per lineage to distill it into
  # durable memory.
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

    # `spawn` is the evidence a memory cites: the digest of the lineage's
    # `:spawn`, the address `lain watch` and the fleet already know it by. Twin
    # spawns of one prompt from one head share it even when they answer apart.
    #
    # `wrote` is whether THIS lineage's clerk moved the recorder's index -- read
    # off the recorder itself, never off `result`, because a clerk that explored
    # and reported its findings in prose still leaves the store untouched.
    #
    # It answers "did what project memory RESOLVES TO change", not "did a
    # `memory_write` call happen". A clerk that writes an id to B and then, in
    # the same lineage, writes it back to the content it held before this
    # lineage ran resolves to what it started at -- `wrote: false` -- even
    # though the append-only store durably gained both writes: nothing a later
    # reader of project memory can observe moved.
    Outcome = Data.define(:spawn, :result, :wrote)

    # Every spawn collaborator is REQUIRED, so a forgotten one is a loud
    # ArgumentError at the wiring site rather than a nil checked one spawn later.
    # That is affordable only because a dry pass builds none of them:
    # {.dry_run} is asked of the class. When `provider:` was optional, four nils
    # were indistinguishable from a deliberate dry run.
    #
    # @param provider [Lain::Provider] the clerk's model
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

    # Never spawns, and needs nothing a spawn does, so a dry run builds no
    # provider and reads no key.
    #
    # It renders the SCAFFOLDS, not a plan naming them. The dry surface is
    # where a human reads what would be sent, and {CLI::Improve#dry_report}
    # has always answered that question -- a list of lineage digests says a
    # pass would happen and nothing about what it would carry. The same
    # {Scaffold} objects the live pass asks, so "what would be sent" and
    # "what was sent" cannot disagree, masking included.
    #
    # @param lineages [Enumerable<Bench::Session::Lineages::Lineage>]
    # @return [String]
    def self.dry_run(lineages)
      scaffolds = lineages.map { |lineage| Scaffold.new(lineage) }
      return "consolidate: no completed subagent lineages found." if scaffolds.empty?

      ["consolidate: #{scaffolds.size} lineage(s) would each get one court_clerk pass",
       *scaffolds.map { |scaffold| rendered_scaffold(scaffold) }].join("\n\n")
    end

    def self.rendered_scaffold(scaffold)
      "-- lineage #{scaffold.spawn} (#{scaffold.turn_count} turns) --\n#{scaffold.render}"
    end
    private_class_method :rendered_scaffold

    # @param lineages [Enumerable<Bench::Session::Lineages::Lineage>]
    # @return [Array<Outcome>] one per lineage, in the order they were recorded
    def call(lineages)
      lineages.map { |lineage| spawn_clerk(Scaffold.new(lineage)) }
    end

    private

    # A reader, not `@recorder`, so the keyword shorthand reads at its senders.
    attr_reader :recorder

    def spawn_clerk(scaffold)
      root_before = recorder.index.root
      result = build_clerk.ask(scaffold.render).text
      Outcome.new(spawn: scaffold.spawn, result:, wrote: recorder.index.root != root_before)
    end

    # The point of this class is the last argument: a tool-phase guard stack the
    # spawn seam would not have supplied.
    def build_clerk
      allowed = role.attenuate(clerk_union)
      Agent.new(
        provider: @provider, context: clerk_context, toolset: allowed,
        handler: Effect::Handler::Live.new,
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

    # The record one clerk reads: one lineage's child turns, rendered. Its ROLE
    # supplies the persona.
    Scaffold = Data.define(:lineage) do
      def spawn = lineage.spawn.digest

      def turn_count = lineage.child_turns.size

      def render
        <<~PROMPT
          You are consolidating one completed subagent lineage into durable memory.

          Lineage spawn (cite this as the evidence/source of every memory you write): #{spawn}
          Spawned from parent turn: #{lineage.spawned_from}
          Turns in this lineage: #{turn_count}

          Transcript:
          #{transcript}

          Write the memories worth keeping from this lineage, each sourced to the lineage spawn above.
        PROMPT
      end

      # Deterministic, one line per turn. The ordinals run across the whole
      # transcript rather than per turn, so two withheld regions two turns
      # apart are two numbers and a reader can count them.
      def transcript
        ordinals = (1..).each
        lineage.child_turns.map { |turn| render_turn(turn, ordinals) }.join("\n")
      end

      private

      def render_turn(turn, ordinals)
        summaries = Array(turn.content).grep(Hash).filter_map { |block| summarize(block) }
        "[#{turn.role}] #{withheld(summaries.join(" "), ordinals)}".rstrip
      end

      # A release put real bytes on the record for the model of the session
      # that asked for it. This pass is a SECOND reader, out of chat, and
      # nobody is at a surface to release anything to it -- so every region the
      # detector finds is withheld, the answer {CLI::ToolGuard::Unreleased}
      # already gives the clerk's own tool phase.
      #
      # Only the record's own bytes go through it. The frame around them is
      # lain's, and a turn digest is a high-entropy token the detector would
      # withhold: a scaffold that asked the clerk to cite evidence it had just
      # masked would be useless.
      def withheld(text, ordinals)
        Sensitivity::Masking.render(text, Sensitivity::Regions.detect(text), ordinals:)
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
