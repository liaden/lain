# frozen_string_literal: true

module Lain
  module CLI
    class Backend
      # WHICH tier compresses a tool result, and WHERE its spend is recorded.
      #
      # Its own object because the summarizer is a SECOND, independent model
      # tier: a provider, a model and a token ceiling of its own, none of them
      # the chat's. It depends on MESSAGES, not on {Backend}, and its name
      # resolves through the SAME PROVIDERS set `--provider` does, so the two
      # flags cannot come to mean different things.
      class Summarizer
        # @param backend [#summarizer_provider, #summarizer_model,
        #   #summarizer_max_tokens, #summarizer_options, #journal] the run's
        #   flag resolution
        def initialize(backend:)
          @backend = backend
        end

        # The tier {Oracle::Eager} fires through: journaling OUTERMOST of what
        # is built HERE, so every answer the live tier paid for reaches the
        # record. A router that substitutes answers belongs ABOVE this whole
        # thing, where an answer it invents never lands on the record as though
        # a model had been billed for it.
        def oracle
          definition = Oracle::Summarize.definition
          Oracle::Recorded::Journaling.new(inner: tier(definition), definition:,
                                           journal: RunJournal.new(@backend))
        end

        private

        # `queue: false` is asked for HERE and nowhere else. {Oracle::Eager}
        # promises the turn that produced a tool result never waits on its
        # summary, so when the endpoint is busy the summary is SKIPPED rather
        # than queued: a queued fire is reaped at teardown having burnt its
        # digest for the whole session, while a skip is a miss
        # {Compaction::SummarySnapshot} already models.
        # {Backend::SpanSummarizer#tier} calls the same `#summarizer_provider`
        # and deliberately does NOT pass this -- it answers on the render path,
        # where the summary is worth waiting for.
        #
        # The {Provider::Journaled} wrap is what puts this tier's QUESTION on
        # the record; the {Oracle::Recorded::Journaling} above records only the
        # answer, since {Oracle::Model} calls `#complete` directly with no
        # middleware stack between them. It goes INSIDE, nearest the wire, so
        # the record is cut from the Request the provider was actually handed.
        def tier(definition)
          provider = Provider::Journaled.new(provider: @backend.summarizer_provider(queue: false),
                                             journal: RunJournal.new(@backend))
          Oracle::Model.new(definition:, provider:, model: @backend.summarizer_model,
                            max_tokens: @backend.summarizer_max_tokens, extra: @backend.summarizer_options)
        end

        # The run's journal, resolved per EVENT instead of captured at
        # construction.
        #
        # Nothing orders {Backend#tool_observer} -- which builds the run's one
        # {Oracle::Eager}, and with it this oracle -- against
        # {Backend#pipeline_source}, where the run's journal gets bound;
        # {CompactionMount} reaches the journal first only because a Hash
        # literal evaluates left to right. A wrap that captured its destination
        # eagerly would hold `Channel::Null` for the whole run under any other
        # call order: every summary answered, none recorded, nothing raised.
        class RunJournal
          def initialize(backend) = @backend = backend

          def <<(event) = @backend.journal << event
        end
      end
    end
  end
end
