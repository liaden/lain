# frozen_string_literal: true

RSpec.describe Lain::StopReason do
  it "knows exactly the non-beta enum" do
    expect(described_class::KNOWN)
      .to contain_exactly(:end_turn, :tool_use, :max_tokens, :stop_sequence, :pause_turn, :refusal)
  end

  # Beta-only. Coding against them on the non-beta path waits for an event that
  # never arrives.
  it "does not pretend the Beta-only reasons exist" do
    expect(described_class::KNOWN).not_to include(:model_context_window_exceeded, :compaction)
  end

  it "normalizes a String" do
    expect(described_class.normalize("tool_use")).to eq(:tool_use)
  end

  # The wire enums are non-exhaustive; an unrecognized value passes through
  # rather than raising, so the state machine needs somewhere to put it.
  it "maps anything unrecognized to :unknown" do
    expect(described_class.normalize("something_new_in_2027")).to eq(:unknown)
    expect(described_class.normalize(nil)).to eq(:unknown)
  end

  it "keeps :stop_sequence, which is easy to forget" do
    expect(described_class.normalize(:stop_sequence)).to eq(:stop_sequence)
  end
end

RSpec.describe Lain::Response do
  let(:blocks) do
    [
      { "type" => "thinking", "thinking" => "hmm" },
      { "type" => "text", "text" => "let me look" },
      { "type" => "tool_use", "id" => "tu_1", "name" => "read_file", "input" => { "path" => "a.rb" } }
    ]
  end

  subject(:response) { described_class.new(content: blocks, stop_reason: :tool_use) }

  it "is frozen" do
    expect(response).to be_frozen
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

  describe "#digest" do
    it "ignores the provider's raw object" do
      a = described_class.new(content: blocks, stop_reason: :tool_use, raw: Object.new)
      b = described_class.new(content: blocks, stop_reason: :tool_use, raw: nil)
      expect(a.digest).to eq(b.digest)
    end

    it "changes with stop_reason" do
      other = described_class.new(content: blocks, stop_reason: :end_turn)
      expect(response.digest).not_to eq(other.digest)
    end
  end
end
