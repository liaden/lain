# frozen_string_literal: true

# The one mint for a tool_result that answers a call the conversation carries
# no real result for. Every repair -- a torn run, a failed settle, a stranded
# head met at the next ask or at load -- answers through here, so the shape
# cannot differ between them and only the sentence says which repair it was.
RSpec.describe Lain::Tool::Cancellation do
  def tool_use(id, name = "echo") = { "type" => "tool_use", "id" => id, "name" => name, "input" => {} }

  let(:head) do
    Lain::Timeline.empty(store: Lain::Store.new)
                  .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
                  .commit(role: :assistant,
                          content: [{ "type" => "text", "text" => "calling" }, tool_use("tu_1"), tool_use("tu_2")])
                  .head
  end

  describe "#blocks" do
    it "answers every tool_use in the head, in the order the model made them" do
      blocks = described_class.new(head, kind: :unknown).blocks

      expect(blocks.map { |block| block["tool_use_id"] }).to eq(%w[tu_1 tu_2])
      expect(blocks.map { |block| block["type"] }).to all(eq("tool_result"))
    end

    it "reports every answer as an error, so nothing claims the tool produced output" do
      expect(described_class.new(head, kind: :errored).blocks.map { |block| block["is_error"] }).to all(be(true))
    end

    it "builds through Tool::ResultBlock, the sole writer of the shape" do
      block = described_class.new(head, kind: :unknown).blocks.first

      expect(block).to eq(Lain::Tool::ResultBlock.of(Lain::Tool::Result.error(described_class::NOTICES.fetch(:unknown)),
                                                     tool_use_id: "tu_1").to_h)
    end

    it "differs between kinds only in the sentence" do
      unknown, errored = %i[unknown errored].map { |kind| described_class.new(head, kind:).blocks }

      expect(unknown.map { |block| block.except("content") }).to eq(errored.map { |block| block.except("content") })
      expect(unknown.map { |block| block["content"] }).not_to eq(errored.map { |block| block["content"] })
    end

    it "is a frozen value" do
      cancellation = described_class.new(head, kind: :unknown)

      expect(cancellation).to be_frozen
      expect(cancellation.blocks).to be_frozen
    end
  end

  describe "the notices" do
    let(:notices) { described_class::NOTICES }

    it "names four kinds, each with its own sentence" do
      expect(notices.keys).to contain_exactly(:unknown, :never_dispatched, :was_running, :errored)
      expect(notices.values.uniq.size).to eq(4)
      expect(notices.values).to all(be_frozen)
    end

    it "lets the three no-result kinds share the fact verbatim and differ only after it" do
      no_result = notices.values_at(:unknown, :never_dispatched, :was_running)

      expect(no_result).to all(start_with("#{described_class::NO_RESULT} "))
      expect(notices.fetch(:unknown)).to end_with(described_class::EFFECTS_UNKNOWN)
    end

    # A result that existed but could not be recorded is neither "cancelled"
    # nor "no result": the call ran, and what failed was the run around it.
    it "says an errored call errored, not that it was cancelled or produced nothing" do
      errored = notices.fetch(:errored)

      expect(errored).to match(/error/i)
      expect(errored).not_to start_with(described_class::NO_RESULT)
      expect(errored).not_to match(/cancel/i)
    end
  end

  describe ".block" do
    it "mints one answer for one id" do
      expect(described_class.block("tu_9", :was_running))
        .to include("tool_use_id" => "tu_9", "content" => described_class::NOTICES.fetch(:was_running),
                    "is_error" => true)
    end

    it "refuses a kind it has no sentence for" do
      expect { described_class.block("tu_9", :interrupted) }.to raise_error(KeyError, /interrupted/)
    end
  end

  # Gate 4 refuses a result naming no tool_use. Translated into a name of its
  # own, so a repair running on the way out of another failure can tell it
  # from a genuine bug and let the failure it was handling through.
  describe "an unpairable call" do
    it "is refused namedly rather than as the builder's ArgumentError" do
      anonymous = Lain::Event.turn(role: :assistant,
                                   content: [{ "type" => "tool_use", "name" => "echo", "input" => {} }])

      expect { described_class.new(anonymous, kind: :unknown) }
        .to raise_error(described_class::Unpairable, /non-empty String id/)
    end

    it "is a Lain::Error, so the exe maps it to a message" do
      expect(described_class::Unpairable.ancestors).to include(Lain::Error)
    end
  end
end
