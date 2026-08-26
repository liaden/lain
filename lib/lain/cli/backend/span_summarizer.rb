# frozen_string_literal: true

module Lain
  module CLI
    class Backend
      # WHICH policy a compacting {Compaction::Derivation} collapses a span
      # with, and -- when that policy is model-backed -- the tier it answers
      # through.
      #
      # Like {Backend::Summarizer} it depends on MESSAGES rather than on
      # {Backend}, so the span tier and the eager tier resolve their provider
      # through the same validated seam and cannot come to mean different
      # things.
      #
      # == Why an unset flag is not {CompactionStrategy::DEFAULT}
      #
      # The un-flagged run already has a span policy: the eager tier, fired per
      # tool result by {Backend#tool_observer} off the turn's critical path and
      # read back through {Compaction::Source}'s per-turn
      # {Compaction::SummarySnapshot}. Resolving `summarizing` by default would
      # retire that whole ladder in silence and replace it with a fresh model
      # call per span at compaction time -- dearer, and on the critical path.
      #
      # The stronger reason is the bench's own premise. A collapse strategy is a
      # SWAPPABLE ARM, and an arm that displaces the shipped path the moment it
      # exists cannot be compared against it. Opt-in keeps both live: the eager
      # tier is the control, `--compact-strategy` is the arm under test.
      #
      # So `--compact-strategy` is opt-in, NOT dead code -- it is declared in
      # `exe/lain`, read here, resolved by {CompactionStrategy}, injected by
      # {Backend#compaction_source} and exercised end to end. The two look
      # identical from a grep for `CompactionStrategy::DEFAULT`, which nothing
      # in `lib/` reads.
      #
      # == The tier is a factory, built over the definition it is handed
      #
      # "One definition, two uses" is a rule only the CALLER can keep, because
      # nothing downstream can ask a built tier what definition it answers
      # through. This is that caller, and it is emphatically NOT
      # {Backend#summary_oracle}, which is already
      # {Oracle::Recorded::Journaling}-wrapped and over {Oracle::Summarize}'s
      # definition -- handing that in would journal one question while the model
      # answered another, with every spec green.
      class SpanSummarizer
        # `--compact-strategy` read and resolved in one call, so the flag's KEY
        # lives with the object that owns what its absence means. Its second
        # caller, {ChatLaunch#preflight}, cannot go through the pipeline to
        # check a name: that resolves the window book off a live round trip, and
        # a construction check must not consult a server.
        #
        # @param backend [Backend] the run's flag resolution
        # @param options [Hash] the invoked command's parsed flags
        # @param sink [Lain::Sink] where a resolved policy reports a DOWN tier
        # @option options [String, nil] :compact_strategy the flag itself
        # @return [Compaction::Source::Collapse] the resolved policy and the
        #   word for the arm it makes; the eager control arm when no flag was
        #   given, never nil
        # @raise [CompactionStrategy::Unknown] on a name outside its set
        def self.resolve(backend:, options:, sink: Sink::Null.new)
          new(backend:, name: options[:compact_strategy], sink:).collapse
        end

        # @param backend [#summarizer_provider, #summarizer_model,
        #   #summarizer_max_tokens, #journal] the run's flag resolution
        # @param name [String, nil] `--compact-strategy`; nil means the flag
        #   was never given, which is not the same as naming its default
        # @param sink [Lain::Sink] where {Compaction::Strategy::Summarizing}
        #   reports a tier that is DOWN. With the Null sink "the summarizer is
        #   unreachable" and "compaction is off" look identical to an operator,
        #   because both leave the span uncollapsed.
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

        # The CHOICE, not merely the policy, which is how
        # `--compact-strategy`'s own string reaches the compaction record
        # without a second keyword on {Backend#compaction_source}.
        #
        # It has to travel because the {Compaction::Scheduler} that journals a
        # compaction is handed a PIPELINE rather than a policy, and because the
        # policy could not answer for itself anyway: `Strategy::Base#name` is a
        # CLASS name, and a composition's is two of them joined by ` | ` --
        # neither what an operator typed nor what a bench groups its arms by.
        #
        # `@name` VERBATIM: {CompactionStrategy} has already refused anything
        # outside its own set by the time `#strategy` answers, so what is left
        # is exactly the flag's value, `+`-composition and all.
        #
        # @return [Compaction::Source::Collapse]
        def collapse = Compaction::Source::Collapse.new(policy: strategy, name: @name)

        private

        # The live tier, over the definition {CompactionStrategy} hands in and
        # never one of this object's own.
        #
        # `#summarizer_provider` is called with NO `queue:` at all, which is the
        # distinction from {Backend::Summarizer#tier} and not an omission: this
        # tier answers on the render path, where a summary is worth waiting for.
        # Passing `queue: false` here is how two round trips end up overlapping
        # on a one-slot local server. The {Provider::Journaled} wrap is what
        # puts the tier's QUESTION on the record; the sibling records why.
        #
        # `@backend.journal` is read here rather than captured at construction
        # because of an ORDERING nothing asserts: this factory runs while
        # {CompactionStrategy.resolve} BUILDS, and what makes the read safe is
        # that {Backend#pipeline_source} assigns `@journal` on the statement
        # before it calls `#compaction_source`. Reading per call costs one hop
        # and keeps a reordering from silently binding Channel::Null for the
        # run.
        def tier(definition)
          provider = Provider::Journaled.new(provider: @backend.summarizer_provider, journal: @backend.journal)
          Oracle::Model.new(definition:, provider:,
                            model: @backend.summarizer_model, max_tokens: @backend.summarizer_max_tokens)
        end
      end
    end
  end
end
