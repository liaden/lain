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

  # The one kind exempt from the boundary rule above, and the exemption IS the
  # ruling: a handoff fires because the keep_last tail is what would not fit,
  # so a handoff that kept keep_last would be one that made no room. The kind
  # is on the record, which is what lets a resume take the same exemption.
  describe "a handoff cut" do
    def hand_off(line)
      current = on(line)
      current.hand_off(current.handoff(pins: Lain::Context::PinnedMessages::NONE).ranges, "the state document")
      session.compaction_cuts.last
    end

    it "collapses everything but the ask, past the keep_last boundary" do
      line = timeline(6)

      cut = hand_off(line)

      expect(cut).to have_attributes(kind: "handoff", supersedes: [], head: Lain::Event.stands_on(line.head))
      expect(cut.spans).to eq([[line.to_a[0].digest, line.to_a[4].digest]])
    end

    it "holds on its own chain where an advance collapsing the same turns would not" do
      line = timeline(6)
      cut = hand_off(line)

      expect(on(line).seam.digest).to eq(cut.digest)
      expect(on(line).seam.keeps_last).to be(false)
    end

    it "renders the document and the ask, and nothing else" do
      line = timeline(6)
      hand_off(line)

      expect(on(line).messages.map { |message| message["content"].first["text"] })
        .to eq(["the state document", block(6)["text"]])
    end

    it "supersedes the cuts that held, so no earlier summary is rendered beside it" do
      line = timeline(6)
      advanced = advance(line)

      cut = hand_off(line)

      expect(cut.supersedes).to eq([advanced.address])
      expect(on(line).seam.collapses).to eq(cut.collapses)
    end

    describe "#kept" do
      def round(id, body)
        [["assistant", [{ "type" => "tool_use", "id" => id, "name" => "read", "input" => {} }]],
         ["user", [{ "type" => "tool_result", "tool_use_id" => id, "content" => body }]]]
      end

      def asking
        [["user", [block(1)]], ["assistant", [block(2)]], ["user", [{ "type" => "text", "text" => "the ask" }]],
         *round("call-1", "answered"), *round("call-2", "unanswered")]
          .inject(Lain::Timeline.empty) { |line, (role, content)| line.commit(role:, content:) }
      end

      def texts(messages) = messages.map { |message| message["content"].first.values_at("text", "content").compact }

      it "is the ask and the round nothing has answered yet" do
        kept = on(asking).kept(pins: Lain::Context::PinnedMessages::NONE)

        expect(texts(kept)).to eq([["the ask"], [], ["unanswered"]])
      end

      it "keeps a pinned turn in its place" do
        messages = on(asking).walk.messages
        pins = Lain::Context::PinnedMessages.new([messages.first], candidates: messages)

        expect(texts(on(asking).kept(pins:)).first).to eq([block(1)["text"]])
      end

      it "is empty when there is nothing left to hand off" do
        line = asking
        hand_off(line)

        expect(on(line).kept(pins: Lain::Context::PinnedMessages::NONE)).to be_empty
      end
    end

    describe "#holds_newest?" do
      it "is false with no cut on the chain" do
        expect(on(timeline(6))).not_to be_holds_newest
      end

      it "is true once the chain renders the latest cut the session recorded" do
        line = timeline(6)
        advance(line)

        expect(on(line)).to be_holds_newest
      end
    end
  end

  # A strategy that leaves a lone opening turn verbatim, as elide-tools beside
  # summarize-conversation does, puts a human turn below the newest cut that no
  # cut replaced. The handoff replaces it all the same, so it has to be shown.
  describe "the question a handoff asks" do
    let(:directive) { "use SQLite, never PostgreSQL" }

    def text(value) = [{ "type" => "text", "text" => value }]

    def chain
      [["user", text(directive)], ["assistant", text("collapsed reply")], ["user", text("collapsed follow-up")],
       ["assistant", [{ "type" => "tool_use", "id" => "call-1", "name" => "probe", "input" => {} }]],
       ["user", [{ "type" => "tool_result", "tool_use_id" => "call-1", "content" => "probed" }]],
       ["assistant", text("probed it")], ["user", text("the ask")]]
        .inject(Lain::Timeline.empty) { |line, (role, content)| line.commit(role:, content:) }
    end

    def advanced_over_one_to_two(line)
      session.record_compaction_cut(
        Lain::Telemetry::CompactionCut.new(
          digest: line.to_a[2].digest, head: Lain::Event.stands_on(line.head), strategy: arm, kind: "advance",
          parent: nil, supersedes: [], plan_step_completions: 0,
          collapses: [{ "span" => [line.to_a[1].digest, line.to_a[2].digest], "content" => text("the replacement") }]
        )
      )
      line
    end

    def question = on(advanced_over_one_to_two(chain)).handoff(pins: Lain::Context::PinnedMessages::NONE).question

    it "shows a lone first turn below the newest cut in its place, before the summary of what followed it" do
      earlier = question[:held]

      expect(earlier).to include(directive)
      expect(earlier.index(directive)).to be < earlier.index("the replacement")
      expect(question[:span]).not_to include(directive)
    end

    # Both are user text turns; only the mark lets the question buy the
    # human's words ahead of the summaries after them when the budget binds.
    describe "under a binding budget" do
      let(:directive) { "use SQLite, never PostgreSQL, #{"and keep every post in it " * 16}".strip }
      let(:summaries) { 14 }

      def chain
        replies = (1..summaries).flat_map do |index|
          [["assistant", text("reply #{index}")], ["user", text("more #{index}")]]
        end
        [["user", text(directive)], *replies, ["assistant", text("probed it")], ["user", text("the ask")]]
          .inject(Lain::Timeline.empty) { |line, (role, content)| line.commit(role:, content:) }
      end

      def summarized(turns)
        (1..summaries).map do |index|
          { "span" => [turns[(2 * index) - 1].digest, turns[2 * index].digest],
            "content" => text("summary #{index}: #{"s" * 500}") }
        end
      end

      def advanced_over_the_replies(line)
        turns = line.to_a
        session.record_compaction_cut(
          Lain::Telemetry::CompactionCut.new(
            digest: turns[2 * summaries].digest, head: Lain::Event.stands_on(line.head), strategy: arm,
            kind: "advance", parent: nil, supersedes: [], plan_step_completions: 0, collapses: summarized(turns)
          )
        )
        line
      end

      it "keeps the directive whole ahead of the summaries that followed it" do
        budget = Lain::Oracle::Handoff.budget_for(Lain::ContextWindow::CONSERVATIVE_FALLBACK)
        earlier = on(advanced_over_the_replies(chain))
                  .handoff(pins: Lain::Context::PinnedMessages::NONE, budget:).question[:held]

        expect(earlier).to include("summary 14: ").and include("bytes in full")
        expect(earlier).to include("user: #{directive}\n")
      end
    end

    it "shows a turn inside a held collapse once, as its replacement" do
      shown = question.values.join

      expect(shown.scan("the replacement").size).to eq(1)
      expect(shown).not_to include("collapsed reply", "collapsed follow-up")
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

    # A record holding an advance, a collapse over two, and then a handoff is
    # the shape a long stuck session really leaves. The handoff stands alone
    # afterwards, so the render carries one replacement and not four.
    it "is superseded whole by a handoff committed over it" do
      line = two_advances
      collapsed = collapse(line)
      current = on(line)

      current.hand_off(current.handoff(pins: Lain::Context::PinnedMessages::NONE).ranges, "the state document")

      expect(session.compaction_cuts.map(&:kind)).to eq(%w[advance advance collapse handoff])
      expect(session.compaction_cuts.last.supersedes).to eq([collapsed.address])
      expect(on(line).messages.map { |message| message["content"].first["text"] })
        .to eq(["the state document", block(8)["text"]])
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

  describe ".ask_index" do
    def text(body) = { "role" => "user", "content" => [{ "type" => "text", "text" => body }] }

    def use(id)
      { "role" => "assistant", "content" => [{ "type" => "tool_use", "id" => id, "name" => "read", "input" => {} }] }
    end

    def result(id)
      { "role" => "user", "content" => [{ "type" => "tool_result", "tool_use_id" => id, "content" => "ok" }] }
    end

    it "names the newest user message made only of text, past the tool rounds that followed it" do
      messages = [text("an earlier ask"), text("the running ask"), use("a"), result("a"), use("b"), result("b")]

      expect(held_cut.ask_index(messages)).to eq(1)
    end

    it "does not take a user message that also carries a tool_result for the ask" do
      mixed = { "role" => "user", "content" => [*result("a")["content"], { "type" => "text", "text" => "and also" }] }

      expect(held_cut.ask_index([text("the ask"), use("a"), mixed])).to eq(0)
    end

    it "is nil on a chain with no ask at all" do
      expect(held_cut.ask_index([use("a"), result("a")])).to be_nil
    end
  end
end
