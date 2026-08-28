# frozen_string_literal: true

# The narrow record a spawned chain's turn puts on the telemetry tee in place of
# itself. The WRITE is spec'd where it happens
# (`spec/lain/session_record/scribe_spec.rb`); what is asserted here is the
# VALUE -- the discriminator a journal reader narrows on, the edges it carries,
# and the two readers it deliberately does not answer.
RSpec.describe Lain::Telemetry::QuestionsConsumed do
  subject(:record) { described_class.new(turn: "blake3:head", digests: %w[blake3:q1 blake3:q2]) }

  it "journals under a type a reader can discriminate without inspecting its shape" do
    expect(record.journal_type).to eq("questions_consumed")
    expect(record.to_journal).to include("type" => "questions_consumed", "turn" => "blake3:head",
                                         "digests" => %w[blake3:q1 blake3:q2])
  end

  it "takes its edges off the turn Event's own causal_parents" do
    turn = Lain::Event.turn(role: :user, content: [{ "type" => "text", "text" => "folded" }],
                            causal_parents: %w[blake3:q1])

    expect(described_class.from_event(turn))
      .to have_attributes(turn: turn.digest, digests: %w[blake3:q1])
  end

  # The tripwire the inbox parity rule needs on this side too: {Lain::Telemetry::TurnUsage}
  # is the one record both inbox surfaces read as a committed turn's payment --
  # by class in {Lain::StatusFeed} and by those two readers in
  # {Lain::Frontend::Neovim::InboxView} -- so a record answering both would
  # retire on one surface and not the other.
  it "answers neither #usage nor #digest, so no surface reads it as a turn's payment" do
    expect(record).not_to respond_to(:usage)
    expect(record).not_to respond_to(:digest)
  end

  # {Lain::StatusFeed#<<} routes anything answering `#kind` into its Event arm,
  # which is the arm that moves the fleet and the inbox on a `:turn`.
  it "answers no #kind, so the status feed cannot mistake it for an Event" do
    expect(record).not_to respond_to(:kind)
  end

  it "is deeply frozen, digests included" do
    expect(Ractor.shareable?(record)).to be(true)
  end
end
