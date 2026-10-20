# frozen_string_literal: true

RSpec.describe Lain::CLI::HumanNotes do
  let(:store) { Lain::Dag::Factory.store }
  let(:mailbox) do
    Lain::Context::Mailbox::Live.new(recipient: Lain::Event::ChainWriter.method(:correlation_of), observer: ->(_) {})
  end
  let(:flight) { [true] }
  let(:notes) { described_class.new(mailbox:, in_flight: -> { flight.first }) }
  let(:timeline) { Lain::Dag::Factory.timeline(store:).commit(role: :user, content: [{ "type" => "text", "text" => "go" }]) }

  def folded_texts = mailbox.capture(timeline).pending.map { |note| [note.from, note.body.fetch("text")] }

  it "queues prose typed while an ask is in flight as a note from the human" do
    expect(notes.take?("prefer Syncthing")).to be(true)
    expect(folded_texts).to eq([["human", "prefer Syncthing"]])
  end

  it "declines a slash command, which keeps its place as the next prompt" do
    expect(notes.take?("/model")).to be(false)
    expect(notes.pending?(timeline)).to be(false)
  end

  it "declines a slash command typed after leading spaces" do
    expect(notes.take?("  /stop")).to be(false)
  end

  it "declines a line that says nothing" do
    expect(notes.take?("   ")).to be(false)
  end

  it "declines prose when no ask is in flight" do
    flight.replace([false])

    expect(notes.take?("prefer Syncthing")).to be(false)
  end

  it "declines prose before the chat has a conductor to ask" do
    flight.replace([nil])

    expect(notes.take?("prefer Syncthing")).to be(false)
  end

  it "says a note is pending until a turn on the chain names it" do
    notes.take?("prefer Syncthing")
    before = notes.pending?(timeline)
    after = timeline.commit(role: :assistant, content: [{ "type" => "text", "text" => "ok" }],
                            causal_parents: mailbox.capture(timeline).folded)

    expect([before, notes.pending?(after)]).to eq([true, false])
  end

  it "hands its mailbox to whoever builds the agent" do
    expect(notes.mailbox).to be(mailbox)
  end

  describe "Null" do
    subject(:null) { described_class::Null }

    it "declines every line, has nothing pending, and lends the agent no inbox" do
      expect([null.take?("prefer Syncthing"), null.pending?(timeline), null.mailbox])
        .to eq([false, false, Lain::Context::Mailbox::Null])
    end
  end
end
