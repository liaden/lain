# frozen_string_literal: true

RSpec.describe Lain::Tools::AskHuman::Notifying do
  let(:store) { Lain::Store.new }
  let(:parent) do
    Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
  end

  it "announces the question to the injected callable and still returns the promise" do
    announced = []
    tool = described_class.new(notify: announced.method(:push), parent:)

    promise = tool.ask("Which port?")

    expect(announced).to eq(["Which port?"])
    expect(promise).to be_a(Lain::Promise)
  end

  it "announces before a reply could possibly race the ask (the Q event is already in the Store)" do
    seen_pending = nil
    tool = described_class.new(notify: ->(_q) { seen_pending = true }, parent:)

    tool.ask("Ready?")

    expect(seen_pending).to be(true)
    expect(tool.last_question).not_to be_nil
  end
end
