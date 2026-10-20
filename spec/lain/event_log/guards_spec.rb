# frozen_string_literal: true

# A turn built through the production factory, so the guards are held over
# whichever event implementation the DAG selects.
RSpec.describe Lain::EventLog::Guards do
  def block(text) = [{ "type" => "text", "text" => text }]

  def turn(role, content)
    Lain::Dag::Factory.event(kind: :turn, body: { "role" => role, "content" => content, "meta" => {} })
  end

  # The turn a render over a head stands on: what a reading or a compaction cut
  # taken on that render is believed on.
  describe ".stands_on" do
    let(:line) do
      Lain::Dag::Factory.timeline(store: Lain::Dag::Factory.store)
                        .commit(role: :user, content: block("ask"))
                        .commit(role: :assistant, content: block("answer"))
    end

    it "is the turn beneath a user turn at the head, which the render added" do
      prompted = line.commit(role: :user, content: block("next"))

      expect(described_class.stands_on(prompted.head)).to eq(line.head_digest)
    end

    it "is the head itself when the head is the model's own turn" do
      expect(described_class.stands_on(line.head)).to eq(line.head_digest)
    end

    it "is nil, the empty chain, beneath a root prompt and for no head at all" do
      expect(described_class.stands_on(line.rewind(1).head)).to be_nil
      expect(described_class.stands_on(nil)).to be_nil
    end
  end

  describe ".pending_tool_use?" do
    let(:torn) do
      turn("assistant", [{ "type" => "tool_use", "id" => "tu_1", "name" => "echo", "input" => {} }])
    end

    it "is defined exactly once in lib/" do
      lib_root = File.expand_path("../../../lib", __dir__)
      definitions = Dir.glob("#{lib_root}/**/*.rb").sum do |file|
        File.read(file).scan(/\bdef\s+(?:self\.)?pending_tool_use\?/).size
      end
      expect(definitions).to eq(1)
    end

    it "answers true for a torn head: an assistant tool_use with no result" do
      expect(described_class.pending_tool_use?(torn)).to be(true)
    end

    it "answers false for no event at all, rather than raising" do
      expect(described_class.pending_tool_use?(nil)).to be(false)
    end

    it "answers false for a settled head: the user event carrying the tool results" do
      expect(described_class.pending_tool_use?(turn("user", block("tool result")))).to be(false)
    end

    it "answers false for an ordinary text answer" do
      expect(described_class.pending_tool_use?(turn("assistant", block("all done")))).to be(false)
    end
  end

  describe ".stranded_prompt?" do
    let(:result) { { "type" => "tool_result", "tool_use_id" => "tu_1", "content" => "ok" } }

    it "answers true for a user turn whose every block is text" do
      expect(described_class.stranded_prompt?(turn("user", block("hi")))).to be(true)
    end

    it "answers false for no event at all, rather than raising" do
      expect(described_class.stranded_prompt?(nil)).to be(false)
    end

    it "answers false for a user turn carrying a tool result" do
      expect(described_class.stranded_prompt?(turn("user", [result]))).to be(false)
    end

    it "answers false for a user turn mixing text with a tool result" do
      expect(described_class.stranded_prompt?(turn("user", block("hi") + [result]))).to be(false)
    end

    it "answers false for an assistant text turn" do
      expect(described_class.stranded_prompt?(turn("assistant", block("hi")))).to be(false)
    end
  end
end
