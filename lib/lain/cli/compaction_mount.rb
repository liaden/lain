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
      # @param channel [Lain::Channel] the run's live Channel, which the
      #   frontend paints. It is here for ONE line: a `--compact-strategy`
      #   summarizer that is DOWN leaves the span uncollapsed and says so, and
      #   with nowhere to say it "the summarizer is unreachable" and
      #   "compaction is off" are the same silence to an operator -- both just
      #   stop shrinking the prompt. Defaults to the Null channel so a caller
      #   with no frontend (bench, headless) is byte-identical to before.
      def initialize(backend:, provider:, chronicle:, channel: Channel::Null.instance)
        @backend = backend
        @provider = provider
        @channel = channel
        @telemetry = chronicle.instrumentation
      end

      # The chronicle's own {Agent::Instrumentation} with compaction folded in:
      # the same `model_middleware`, a `journal` that also feeds the source, and
      # the two members the chronicle left at their Nulls. `#with`, not a fresh
      # value, because what the RECORD needs must survive what compaction adds.
      #
      # @return [Lain::Agent::Instrumentation] the value `Agent.new` takes
      def instrumentation
        @telemetry.with(journal: fed_journal, pipeline_source: source, tool_observer: @backend.tool_observer)
      end

      private

      # The Source's own records cannot loop back through here: a
      # {Compaction::Source::CompactionDecision} answers neither `#usage` nor
      # `#stop_reason`, so the Source is inert on re-entry.
      def fed_journal = JournalTee.new(destination, *sinks)

      # Where the chronicle puts turn_usage: the session journal, the --nvim
      # tee, or -- under --no-journal -- the Null channel its instrumentation
      # carries, which is the same one {Agent} would have defaulted to.
      def destination = @telemetry.journal

      # `--no-compact` leaves {Agent::PipelineSource::Null} in place, and that
      # is a render strategy, not a sink; teeing it would turn every journaled
      # turn into a {JournalTee} sink failure. An empty sink list makes the tee
      # the pass-through it should be, so the off switch changes nothing.
      def sinks = source.respond_to?(:<<) ? [source] : []

      def source
        @source ||= @backend.pipeline_source(cache_profile: @provider.cache_profile, journal: destination,
                                             sink: diagnostics)
      end

      # The one route from `lib/` to an operator's screen: the frontend renders
      # exactly one event ({Telemetry::ToolOutput}, `decorators.rb:18`), and
      # {Sink::IOAdapter} is what turns an IO-shaped `#puts` into one. So the
      # attribution is SYNTHETIC and deliberately so -- there is no tool call
      # here, and a diagnostic routed anywhere the frontend does not render is
      # {Sink::Null} with extra steps. `:stderr`, because a summarizer that
      # cannot be reached is a fault report and not part of the conversation.
      def diagnostics = Sink::IOAdapter.new(@channel, tool_use_id: DIAGNOSTICS, stream: :stderr)

      # Stable and NAMESPACED, so a reader grepping a journal or an nvim view
      # can filter these apart from real tool output exactly rather than
      # probably: {Provider::Ollama} mints `call["id"] || "ollama-tool-#{index}"`
      # for a local model that answered without one, so a bare "compaction" is a
      # string a model could produce. `lain:` is a prefix nothing else emits.
      DIAGNOSTICS = "lain:compaction"
      private_constant :DIAGNOSTICS
    end
  end
end
