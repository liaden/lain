# frozen_string_literal: true

# lain://tree: every head the view has seen, drawn as a tree with the live chain as its trunk.
RSpec.describe Lain::Frontend::Neovim::TreeView do
  let(:store) { Lain::Dag::Factory.store }
  let(:session) { Lain::Session.new }
  let(:view) { described_class.new(store:, session:) }
  # Four turns, a rewind to the second, then two others.
  let(:first) { say(Lain::Dag::Factory.timeline(store:), :user, "one") }
  let(:second) { say(first, :assistant, "two") }
  let(:third) { say(second, :user, "three") }
  let(:fourth) { say(third, :assistant, "four") }
  let(:third_again) { say(second, :user, "three again") }
  let(:fourth_again) { say(third_again, :assistant, "four again") }

  def say(timeline, role, text)
    timeline.commit(role:, content: [{ "type" => "text", "text" => text }])
  end

  def usage(timeline)
    Lain::Telemetry::TurnUsage.new(digest: timeline.head_digest, model: "m", stop_reason: :end_turn, usage: {})
  end

  def rewound(from, to) = { "type" => "rewound", "from" => from.head_digest, "to" => to.head_digest }

  def branched
    view.update(usage(fourth))
    view.update(rewound(fourth, second))
    view.update(usage(fourth_again))
  end

  it "says so before any turn" do
    expect(view.initial).to eq(["(no turns yet)"])
  end

  it "draws a chain as one flat trunk with the head marked" do
    expect(view.update(usage(second))).to eq(["user: one", "assistant: two  [head]"])
  end

  it "ignores an event that names no turn" do
    expect(view.update(Object.new)).to be_nil
  end

  it "draws a rewound branch indented and marked abandoned, the new turns following the trunk" do
    expect(branched).to eq(["user: one", "assistant: two",
                            "  user: three  [abandoned]", "  assistant: four  [abandoned]",
                            "user: three again", "assistant: four again  [head]"])
  end

  it "marks the rewind target as the head before anything new lands" do
    view.update(usage(fourth))

    expect(view.update(rewound(fourth, second))).to eq(["user: one", "assistant: two  [head]",
                                                        "user: three  [abandoned]", "assistant: four  [abandoned]"])
  end

  it "ends a line with the label of its turn" do
    session.record_label(second.head_digest, "before refactor")

    expect(view.update(usage(second))).to eq(["user: one", "assistant: two  [head]  # before refactor"])
  end

  it "redraws when a label moved even though the event names no turn" do
    view.update(usage(second))
    session.record_label(first.head_digest, "start")

    expect(view.update(Object.new)).to eq(["user: one  # start", "assistant: two  [head]"])
  end

  it "answers nil when nothing moved" do
    view.update(usage(second))

    expect(view.update(usage(second))).to be_nil
  end

  it "keeps one line per turn when a preview holds a newline" do
    two = say(first, :assistant, "a\nb")

    expect(view.update(usage(two)).last).to eq("assistant: a b  [head]")
  end

  it "names a head the store does not hold" do
    event = Lain::Telemetry::TurnUsage.new(digest: "blake3:nope", model: "m", stop_reason: :end_turn, usage: {})

    expect(view.update(event)).to eq(["(turn not in store)  [head]"])
  end

  describe "#digest_at" do
    it "names the turn each drawn line shows" do
      branched

      expect([1, 3, 6].map { |line| view.digest_at(line) })
        .to eq([first.head_digest, third.head_digest, fourth_again.head_digest])
    end

    it "names nothing for a line off the buffer" do
      branched

      expect([0, 7].map { |line| view.digest_at(line) }).to eq([nil, nil])
    end
  end

  describe "#pick" do
    before { branched }

    it "offers a turn of the live chain for rewinding" do
      pick = view.pick(1, generation: view.generation)

      expect([pick.rewindable?, pick.digest]).to eq([true, first.head_digest])
    end

    it "refuses an abandoned turn in words" do
      pick = view.pick(3, generation: view.generation)

      expect(pick.rewindable?).to be(false)
      expect(pick.report).to include("abandoned branch").and(satisfy { |text| !text.include?("fork") })
    end

    it "refuses a line that names no turn" do
      expect(view.pick(9, generation: view.generation).report).to include("no turn on lain://tree line 9")
    end
  end

  describe "#label" do
    before { branched }

    it "journals the label for the turn under the line" do
      outcome = view.label(3, "idea 2", generation: view.generation)

      expect([outcome.labeled?, session.labels]).to eq([true, { third.head_digest => "idea 2" }])
    end

    it "refuses a line that names no turn and labels nothing" do
      outcome = view.label(9, "x", generation: view.generation)

      expect([outcome.labeled?, session.labels]).to eq([false, {}])
    end
  end

  describe "stamping" do
    it "bumps the generation when the drawn turns change, so a held line can be told stale" do
      view.update(usage(second))
      before = view.generation
      view.update(usage(third))

      expect(view.generation).to be > before
    end

    it "keeps the generation when only a label moved the text" do
      view.update(usage(second))
      before = view.generation
      session.record_label(first.head_digest, "start")
      view.update(Object.new)

      expect(view.generation).to eq(before)
    end

    it "refuses a rewind pressed on an older rendering, whatever turn now sits on the line" do
      view.update(usage(second))
      old = view.generation
      view.update(usage(third))

      pick = view.pick(1, generation: old)

      expect(pick.rewindable?).to be(false)
      expect(pick.report).to include("changed")
    end

    it "refuses a label whose rendering moved while the prompt was open, and labels nothing" do
      view.update(usage(second))
      old = view.generation
      view.update(usage(third))

      outcome = view.label(1, "late", generation: old)

      expect([outcome.labeled?, session.labels]).to eq([false, {}])
    end

    it "hands back the redrawn lines with the label in them, with no further event" do
      view.update(usage(second))

      outcome = view.label(1, "start", generation: view.generation)

      expect(outcome.lines).to eq(["user: one  # start", "assistant: two  [head]"])
      expect(outcome.generation).to eq(view.generation)
    end
  end
end
