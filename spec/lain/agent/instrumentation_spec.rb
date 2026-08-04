# frozen_string_literal: true

# T22: the seven keywords a run REPORTS through, as one value. They were seven
# separate slots on Agent#initialize and three Hash reifications in the CLI
# (CompactionMount#agent_kwargs, Chronicle#telemetry_kwargs, ToolGuard#kwargs),
# each poking at the Hash with `.fetch`/`.slice`/`.merge` -- the tell of a value
# object nobody had named.
RSpec.describe Lain::Agent::Instrumentation do
  # The per-turn Context source duck, as a value distinguishable from the Null.
  def a_source = Class.new { def context_for(base:, **) = base }.new

  describe "the defaults" do
    # Each member's Null, so no consumer ever writes `if journal`. Asserted by
    # IDENTITY where a shared frozen Null exists, because a fresh equal object
    # would mean the default allocates per Agent.
    it "reports nowhere and decides nothing" do
      value = described_class.new

      expect(value.journal).to be(Lain::Channel::Null.instance)
      expect(value.transition_listener).to be(Lain::Agent::TransitionListener::Null)
      expect(value.pipeline_source).to be(Lain::Agent::PipelineSource::Null)
      expect(value.tool_observer).to be_a(Lain::Agent::ToolRunner::Observer::Null)
    end

    it "carries an empty stack for each of the three middleware phases" do
      value = described_class.new

      expect([value.model_middleware, value.tool_middleware, value.turn_middleware].map(&:to_a))
        .to eq([[], [], []])
    end

    # A shared MUTABLE default would let one Agent's `#use` reach every other
    # Agent's stack, so each default-built value gets its own.
    it "gives each value its own stacks rather than sharing one mutable default" do
      first = described_class.new
      second = described_class.new

      expect(first.turn_middleware).not_to be(second.turn_middleware)
    end
  end

  describe "#with" do
    it "replaces one member and carries the other six through untouched" do
      journal = RecordingChannel.new
      base = described_class.new(journal:, turn_middleware: Lain::Middleware::Stack.new([Lain::Middleware::Identity]))

      source = a_source
      folded = base.with(pipeline_source: source)

      expect(folded.journal).to be(journal)
      expect(folded.turn_middleware).to be(base.turn_middleware)
      expect(folded.pipeline_source).to be(source)
    end

    it "leaves the receiver alone -- it is a value, not a builder" do
      base = described_class.new
      base.with(journal: RecordingChannel.new)

      expect(base.journal).to be(Lain::Channel::Null.instance)
    end
  end

  # A Data is frozen, which is the mechanical statement that the WIRING cannot
  # be edited after construction. It is not deeply frozen and must not pretend
  # to be: a journal and a middleware stack are live collaborators by nature
  # (Middleware::Stack is deliberately mutable -- see middleware.rb). This is
  # the Timeline-value rule's counterpart, not an exception smuggled past it.
  it "is a frozen value holding live collaborators" do
    value = described_class.new(journal: RecordingChannel.new)

    expect(value).to be_frozen
    expect(value).not_to be_deeply_frozen
  end

  # The refusal's TEXT is the subject in this group, so it is captured rather
  # than matched by one loose regex: a message can name the typo and still fail
  # to name the keyword the caller meant, and that difference is the whole
  # legibility question. Every expectation below reads against literals.
  def refusal_message
    yield
    raise "expected an ArgumentError, and none was raised"
  rescue ArgumentError => e
    e.message
  end

  describe "keywords a caller never wrote" do
    # Direct construction is `Data`'s own business, and its `unknown keyword:`
    # is the right error there: nothing has been swept into a splat, so the
    # keyword the caller typed is the whole story. The vocabulary belongs one
    # layer up, at {.resolve} -- see the group below.
    it "refuses an unknown keyword, so a typo cannot be swallowed" do
      expect(refusal_message { described_class.new(jurnal: RecordingChannel.new) })
        .to include("jurnal")
    end

    # The way to take a default is to OMIT the keyword. `pipeline_source: nil`
    # used to be accepted and crash on the first render instead.
    %i[journal model_middleware tool_middleware turn_middleware
       tool_observer transition_listener pipeline_source].each do |member|
      it "refuses an explicit #{member}: nil rather than reading it as the default" do
        expect { described_class.new(member => nil) }.to raise_error(ArgumentError, /#{member}.*nil/m)
      end
    end

    it "names every explicit nil at once, so one round trip fixes them all" do
      expect { described_class.new(journal: nil, pipeline_source: nil) }
        .to raise_error(ArgumentError, /journal.*pipeline_source|pipeline_source.*journal/m)
    end
  end

  # The Agent's two-style rule lives here rather than in the constructor,
  # because it is a statement about THIS value: either a caller hands one over,
  # or the legacy keywords build one, never both.
  describe ".resolve" do
    let(:omitted) { Lain::Agent::Collaborators::OMITTED }

    it "builds one from the legacy keywords when none was handed over" do
      journal = RecordingChannel.new
      resolved = described_class.resolve(omitted, { journal: })

      expect(resolved).to be_a(described_class)
      expect(resolved.journal).to be(journal)
      expect(resolved.pipeline_source).to be(Lain::Agent::PipelineSource::Null)
    end

    it "answers the very value it was handed" do
      value = described_class.new

      expect(described_class.resolve(value, {})).to be(value)
    end

    it "refuses a handed-over value beside a legacy keyword, naming both halves" do
      expect { described_class.resolve(described_class.new, { journal: RecordingChannel.new }) }
        .to raise_error(ArgumentError, /instrumentation:.*journal:/m)
    end

    it "refuses an explicit nil, which no default may stand in for" do
      expect { described_class.resolve(nil, {}) }.to raise_error(ArgumentError, /instrumentation.*nil/m)
    end

    # This is where every wiring typo lands: {Lain::Agent} names its collaborator
    # keywords on the signature and sweeps everything else through here, which
    # also puts {Lain::Agent::Collaborators#refuse_unknown}'s vocabulary list out
    # of reach. So the message has to carry the WHOLE vocabulary, or an operator
    # gets Data's bare `unknown keyword: :providr` with no route to `provider:`.
    it "names the whole wiring vocabulary, both halves of it, not just the typo" do
      message = refusal_message { described_class.resolve(omitted, { jurnal: RecordingChannel.new }) }

      expect(message).to include("unknown wiring keyword: jurnal:")
      expect(message).to include("journal:", "model_middleware:", "tool_middleware:", "turn_middleware:",
                                 "tool_observer:", "transition_listener:", "pipeline_source:")
      expect(message).to include("model_caller:", "tool_runner:", "accounting:", "provider:", "handler:")
    end

    # Asked FIRST, ahead of the both-styles clash, because a typo makes every
    # later question meaningless -- the order {Lain::Agent::Collaborators} keeps.
    # Read the other way round: a typo is not something the value "CARRIES", so
    # the clash message would be saying something false about it.
    it "reads a typo beside a handed-over value as a typo, not as a clash" do
      message = refusal_message { described_class.resolve(described_class.new, { jurnal: 1 }) }

      expect(message).to include("unknown wiring keyword: jurnal:")
      expect(message).not_to include("CARRIES")
    end
  end
end
