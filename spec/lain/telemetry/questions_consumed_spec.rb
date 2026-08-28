# frozen_string_literal: true

require "json"
require "tmpdir"

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

  # The record's one producer, {Lain::Event#normalize_causal}, always hands it
  # an Array -- but a `Data.define` constructor is public, and `Canonical.normalize`
  # passes a bare String through unchanged rather than wrapping it. Left alone,
  # that makes `digests: "blake3:q1"` constructible, and both inbox surfaces
  # raise on it (`Inbox#retire` calls `#each`, `InboxView#retire` calls
  # `#inject`) rather than treating the record as malformed. The record
  # guarantees its own shape instead of trusting whoever calls `.new` next.
  it "wraps a bare digest handed in without an array" do
    lone = described_class.new(turn: "blake3:head", digests: "blake3:q1")

    expect(lone.digests).to eq(%w[blake3:q1])
  end

  it "normalizes no digests at all to an empty list, not nil" do
    empty = described_class.new(turn: "blake3:head", digests: nil)

    expect(empty.digests).to eq([])
  end

  it "dedupes a repeated digest while keeping first-seen order" do
    repeated = described_class.new(turn: "blake3:head", digests: %w[blake3:q2 blake3:q1 blake3:q2])

    expect(repeated.digests).to eq(%w[blake3:q2 blake3:q1])
  end

  # `Event#normalize_causal` sorts because a causal edge SET is canonicalized
  # into a hashed payload; this record hashes nothing and neither consumer is
  # order-sensitive, so sorting here bought nothing on the production path
  # while adding a new failure mode of its own: `sort` raises
  # `ArgumentError: comparison failed` on any element two elements can't be
  # ordered against, which turns a still-harmless shape (a stray non-String
  # digest, which `Inbox#retire` merely `each`-es into a Set) into a
  # constructor raise -- the opposite of what this card exists to fix.
  it "does not raise on elements an ordering cannot compare, since nothing here sorts them" do
    expect { described_class.new(turn: "blake3:head", digests: ["blake3:q1", nil]) }.not_to raise_error
    expect { described_class.new(turn: "blake3:head", digests: [1, "blake3:q1"]) }.not_to raise_error
    expect { described_class.new(turn: "blake3:head", digests: [{ "a" => 1 }, { "b" => 2 }]) }.not_to raise_error
  end

  # Drives the two REAL inbox surfaces with no double between them: the defect
  # this guards against is exactly that a malformed record reaches production
  # code that assumes an Array, so the assertion has to be that code, not a
  # stand-in for it. The status arm goes in through {Lain::StatusFeed#<<},
  # which is the code that actually reads `#digests` in production
  # ({StatusFeed#observe_consumption}) -- handing `Inbox` a pre-unwrapped
  # `.digests` would bypass that reader and leave the arm's half of this
  # example proving nothing a rename of the member wouldn't also survive.
  # {Lain::Frontend::Neovim::InboxView#update} is the nvim arm's equivalent
  # public entry, reaching the same read through `#consume`.
  it "leaves both inbox surfaces unraised across every shape a caller might hand it", :seam do
    Dir.mktmpdir("t7-questions-consumed-seam") do |dir|
      store = Lain::Store.new
      parent = Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => "seed" }])
      question = Lain::Event::ChainWriter.new.put(parent, kind: :message, from: "orchestrator", to: "human",
                                                          causal_parents: [], body: { "question" => "which db?" })
      shapes = [
        described_class.new(turn: "blake3:head", digests: question.digest),
        described_class.new(turn: "blake3:head", digests: nil),
        described_class.new(turn: "blake3:head", digests: [question.digest])
      ]
      feed = Lain::StatusFeed.new(path: File.join(dir, "state.json"), store:)
      view = Lain::Frontend::Neovim::InboxView.new(store:)

      feed << question
      view.update(Lain::Telemetry::Message.from_event(question))

      rendered = nil
      shapes.each do |shape|
        expect { feed << shape }.not_to raise_error
        moved = nil
        expect { moved = view.update(shape) }.not_to raise_error
        rendered = moved if moved
      end

      # Proves both arms were actually entered, not merely silent: the real
      # question retires off each real reader -- on disk for the status feed,
      # back to the empty placeholder for the nvim view.
      expect(JSON.parse(File.read(File.join(dir, "state.json")))["inbox_count"]).to eq(0)
      expect(rendered).to eq(Lain::Frontend::Neovim::InboxView::EMPTY)
    end
  end
end
