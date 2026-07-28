# frozen_string_literal: true

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
    kwargs = mount(backend, channel:).agent_kwargs

    expect(kwargs[:pipeline_source]).to be_a(Lain::Compaction::Source)
    expect(kwargs[:tool_observer]).to be(backend.tool_observer)
    expect(kwargs[:journal]).to be_a(Lain::CLI::JournalTee)
  end

  # The seam this spec exists for. A `--compact-strategy` summarizer that is
  # DOWN leaves the span uncollapsed and reports it; with a Null sink that
  # report goes nowhere and is indistinguishable from compaction being off.
  describe "the sink a down summarizer reports through" do
    def strategy_of(built)
      built.agent_kwargs[:pipeline_source]
           .instance_variable_get(:@derived).instance_variable_get(:@strategy)
    end

    def sink_of(built) = strategy_of(built).instance_variable_get(:@sink)

    it "routes it to the run's live channel, where the frontend can paint it" do
      built = mount(backend_for(compact_strategy: "summarizing"), channel:)

      sink_of(built).puts("the summarizer is unreachable")

      expect(channel.events.grep(Lain::Telemetry::ToolOutput).map(&:bytes))
        .to eq(["the summarizer is unreachable\n"])
    end

    # Attributed apart from real tool output, so a reader of an nvim view or a
    # journal can tell a compaction diagnostic from a tool's stdout.
    it "attributes it to compaction, on stderr" do
      built = mount(backend_for(compact_strategy: "summarizing"), channel:)

      sink_of(built).puts("down")

      reported = channel.events.grep(Lain::Telemetry::ToolOutput).last
      expect(reported.tool_use_id).to eq("lain:compaction")
      expect(reported.stream).to eq(:stderr)
    end

    # A caller with no frontend -- bench, headless -- is byte-identical to
    # before: the Null channel swallows it, and nothing raises.
    it "degrades to the Null channel when no frontend is wired" do
      built = mount(backend_for(compact_strategy: "summarizing"))

      expect { sink_of(built).puts("down") }.not_to raise_error
      expect(channel.events).to be_empty
    end

    # The un-flagged run holds no strategy at all (see Backend::SpanSummarizer),
    # so there is nothing to report through -- and the mount must not fall over
    # building a sink for it.
    it "still builds cleanly for an un-flagged run, which holds no strategy" do
      expect(strategy_of(mount(backend_for, channel:))).to be_nil
    end
  end

  it "tees nothing under --no-compact, where the source is a render strategy and not a sink" do
    kwargs = mount(backend_for(compact: false), channel:).agent_kwargs

    expect(kwargs[:pipeline_source]).to be(Lain::Agent::PipelineSource::Null)
  end
end
