# frozen_string_literal: true

module Lain
  module Bench
    # How a bench agent is WIRED: what it may do, and what it reports through.
    #
    # Both members are FACTORIES asked once per AGENT rather than values held
    # for the run, and the reason is contamination rather than tidiness. The
    # tools share a {Memory::Recorder}, so one instance across a comparison
    # would let the fourth arm's `memory_read` answer with the first arm's
    # `memory_write`; an {Agent::Instrumentation} holds the run's journal and
    # three deliberately mutable {Middleware::Stack}s, so one instance would let
    # a `#use` on one agent's phase reach every other agent's. What must NOT
    # move between calls is the toolset's {Lain::Toolset#digest}, since that is
    # the prompt-cache prefix -- and it does not: the schema is a function of
    # the tool list, never of the recorder behind it.
    #
    # `::Lain::CLI` is root-qualified at every mention below. `CLI` alone
    # resolves to {Bench::CLI} from inside this namespace, which is a different
    # class one lookup away.
    module Harness
      # The chat's own capability floor, through the SAME
      # {Lain::CLI::Wiring::BaseTools} production builds it from
      # (`cli/wiring/toolset_build.rb`'s `#capability_floor`), so a bench arm
      # and a chat cannot come to hold two different lists.
      TOOLS = lambda { |recorder:, journal: Channel::Null.instance|
        Toolset.new(::Lain::CLI::Wiring::BaseTools.build(recorder, journal:))
      }

      # No capabilities at all. Kept as a NAMED arm rather than left as the
      # accident it was: "does the harness set the score" is only a question
      # this bench can answer if the toolless run is still runnable, and it is
      # also the only harness a command that leases nothing may default to.
      #
      # It names both keywords its sibling reads and ignores them, rather than
      # swallowing them in a `**`. The two arms of one duck must fail equally
      # loudly on a keyword neither knows.
      NO_TOOLS = ->(recorder:, journal: nil) { Toolset.new([]) } # rubocop:disable Lint/UnusedBlockArgument

      # The floor's members that reach a filesystem the run does not own. The
      # partition below it is TOTAL and there is a spec saying so, which is what
      # makes a tool added to the floor a red example rather than a silent
      # promotion to "safe" -- the shape `spec/lain/tools/parallel_safety_spec.rb`
      # already uses for its own partition.
      #
      # `bash` is here because the model controls its command string, which is
      # the axis {Lain::Tool#requires_approval?} says predicts danger; the other
      # two write a path the model names. `memory_write` and `todo_write` write
      # session state that dies with the process, so they are not on this list.
      WRITERS = %w[bash edit_file write_file].freeze

      # The floor's remaining members, named so the partition can be checked for
      # totality rather than assumed.
      READERS = %w[ast_dump ast_search file_symbols glob grep list_files memory_read memory_write
                   read_file test_pattern todo_write web_fetch web_search].freeze

      module_function

      # Whether this capability set can act outside the run's own memory.
      #
      # @param toolset [Lain::Toolset]
      # @return [Boolean]
      def writes?(toolset) = WRITERS.intersect?(toolset.names)

      # Where a bench run REPORTS: the journal it was called with, wrapped so
      # each turn is paired with the memory root in force when it rendered;
      # every outbound Request recorded innermost, which is what makes "the
      # provider saw these tools" readable off the record rather than inferred;
      # and the SAME guard stack every other run with no chat behind it gets.
      #
      # The guards are {Lain::CLI::ToolGuard.detached}'s, not a list assembled
      # here. Hand-rolling them is how a bench acquires all four tier-1 read
      # tools and one quarter of the boundary that governs them -- and CLAUDE.md
      # is explicit that those tools do not check paths themselves, precisely
      # because the boundary is meant to be one place a reader can find. Reuse
      # also means a later tightening of `detached` reaches the bench for free.
      #
      # A FRESH board per agent, where {Consolidation} memoizes one for its
      # whole run: a release ledger shared across arms is the same cross-arm
      # contamination the per-spawn recorder exists to prevent.
      #
      # `pipeline_source:` is left at {Agent::PipelineSource::Null} and is the
      # one axis still closed. The production builder,
      # {Lain::CLI::Backend#pipeline_source}, memoizes and binds its journal
      # ONCE per run because a compaction source is run state; the bench builds
      # one agent per arm per task, each with its own journal, so a shared
      # source would let one arm read another's accumulated cache warmth and
      # summaries. Injectable, so a caller holding an honest per-agent source
      # can supply one; not defaulted, because nothing here can build one
      # without becoming a second authority over how a run compacts.
      INSTRUMENTATION = lambda { |journal:, recorder:, worker_env:|
        Agent::Instrumentation.new(
          journal: Memory::JournalMemoryRoot.new(journal:, recorder:),
          model_middleware: Middleware::Stack.new([Middleware::JournalRequests.new(journal:)]),
          tool_middleware: ::Lain::CLI::ToolGuard.detached(journal:).call(worker_env)
        )
      }
    end
  end
end
