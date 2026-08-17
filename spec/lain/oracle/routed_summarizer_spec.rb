# frozen_string_literal: true

require "async"

# A3: the free tier is consulted BEFORE the model tier. {Lain::Summarizer::Catalog}
# holds the project's declared summarizers; this tier asks it first and falls
# through to the model-backed tier whenever the catalog cannot (or will not)
# answer. It is the OUTERMOST wrap, above {Lain::Oracle::Recorded::Journaling},
# so a custom answer is never journalled as an oracle call that a model was
# billed for.
#
# The fixtures live out here rather than in the RSpec block
# (Lint/ConstantDefinitionInBlock).
module RoutedSummarizerSpecSupport
  # The declarations a project would write in `.lain/summarizers.rb`, one per
  # behaviour this tier has to have an answer for.
  DECLARATIONS = {
    # `suitable?` reads the TEXT, which is the axis a coverage report and a
    # build log divide on -- both are `bash`.
    coverage: <<~RUBY,
      summarizer "coverage" do
        def suitable?(result) = result.text.include?("Coverage report")
        def compact(result) = "coverage: 94.2% of lines"
      end
    RUBY
    # Suitability keyed on the TOOL, which is the half of {Summarizer::Result}
    # this card exists to deliver: identical text from another tool must miss.
    by_tool: <<~RUBY,
      summarizer "bash-only" do
        def suitable?(result) = result.tool_name == "bash"
        def compact(result) = "a bash result"
      end
    RUBY
    raising_compact: <<~RUBY,
      summarizer "broken-compact" do
        def suitable?(result) = true
        def compact(result) = raise("compact exploded")
      end
    RUBY
    # {Summarizer::Catalog#for} documents that it raises whatever a user
    # predicate raises, and names this tier as the caller that must contain it.
    raising_suitable: <<~RUBY,
      summarizer "broken-suitable" do
        def suitable?(result) = raise("suitable? exploded")
        def compact(result) = "never reached"
      end
    RUBY
    blank: <<~RUBY,
      summarizer "blank" do
        def suitable?(result) = true
        def compact(result) = ""
      end
    RUBY
    # The half-written file, which is what {Summarizer::Base}'s
    # NotImplementedError exists FOR: declared, `suitable?` written, `compact`
    # not yet. NotImplementedError is a ScriptError, NOT a StandardError.
    half_written: <<~RUBY,
      summarizer "wip" do
        def suitable?(result) = true
      end
    RUBY
    # Unbounded recursion in a predicate. SystemStackError descends straight
    # from Exception -- it is neither a ScriptError nor a StandardError -- and a
    # half-written `suitable?` that calls itself is the same authoring state the
    # NotImplementedError cases cover. Every tool result runs these predicates
    # since T4, so the containment has to name it.
    recursive_suitable: <<~RUBY,
      summarizer "recursive" do
        def suitable?(result) = suitable?(result)
        def compact(result) = "never reached"
      end
    RUBY
    # The same hole one method earlier: `suitable?` itself is the unwritten one,
    # and {Catalog#for} is what calls it.
    half_written_suitable: <<~RUBY,
      summarizer "wip-suitable" do
        def compact(result) = "never reached"
      end
    RUBY
    non_string: <<~RUBY
      summarizer "typo" do
        def suitable?(result) = true
        def compact(result) = { lines: 94.2 }
      end
    RUBY
  }.freeze

  # A model tier recording every question it was asked. Answers through the SAME
  # {Lain::Oracle::Definition} the live tier is built over, so a caller cannot
  # tell it from {Lain::Oracle::Model} -- and reports a model and a non-empty
  # usage, which is what a journalling wrap reads off it.
  class RecordingTier
    attr_reader :questions

    def initialize(definition, summary: "the model's summary")
      @definition = definition
      @summary = summary
      @questions = []
    end

    def ask(inputs = {})
      @questions << inputs
      @definition.answer(summary: @summary)
    end

    def called? = !@questions.empty?

    def model = "test-summarizer-model"
    def usage = { "input_tokens" => 12, "output_tokens" => 7 }
  end
