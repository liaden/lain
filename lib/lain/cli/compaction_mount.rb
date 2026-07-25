# frozen_string_literal: true

module Lain
  module CLI
    # How a chat's compaction machinery attaches to its Agent, lifted out of
    # {Wiring} for the reason every other extraction there was made (CLAUDE.md:
    # a tripped Metrics cop names a missing object; extract, never loosen).
    # {Backend} decides WHAT the run compacts with -- the source, the eager
    # store, the observer, all memoized run state; this decides where those
    # three plug in, which is three different seams on the same `Agent.new`.
    #
    # The third one is the reason this is an object rather than three keywords.
    # `Compaction::Source#context_for` is handed A2's LAST-TURN input tokens, an
    # Integer, but {Compaction::Cold} reads a {Telemetry::TurnUsage}'s
    # `cache_read_input_tokens`, and the render seam has no route to it -- the
    # count exists only on a model RESPONSE. So the Source is ALSO a `#<<` sink
    # and rides the Agent's own turn_usage journal through a {JournalTee},
    # exactly as {StatusFeed} rides the live-view tee.
    #
    # Skip that tee and nothing fails: compaction still fires on the byte
    # threshold, the hard cap and the window. But `Cold` is never fed, so the
    # `:cold` decision path is dead on the live path and every compaction
    # journals `cache_state: forced` -- quietly turning one of the bench's
    # comparison arms into an arm that measures nothing.
    class CompactionMount
      # @param backend [CLI::Backend] owns the memoized source/eager/observer
      # @param provider [#cache_profile] the CHAT provider, asked for its cache
      #   economics only -- {Compaction::Cold} needs a real TTL to compare idle
      #   time against, and a TTL-less provider confirms cold off the zero
      #   cache-read alone. Injected rather than rebuilt from the Backend so
      #   the profile is the one the run actually talks to.
      # @param chronicle [CLI::Chronicle] resolves the telemetry destinations
      def initialize(backend:, provider:, chronicle:)
        @backend = backend
        @provider = provider
        @telemetry = chronicle.telemetry_kwargs
      end

      # The chronicle's telemetry keywords with compaction folded in: the same
      # `model_middleware`, a `journal` that also feeds the source, and the two
      # collaborators {Agent} defaults to Nulls.
      #
      # @return [Hash] keywords for `Agent.new`
      def agent_kwargs
        @telemetry.merge(journal: fed_journal, pipeline_source: source, tool_observer: @backend.tool_observer)
      end

      private

      # The Source's own records cannot loop back through here: a
      # {Compaction::Source::CompactionDecision} answers neither `#usage` nor
      # `#stop_reason`, so the Source is inert on re-entry.
      def fed_journal = JournalTee.new(destination, *sinks)

      # Where the chronicle puts turn_usage: the session journal, the --nvim
      # tee, or -- under --no-journal, which passes no `journal:` at all -- the
      # same Null channel {Agent} would have defaulted to.
      def destination = @telemetry.fetch(:journal) { Channel::Null.instance }

      # `--no-compact` leaves {Agent::PipelineSource::Null} in place, and that
      # is a render strategy, not a sink; teeing it would turn every journaled
      # turn into a {JournalTee} sink failure. An empty sink list makes the tee
      # the pass-through it should be, so the off switch changes nothing.
      def sinks = source.respond_to?(:<<) ? [source] : []

      def source
        @source ||= @backend.pipeline_source(cache_profile: @provider.cache_profile, journal: destination)
      end
    end
  end
end
