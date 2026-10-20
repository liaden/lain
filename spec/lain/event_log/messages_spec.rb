# frozen_string_literal: true

RSpec.describe Lain::EventLog::Messages do
  let(:line) do
    Lain::Dag::Factory.timeline(store: Lain::Dag::Factory.store)
                      .commit(role: :user, content: [{ "type" => "text", "text" => "ask" }])
                      .commit(role: :assistant, content: [{ "type" => "text", "text" => "answer" }])
  end

  describe ".project" do
    it "is the root-first role and content of each turn" do
      expect(described_class.project(line.to_a))
        .to eq([{ "role" => "user", "content" => [{ "type" => "text", "text" => "ask" }] },
                { "role" => "assistant", "content" => [{ "type" => "text", "text" => "answer" }] }])
    end

    it "is deeply frozen, so Ractor shareable" do
      expect(Ractor.shareable?(described_class.project(line.to_a))).to be(true)
    end

    it "is empty for no turns" do
      expect(described_class.project([])).to eq([])
    end
  end
end
