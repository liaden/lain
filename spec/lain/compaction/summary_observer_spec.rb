# frozen_string_literal: true

# Kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module SummaryObserverSpecSupport
  # Records what it was asked to summarize, so the observer's POLICY can be
  # pinned without a reactor -- whether a fire survives is {Oracle::Eager}'s
  # own question, answered by eager_spec.
  class RecordingEager
    attr_reader :fired

    def initialize
      @fired = []
    end

    def fire(digest, text)
      @fired << [digest, text]
    end
  end

  # The model-backed tier, reduced to what {Oracle::RoutedSummarizer} asks of
  # it, plus a count of the calls these examples exist to prove did not happen.
  class ModelTier
    attr_reader :calls

    def initialize(definition)
      @definition = definition
      @calls = 0
    end

    def ask(_inputs)
      @calls += 1
      @definition.answer(summary: "the model's summary")
    end

    def model = "test-summarizer-model"
    def usage = {}
  end
end

# The production observer {Agent::ToolRunner}'s post-dispatch seam is mounted
# with: which completed tool results earn an eager summary, and under which key.
# Wiring it over the run's one {Oracle::Eager} is {CLI::Backend#tool_observer}'s,
# and its placement after gather is pinned in tool_runner_spec.
RSpec.describe Lain::Compaction::SummaryObserver do
  let(:eager) { SummaryObserverSpecSupport::RecordingEager.new }

  def block_for(content, is_error: false)
    { "type" => "tool_result", "tool_use_id" => "tu_1", "content" => content, "is_error" => is_error }
  end

  def observing(content, is_error: false, tool_name: "bash")
    described_class.new(eager:).observe(block_for(content, is_error:), tool_name)
    eager.fired
  end

  def fired_for(content, tool_name: "bash")
    [Lain::Canonical.digest(content), Lain::Summarizer::Result.new(tool_name:, text: content)]
  end

  it "exposes the Eager it fires into, so the run's ONE store can be checked rather than assumed" do
    expect(described_class.new(eager:).eager).to be(eager)
  end

  # The digest stays the content address of the tool's own bytes -- what
  # {Compaction::SummarySnapshot} looks a summary up by -- while the fired
  # VALUE gains the tool name a custom summarizer routes on.
  it "fires a successful String result, keyed by its content address" do
    content = "x" * 5000

    expect(observing(content)).to eq([fired_for(content)])
  end

  it "carries the producing tool's name into the fired result" do
    content = "x" * 5000

    expect(observing(content, tool_name: "read_file")).to eq([fired_for(content, tool_name: "read_file")])
  end

  # An observation that cannot say WHICH tool ran must not route every result
  # as nameless -- that would silently disable every tool-keyed summarizer --
  # so the name is a required argument and its absence is an ArgumentError,
  # not a miss.
  it "refuses an observation with no tool name" do
    observer = described_class.new(eager:)

    expect { observer.observe(block_for("x" * 5000)) }.to raise_error(ArgumentError)
  end

  it "declines an error result however large -- a failure is not worth compressing" do
    expect(observing("x" * 5000, is_error: true)).to be_empty
  end

  # This seam holds no SIZE policy. It once declined below 4096 bytes, which
  # gated the project's own declared (free, token-less) summarizers behind the
  # MODEL tier's cost threshold and made them dead for every ordinary tool
  # result. The byte rule still exists, one layer down at
  # {Lain::Oracle::RoutedSummarizer::MODEL_THRESHOLD_BYTES}, where the tier
  # that pays for a fallthrough can apply it to the fallthrough alone.
  it "fires a small result, so the free tier is consulted for it" do
    expect(observing("small")).to eq([fired_for("small")])
  end

  # Array content is structured blocks, not free text: there is nothing for a
  # prose summarizer to compress.
  it "declines structured block (Array) content" do
    expect(observing([{ "type" => "text", "text" => "x" * 5000 }])).to be_empty
  end

  # A real Eager: the key is the content address, so the same bytes from two
  # different calls are ONE summary, however many tool_use ids produced them.
  it "fires once for repeated result content, keyed by its source digest" do
    oracle = Lain::Oracle::Heuristic.new(definition: Lain::Oracle::Summarize.definition(tier: :heuristic),
                                         predicate: ->(_inputs) { { "summary" => "once" } })
    counting = Class.new(SimpleDelegator) do
      def calls = (@calls ||= 0)

      def ask(inputs)
        @calls = calls + 1
        __getobj__.ask(inputs)
      end
    end.new(oracle)
    real = Lain::Oracle::Eager.new(oracle: counting)
    observer = described_class.new(eager: real)

    Sync do
      observer.observe(block_for("x" * 100).merge("tool_use_id" => "tu_1"), "read_file")
      observer.observe(block_for("x" * 100).merge("tool_use_id" => "tu_2"), "read_file")
    end

    expect(counting.calls).to eq(1)
  end

  # WHICH tier a fire lands on, through the real routing tier over a real
  # declared catalog -- no double between the observer and the decision. That
  # gap is where a dead free tier once hid: every unit was individually right
  # and the composition consulted the catalog for nothing an ordinary session
  # produced.
  describe "the tier a fired result actually reaches" do
    let(:small) { "tiny" }
    let(:model_tier) do
      SummaryObserverSpecSupport::ModelTier.new(Lain::Oracle::Summarize.definition(tier: :heuristic))
    end

    def declaration
      <<~RUBY
        summarizer "bash-only" do
          def suitable?(result) = result.tool_name == "bash"
          def compact(result) = "a bash result"
        end
      RUBY
    end

    def routed
      Lain::Oracle::RoutedSummarizer.new(
        inner: model_tier,
        catalog: Lain::Summarizer::Catalog.new(Lain::Summarizer::Builder.build(declaration, ".lain/summarizers.rb"))
      )
    end

    def fire(content, tool_name)
      real = Lain::Oracle::Eager.new(oracle: routed)
      described_class.new(eager: real).observe(block_for(content), tool_name)
      Async::Task.current.children&.each(&:wait)
      real.held(Lain::Canonical.digest(content))
    end

    it "answers a small declared result from the free tier, with no model call" do
      Sync do
        expect(fire(small, "bash").summary).to eq("a bash result")
        expect(model_tier.calls).to eq(0)
      end
    end

    it "spends no model call on a small result no declaration handles" do
      Sync do
        expect(fire(small, "read_file")).to be_nil
        expect(model_tier.calls).to eq(0)
      end
    end

    # The half of the policy that survives: over the cost threshold an
    # unhandled result is still worth asking a model about.
    it "still spends a model call on an unhandled result over the cost threshold" do
      Sync do
        bulky = "x" * (Lain::Oracle::RoutedSummarizer::MODEL_THRESHOLD_BYTES + 1)

        expect(fire(bulky, "read_file").summary).to eq("the model's summary")
        expect(model_tier.calls).to eq(1)
      end
    end
  end
end
