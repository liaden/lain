# frozen_string_literal: true

RSpec.describe Lain::Journal::Line do
  describe ".classify" do
    def classify(line, last: false) = described_class.classify(line, last:)

    it "calls a JSON object a record" do
      expect(classify(%({"type":"turn"}\n))).to eq(:record)
    end

    it "calls an already-parsed Hash a record" do
      expect(classify({ type: "turn" })).to eq(:record)
    end

    it "calls a whitespace-only line blank" do
      expect(classify("  \n")).to eq(:blank)
    end

    it "calls JSON that is not an object another writer's line" do
      expect(classify("[1,2]\n")).to eq(:foreign)
    end

    it "calls a non-String, non-Hash entry foreign" do
      expect(classify(42)).to eq(:foreign)
    end

    it "calls an unparseable last line without its newline the tail" do
      expect(classify(%({"type":"tu), last: true)).to eq(:tail)
    end

    it "calls an unparseable line damage when it is not the last" do
      expect(classify(%({"type":"tu))).to eq(:damage)
    end

    it "calls an unparseable last line damage when it carries its newline" do
      expect(classify(%({"type":"tu\n), last: true)).to eq(:damage)
    end

    it "lets a whole record win over the tail test" do
      expect(classify(%({"type":"turn"}), last: true)).to eq(:record)
    end
  end
end
