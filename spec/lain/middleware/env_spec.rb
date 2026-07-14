# frozen_string_literal: true

RSpec.describe Lain::Middleware::Env do
  describe ".wrap" do
    it "wraps a plain Hash into an Env" do
      expect(described_class.wrap({ request: :r })).to be_a(described_class)
    end

    it "is idempotent: wrapping an Env returns the very same object" do
      env = described_class.wrap({ a: 1 })
      expect(described_class.wrap(env)).to be(env)
    end

    it "wrap idempotence preserves the original entries through to_h" do
      h = { request: :r, extra: 1 }
      expect(described_class.wrap(described_class.wrap(h)).to_h).to eq(h)
    end
  end

  describe "the Hash-duck surface middleware rely on" do
    let(:env) { described_class.wrap({ request: :r, context: :c }) }

    it "#fetch reads a present key" do
      expect(env.fetch(:request)).to eq(:r)
    end

    it "#fetch honors a default argument for a missing key" do
      expect(env.fetch(:missing, :fallback)).to eq(:fallback)
    end

    it "#fetch honors a default block, yielding the missing key to it" do
      expect(env.fetch(:missing) { |key| "no #{key}" }).to eq("no missing")
    end

    it "#[] reads a present key and returns nil for a missing one" do
      expect(env[:request]).to eq(:r)
      expect(env[:missing]).to be_nil
    end

    it "#merge returns a new Env without mutating the receiver" do
      merged = env.merge(response: :resp)
      expect(merged).to be_a(described_class)
      expect(merged.fetch(:response)).to eq(:resp)
      expect(env[:response]).to be_nil
    end

    it "#merge accepts another Env as its argument" do
      merged = env.merge(described_class.wrap({ response: :resp }))
      expect(merged.fetch(:response)).to eq(:resp)
    end

    it "#to_h yields a Hash carrying the entries" do
      expect(env.to_h).to eq({ request: :r, context: :c })
    end
  end

  describe "per-phase reader sugar" do
    it "exposes the model phase's :request and :response" do
      env = described_class.wrap({ request: :req, response: :resp })
      expect(env.request).to eq(:req)
      expect(env.response).to eq(:resp)
    end

    it "exposes the tool phase's :effect and :result" do
      env = described_class.wrap({ effect: :eff, result: :res })
      expect(env.effect).to eq(:eff)
      expect(env.result).to eq(:res)
    end

    it "a reader for an absent key fails loudly (KeyError), never a silent nil" do
      expect { described_class.wrap({}).response }.to raise_error(KeyError)
    end
  end

  # The whole point of Env is that Middleware#merge cannot diverge from
  # Hash#merge without a law breaking: the same associativity + identity the
  # phases already satisfy, now carried through the whole value.
  describe "the middleware monoid law holds over Env" do
    def tag(symbol)
      Class.new(Lain::Middleware::Base) do
        define_method(:call) do |env, &downstream|
          entered = env.merge(trace: env.fetch(:trace, []) + [[symbol, :in]])
          exited = downstream.call(entered)
          exited.merge(trace: exited.fetch(:trace) + [[symbol, :out]])
        end
      end.new
    end

    # Every observation starts from a wrapped Env, so the trace threads through
    # Env#merge/#fetch rather than Hash's -- that is what "over Env" means.
    def observe(middleware)
      middleware.call(Lain::Middleware::Env.wrap({ trace: [] })) { |env| env }.fetch(:trace)
    end

    let(:pool) { { a: tag(:a), b: tag(:b), c: tag(:c), d: tag(:d) } }

    def compose(sequence)
      sequence.map { |symbol| pool.fetch(symbol) }.reduce(Lain::Middleware::Identity, :>>)
    end

    include_examples "a monoid",
                     operation: ->(a, b) { a >> b },
                     identity: Lain::Middleware::Identity,
                     generator: -> { compose(Array.new(rand(0..3)) { %i[a b c d].sample }) },
                     equal: ->(a, b) { observe(a) == observe(b) }
  end
end
