# frozen_string_literal: true

# Records the mount's one call to {Lain::CLI::Backend#pipeline_source} and
# answers a real PipelineSource, so the mount behaves exactly as it does in
# production while the argument it owes -- `sink:` -- becomes assertable at the
# mount's own boundary. The alternative was reading three ivars down into a
# Compaction::Source (`@derived` -> `@strategy` -> `@sink`), which coupled the
# spec to two objects' internals to check one object's wiring.
module CompactionMountSpec
  class RecordingBackend
    attr_reader :sink, :journal, :cache_profile, :tool_observer

    def initialize(source: Lain::Agent::PipelineSource::Null,
                   tool_observer: Lain::Agent::ToolRunner::Observer::Null.new)
      @source = source
      @tool_observer = tool_observer
    end

    def pipeline_source(cache_profile:, journal:, sink:)
      @cache_profile = cache_profile
      @journal = journal
      @sink = sink
      @source
    end
  end
end

# The mount had no spec of its own: it was three keywords over a Backend, and
# `wiring_spec` covered it end to end. T9 gave it a fourth responsibility with
# a failure mode of its own -- routing a down summarizer's report somewhere an
# operator can see it -- and "the sink is threaded" is exactly the kind of claim
# that passes an end-to-end spec while being wired to the Null.
RSpec.describe Lain::CLI::CompactionMount do
  let(:channel) { RecordingChannel.new }
  let(:journal) { RecordingChannel.new }
  let(:chronicle) { Lain::CLI::Chronicle.new(journal:, journal_path: "mount-spec-fake-session.ndjson") }
  let(:provider) { Lain::Provider::Mock.new }

  def backend_for(**overrides)
    Lain::CLI::Backend.new({ provider: "ollama", model: "qwen3:4b", max_tokens: 64, **overrides })
  end

  def mount(backend, **overrides) = described_class.new(backend:, provider:, chronicle:, **overrides)

  it "hands the Agent the run's one source, eager observer and fed journal" do
    backend = backend_for
    instrumentation = mount(backend, channel:).instrumentation

    expect(instrumentation.pipeline_source).to be_a(Lain::Compaction::Source)
    expect(instrumentation.tool_observer).to be(backend.tool_observer)
    expect(instrumentation.journal).to be_a(Lain::CLI::JournalTee)
  end

  # The chronicle's own members ride through untouched -- the mount FOLDS
  # compaction into the value it was handed (`#with`), it does not mint a new
  # one and drop what the record needs. Without this, `--nvim`'s JournalRequests
  # phase would vanish the moment compaction was wired.
  it "carries the chronicle's own instrumentation through, folding compaction in" do
    instrumentation = mount(backend_for, channel:).instrumentation

    expect(instrumentation.model_middleware.to_a.map(&:class))
      .to eq([Lain::Middleware::JournalRequests])
  end

  # The seam this spec exists for. A `--compact-strategy` summarizer that is
  # DOWN leaves the span uncollapsed and reports it; with a Null sink that
  # report goes nowhere and is indistinguishable from compaction being off.
  #
  # Asserted at the mount's OWN boundary -- the one `Backend#pipeline_source`
  # call it makes -- rather than by reading three ivars down into a
  # Compaction::Source (`@derived` -> `@strategy` -> `@sink`). What the mount
  # owes is the sink argument; where the Source then keeps it is the Source's
  # business, and a spec that knew both broke on either.
  describe "the sink a down summarizer reports through" do
    def recording_backend = CompactionMountSpec::RecordingBackend.new

    def sink_handed_to(backend, **overrides)
      mount(backend, **overrides).instrumentation
      backend.sink
    end

    it "routes it to the run's live channel, where the frontend can paint it" do
      sink = sink_handed_to(recording_backend, channel:)

      expect(channel.events).to be_empty
      sink.puts("the summarizer is unreachable")

      expect(channel.events.grep(Lain::Telemetry::ToolOutput).map(&:bytes))
        .to eq(["the summarizer is unreachable\n"])
    end

    # Attributed apart from real tool output, so a reader of an nvim view or a
    # journal can tell a compaction diagnostic from a tool's stdout.
    it "attributes it to compaction, on stderr" do
      sink_handed_to(recording_backend, channel:).puts("down")

      reported = channel.events.grep(Lain::Telemetry::ToolOutput).last
      expect(reported.tool_use_id).to eq("lain:compaction")
      expect(reported.stream).to eq(:stderr)
    end

    # A caller with no frontend -- bench, headless -- is byte-identical to
    # before: the Null channel swallows it, and nothing raises.
    #
    # The `channel` is deliberately NOT passed to the mount here, so the second
    # assertion says what it has to say: a report written through the DEFAULT
    # sink reaches no channel the caller holds. Before T22's review it read
    # `expect(channel.events).to be_empty` against a `channel` that had never
    # been wired to anything -- an assertion that could not fail. The
    # `sink_handed_to(recording_backend, channel:)` sibling above is what proves
    # the same `channel` does receive when it IS wired, so these two together
    # are a difference and not an omission.
    it "degrades to the Null channel when no frontend is wired" do
      wired = sink_handed_to(recording_backend, channel:)
      unwired = sink_handed_to(recording_backend)

      wired.puts("wired")
      expect { unwired.puts("down") }.not_to raise_error

      expect(channel.events.grep(Lain::Telemetry::ToolOutput).map(&:bytes)).to eq(["wired\n"])
    end

    # The Source is fed the SAME journal the chronicle resolved, because
    # Compaction::Cold reads cache-read counts that exist only on a response --
    # the render seam has no route to them (see the class doc).
    it "hands the Backend the chronicle's own destination as the Source's journal" do
      backend = recording_backend
      mount(backend, channel:).instrumentation

      expect(backend.journal).to be(journal)
    end
  end

  it "tees nothing under --no-compact, where the source is a render strategy and not a sink" do
    instrumentation = mount(backend_for(compact: false), channel:).instrumentation

    expect(instrumentation.pipeline_source).to be(Lain::Agent::PipelineSource::Null)
  end

  # Under --no-compact the Source is not a `#<<` sink, so the tee has no sinks
  # and the journal the Agent gets is a pass-through onto the chronicle's own.
  it "still journals turn_usage under --no-compact, through a sink-less tee" do
    instrumentation = mount(backend_for(compact: false), channel:).instrumentation

    instrumentation.journal << Lain::Telemetry::TurnUsage.new(digest: "blake3:t1", model: nil,
                                                              stop_reason: :end_turn, usage: {})

    expect(journal.events.map(&:class)).to eq([Lain::Telemetry::TurnUsage])
  end
end
