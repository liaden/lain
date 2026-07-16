# frozen_string_literal: true

RSpec.describe Lain::Context::Mailbox do
  # A :message event addressed to `to`, carrying renderable "text" -- the same
  # shape Tools::Subagent::Lineage#note writes into the shared log.
  def message(to:, text:, from: "actor")
    payload = Lain::Event::Payload.new(kind: :message, body: { "text" => text })
    Lain::Event.new(kind: :message, from:, to:, payload_digest: payload.digest, body: payload.body)
  end

  # An assistant turn that names the given messages among its causal parents --
  # exactly what {Agent} records at commit for the messages a render folded.
  def fold_turn(*messages)
    Lain::Event.turn(role: "assistant", content: [{ "type" => "text", "text" => "answered" }],
                     causal_parents: messages.map(&:digest))
  end

  # The per-turn frozen snapshot both the render-side combinator and the
  # commit-side folded derivation consume.
  def snapshot(events, recipient: "parent")
    Lain::Context::Mailbox::Snapshot.new(recipient:, events:)
  end

  def user(text) = { "role" => "user", "content" => [{ "type" => "text", "text" => text }] }
  def assistant(text) = { "role" => "assistant", "content" => [{ "type" => "text", "text" => text }] }

  # Three pending messages to "parent", plus one to someone else (never folded).
  let(:pending) do
    [message(to: "parent", text: "first"),
     message(to: "parent", text: "second"),
     message(to: "parent", text: "third")]
  end
  let(:other) { message(to: "worker", text: "not for the parent") }
  let(:mailbox) { described_class.new(snapshot: snapshot(pending + [other])) }

  let(:conversation) { [user("hello"), assistant("hi"), user("more please")] }

  describe "folding the recipient's pending messages" do
    it "appends exactly the recipient's messages as one <mailbox> block at the tail" do
      folded = mailbox.call(conversation)

      block = folded.last["content"].last
      expect(block["type"]).to eq("text")
      expect(block["text"]).to start_with("<mailbox>").and(end_with("</mailbox>"))
      expect(block["text"]).to include("first").and(include("second")).and(include("third"))
    end

    it "never folds a message addressed to someone else" do
      folded = mailbox.call(conversation)
      expect(folded.last["content"].last["text"]).not_to include("not for the parent")
    end

    it "leaves the conversation unchanged when nothing is pending for the recipient" do
      empty = described_class.new(snapshot: snapshot([other]))
      expect(empty.call(conversation)).to eq(conversation)
    end
  end

  # Scenario: the parent folds deliberately -- the fold rides AFTER the last
  # cache breakpoint, so the cached prefix is byte-identical to a render without
  # it (the Recall tail rule: strictly after the last neutral marker).
  describe "riding after the last cache breakpoint" do
    let(:marked) { Lain::Context::CacheBreakpoints.new.call(conversation) }
    let(:folded) { mailbox.call(marked) }

    it "leaves every message before the last untouched" do
      expect(folded[0..-2]).to eq(marked[0..-2])
    end

    it "leaves the cached prefix of the last message -- marker included -- intact" do
      cached_prefix = marked.last["content"]
      expect(folded.last["content"][0...cached_prefix.size]).to eq(cached_prefix)
      expect(cached_prefix.last["cache"]).to be(true)
    end

    it "places the fold strictly after the neutral marker, which is no longer last" do
      cached_prefix = marked.last["content"]
      expect(folded.last["content"][cached_prefix.size - 1]["cache"]).to be(true)
      expect(folded.last["content"].last).not_to have_key("cache")
    end
  end

  # Decision 2 / panel B2: the fold is a PURE projection -- no cursor, no
  # consumed queue. "Pending" is DERIVED from causal edges (a message is pending
  # until a committed turn names it a causal parent), so the same snapshot folds
  # byte-identically however many times render runs, and a dispatch that never
  # commits loses nothing.
  describe "purity: the fold is derived, not consumed" do
    # Scenario: render is pure again.
    it "folds byte-identically when render runs twice on the same inputs" do
      expect(mailbox.call(conversation)).to eq(mailbox.call(conversation))
    end

    # Scenario: a failed dispatch loses nothing -- no turn committed between the
    # two renders, so both fold every message again.
    it "re-folds every message when no turn committed between renders" do
      first = mailbox.call(conversation)
      second = mailbox.call(conversation)
      expect(second.last["content"].last["text"])
        .to include("first").and(include("second")).and(include("third"))
      expect(second).to eq(first)
    end

    it "does not mutate the message list it folds over" do
      frozen = conversation.map(&:freeze).freeze
      mailbox.call(frozen)
      expect(frozen).to be_frozen
    end

    it "leaves folded events queryable in the log -- the view is never consumed" do
      mailbox.call(conversation)
      expect(Lain::Event::Projection.new(pending + [other]).mailbox("parent").to_a).to eq(pending)
    end
  end

  # Scenario: a committed turn consumes its folded messages.
  describe "a committed turn consumes what it folded" do
    let(:committed) { snapshot(pending + [other, fold_turn(pending[0], pending[1])]) }

    it "stops folding the messages the turn named as causal parents" do
      folded = described_class.new(snapshot: committed).call(conversation)
      text = folded.last["content"].last["text"]
      expect(text).to include("third")
      expect(text).not_to include("first")
      expect(text).not_to include("second")
    end

    it "folds nothing once every pending message has been consumed" do
      drained = described_class.new(snapshot: snapshot(pending + [fold_turn(*pending)]))
      expect(drained.call(conversation)).to eq(conversation)
    end

    # Diverge-safe: the fork BEFORE the commit shares the same message log but
    # not the consuming turn, so it still folds them.
    it "still folds them on a fork that predates the consuming commit" do
      fork = described_class.new(snapshot: snapshot(pending + [other])).call(conversation)
      expect(fork.last["content"].last["text"]).to include("first").and(include("second"))
    end
  end

  describe "the tail-placement guards Recall also honors" do
    it "returns an empty conversation unchanged" do
      expect(mailbox.call([])).to eq([])
    end

    it "does not fold when the last message is not the user's" do
      ending_assistant = [user("hi"), assistant("working")]
      expect(mailbox.call(ending_assistant)).to eq(ending_assistant)
    end
  end

  # The per-turn frozen snapshot: the ONE object both the render-side fold and
  # the commit-side causal_parents derivation read. Agreement between render and
  # commit is a property of CONSTRUCTION -- one pure function over one immutable
  # input -- not of two call sites racing the mutable log.
  describe Lain::Context::Mailbox::Snapshot do
    it "exposes the pending events and their digests as one immutable answer" do
      snap = snapshot(pending + [other, fold_turn(pending[0])])
      expect(snap.pending).to eq([pending[1], pending[2]])
      expect(snap.folded).to eq([pending[1].digest, pending[2].digest])
    end

    it "is frozen, so neither side can see it change" do
      snap = snapshot(pending)
      expect(snap).to be_frozen
      expect(snap.pending).to be_frozen
    end
  end

  # The Agent's read-side of its inbox. `capture(timeline)` is the ONE live read
  # of the mutable log, at turn start; the {Snapshot} it returns is what render
  # and commit both consume.
  describe Lain::Context::Mailbox::Source do
    let(:store) { Lain::Store.new }
    let(:log) { Lain::Tools::Subagent::Log.new }
    let(:source) { described_class.new(recipient: "parent", log:) }

    def put_message(to:, text:, from: "actor")
      payload = Lain::Event::Payload.new(kind: :message, body: { "text" => text })
      event = Lain::Event.new(kind: :message, from:, to:, payload_digest: payload.digest, body: payload.body)
      store.put(payload)
      store.put(event)
      log << event
      event
    end

    it "captures every pending message's digest over an unconsumed timeline" do
      first = put_message(to: "parent", text: "one")
      second = put_message(to: "parent", text: "two")

      expect(source.capture(Lain::Timeline.empty(store:)).folded).to eq([first.digest, second.digest])
    end

    it "drops a message a committed turn on the timeline already consumed" do
      first = put_message(to: "parent", text: "one")
      second = put_message(to: "parent", text: "two")
      timeline = Lain::Timeline.empty(store:)
                               .commit(role: :assistant, content: [{ "type" => "text", "text" => "x" }],
                                       causal_parents: [first.digest])

      expect(source.capture(timeline).folded).to eq([second.digest])
    end

    it "ignores messages addressed to someone else" do
      mine = put_message(to: "parent", text: "mine")
      put_message(to: "worker", text: "theirs")

      expect(source.capture(Lain::Timeline.empty(store:)).folded).to eq([mine.digest])
    end

    # Probe-becomes-spec (panel probe #2): a message ARRIVING between render and
    # commit -- an actor replying during the provider round trip, the OM-3 point.
    # The commit must claim exactly what the render folded (one shared frozen
    # snapshot), and the arrival must still be pending at the next turn's
    # snapshot. Reading the log LIVE at commit claimed m2 as a causal parent of
    # a turn that never rendered it -- marked consumed, never folded again: lost.
    describe "a message arriving mid-dispatch (the render/commit window)" do
      it "is not claimed by the in-flight commit and still folds next turn" do
        m1 = put_message(to: "parent", text: "first")
        timeline = Lain::Timeline.empty(store:)
        turn_snapshot = source.capture(timeline)

        # Render folds the snapshot: m1 only.
        rendered = Lain::Context::Mailbox.new(snapshot: turn_snapshot).call([user("go")])
        expect(rendered.last["content"].last["text"]).to include("first")

        # Mid-dispatch: a child replies; the shared log grows concurrently.
        m2 = put_message(to: "parent", text: "arrived-during-roundtrip")
        expect(rendered.last["content"].last["text"]).not_to include("arrived-during-roundtrip")

        # Commit claims the SAME snapshot's folded set: m1 only, never m2.
        expect(turn_snapshot.folded).to eq([m1.digest])
        committed = timeline.commit(role: :assistant, content: [{ "type" => "text", "text" => "ok" }],
                                    causal_parents: turn_snapshot.folded)

        # Next turn's snapshot: m1 consumed, m2 still pending -- nothing lost.
        expect(source.capture(committed).folded).to eq([m2.digest])
      end
    end
  end

  # The Agent's default inbox: a plain Agent has nothing addressed to it, so
  # nothing folds and every assistant commit records causal_parents [].
  describe Lain::Context::Mailbox::Null do
    it "captures an empty snapshot, whatever the timeline" do
      snap = described_class.capture(Lain::Timeline.empty(store: Lain::Store.new))
      expect(snap.folded).to eq([])
      expect(snap.pending).to eq([])
    end
  end
end
