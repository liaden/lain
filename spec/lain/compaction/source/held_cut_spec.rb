# frozen_string_literal: true

require "stringio"

# Which recorded cut holds on a chain, and the head a new advance is committed
# at. Private to {Lain::Compaction::Source}, so it is reached by name; the
# Source's own spec drives the same rules through whole renders.
RSpec.describe "Lain::Compaction::Source::HeldCut" do
  let(:held_cut) { Lain::Compaction::Source.const_get(:HeldCut) }
  let(:session) { Lain::Session.new(journal: Lain::Journal.new(io: StringIO.new)) }
  let(:arm) { "eager" }
  let(:derived) { Lain::Compaction::Source::Derived.new(keep_last: 2) }

  def block(index) = { "type" => "text", "text" => "the quick brown fox, turn #{index}. " * 12 }

  # Opens on two user turns, then alternates, as the Agent's chains do.
  def role_at(index) = index.odd? && index > 1 ? "assistant" : "user"

  def timeline(size)
    (1..size).inject(Lain::Timeline.empty) { |line, index| line.commit(role: role_at(index), content: [block(index)]) }
  end

  def at(line, index) = line.checkout(line.to_a[index].digest)

  def prompt(line, text) = line.commit(role: "user", content: [{ "type" => "text", "text" => text }])

  def on(line, derived: self.derived) = held_cut.on(session:, timeline: line, derived:, arm:)

  # One advance over whatever is droppable past the cut holding on `line`.
  def advance(line)
    current = on(line)
    head = Lain::Compaction::Head.new(messages: current.remaining, keep_last: derived.keep_last)
    snapshot = Lain::Compaction::SummarySnapshot.take(messages: head.messages,
                                                      eager: Lain::Compaction::Source::NoSummaries)
    outcome = derived.over(line, walk: current.walk, pins: Lain::Context::PinnedMessages::NONE, snapshot:,
                                 cut: current.seam)
    current.advance(outcome)
    session.compaction_cuts.last
  end

  describe "the head an advance is committed at" do
    it "is the turn below an asked prompt, which the ask may still withdraw" do
      line = timeline(6)

      cut = advance(line)

      expect(line.head.role).to eq("user")
      expect(cut.head).to eq(line.to_a[4].digest)
    end

    it "is the head itself when the head is the model's own turn" do
      line = timeline(7)

      cut = advance(line)

      expect(line.head.role).to eq("assistant")
      expect(cut.head).to eq(line.head_digest)
    end
  end

  describe "which cut holds" do
    it "holds through a withdrawal that took only the asked prompt, under the next prompt" do
      line = timeline(6)
      cut = advance(line)

      reasked = prompt(at(line, 4), "the next prompt, in place of the withdrawn one")

      expect(on(reasked).seam.digest).to eq(cut.digest)
    end

    it "holds on a stranded prompt folded into a new one cut from the same parent" do
      line = timeline(6)
      cut = advance(line)

      folded = prompt(at(line, 4), "#{line.head.content.first["text"]} and what was asked next")

      expect(on(folded).seam.digest).to eq(cut.digest)
    end

    it "retreats on a chain that no longer holds the turn it was committed at" do
      line = timeline(6)
      advance(line)

      rewound = prompt(prompt(at(line, 3), "a different road"), "and further along it")

      expect(rewound.length).to eq(line.length)
      expect(on(rewound).seam).to eq(Lain::Compaction::Derivation::UNCUT)
    end

    # The guarantee a resume under a larger `--compact-keep` rests on: a cut
    # never collapses a turn the run's keep_last retains, whatever its head.
    it "does not hold on its own chain under a keep_last that retains the turns it collapsed" do
      line = timeline(6)
      advance(line)

      wider = Lain::Compaction::Source::Derived.new(keep_last: 4)

      expect(on(line, derived: wider).seam).to eq(Lain::Compaction::Derivation::UNCUT)
    end

    it "is not committed again by a render after the withdrawal" do
      line = timeline(6)
      advance(line)

      advance(prompt(at(line, 4), "the next prompt, in place of the withdrawn one"))

      expect(session.compaction_cuts.size).to eq(1)
    end
  end
end
