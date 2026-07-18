# frozen_string_literal: true

RSpec.describe Lain::Context::DedupeToolCalls do
  def tool_use(id:, name:, input:)
    { "type" => "tool_use", "id" => id, "name" => name, "input" => input }
  end

  def tool_result(id:, content:, is_error: false)
    { "type" => "tool_result", "tool_use_id" => id, "content" => content, "is_error" => is_error }
  end

  def assistant(*blocks) = { "role" => "assistant", "content" => blocks }
  def user(*blocks) = { "role" => "user", "content" => blocks }

  let(:duplicated_messages) do
    [
      assistant(tool_use(id: "call-1", name: "search", input: { "q" => "cats" })),
      user(tool_result(id: "call-1", content: "old result")),
      assistant(tool_use(id: "call-2", name: "search", input: { "q" => "cats" })),
      user(tool_result(id: "call-2", content: "new result"))
    ]
  end

  describe "AC1: dedupe keeps the newest identical tool result" do
    it "drops the older call+result pair, keeping only the newest" do
      result = described_class.new.call(duplicated_messages)
      expect(result).to eq(
        [
          assistant(tool_use(id: "call-2", name: "search", input: { "q" => "cats" })),
          user(tool_result(id: "call-2", content: "new result"))
        ]
      )
    end

    it "leaves distinct (name, args) tool calls untouched" do
      messages = [
        assistant(tool_use(id: "call-1", name: "search", input: { "q" => "cats" })),
        user(tool_result(id: "call-1", content: "cats result")),
        assistant(tool_use(id: "call-2", name: "search", input: { "q" => "dogs" })),
        user(tool_result(id: "call-2", content: "dogs result"))
      ]
      expect(described_class.new.call(messages)).to eq(messages)
    end

    it "leaves non-tool messages untouched" do
      messages = [
        { "role" => "user", "content" => [{ "type" => "text", "text" => "hi" }] },
        { "role" => "assistant", "content" => [{ "type" => "text", "text" => "hello" }] }
      ]
      expect(described_class.new.call(messages)).to eq(messages)
    end

    it "does not mutate the input message list -- a pure projection" do
      before = Lain::Canonical.dump(duplicated_messages)
      described_class.new.call(duplicated_messages)
      expect(Lain::Canonical.dump(duplicated_messages)).to eq(before)
    end
  end

  it "is pure: identical input yields identical output" do
    combinator = described_class.new
    expect(combinator.call(duplicated_messages)).to eq(combinator.call(duplicated_messages))
  end

  it "declares no required capabilities -- deduping is purely client-side" do
    expect(described_class.new.requires).to eq([])
  end

  it "composes with other combinators via >>" do
    composed = described_class.new >> Lain::Context::Identity
    expect(composed.call(duplicated_messages).size).to eq(2)
  end

  describe "the monoid law (property-tested)" do
    let(:pool) { { dedupe: described_class.new, identity: Lain::Context::Identity } }

    def compose(sequence)
      sequence.map { |symbol| pool.fetch(symbol) }.reduce(Lain::Context::Identity, :>>)
    end

    def observe(combinator)
      combinator.call(duplicated_messages)
    end

    include_examples "a monoid",
                     operation: ->(a, b) { a >> b },
                     identity: Lain::Context::Identity,
                     generator: -> { compose(Array.new(rand(0..3)) { %i[dedupe identity].sample }) },
                     equal: ->(a, b) { observe(a) == observe(b) }
  end
end
