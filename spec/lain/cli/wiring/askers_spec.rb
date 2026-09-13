# frozen_string_literal: true

require "async"

RSpec.describe Lain::CLI::Wiring::Askers do
  let(:store) { Lain::Store.new }
  let(:timeline) do
    Lain::Timeline.empty(store:)
                  .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
  end
  let(:askers) { described_class.new(observer: Lain::Event::ChainWriter::Null.new) }

  # {Tools::AskHuman}'s `parent:` is the idiom {Lain.live} generalizes: the
  # toolset is built before the Agent whose Timeline it asks against exists,
  # so the wiring hands a thunk and the read happens at the instant a question
  # is actually asked, not at enrolment.
  it "reads a callable timeline source lazily, at ask time rather than at enrol time" do
    called = false
    source = lambda do
      called = true
      timeline
    end

    asker = askers.enrol(source).asker
    expect(called).to be(false)

    Sync { asker.ask("which file?") }

    expect(called).to be(true)
  end
end
