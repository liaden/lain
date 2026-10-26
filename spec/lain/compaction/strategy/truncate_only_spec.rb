# frozen_string_literal: true

module TruncateOnlyFixtures
  module_function

  def text(body) = { "type" => "text", "text" => body }

  def message(*blocks, role: "user") = { "role" => role, "content" => blocks }

  def tool_use(id, input = {}) = { "type" => "tool_use", "id" => "toolu_#{id}", "name" => "read", "input" => input }

  def tool_result(id, body) = { "type" => "tool_result", "tool_use_id" => "toolu_#{id}", "content" => body }

  # Roles alternate by index, which is what Context::Conversation accepts.
  def history(blocks, store: Lain::Dag::Factory.store)
    blocks.each_with_index.inject(Lain::Dag::Factory.timeline(store:)) do |timeline, (content, index)|
      timeline.commit(role: index.even? ? "user" : "assistant", content:)
    end
  end

  def texts(turn) = turn.content.map { |block| block["text"] }

  # `[m, other, m]` so the elementwise law's functional reading has a repeat to judge.
  def repeating
    repeated = message(text("a"))
    [repeated, message(text("b"), role: "assistant"), repeated]
  end

  def spans
    [0, 1, 2, 4].map { |size| Array.new(size) { |i| message(text("m#{i}" * 3), role: i.even? ? "user" : "assistant") } }
  end
end

RSpec.describe Lain::Compaction::Strategy::TruncateOnly do
  subject(:strategy) { described_class.new }

  let(:fixtures) { TruncateOnlyFixtures }

  def texts(replacement) = replacement.content.map { |block| block["text"] }

  describe "the replacement it builds" do
    let(:arguments) { { "path" => "a" * 400 } }
    let(:span) do
      [fixtures.message(fixtures.text("please read the file")),
       fixtures.message(fixtures.text("reading it"), fixtures.tool_use(1, arguments), role: "assistant"),
       fixtures.message(fixtures.tool_result(1, "r" * 2000)),
       fixtures.message(fixtures.text("h" * 25_000), role: "user")]
    end
    let(:lines) { texts(strategy.collapse(span)) }

    it "keeps an assistant text verbatim" do
      expect(lines).to include("reading it")
    end

    it "writes a tool call as one line, its arguments cut to 150 characters" do
      line = lines.find { |text| text.start_with?("[tool] read ") }

      expect(line).to eq(%([tool] read {"path":"#{"a" * 141}))
      expect(line.delete_prefix("[tool] read ").size).to eq(150)
    end

    it "cuts a tool result to 500 characters" do
      expect(lines).to include("r" * 500)
      expect(lines).not_to include("r" * 501)
    end

    it "keeps a human turn up to 20000 characters" do
      expect(lines).to include("h" * 20_000)
      expect(lines.map(&:size).max).to eq(20_000)
    end

    it "keeps an assistant text of any length uncut" do
      long = fixtures.message(fixtures.text("w" * 25_000), role: "assistant")

      expect(texts(strategy.collapse([long]))).to eq(["w" * 25_000])
    end

    it "makes invalid UTF-8 in a tool result legible rather than raising" do
      broken = fixtures.message(fixtures.tool_result(1, "ab\xFF"))

      expect(texts(strategy.collapse([broken]))).to eq(["ab\uFFFD"])
    end

    it "marks an error result, since parts carry no role label" do
      failed = fixtures.message(fixtures.tool_result(1, "boom").merge("is_error" => true))

      expect(texts(strategy.collapse([failed]))).to eq(["[tool error] boom"])
    end

    it "reads a tool result carried as a list of text blocks" do
      listed = fixtures.message(fixtures.tool_result(1, [fixtures.text("one"), fixtures.text("two")]))

      expect(texts(strategy.collapse([listed]))).to eq(["one\ntwo"])
    end

    it "drops what it cannot state as text, and a blank part with it" do
      odd = fixtures.message({ "type" => "thinking", "thinking" => "hm" }, fixtures.text(""),
                             fixtures.tool_result(2, ""), role: "assistant")

      expect(strategy.collapse([odd])).to be(Lain::Compaction::Strategy::DROP)
    end
  end

  describe "the ranges it proposes" do
    it "offers the whole span when no tool call dangles" do
      messages = fixtures.spans.last

      expect(strategy.ranges(messages, span: 0...4)).to eq([0..3])
    end

    it "ends before a trailing tool_use whose result follows the span" do
      messages = [fixtures.message(fixtures.text("ask")),
                  fixtures.message(fixtures.text("ok"), role: "assistant"),
                  fixtures.message(fixtures.text("again")),
                  fixtures.message(fixtures.tool_use(1), role: "assistant"),
                  fixtures.message(fixtures.tool_result(1, "out"))]

      expect(strategy.ranges(messages, span: 0...4)).to eq([0..2])
    end

    it "proposes nothing when the only message is the dangling tool_use" do
      messages = [fixtures.message(fixtures.tool_use(1), role: "assistant"),
                  fixtures.message(fixtures.tool_result(1, "out"))]

      expect(strategy.ranges(messages, span: 0...1)).to be_empty
    end
  end

  describe "a session cut twice" do
    let(:blocks) do
      [[fixtures.text("ask")], [fixtures.text("one")], [fixtures.text("more")], [fixtures.text("two")],
       [fixtures.text("again")], [fixtures.text("three")], [fixtures.text("then")], [fixtures.text("four")],
       [fixtures.text("last")], [fixtures.text("five")]]
    end
    let(:store) { Lain::Dag::Factory.store }
    let(:derivation) { Lain::Compaction::Derivation.new(strategy:, keep_last: 2) }
    let(:first) { fixtures.history(blocks.first(6), store:) }
    let(:second) { fixtures.history(blocks, store:) }

    def seam_after(source) = derivation.derive(source) { |_derived, seam, _resume| seam }

    def replacements(chain) = chain.to_a.select { |turn| turn.causal_parents.any? }

    it "keeps every earlier replacement beside the new one, in order" do
      derived = derivation.derive(second, cut: seam_after(first))

      expect(replacements(derived).size).to eq(2)
      expect(replacements(derived).map { |turn| fixtures.texts(turn).join }).to match(
        [a_string_including("one", "ask"), a_string_including("three")]
      )
    end
  end

  describe "the construction" do
    it "holds no collaborator, so it consults no model" do
      expect { described_class.new(Lain::Channel::Null.instance) }.to raise_error(ArgumentError)
      expect(strategy.instance_variables).to be_empty
      expect(strategy).to be_deeply_frozen
    end
  end

  describe "held to the homomorphism law over generated spans" do
    strategy = described_class.new
    drawn = TruncateOnlyFixtures.spans

    include_examples "a monoid homomorphism",
                     collapse: ->(messages) { strategy.collapse(messages) },
                     unit: Lain::Compaction::Strategy::DROP,
                     spans: -> { drawn }
  end

  describe "held to the elementwise laws on #blocks" do
    strategy = described_class.new
    drawn = [TruncateOnlyFixtures.repeating, *TruncateOnlyFixtures.spans]

    include_examples "an elementwise map",
                     instance: -> { strategy },
                     spans: -> { drawn },
                     operation: :blocks,
                     each: :parts,
                     analysis: nil
  end

  describe "held to the purity laws on #blocks" do
    strategy = described_class.new

    include_examples "a pure operation",
                     instance: -> { strategy },
                     operation: :blocks,
                     population: -> { TruncateOnlyFixtures.spans }
  end
end
