# frozen_string_literal: true

module Lain
  module CLI
    class Backend
      # WHICH policy a compacting {Compaction::Derivation} collapses a span
      # with, and -- when that policy is model-backed -- the tier it answers
      # through.
      #
      # Its own object for {Backend::Summarizer}'s reason and no other:
      # {Backend} sits at the {Metrics/ClassLength} cap and was deliberately
      # kept out of every card in this chunk because of it (CLAUDE.md: extract,
      # never loosen). Like that sibling it depends on MESSAGES rather than on
      # {Backend} -- `#summarizer_provider`, `#summarizer_model`,
      # `#summarizer_max_tokens`, `#journal` -- so the span tier and the eager
      # tier resolve their provider through the same validated seam and cannot
      # come to mean different things.
      #
      # == Why an unset flag is not {CompactionStrategy::DEFAULT}
      #
      # That constant answers "what does no `--compact-strategy` mean to the
      # RESOLVER", and resolving it here would answer a different question
      # wrongly. The un-flagged run already has a span policy: the eager tier,
      # fired per tool result by {Backend#tool_observer} off the turn's critical
      # path and read back through {Compaction::Source}'s per-turn
      # {Compaction::SummarySnapshot}. Resolving `summarizing` by default would
      # retire that whole ladder in silence and replace it with a fresh model
      # call per span at compaction time -- dearer, on the critical path, and
      # nobody asked for it.
      #
      # The stronger reason is the bench's own premise. A collapse strategy is a
      # SWAPPABLE ARM, and an arm that displaces the shipped path the moment it
      # exists cannot be compared against it. Opt-in keeps both live: the eager
      # tier is the control, `--compact-strategy` is the arm under test. So
      # naming a strategy OPTS IN to the seam; naming none keeps what the run
      # already pays for.
      #
      # == This is OPT-IN, and it is NOT the "unwired in production" pattern
      #
      # Read the sentence above carefully before concluding that
      # `--compact-strategy` is dead code. It is declared (`exe/lain`), read
      # (here), resolved ({CompactionStrategy}), injected ({Backend
      # #compaction_source}) and exercised end to end -- `spec/lain/cli/
      # backend_spec.rb`'s `--compact-strategy` group walks all five. The five
      # genuinely unwired objects this chunk's F7 catalogued have NO caller at
      # all; this one has a caller and a default that is a considered choice.
      # The difference matters because the two look identical from a grep for
      # `CompactionStrategy::DEFAULT`, which nothing in `lib/` reads.
      #
      # == The tier is a factory, built over the definition it is handed
      #
      # {CompactionStrategy}'s own doc argues this at length: the rule that
      # "one definition, two uses" holds is a rule only the CALLER can keep,
      # because nothing there can ask a built tier what definition it answers
      # through. This is that caller. It is emphatically NOT
      # {Backend#summary_oracle}, which is already {Oracle::Recorded::Journaling}
      # -wrapped and over {Oracle::Summarize}'s definition -- handing that in
      # would journal one question while the model answered another, with every
      # spec green.
      class SpanSummarizer
        # `--compact-strategy` read and resolved in one call, so the flag's KEY
        # lives with the object that already owns what its absence means rather
        # than at each caller. Two callers now: {Backend#compaction_source},
        # which builds the run's pipeline, and {ChatLaunch#preflight}, which
        # only wants to know whether the name is one lain can build. The
        # pre-flight cannot go through the pipeline for that -- it resolves the
        # window book off a live round trip, and a construction check must not
        # consult a server -- so the shared seam is HERE, one resolver over one
        # Backend, which is what keeps the two from meaning different things.
        #
        # @param backend [Backend] the run's flag resolution
        # @param options [Hash] the invoked command's parsed flags
        # @option options [String, nil] :compact_strategy the flag itself
        # @param sink [Lain::Sink] where a resolved policy reports a DOWN tier
        # @return [Compaction::Strategy::Base, nil] nil when no flag was given
        # @raise [CompactionStrategy::Unknown] on a name outside its set
        def self.resolve(backend:, options:, sink: Sink::Null.new)
          new(backend:, name: options[:compact_strategy], sink:).strategy
        end

        # @param backend [#summarizer_provider, #summarizer_model,
        #   #summarizer_max_tokens, #journal] the run's flag resolution
        # @param name [String, nil] `--compact-strategy`; nil means the flag
        #   was never given, which is not the same as naming its default
        # @param sink [Lain::Sink] where {Compaction::Strategy::Summarizing}
        #   reports a tier that is DOWN. It matters: with the Null sink "the
        #   summarizer is unreachable" and "compaction is off" look identical
        #   to an operator, because both leave the span uncollapsed.
        def initialize(backend:, name:, sink:)
          @backend = backend
          @name = name
          @sink = sink
        end

        # @return [Compaction::Strategy::Base, nil] nil when no flag was given
        def strategy
          return nil if @name.nil?

          CompactionStrategy.resolve(@name, tier: method(:tier), sink: @sink, journal: @backend.journal)
        end

        private

        # The live tier, over the definition {CompactionStrategy} hands in and
        # never one of this object's own. It answers the full
        # {Oracle::Model} duck, which is what {Oracle::Recorded::Journaling}
        # reads off its inner.
        def tier(definition)
          Oracle::Model.new(definition:, provider: @backend.summarizer_provider,
                            model: @backend.summarizer_model, max_tokens: @backend.summarizer_max_tokens)
        end
      end
    end
  end
end
