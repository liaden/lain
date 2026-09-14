# frozen_string_literal: true

RSpec.describe Lain::Context::Combinator do
  # A "tag" combinator appends marker text blocks to the message list, purely.
  # Two composed combinators are OBSERVATIONALLY EQUAL exactly when they produce
  # the same tagged output for the same input, which is how "monoid law" is made
  # concrete here without depending on Prune/Compact/etc internals.
  def tag(*symbols)
    Class.new(described_class) do
      define_method(:call) do |messages|
        tags = symbols.map { |symbol| { "role" => "tag", "content" => [{ "type" => "text", "text" => symbol.to_s }] } }
        messages + tags
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

  # Each draw is ONE leaf appending up to three tags, never a chain folded with
  # `>>`: a population built by the operation under test bends along with it,
  # and an operator that is wrong only when an operand is already composed then
  # passes the laws over draws that are all composed the same way.
  describe "the monoid law (property-tested)" do
    include_examples "a monoid",
                     operation: ->(a, b) { a >> b },
                     identity: Lain::Context::Identity,
                     generator: -> { tag(*Array.new(rand(0..3)) { %i[a b c d].sample }) },
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

    # NOT the union #requires takes, and the asymmetry is the point: `second`
    # is handed `first`'s output and can never see what the composition was
    # called with, so a substituting stage blinds everything behind it while a
    # reading stage in front of one still reads.
    it "reads its messages exactly when the FIRST stage does" do
      substituting = Class.new(described_class) { def reads_messages? = false }.new

      expect((substituting >> described_class.new).reads_messages?).to be(false)
      expect((described_class.new >> substituting).reads_messages?).to be(true)
    end

    # NESTED, because `>>` is associative and a composition's first stage is
    # itself often a composition -- which is exactly the shape a compacting turn
    # builds (Replay composed ahead of an already-composed base pipeline). The
    # recursion has to reach the leftmost LEAF, not just the outer pair.
    it "reaches the leftmost leaf through nested compositions" do
      substituting = Class.new(described_class) { def reads_messages? = false }.new
      reading = described_class.new

      expect(((substituting >> reading) >> reading).reads_messages?).to be(false)
      expect((substituting >> (reading >> reading)).reads_messages?).to be(false)
      expect(((reading >> substituting) >> reading).reads_messages?).to be(true)
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

    # A transform reads what it is handed; only a stage that substitutes a list
    # of its own says otherwise, so the default is what every shipped
    # combinator inherits without declaring anything.
    it "reads the messages it is handed" do
      expect(described_class.new.reads_messages?).to be(true)
    end
  end
end
