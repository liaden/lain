# frozen_string_literal: true

RSpec.describe Lain::Effect do
  let(:tool_call) { Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "echo", input: { text: "hi" }) }
  let(:approval) { Lain::Effect::Approval.new(effect: tool_call) }
  let(:model_call) { Lain::Effect::ModelCall.new(request: :some_request) }

  describe "kind predicates" do
    # The reading sites (Handler#handles?) ask an effect what it is rather than
    # matching its class, so the predicate must be TOTAL over the vocabulary --
    # every effect answers both questions, defaulting to false, with no
    # respond_to? guard and no rescue anywhere in the call path.
    it "answers tool_call? true only for a ToolCall" do
      expect(tool_call.tool_call?).to be(true)
      expect(approval.tool_call?).to be(false)
      expect(model_call.tool_call?).to be(false)
    end

    it "answers approval? true only for an Approval" do
      expect(approval.approval?).to be(true)
      expect(tool_call.approval?).to be(false)
      expect(model_call.approval?).to be(false)
    end

    it "a bare effect kind (ModelCall) answers both predicates false" do
      expect(model_call.tool_call?).to be(false)
      expect(model_call.approval?).to be(false)
    end
  end

  describe "value semantics" do
    # Effects are frozen Data values (a ToolCall is not deeply Ractor-shareable
    # only because its `input` Hash is caller-supplied and unfrozen -- deep
    # shareability is the Turn's contract, not the effect's).
    it "is a frozen Data value" do
      expect(tool_call).to be_frozen
      expect(approval).to be_frozen
      expect(model_call).to be_frozen
    end

    it "interns tool_use_id and name as frozen Strings" do
      expect(tool_call.tool_use_id).to eq("tu_1")
      expect(tool_call.name).to eq("echo")
      expect(tool_call.tool_use_id).to be_frozen
      expect(tool_call.name).to be_frozen
    end

    it "equates two effects with equal fields" do
      twin = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "echo", input: { text: "hi" })
      expect(tool_call).to eq(twin)
    end
  end
end
