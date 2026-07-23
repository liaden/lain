# frozen_string_literal: true

RSpec.describe Lain::Context::StaticModel do
  subject(:model) { described_class.new("claude-opus-4-8") }

  describe "the fixed model slot" do
    it "answers #current with the interned id" do
      expect(model.current).to eq("claude-opus-4-8")
    end

    it "reads as the model in string position, like ModelSwitch" do
      expect(model.to_s).to eq("claude-opus-4-8")
    end

    it "interns to a frozen String, like every model the Context hands a Request" do
      expect(model.current).to be_frozen
    end

    it "coerces a Symbol id through #to_s" do
      expect(described_class.new(:"claude-haiku-4-5").current).to eq("claude-haiku-4-5")
    end

    it "is frozen and Ractor-shareable -- no mutable coordination state, unlike ModelSwitch" do
      expect(model).to be_frozen
      expect(Ractor.shareable?(model)).to be(true)
    end
  end

  # The acceptance the card names: a StaticModel-wrapped Context must render
  # BYTE-IDENTICALLY to the old bare-String path.
  describe "byte-identical render against the bare-String path" do
    let(:store) { Lain::Store.new }
    let(:toolset) { Lain::Toolset.new }
    let(:timeline) do
      Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => "hello" }])
    end

    it "produces the same Request digest whether the model is a String or a StaticModel" do
      as_string = Lain::Context.new(model: "claude-opus-4-8", max_tokens: 64)
      as_static = Lain::Context.new(model: described_class.new("claude-opus-4-8"), max_tokens: 64)

      string_request = as_string.render(timeline:, toolset:)
      static_request = as_static.render(timeline:, toolset:)

      expect(static_request.model).to eq("claude-opus-4-8")
      expect(static_request.digest).to eq(string_request.digest)
      expect(static_request.cache_payload).to eq(string_request.cache_payload)
    end
  end
end
