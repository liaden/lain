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

  describe "a collapse over the cuts it holds" do
    # Two advances, at 6 and at 8 turns, so two cuts hold on the longer chain.
    def two_advances
      line = timeline(6)
      advance(line)
      longer = grow(line, 7..8)
      advance(longer)
      longer
    end

    def grow(line, indices)
      indices.inject(line) { |grown, index| grown.commit(role: role_at(index), content: [block(index)]) }
    end

    def collapse(line)
      current = on(line)
      snapshot = Lain::Compaction::SummarySnapshot.take(messages: current.stretch.messages,
                                                        eager: Lain::Compaction::Source::NoSummaries)
      current.advance(derived.collapsed(current.stretch, pins: Lain::Context::PinnedMessages::NONE, snapshot:))
      session.compaction_cuts.last
    end

    it "is offered only while more than one cut holds" do
      line = timeline(6)
      advance(line)
      expect(on(line)).not_to be_collapsible

      expect(on(two_advances)).to be_collapsible
    end

    it "shows the summarizer the held replacements, and the turns between them, as the stretch it collapses" do
      line = two_advances

      stretch = on(line).stretch.messages

      expect(stretch).to eq(on(line).messages.first(stretch.size))
      expect(stretch.size).to eq(2)
    end

    it "records a collapse cut that supersedes every cut it held, past the last of them" do
      line = two_advances
      advances = session.compaction_cuts.dup

      cut = collapse(line)

      expect(cut).to have_attributes(kind: "collapse", supersedes: advances.map(&:address),
                                     parent: advances.last.address, digest: advances.last.digest,
                                     head: Lain::Event.stands_on(line.head))
      expect(cut.spans).to eq([[line.to_a[0].digest, line.to_a[5].digest]])
    end

    it "holds the collapse alone, folding the cuts it supersedes out of the seam" do
      line = two_advances
      cut = collapse(line)

      held = on(line)

      expect(held.seam.collapses).to eq(cut.collapses)
      expect(held).not_to be_collapsible
      expect(held.messages.size).to eq(3)
    end

    it "records the advance past a collapse as the collapse's child" do
      line = two_advances
      cut = collapse(line)
      longer = grow(line, 9..10)

      advanced = advance(longer)

      expect(advanced).to have_attributes(kind: "advance", supersedes: [], parent: cut.address)
      expect(on(longer).seam.collapses).to eq(cut.collapses + advanced.collapses)
    end
  end
end
