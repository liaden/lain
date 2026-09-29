# frozen_string_literal: true

RSpec.describe Lain::Response do
  subject(:response) { described_class.new(content: blocks, stop_reason: :tool_use) }

  let(:blocks) do
    [
      { "type" => "thinking", "thinking" => "hmm" },
      { "type" => "text", "text" => "let me look" },
      { "type" => "tool_use", "id" => "tu_1", "name" => "read_file", "input" => { "path" => "a.rb" } }
    ]
  end

  it "is frozen" do
    expect(response).to be_deeply_frozen
  end

  # Correctness gate 1: the FULL block list is what gets appended to the
  # Timeline. Extracting only text and discarding thinking or tool_use corrupts
  # the very next turn.
  it "retains thinking and tool_use blocks, not just text" do
    expect(response.content.map { |b| b["type"] }).to eq(%w[thinking text tool_use])
  end

  it "defaults usage to the monoid identity" do
    expect(described_class.new(content: [], stop_reason: :end_turn).usage).to eq(Lain::Usage.zero)
  end

  describe "#tool_uses" do
    it "returns only tool_use blocks" do
      expect(response.tool_uses.map { |b| b["name"] }).to eq(["read_file"])
    end

    # Nothing above the Provider should have to know that Anthropic's streaming
    # path hands back `input` as a raw JSON String.
    it "exposes input as a parsed Hash" do
      expect(response.tool_uses.first["input"]).to eq({ "path" => "a.rb" })
    end

    it "is empty when there are none" do
      expect(described_class.new(content: [], stop_reason: :end_turn).tool_uses).to eq([])
    end

    # The lens is a VIEW: named readers for the runner, Hash-duck reads for
    # everyone else, and the underlying block hash untouched.
    it "hands back ToolUse lenses over the raw blocks" do
      use = response.tool_uses.first

      expect(use).to be_a(Lain::Response::ToolUse)
      expect(use.id).to eq("tu_1")
      expect(use.to_h).to be(response.content.last)
    end
  end

  it "answers tool_use?" do
    expect(response).to be_tool_use
    expect(described_class.new(content: [], stop_reason: :end_turn)).not_to be_tool_use
  end

  describe "#text" do
    it "concatenates text blocks only" do
      expect(response.text).to eq("let me look")
    end

    it "is empty when the model only thought and called a tool" do
      quiet = described_class.new(content: [blocks.first, blocks.last], stop_reason: :tool_use)
      expect(quiet.text).to eq("")
    end
  end

  describe "#failure" do
    def stopped(reason, text: "")
      described_class.new(content: [{ "type" => "text", "text" => text }], stop_reason: reason)
    end

    it "is nil for an answer that finished or is still mid-loop" do
      failures = %i[end_turn stop_sequence tool_use pause_turn].map { |reason| stopped(reason).failure }

      expect(failures).to all(be_nil)
    end

    it "says a max_tokens stop before finishing, and keeps the text" do
      failure = stopped(:max_tokens, text: "partial").failure

      expect(failure.message).to eq("model hit max_tokens before finishing")
      expect(failure.withholds_text?).to be(false)
    end

    it "names a refusal and an unrecognized wire reason" do
      expect(stopped(:refusal).failure.message).to include("refused")
      expect(stopped("coined_in_2099").failure.message).to include("unrecognized")
    end

    it "withholds the text of a malformed turn and says it was a tool call written as prose" do
      failure = stopped(:malformed, text: "<function=bash>").failure

      expect(failure.withholds_text?).to be(true)
      expect(failure.message).to include("malformed", "written as prose", "malformed_response journal record")
    end

    it "says a malformed turn with no text said nothing at all" do
      expect(stopped(:malformed).failure.message).to include("said nothing at all")
    end

    it "stays deeply frozen" do
      expect(Ractor.shareable?(stopped(:malformed).failure)).to be(true)
    end
  end

  describe "#digest" do
    it "ignores the provider's raw object" do
      a = described_class.new(content: blocks, stop_reason: :tool_use, raw: Object.new)
      b = described_class.new(content: blocks, stop_reason: :tool_use, raw: nil)
      expect(a).to have_same_digest_as(b)
    end

    it "changes with stop_reason" do
      other = described_class.new(content: blocks, stop_reason: :end_turn)
      expect(response).not_to have_same_digest_as(other)
    end
  end

  # The reading lain makes of a wire reply has to survive construction: a
  # Response that rewrote it to :unknown would still fail the turn, under the
  # wrong diagnostic.
  describe "stop_reason admission" do
    it "keeps a malformed reading the provider already typed" do
      expect(described_class.new(content: [], stop_reason: Lain::StopReason::MALFORMED).stop_reason)
        .to eq(:malformed)
    end

    it "reads a wire String spelling malformed as unrecognized, not as lain's own reading" do
      expect(described_class.new(content: [], stop_reason: "malformed").stop_reason).to eq(:unknown)
    end
  end
end
