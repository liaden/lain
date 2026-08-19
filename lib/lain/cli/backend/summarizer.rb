# frozen_string_literal: true

module Lain
  module CLI
    class Backend
      # WHICH tier compresses a tool result, and WHERE its spend is recorded.
      #
      # Its own object because the summarizer is a SECOND, independent model
      # tier: a provider, a model and a token ceiling of its own, none of them
      # the chat's. Folding a second set of those into {Backend} is what a
      # Metrics cop would have called out, and the cop would have been right --
      # an object was missing (CLAUDE.md: extract, never loosen).
      #
      # It depends on MESSAGES, not on {Backend}: `#summarizer_provider`,
      # `#summarizer_model`, `#summarizer_max_tokens`, `#journal`. Backend owns
      # those because turning flags into a validated provider name is Backend's
      # whole job -- and the summarizer's name resolves through the SAME
      # PROVIDERS set `--provider` does, so the two flags cannot come to mean
      # different things.
      class Summarizer
        # @param backend [#summarizer_provider, #summarizer_model,
        #   #summarizer_max_tokens, #journal] the run's flag resolution
        def initialize(backend:)
          @backend = backend
        end

        # The tier {Oracle::Eager} fires through, nested
        # `Journaling(Model)` -- journaling OUTERMOST of what is built HERE, so
        # every answer the live tier paid for reaches the record. A router that
        # substitutes answers belongs ABOVE this whole thing, where an answer it
        # invents never lands on a record as though a model had been billed for
        # it.
        def oracle
          definition = Oracle::Summarize.definition
          Oracle::Recorded::Journaling.new(inner: tier(definition), definition:,
                                           journal: RunJournal.new(@backend))
        end

        private

        # `queue: false` is open decision 4, and this is the ONLY place it is
        # asked for. This tier is the one {Oracle::Eager} fires through, and
        # `oracle/eager.rb:45-47` promises the turn that produced a tool result
        # never waits on its summary -- so when the endpoint is busy the summary
        # is SKIPPED rather than queued. A queued fire is the worse failure: it
        # is reaped at teardown having burnt its digest for the whole session,
        # while a skip is a miss {Compaction::SummarySnapshot} already models.
        #
        # {Backend::SpanSummarizer#tier} calls the same `#summarizer_provider`
        # and deliberately does NOT pass this: it answers on the render path,
        # where the summary is worth waiting for.
        def tier(definition)
          Oracle::Model.new(definition:, provider: @backend.summarizer_provider(queue: false),
                            model: @backend.summarizer_model, max_tokens: @backend.summarizer_max_tokens)
        end

        # The run's journal, resolved per EVENT instead of captured at
        # construction.
        #
        # Nothing orders {Backend#tool_observer} -- which builds the run's one
        # {Oracle::Eager}, and with it this oracle -- against
        # {Backend#pipeline_source}, which is where the run's journal gets
        # bound. {CompactionMount} happens to reach the journal first only
        # because a Hash literal evaluates left to right. A wrap that captured
        # its destination eagerly would therefore hold `Channel::Null` for the
        # whole run under any other call order: every summary answered, none
        # recorded, nothing raised. Late binding costs one forwarding hop and a
        # summary does not fire until a turn runs, long after both calls.
        class RunJournal
          def initialize(backend) = @backend = backend

          def <<(event) = @backend.journal << event
        end
      end
    end
  end
end
