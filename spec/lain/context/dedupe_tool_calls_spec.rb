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

  describe "dedupe keeps the newest identical tool result" do
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

    # The key is (name, args), and only the args half was pinned: replacing the
    # name in the grouping key with a constant left every other example in this
    # file green, so nothing said two DIFFERENT tools asked the same question
    # are two calls. They are -- "search cats" and "lookup cats" answer
    # differently, and dropping the older would drop an answer nothing else
    # holds.
    it "keeps two different tools asked the same question -- the key is (name, args), not args" do
      messages = [
        assistant(tool_use(id: "call-1", name: "search", input: { "q" => "cats" })),
        user(tool_result(id: "call-1", content: "search says")),
        assistant(tool_use(id: "call-2", name: "lookup", input: { "q" => "cats" })),
        user(tool_result(id: "call-2", content: "lookup says"))
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

  # The two phases the class is factored into: an analysis of the whole list,
  # then a map over each message against that fixed analysis. The analysis is
  # surface; the per-message map is a private helper, reached here by `send`.
  describe "the two-phase factoring" do
    # One message is REWRITTEN (its text survives, its stale tool_use does not)
    # and one is DROPPED (nothing survives), which is the pair of outcomes the
    # per-message map has to be able to express.
    let(:mixed_messages) do
      [
        assistant({ "type" => "text", "text" => "let me look" },
                  tool_use(id: "call-1", name: "search", input: { "q" => "cats" })),
        user(tool_result(id: "call-1", content: "old result")),
        assistant(tool_use(id: "call-2", name: "search", input: { "q" => "cats" })),
        user(tool_result(id: "call-2", content: "new result"))
      ]
    end

    def analysis_of(combinator, list) = combinator.stale_tool_use_ids(list)

    def image_of(combinator, message, analysis) = combinator.send(:without_stale, message, analysis)

    it "answers the stale identifiers it would act on, without transforming anything" do
      before = Lain::Canonical.dump(duplicated_messages)
      expect(analysis_of(described_class.new, duplicated_messages)).to eq(["call-1"])
      expect(Lain::Canonical.dump(duplicated_messages)).to eq(before)
    end

    it "is elementwise in that analysis: per-message mapping equals the whole-list call" do
      combinator = described_class.new
      analysis = analysis_of(combinator, duplicated_messages)
      expect(duplicated_messages.flat_map { |message| image_of(combinator, message, analysis) })
        .to eq(combinator.call(duplicated_messages))
    end

    it "traces every surviving message to exactly one input message" do
      combinator = described_class.new
      analysis = analysis_of(combinator, mixed_messages)
      images = mixed_messages.map { |message| image_of(combinator, message, analysis) }

      expect(images.map(&:size)).to eq([1, 0, 1, 1])
      expect(images.flatten(1)).to eq(combinator.call(mixed_messages))
      expect(images.first.first["content"]).to eq([{ "type" => "text", "text" => "let me look" }])
    end

    it "keeps the per-message map a private helper" do
      expect(described_class.new).not_to respond_to(:without_stale)
    end

    # The bytes the whole-span map answered while it was generated from the
    # per-message map, pinned so that writing it out by hand is a refactor and
    # not a change: the rewritten message keeps its text, the stale answer is
    # dropped, and the newest pair survives in order.
    it "answers a span with a stale tool use byte for byte as the generated map did" do
      expected = [assistant({ "type" => "text", "text" => "let me look" }),
                  assistant(tool_use(id: "call-2", name: "search", input: { "q" => "cats" })),
                  user(tool_result(id: "call-2", content: "new result"))]

      expect(Lain::Canonical.dump(described_class.new.call(mixed_messages))).to eq(Lain::Canonical.dump(expected))
    end
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

# The elementwise laws, over the shapes the per-message map has to survive. The
# spans are built eagerly and handed back by a lambda that closes over them: a
# lambda that called back into the group would resolve helpers against whatever
# `self` the law group `instance_exec`s it with.
RSpec.describe Lain::Context::DedupeToolCalls, "the elementwise laws" do
  def self.tool_use(id:, input: { "q" => "cats" })
    { "type" => "tool_use", "id" => id, "name" => "search", "input" => input }
  end

  def self.tool_result(id:, content: "r")
    { "type" => "tool_result", "tool_use_id" => id, "content" => content, "is_error" => false }
  end

  def self.message(role, *blocks) = { "role" => role, "content" => blocks }

  # A stale tool_use superseded by a later identical one: the first call's
  # message is rewritten and its answering tool_result dropped, which is the
  # pair of outcomes a per-message map has to be able to express.
  restated_call = [message("assistant", tool_use(id: "a")), message("user", tool_result(id: "a", content: "old")),
                   message("assistant", tool_use(id: "b")), message("user", tool_result(id: "b", content: "new"))]

  # Deliberately the same SHAPE as the purge combinator's refutation witness,
  # `[m, answer, m]`, where the two `==` messages are ones the call genuinely
  # rewrites: each carries a text block, so dropping the duplicated tool_use
  # leaves content behind rather than emptying the message. Both take the same
  # image, because `#without_stale` is a function of the message and the
  # analysis. Two `==` messages this call never touches would prove nothing.
  repeated = message("assistant", { "type" => "text", "text" => "look" }, tool_use(id: "dup"))
  answer = message("user", tool_result(id: "dup"), { "type" => "text", "text" => "note" })
  spans = [restated_call, [repeated, answer, repeated], []]

  # The conditional law and not the plain homomorphism: splitting a span splits
  # the analysis, so `call(A ++ B) == call(A) ++ call(B)` fails for this
  # combinator while `call(S) == S.flat_map { each(_1, analysis(S)) }` holds.
  include_examples "an elementwise map",
                   instance: -> { described_class.new },
                   spans: -> { spans },
                   operation: :call,
                   each: :without_stale,
                   analysis: :stale_tool_use_ids
end
