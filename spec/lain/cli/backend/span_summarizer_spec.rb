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

  # A Backend on `--provider ollama` asks its server which window it is
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
    Lain::CLI::Backend.new({ provider: "ollama", model: "qwen3:4b", max_tokens: 64,
                             compact_strategy: "summarizing" }).tap do |backend|
      allow(backend).to receive(:summarizer_provider).and_return(answering_provider)
    end
  end

  def answers = journal.events.grep(Lain::Telemetry::OracleAnswer)

  def collapsed(strategy) = Sync { strategy.blocks(messages) }.map { |block| block["text"] }

  # The flag's KEY lives here, so the pipeline that builds the run and the
  # construction check `lain up` makes before it creates a session resolve
  # `--compact-strategy` through one object. See {Lain::CLI::ChatLaunch
  # #preflight} for why that check cannot reach it through
  # {Lain::CLI::Backend#pipeline_source} instead.
  describe ".resolve" do
    def flags(**overrides) = { provider: "ollama", model: "qwen3:4b", max_tokens: 64 }.merge(overrides)

    it "reads --compact-strategy out of the flag set it is handed" do
      chosen = described_class.resolve(backend: summarizing_backend, options: flags(compact_strategy: "elide"))

      expect(chosen.policy).to be_a(Lain::Compaction::Strategy::Elide)
    end

    # The policy alone cannot be journalled by name: `Strategy::Base#name`
    # answers a CLASS name, and a composition answers two of them joined by
    # ` | `, neither of which is what an operator typed or what a bench groups
    # its arms by. So the flag's own string travels beside the policy, in the
    # slot {Lain::Compaction::Source} already takes -- {Lain::CLI::Backend} is
    # at the `Metrics/ClassLength` cap and can carry no second keyword.
    it "carries the operator's own word beside the policy it resolved" do
      chosen = described_class.resolve(backend: summarizing_backend,
                                       options: flags(compact_strategy: "elide-tools+summarize-conversation"))

      expect(chosen.name).to eq("elide-tools+summarize-conversation")
      expect(chosen.policy).to be_a(Lain::Compaction::Strategy::Composed)
    end

    # The policy is still nil for an un-flagged run -- naming a strategy is what
    # opts into the seam, and resolving one here would retire the eager tier in
    # silence. What is NOT nil is the name: that run is the control arm, and a
    # nil there would be indistinguishable in the journal from a record written
    # before the field existed.
    it "answers the eager control arm for a flag set naming none, rather than nothing at all" do
      chosen = described_class.resolve(backend: summarizing_backend, options: flags)

      expect(chosen.policy).to be_nil
      expect(chosen.name).to eq(Lain::Telemetry::Compaction::EAGER_CONTROL_ARM)
    end

    it "refuses an unknown name in the flag's own words" do
      expect { described_class.resolve(backend: summarizing_backend, options: flags(compact_strategy: "nope")) }
        .to raise_error(Lain::CLI::CompactionStrategy::Unknown, /--compact-strategy/)
    end
  end

  # The examples above pin what `.resolve` ANSWERS. This one pins that the
  # answer survives the one hop that matters: {Lain::CLI::Backend
  # #compaction_source} drops it into the slot {Lain::Compaction::Source}
  # already took a bare policy in, so the built pipeline source -- the object a
  # compacting turn journals from -- can name the arm without {Lain::CLI::
  # Backend} growing a second keyword it has no `Metrics/ClassLength` left for.
  describe "the arm the built pipeline source names" do
    # `elide-tools` and not `summarizing`: it resolves with no oracle tier, so
    # what this example measures is the wiring and nothing about a summarizer.
    it "carries the operator's own word through to the source the run compacts with" do
      backend = Lain::CLI::Backend.new({ provider: "ollama", model: "qwen3:4b", max_tokens: 64,
                                         compact_strategy: "elide-tools" })

      built = backend.pipeline_source(cache_profile: Lain::CacheProfile::NO_CACHING, journal:, sink:)

      expect(built.collapse_strategy).to eq("elide-tools")
    end

    it "names the eager control arm for a run launched with no flag at all" do
      backend = Lain::CLI::Backend.new({ provider: "ollama", model: "qwen3:4b", max_tokens: 64 })

      built = backend.pipeline_source(cache_profile: Lain::CacheProfile::NO_CACHING, journal:, sink:)

      expect(built.collapse_strategy).to eq(Lain::Telemetry::Compaction::EAGER_CONTROL_ARM)
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
      backend = Lain::CLI::Backend.new({ provider: "ollama", model: "qwen3:4b", max_tokens: 64,
                                         summarizer_model: "qwen3:8b", summarizer_max_tokens: 256,
                                         compact_strategy: "summarizing" })
      tier = wired_strategy(backend).instance_variable_get(:@oracle).instance_variable_get(:@inner)

      expect(tier.model).to eq("qwen3:8b")
      expect(tier.instance_variable_get(:@max_tokens)).to eq(256)
    end
  end

  # The SPAN tier's half of the pair. Its sibling
  # {Lain::CLI::Backend::Summarizer} is pinned in its own file, and the two are
  # deliberately not collapsed into one: they call the same
  # `#summarizer_provider` with opposite `queue:` answers, and an eager tier that
  # started queueing would be the same self-inflicted stall -- the turn that
  # produced a tool result waiting on its summary.
  describe "the record a collapsed span leaves" do
    it "journals the request_sent its round trip spent, over the summarizer's model" do
      in_project_declaring(:nothing) { collapsed(wired_strategy(summarizing_backend)) }

      sent = journal.events.grep(Lain::Telemetry::RequestSent)
      expect(sent.size).to eq(1)
      expect(sent.last.payload).to include("model" => "qwen3:4b")
    end

    # `no_args` IS the assertion: `#tier` here passes no `queue:` at all, taking
    # {Lain::CLI::Backend#summarizer_provider}'s default of true. This tier
    # answers on the RENDER path, where the summary is worth waiting for.
    it "asks for a provider willing to WAIT for capacity, unlike the eager tier" do
      backend = summarizing_backend

      in_project_declaring(:nothing) { collapsed(wired_strategy(backend)) }

      expect(backend).to have_received(:summarizer_provider).with(no_args)
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

    # The span tier shares the eager tier's runner rule, resolved by the same
    # Backend: on the chat's own model a collapse is one more request that
    # runner answers, and without the chat's batch size it would reload it.
    it "journals a request carrying the chat's batch size, and not its temperature" do
      backend = Lain::CLI::Backend.new({ provider: "ollama", model: "qwen3:4b", max_tokens: 64, num_batch: 2048,
                                         temperature: 0.2, compact_strategy: "summarizing" })
      allow(backend).to receive(:summarizer_provider).and_return(answering_provider)

      in_project_declaring(:nothing) { collapsed(wired_strategy(backend)) }

      extra = journal.events.grep(Lain::Telemetry::RequestSent).last.extra
      expect(extra).to include("num_batch" => 2048)
      expect(extra).not_to have_key("temperature")
    end
  end

  # == THE GAP, recorded rather than fixed
  #
  # These pin what `--compact-strategy=summarizing` does NOT do, in the shape
  # {Lain::Compaction::Strategy::Summarizing}'s own refutations use: a negative
  # is worth more in a spec a walk of the tree reaches than in a comment a later
  # reader tidies away. They are a DEFECT under glass, not a design being
  # blessed -- do not read a green run here as "the free tier is wired".
  #
  # This strategy was meant to route through {Lain::Oracle::RoutedSummarizer},
  # so a project's own `.lain/summarizers.rb` could collapse a span for free.
  # It cannot, and the reason is one layer down rather than in the wiring:
  # {Lain::Compaction::Strategy::Summarizing#question} is `Canonical.dump`
  # of the span, a bare String, while the router routes on `#tool_name` --
  # which only {Lain::Summarizer::Result} carries, and which only
  # {Lain::Compaction::SummaryObserver} ever builds, per tool
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
