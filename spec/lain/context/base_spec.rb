# frozen_string_literal: true

RSpec.describe Lain::Context::Combinator do
  # A "tag" combinator appends a marker text block to the message list,
  # purely -- mirroring middleware_spec.rb's `tag` helper. Two composed
  # combinators are OBSERVATIONALLY EQUAL exactly when they produce the same
  # tagged output for the same input, which is how "monoid law" is made
  # concrete here without depending on Prune/Compact/etc internals.
  def tag(symbol)
    Class.new(described_class) do
      define_method(:call) do |messages|
        messages + [{ "role" => "tag", "content" => [{ "type" => "text", "text" => symbol.to_s }] }]
      end
    end.new
  end

  let(:pool) { { a: tag(:a), b: tag(:b), c: tag(:c), d: tag(:d) } }

  def compose(sequence)
    sequence.map { |symbol| pool.fetch(symbol) }.reduce(Lain::Context::Identity, :>>)
  end

  def observe(combinator)
    combinator.call([]).map { |m| m["content"].first["text"] }
  end

  describe "the monoid law (property-tested)" do
    include_examples "a monoid",
                     operation: ->(a, b) { a >> b },
                     identity: Lain::Context::Identity,
                     generator: -> { compose(Array.new(rand(0..3)) { %i[a b c d].sample }) },
                     equal: ->(a, b) { observe(a) == observe(b) }
  end

  describe "#>>" do
    it "runs the first combinator, then the second, on the message list" do
      composed = tag(:a) >> tag(:b)
      expect(observe(composed)).to eq(%w[a b])
    end

    it "unions #requires from both sides" do
      requiring_x = Class.new(described_class) { def requires = %i[x] }.new
      requiring_y = Class.new(described_class) { def requires = %i[y] }.new
      expect((requiring_x >> requiring_y).requires).to contain_exactly(:x, :y)
    end
  end

  describe Lain::Context::Identity do
    it "passes the message list through unchanged" do
      messages = [{ "role" => "user", "content" => [{ "type" => "text", "text" => "hi" }] }]
      expect(described_class.call(messages)).to eq(messages)
    end

    it "declares no capabilities" do
      expect(described_class.requires).to eq([])
    end
  end

  describe "a combinator with no override" do
    it "is the identity by default" do
      messages = [{ "role" => "user", "content" => [] }]
      expect(described_class.new.call(messages)).to eq(messages)
    end
  end
end
