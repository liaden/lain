# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# The `.lain/summarizers.rb` declarations these drive, in the module-namespaced
# shape `oracle/routed_summarizer_spec.rb` uses -- a constant assigned inside an
# example group would land on Object.
module SpanSummarizerSpecSupport
  DECLARATIONS = {
    # Answers EVERY source, so "the free tier was consulted" and "the free tier
    # answered" are the same observation.
    everything: <<~RUBY,
      summarizer "everything" do
        def suitable?(_source) = true
        def compact(_source) = "the declaration's summary"
      end
    RUBY
    nothing: <<~RUBY
      summarizer "nothing" do
        def suitable?(_source) = false
        def compact(_source) = "unreachable"
      end
    RUBY
  }.freeze
end

# The tier `--compact-strategy=summarizing` collapses a span through, driven
# end to end: a real {Lain::CLI::Backend}, its real {Lain::CLI::CompactionStrategy}
# resolution, and the real {Lain::Compaction::Strategy::Summarizing} the Source
# is injected with. Nothing here hand-builds an oracle -- WHICH oracle the
# wiring constructs is the whole subject.
RSpec.describe Lain::CLI::Backend::SpanSummarizer do
  let(:journal) { RecordingChannel.new }
  let(:sink) { Lain::Sink::Null.new }

  # A span of CONVERSATION, which is what a compacting derivation offers a
  # strategy -- messages, never a tool result. That distinction is the whole of
  # the gap pinned at the foot of this file.
  let(:messages) do
    [{ "role" => "user", "content" => [{ "type" => "text", "text" => "what does the parser do?" }] },
     { "role" => "assistant", "content" => [{ "type" => "text", "text" => "it tokenizes, then folds" }] }]
  end

  # T10: a Backend on `--provider ollama` asks its server which window it is
  # serving before it builds the run's book ({Backend#context_window}), so
  # wiring a source here now makes one GET. Nothing in this file is about that
  # number -- "nothing resident" is the answer that leaves the conservative
  # fallback in charge, which is what every example here measured before.
  before do
    stub_request(:get, %r{/api/ps})
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: JSON.generate("models" => []))
  end

  # A local reply the summarizer schema accepts, so the model tier resolves
  # rather than dying on the wire -- and so "the model answered" is legible in
  # the collapsed block itself rather than only in the journal.
  def answering_provider
    reply = Lain::Response.new(content: [{ "type" => "text", "text" => %({"summary":"the model's summary"}) }],
                               stop_reason: :end_turn,
                               usage: Lain::Usage.new(input_tokens: 12, output_tokens: 7))
    Lain::Provider::Mock.new(responses: [reply])
  end

  # The project's own `.lain/summarizers.rb`. {Lain::Summarizer::Catalog.load}
  # reads `Dir.pwd`, so a declaration is only reachable from inside the
  # throwaway tree that holds it.
  def in_project_declaring(kind, &)
    Dir.mktmpdir("lain-span-summarizer") do |root|
      FileUtils.mkdir_p(File.join(root, ".lain"))
      File.write(File.join(root, ".lain", "summarizers.rb"), SpanSummarizerSpecSupport::DECLARATIONS.fetch(kind))
      Dir.chdir(root, &)
    end
  end

  # The strategy the run is actually wired with, reached the way the live path
  # reaches it: {Lain::CLI::Backend#pipeline_source} builds the Source, and the
  # Source holds the derivation the strategy was injected into.
  def wired_strategy(backend)
    backend.pipeline_source(cache_profile: Lain::CacheProfile::NO_CACHING, journal:, sink:)
           .instance_variable_get(:@derived).instance_variable_get(:@strategy)
  end

  def summarizing_backend
    Lain::CLI::Backend.new(provider: "ollama", model: "qwen3:4b", max_tokens: 64,
                           compact_strategy: "summarizing").tap do |backend|
      allow(backend).to receive(:summarizer_provider).and_return(answering_provider)
    end
  end

  def answers = journal.events.grep(Lain::Telemetry::OracleAnswer)

  def collapsed(strategy) = Sync { strategy.blocks(messages) }.map { |block| block["text"] }

  # T9: the flag's KEY lives here, so the pipeline that builds the run and the
  # construction check `lain up` makes before it creates a session resolve
  # `--compact-strategy` through one object. See {Lain::CLI::ChatLaunch
  # #preflight} for why that check cannot reach it through
  # {Lain::CLI::Backend#pipeline_source} instead.
  describe ".resolve" do
    def flags(**overrides) = { provider: "ollama", model: "qwen3:4b", max_tokens: 64 }.merge(overrides)

    it "reads --compact-strategy out of the flag set it is handed" do
      strategy = described_class.resolve(backend: summarizing_backend, options: flags(compact_strategy: "elide"))

      expect(strategy).to be_a(Lain::Compaction::Strategy::Elide)
    end

    it "answers nil for a flag set naming none, exactly as the constructor does" do
      expect(described_class.resolve(backend: summarizing_backend, options: flags)).to be_nil
    end

    it "refuses an unknown name in the flag's own words" do
      expect { described_class.resolve(backend: summarizing_backend, options: flags(compact_strategy: "nope")) }
        .to raise_error(Lain::CLI::CompactionStrategy::Unknown, /--compact-strategy/)
    end
  end

  describe "the tier a named strategy resolves to" do
    it "answers nil for an un-flagged run rather than resolving the resolver's default" do
      expect(described_class.new(backend: summarizing_backend, name: nil, sink:).strategy).to be_nil
    end

    # Built over the definition {Lain::CLI::CompactionStrategy} hands in and
    # never one of this object's own -- the "one definition, two uses" rule only
    # this caller can keep, since nothing downstream can ask a built tier what
    # definition it answers through.
    it "builds its live tier over the strategy's own definition" do
      tier = wired_strategy(summarizing_backend).instance_variable_get(:@oracle)
                                                .instance_variable_get(:@inner)

      expect(tier).to be_a(Lain::Oracle::Model)
      expect(tier.instance_variable_get(:@definition).digest)
        .to eq(Lain::Compaction::Strategy::Summarizing.definition.digest)
    end

    it "resolves the summarizer flags through the Backend, not a second copy" do
      backend = Lain::CLI::Backend.new(provider: "ollama", model: "qwen3:4b", max_tokens: 64,
                                       summarizer_model: "qwen3:8b", summarizer_max_tokens: 256,
                                       compact_strategy: "summarizing")
      tier = wired_strategy(backend).instance_variable_get(:@oracle).instance_variable_get(:@inner)

      expect(tier.model).to eq("qwen3:8b")
      expect(tier.instance_variable_get(:@max_tokens)).to eq(256)
    end
  end

  describe "collapsing a span through the model tier" do
    it "carries the model's summary into the replacement" do
      in_project_declaring(:nothing) do
        expect(collapsed(wired_strategy(summarizing_backend))).to eq(["the model's summary"])
      end
    end

    it "journals exactly one oracle_answer for it" do
      in_project_declaring(:nothing) do
        collapsed(wired_strategy(summarizing_backend))
      end

      expect(answers.size).to eq(1)
    end
  end

  # == T5's GAP, recorded rather than fixed
  #
  # These pin what `--compact-strategy=summarizing` does NOT do, in the shape
  # {Lain::Compaction::Strategy::Summarizing}'s own refutations use: a negative
  # is worth more in a spec a walk of the tree reaches than in a comment a later
  # reader tidies away. They are a DEFECT under glass, not a design being
  # blessed -- do not read a green run here as "the free tier is wired".
  #
  # T5 set out to route this strategy through {Lain::Oracle::RoutedSummarizer},
  # so a project's own `.lain/summarizers.rb` could collapse a span for free.
  # It cannot, and the reason is one layer down rather than in the wiring:
  # {Lain::Compaction::Strategy::Summarizing#question} is `Canonical.dump`
  # of the span, a bare String, while the router routes on `#tool_name` --
  # which only {Lain::Summarizer::Result} carries, and which only
  # {Lain::Effect::Handler::Summarizing::Observer} ever builds, per tool
  # result. So a router wrapped around this tier falls straight through on
  # every span and changes nothing.
  #
  # Closing it means giving the span boundary a routable source, which is a
  # contract change and not a wiring one: a declaration's `suitable?` would
  # start being asked about a stretch of conversation rather than a tool
  # result, and the size gate on {Lain::Oracle::RoutedSummarizer
  # ::MODEL_THRESHOLD_BYTES} would then apply here -- whose decline resolves to
  # nil, which `#asked` reads `.summary` off. See that constant's own warning.
  describe "the project's declared free tier, which a span never reaches" do
    it "collapses through the model even where a declaration answers everything" do
      in_project_declaring(:everything) do
        expect(collapsed(wired_strategy(summarizing_backend))).to eq(["the model's summary"])
      end
    end

    it "bills a model call for a span a declaration would have answered for free" do
      in_project_declaring(:everything) do
        collapsed(wired_strategy(summarizing_backend))
      end

      expect(answers.size).to eq(1)
    end

    # The mechanical reason, so a reader sees WHY rather than only THAT.
    it "hands the oracle a bare String span source, carrying no tool name to route on" do
      source = wired_strategy(summarizing_backend).question(messages)

      expect(source).to be_a(String)
      expect(source).not_to respond_to(:tool_name)
    end
  end
end