end

RSpec.describe Lain::Oracle::RoutedSummarizer do
  subject(:routed) { described_class.new(inner: tier, catalog: catalog(:coverage)) }

  let(:definition) { Lain::Oracle::Summarize.definition }
  let(:tier) { RoutedSummarizerSpecSupport::RecordingTier.new(definition) }
  # Both fixtures are over {described_class::MODEL_THRESHOLD_BYTES}, so a
  # catalog MISS is still worth a model call: the examples that follow are
  # about ROUTING, and the cost gate has its own group at the foot of this file
  # (where a below-threshold miss is asserted to spend nothing at all).
  let(:coverage_text) { "Coverage report\n#{"line covered\n" * 400}" }
  let(:coverage) { Lain::Summarizer::Result.new(tool_name: "bash", text: coverage_text) }
  let(:unrelated_text) { "module Lain; end\n" * 300 }
  let(:unrelated) { Lain::Summarizer::Result.new(tool_name: "read_file", text: unrelated_text) }

  def catalog(kind)
    source = RoutedSummarizerSpecSupport::DECLARATIONS.fetch(kind)
    Lain::Summarizer::Catalog.new(Lain::Summarizer::Builder.build(source, ".lain/summarizers.rb"))
  end

  def ask(oracle, result) = oracle.ask(Lain::Oracle::Eager::DEFAULT_SLOT => result).await

  it "answers a suitable result from the custom summarizer, with no provider call" do
    answer = ask(routed, coverage)

    expect(answer.summary).to eq("coverage: 94.2% of lines")
    expect(tier).not_to be_called
  end

  it "falls through to the model tier for an unsuitable result" do
    answer = ask(routed, unrelated)

    expect(answer.summary).to eq("the model's summary")
    expect(tier).to be_called
  end

  # The model tier's question is the TEXT, exactly as it was before this tier
  # existed: a Result reaching {Oracle::Definition#render} would be a loud
  # {Prompt::NonStringSlot}, and a fallthrough must not change the address the
  # journal (and its replay) keys on.
  it "hands the model tier the source TEXT, never the Result wrapper" do
    ask(routed, unrelated)

    expect(tier.questions).to eq([{ Lain::Oracle::Eager::DEFAULT_SLOT => unrelated_text }])
  end

  it "falls through when a suitable summarizer raises on compact, rather than losing the summary" do
    oracle = described_class.new(inner: tier, catalog: catalog(:raising_compact))

    expect(ask(oracle, coverage).summary).to eq("the model's summary")
    expect(tier).to be_called
  end

  # Catalog#for RUNS user predicates, so the scan needs the same containment the
  # compaction does -- a raising `suitable?` in a first declaration would
  # otherwise take out the whole compaction turn.
  it "falls through when a summarizer raises from suitable?" do
    oracle = described_class.new(inner: tier, catalog: catalog(:raising_suitable))

    expect(ask(oracle, coverage).summary).to eq("the model's summary")
    expect(tier).to be_called
  end

  # NotImplementedError is a ScriptError, not a StandardError, so a bare
  # `rescue StandardError` misses it -- and a half-written `.lain/summarizers.rb`
  # is the single most likely real failure, since it is the state the DSL is in
  # while it is being authored. Losing the summary is the contract; losing the
  # TURN is not.
  it "falls through when a declaration has not implemented compact yet" do
    oracle = described_class.new(inner: tier, catalog: catalog(:half_written))

    expect(ask(oracle, coverage).summary).to eq("the model's summary")
    expect(tier).to be_called
  end

  # SystemStackError is neither a ScriptError nor a StandardError, so the rescue
  # that contains every other broken declaration misses it -- and T4 widened the
  # exposure from "results over 4096 bytes" to every tool result.
  it "falls through when a declaration recurses without bound" do
    oracle = described_class.new(inner: tier, catalog: catalog(:recursive_suitable))

    expect(ask(oracle, coverage).summary).to eq("the model's summary")
    expect(tier).to be_called
  end

  it "falls through when a declaration has not implemented suitable? yet" do
    oracle = described_class.new(inner: tier, catalog: catalog(:half_written_suitable))

    expect(ask(oracle, coverage).summary).to eq("the model's summary")
    expect(tier).to be_called
  end

  # `field :summary, :string` COERCES rather than refuses, so a typo'd compact
  # returning an Object yields "#<Object:0x...>" -- a DIFFERENT string every
  # run, and that string replaces the tool result in the rendered prompt.
  # Nondeterministic prompt bytes break both invariants Canonical holds: an
  # unreproducible bench arm and a cache prefix that never hits, silently.
  it "refuses a non-String custom summary loudly, naming the declaration" do
    oracle = described_class.new(inner: tier, catalog: catalog(:non_string))

    expect { ask(oracle, coverage) }
      .to raise_error(Lain::Oracle::InvalidAnswer, /summarizer "typo" returned a Hash/)
    expect(tier).not_to be_called
  end

  it "refuses a blank custom summary loudly instead of substituting one" do
    oracle = described_class.new(inner: tier, catalog: catalog(:blank))

    expect { ask(oracle, coverage) }.to raise_error(Lain::Oracle::InvalidAnswer, /summary/i)
    expect(tier).not_to be_called
  end

  it "routes on the tool name: identical text from another tool falls through" do
    oracle = described_class.new(inner: tier, catalog: catalog(:by_tool))
    text = "the very same bytes\n" * 250

    from_bash = ask(oracle, Lain::Summarizer::Result.new(tool_name: "bash", text:))
    from_read = ask(oracle, Lain::Summarizer::Result.new(tool_name: "read_file", text:))

    expect(from_bash.summary).to eq("a bash result")
    expect(from_read.summary).to eq("the model's summary")
    expect(tier.questions.size).to eq(1)
  end

  # A source carrying no tool name has nothing to route ON, so it goes where it
  # went before this tier existed. The mount that failed to thread a name fails
  # loudly where the name actually is -- see the Observer's own examples.
  it "sends a bare String source straight to the model tier" do
    expect(ask(routed, "a bare tool result").summary).to eq("the model's summary")
    expect(tier.questions).to eq([{ Lain::Oracle::Eager::DEFAULT_SLOT => "a bare tool result" }])
  end

  # T4: the size gate is a COST policy, and this is the object that knows which
  # tier pays. The catalog above it is free -- no tokens, no latency, no
  # network -- so it is consulted for EVERY result; only the fallthrough to the
  # model tier has to clear the threshold. Gating both together is what made a
  # project's own declarations dead for every ordinary tool result.
  describe "the model tier's cost threshold" do
    let(:threshold) { described_class::MODEL_THRESHOLD_BYTES }
    let(:oracle) { described_class.new(inner: tier, catalog: catalog(:by_tool)) }

    def routed_result(text) = Lain::Summarizer::Result.new(tool_name: "read_file", text:)

    it "consults the catalog for a routed result far below the threshold" do
      small = Lain::Summarizer::Result.new(tool_name: "bash", text: "ok\n")

      expect(ask(oracle, small).summary).to eq("a bash result")
      expect(tier).not_to be_called
    end

    it "spends no model call on an unhandled routed result below the threshold" do
      expect(ask(oracle, routed_result("x" * (threshold - 1)))).to be_nil
      expect(tier).not_to be_called
    end

    # Strictly OVER, the rule the byte gate always had.
    it "declines at exactly the threshold and asks the model one byte later" do
      at = described_class.new(inner: tier, catalog: catalog(:by_tool))
      over = described_class.new(inner: RoutedSummarizerSpecSupport::RecordingTier.new(definition),
                                 catalog: catalog(:by_tool))

      expect(ask(at, routed_result("x" * threshold))).to be_nil
      expect(ask(over, routed_result("x" * (threshold + 1))).summary).to eq("the model's summary")
      expect(tier).not_to be_called
    end

    # A length check would let 1366 multibyte characters -- 4098 bytes -- read
    # as under the gate.
    it "measures the threshold in bytes, not characters" do
      multibyte = routed_result("あ" * ((threshold / 3) + 1))

      expect(ask(oracle, multibyte).summary).to eq("the model's summary")
    end

    # An injected policy, so a bench arm can move the gate without editing the
    # class that states the default.
    it "honours an injected threshold" do
      lowered = described_class.new(inner: tier, catalog: catalog(:by_tool), threshold_bytes: 2)

      expect(ask(lowered, routed_result("xxx")).summary).to eq("the model's summary")
    end

    # The gate guards results fired UNBIDDEN, one per tool call, into
    # {Lain::Oracle::Eager}, whose `#held` already means "no summary" by nil. A
    # bare-text caller is a different contract: it reads `.summary` off the
    # answer, where nil is a NoMethodError rather than a graceful miss. Its
    # question must also stay byte-identical to what it was before this tier
    # existed, since a journal replay keys on it.
    it "never gates a bare String source, however small" do
      expect(ask(routed, "tiny").summary).to eq("the model's summary")
      expect(tier.questions).to eq([{ Lain::Oracle::Eager::DEFAULT_SLOT => "tiny" }])
    end

    # A source that ROUTES but carries no text has no bytes to weigh, and the
    # gate must not be what decides its fate: `bytesize` on it would die as a
    # bare NoMethodError from inside this object, where passing it on reaches
    # {Lain::Oracle::Definition#render} and its named slot refusal. Latent --
    # only {Lain::Summarizer::Result} satisfies the routing duck today.
    it "passes a routed source carrying no text to the model tier rather than dying in the gate" do
      textless = Struct.new(:tool_name).new("bash")

      expect { ask(routed, textless) }.not_to raise_error
      expect(tier.questions).to eq([{ Lain::Oracle::Eager::DEFAULT_SLOT => textless }])
    end
  end

  describe "journalling, with the Journaling wrap INSIDE this one" do
    subject(:routed) { described_class.new(inner: journalling, catalog: catalog(:coverage)) }

    let(:journal) { [] }
    let(:journalling) { Lain::Oracle::Recorded::Journaling.new(inner: tier, definition:, journal:) }

    def answers = journal.grep(Lain::Telemetry::OracleAnswer)

    it "journals nothing when the custom summarizer answered -- no model was billed" do
      expect(ask(routed, coverage).summary).to eq("coverage: 94.2% of lines")
      expect(answers).to be_empty
    end

    # Uniform with {Oracle::Heuristic}: there is no model call here, so both are
    # legitimately empty rather than a gap. Delegating instead would ALSO raise,
    # since Journaling defines neither.
    it "reports no model and empty usage for a custom answer" do
      ask(routed, coverage)

      expect(routed.model).to be_nil
      expect(routed.usage).to be_empty
    end

    it "journals a fallen-through answer exactly once" do
      ask(routed, unrelated)

      expect(answers.size).to eq(1)
      expect(answers.first.model).to eq("test-summarizer-model")
      expect(answers.first.usage).to include("input_tokens" => 12)
    end
  end

  # The end the summary is actually read from: {Oracle::Eager} holds it against
  # the SOURCE DIGEST, which stays the content address of the tool's own bytes
  # even though the fire now carries a {Summarizer::Result}.
  it "holds a custom summary under the source digest when fired through an Eager" do
    eager = Lain::Oracle::Eager.new(oracle: routed)
    digest = Lain::Canonical.digest(coverage_text)

    Sync { eager.fire(digest, coverage).wait }

    expect(eager.held(digest).summary).to eq("coverage: 94.2% of lines")
    expect(tier).not_to be_called
  end
end
