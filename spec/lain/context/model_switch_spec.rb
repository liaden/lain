# frozen_string_literal: true

require "stringio"

RSpec.describe Lain::Context::ModelSwitch do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:switch) { described_class.new("claude-opus-4-8", journal:) }

  def switches
    Lain::Journal.records(journal_io.string.lines, type: "model_switch").to_a
  end

  describe "the delegating slot" do
    it "answers the initial model until switched" do
      expect(switch.current).to eq("claude-opus-4-8")
    end

    it "answers the new model after a switch" do
      switch.switch("claude-haiku-4-5", surface: "tty")
      expect(switch.current).to eq("claude-haiku-4-5")
    end

    it "reads as the current model in string position" do
      expect(switch.to_s).to eq("claude-opus-4-8")
    end

    it "stores the id VERBATIM -- an unknown model must fail loudly at dispatch, never fall back" do
      switch.switch("totally-bogus-model", surface: "tty")
      expect(switch.current).to eq("totally-bogus-model")
    end

    it "answers frozen strings, like every model the Context hands a Request" do
      switch.switch(:"claude-haiku-4-5", surface: "tty")
      expect(switch.current).to be_frozen
    end
  end

  describe "the journaled change" do
    it "journals each switch with the old model, the new model, and the deciding surface" do
      switch.switch("claude-haiku-4-5", surface: "tty")

      expect(switches).to contain_exactly(
        a_hash_including("from" => "claude-opus-4-8", "to" => "claude-haiku-4-5", "surface" => "tty")
      )
    end

    it "journals nothing at construction" do
      switch
      expect(switches).to be_empty
    end
  end

  # The seam reality the card names: Agent's @context is construction-fixed and
  # call_model always renders from it, so /model works by the Context reading
  # this slot at render time. A deliberate, journaled impurity with an obvious
  # cache consequence -- a model change breaks the cached prefix anyway. A
  # String-modeled Context is untouched (context_spec.rb's purity examples).
  describe "read at render time by a Context holding the switch" do
    let(:store) { Lain::Store.new }
    let(:toolset) { Lain::Toolset.new }
    let(:timeline) do
      Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => "hello" }])
    end

    it "renders the model in force at render time, not at construction" do
      context = Lain::Context.new(model: switch, max_tokens: 64)

      before = context.render(timeline:, toolset:)
      switch.switch("claude-haiku-4-5", surface: "tty")
      after = context.render(timeline:, toolset:)

      expect([before.model, after.model]).to eq(%w[claude-opus-4-8 claude-haiku-4-5])
    end

    it "reads through Context#model, so session headers record the model in force" do
      context = Lain::Context.new(model: switch, max_tokens: 64)
      switch.switch("claude-haiku-4-5", surface: "tty")

      expect(context.model).to eq("claude-haiku-4-5")
    end

    it "grafts onto an already-built Context via #with_model, keeping everything else" do
      built = Lain::Context.new(model: "claude-opus-4-8", max_tokens: 64, system: "be terse")
      grafted = built.with_model(switch)
      switch.switch("claude-haiku-4-5", surface: "tty")

      request = grafted.render(timeline:, toolset:)
      expect(request.model).to eq("claude-haiku-4-5")
      expect([grafted.max_tokens, grafted.system]).to eq([64, "be terse"])
    end
  end
end
