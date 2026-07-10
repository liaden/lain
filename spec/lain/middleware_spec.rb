# frozen_string_literal: true

require "lain/middleware"

RSpec.describe Lain::Middleware do
  # A "tag" middleware records its entry and exit around the downstream in a
  # purely functional way -- it appends to `env[:trace]` on the way in and to the
  # returned env's trace on the way out, never mutating shared state. That makes
  # two composed stacks OBSERVATIONALLY EQUAL exactly when they produce the same
  # trace for the same input, which is how we make "monoid law" concrete.
  def tag(symbol)
    Class.new(Lain::Middleware::Base) do
      define_method(:call) do |env, &downstream|
        entered = env.merge(trace: env.fetch(:trace, []) + [[symbol, :in]])
        exited = downstream.call(entered)
        exited.merge(trace: exited.fetch(:trace) + [[symbol, :out]])
      end
    end.new
  end

  # The observation: run a middleware over an empty-trace env, terminating in the
  # identity app, and read the trace it produced.
  def observe(middleware)
    middleware.call({ trace: [] }) { |env| env }.fetch(:trace)
  end

  let(:pool) { { a: tag(:a), b: tag(:b), c: tag(:c), d: tag(:d) } }

  # Fold a sequence of tag symbols into a single composed middleware; an empty
  # sequence folds to the identity, which is exactly why the identity has to
  # exist as a real value.
  def compose(sequence)
    sequence.map { |symbol| pool.fetch(symbol) }.reduce(Lain::Middleware::Identity, :>>)
  end

  # Not commutative BY DESIGN -- Stack's insert_before/insert_after exist
  # precisely because middleware order is meaningful -- so only "a monoid" is
  # included, never "a commutative monoid".
  describe "the monoid law (property-tested)" do
    include_examples "a monoid",
                     operation: ->(a, b) { a >> b },
                     identity: Lain::Middleware::Identity,
                     generator: -> { compose(Array.new(rand(0..3)) { %i[a b c d].sample }) },
                     equal: ->(a, b) { observe(a) == observe(b) }
  end

  describe described_class::Stack do
    let(:a) { tag(:a) }
    let(:b) { tag(:b) }
    let(:c) { tag(:c) }

    it "nests in declared order: first #use is outermost" do
      stack = described_class.new
      stack.use(a).use(b).use(c)
      expect(observe(stack)).to eq([%i[a in], %i[b in], %i[c in], %i[c out], %i[b out], %i[a out]])
    end

    it "#insert_before places a middleware ahead of a matched class" do
      stack = described_class.new([a, c])
      stack.insert_before(c.class, b)
      expect(stack.to_a).to eq([a, b, c])
    end

    it "#insert_after places a middleware behind a matched class" do
      stack = described_class.new([a, c])
      stack.insert_after(a.class, b)
      expect(stack.to_a).to eq([a, b, c])
    end

    it "#to_a is a copy -- inspecting the order cannot mutate the stack" do
      stack = described_class.new([a])
      stack.to_a << b
      expect(stack.to_a).to eq([a])
    end

    it "raises when insert targets a middleware that is not present" do
      expect { described_class.new([a]).insert_before(b.class, c) }
        .to raise_error(ArgumentError, /no middleware matching/)
    end

    it "is itself composable -- a Stack is a middleware" do
      inner = described_class.new([b])
      composed = a >> inner >> c
      expect(observe(composed)).to eq([%i[a in], %i[b in], %i[c in], %i[c out], %i[b out], %i[a out]])
    end
  end

  describe described_class::Logging do
    # Log lines must go to an injected sink, NEVER to the terminal. We route them
    # through a Sink::IOAdapter over a Channel and read them back as attributed
    # events, proving the output-discipline path.
    it "writes before/after lines to the injected sink, not stdout" do
      channel = Lain::Channel.new
      sink = Lain::Sink::IOAdapter.new(channel, tool_use_id: "log_1", stream: :stdout)
      logging = described_class.new(sink: sink, label: "tool")

      logging.call({ effect: :x }) { |env| env }

      lines = channel.drain.map(&:bytes).join
      expect(lines).to match(/tool > /)
      expect(lines).to match(/tool < /)
    end

    it "passes the env through unchanged (it observes, it does not transform)" do
      sink = Lain::Sink::Null.new
      logging = described_class.new(sink: sink, label: "x")
      expect(logging.call({ n: 1 }) { |env| env.merge(seen: true) }).to eq({ n: 1, seen: true })
    end
  end

  describe described_class::Timeout do
    it "publishes a monotonic deadline into the env for cooperative cancellation" do
      clock = -> { 100.0 }
      timeout = described_class.new(seconds: 5, clock: clock)
      seen = nil
      timeout.call({}) do |env|
        seen = env[described_class::DEADLINE_KEY]
        env
      end
      expect(seen).to eq(105.0)
    end

    it "raises Exceeded when the downstream overruns the budget" do
      now = 0.0
      clock = -> { now }
      timeout = described_class.new(seconds: 1, clock: clock)
      expect do
        timeout.call({}) do |env|
          now = 2.5
          env
        end
      end
        .to raise_error(described_class::Exceeded, /exceeded 1s budget \(took 2.5s\)/)
    end

    it "does not raise when the downstream stays within budget" do
      now = 0.0
      clock = -> { now }
      timeout = described_class.new(seconds: 1, clock: clock)
      expect(timeout.call({}) do |env|
        now = 0.5
        env.merge(done: true)
      end).to include(done: true)
    end

    it "rejects a non-positive budget" do
      expect { described_class.new(seconds: 0) }.to raise_error(ArgumentError, /positive Numeric/)
    end
  end

  # A bare `yield` inside a middleware raises LocalJumpError the moment anyone
  # calls it outside a stack, and no RuboCop cop can catch that statically. So
  # every middleware routes through Base#downstream, which is the identity when
  # there is no downstream. These specs pin that totality down.
  describe "a middleware called with no downstream" do
    let(:env) { { a: 1 } }

    it "passes env through for Base" do
      expect(described_class::Base.new.call(env)).to eq(env)
    end

    it "passes env through for Identity" do
      expect(described_class::Identity.call(env)).to eq(env)
    end

    it "passes env through for Logging, and still logs" do
      sink = Lain::Sink::IOAdapter.new(Lain::Channel.new, tool_use_id: "tu_1", stream: :stdout)
      expect(described_class::Logging.new(sink: sink).call(env)).to eq(env)
    end

    it "passes env through for Timeout, adding its deadline" do
      result = described_class::Timeout.new(seconds: 1).call(env)
      expect(result[:a]).to eq(1)
      expect(result[described_class::Timeout::DEADLINE_KEY]).to be_a(Float)
    end

    it "passes env through for a Composed pair" do
      composed = described_class::Identity >> described_class::Identity
      expect(composed.call(env)).to eq(env)
    end

    it "passes env through for an empty Stack" do
      expect(described_class::Stack.new.call(env)).to eq(env)
    end
  end
end
