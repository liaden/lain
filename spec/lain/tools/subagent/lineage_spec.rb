# frozen_string_literal: true

require "async"

# The causal record a spawn leaves behind, the vocabulary its bodies speak,
# and the identity an adopted actor is addressed by. A one-shot's completion
# used to be recognisable only by the presence of a "result" key while every
# other transition carried a body-level lifecycle mark; these pin that the
# completion now speaks the same closed vocabulary.
#
# A spawn digest IS an actor's address, which is what makes the rest of this
# file's shape load-bearing in both directions: the ACTOR path must separate
# two live children launched from one head, and the ONE-SHOT path -- adopted by
# nobody, addressed by nobody -- must stay byte-identical to the journals
# already on disk.
RSpec.describe Lain::Tools::Subagent::Lineage do
  subject(:lineage) { described_class.new(policy:) }

  let(:policy) { Lain::Tool::SpawnPolicy.new(prefix: :fresh, posture: :schema, only: []) }
  let(:store) { Lain::Store.new }
  let(:parent) do
    Lain::Timeline.empty(store:)
                  .commit(role: :user, content: text("hi"))
                  .commit(role: :assistant, content: text("yo"))
  end
  let(:child) { Lain::Timeline.empty(store:).commit(role: :user, content: text("child task")) }
  let(:response) { Data.define(:text).new(text: "child answer") }

  def text(body) = [{ "type" => "text", "text" => body }]

  describe "#message" do
    # The mark is asserted by VALUE, not by membership in the vocabulary and
    # not through the reader: a "result" body reads terminal on its own, so a
    # completion wrongly marked "settled" would satisfy both of those and
    # still be the precise mistake the vocabulary exists to prevent. This is
    # the file a reader opens to learn what Lineage writes, so the exact word
    # has to be pinned here.
    it "marks the completion terminal in the closed vocabulary, beside the result and the child's head" do
      message = lineage.message(parent, lineage.spawn(parent), child, response)

      expect(message.body.fetch("lifecycle")).to eq(Lain::Telemetry::SpawnLifecycle::STOPPED)
      expect(message.body.fetch("result")).to eq("child answer")
      expect(message.body.fetch("final")).to eq(child.head_digest)
    end

    it "still cites the :spawn and the child's final turn, at correlation grain" do
      spawn = lineage.spawn(parent)
      message = lineage.message(parent, spawn, child, response)

      expect(message.kind).to eq(:message)
      expect(message.causal_parents).to contain_exactly(spawn.digest, child.head_digest)
      expect(message.from).to eq(lineage.correlation_of(child))
      expect(message.to).to eq(lineage.correlation_of(parent))
    end
  end

  describe "#spawn" do
    # Load-bearing: a one-shot :spawn's digest is what FleetWindows windows on
    # and what StatusFeed keys its fleet by, so a mark on the COMPLETION must
    # leave the spawn's bytes exactly where they were.
    it "writes no lifecycle mark for a one-shot" do
      expect(lineage.spawn(parent).body).not_to have_key("lifecycle")
    end

    it "writes the mark an actor asks for, so only the actor path pays the byte change" do
      expect(lineage.spawn(parent, lifecycle: "launched").body)
        .to include("lifecycle" => Lain::Telemetry::SpawnLifecycle::LAUNCHED)
    end

    # The same asymmetry the lifecycle mark is written under: a one-shot is
    # never adopted, nothing routes on its digest, and so its bytes -- and
    # every journal already holding them -- stay exactly where they were.
    it "gives a one-shot no adoption identity" do
      expect(lineage.spawn(parent).body).not_to have_key("adoption")
    end

    # An actor's address IS its :spawn digest, and two launches of one arm from
    # one head are otherwise byte-identical. Without a per-adoption mark the
    # two live children share one address, which is what folds them into a
    # single fleet entry and lets either child's farewell retire both.
    it "gives two actors launched from one head different addresses" do
      first = lineage.spawn(parent, lifecycle: "launched")
      second = lineage.spawn(parent, lifecycle: "launched")

      expect(second.body.fetch("adoption")).not_to eq(first.body.fetch("adoption"))
      expect(second.digest).not_to eq(first.digest)
    end

    # Deterministic is the binding constraint, and it is why the mark is a
    # counter rather than a nonce: a nonce would separate the twins just as
    # well and cost exactly this, so two runs of one bench arm could no longer
    # be joined on a spawn digest.
    it "re-derives the same address for the same adoption in an identical run" do
      first_run = lineage.spawn(parent, lifecycle: "launched")

      other_store = Lain::Store.new
      other_parent = Lain::Timeline.empty(store: other_store)
                                   .commit(role: :user, content: text("hi"))
                                   .commit(role: :assistant, content: text("yo"))
      second_run = described_class.new(policy:).spawn(other_parent, lifecycle: "launched")

      expect(second_run.digest).to eq(first_run.digest)
    end

    # The counter is keyed by the head, so a second head starts its own
    # sequence -- what makes the mark a property of the scope collisions happen
    # in rather than of how many spawns this writer has ever made.
    # Two issues' actors are launched by two writers from the chat's one
    # head, so their per-writer counts both read 1 and only the lane can keep
    # their addresses apart.
    it "names its lane in an actor's spawn, so two lanes' first actors from one head differ" do
      a = described_class.new(policy:, lane: "issue.demo.a").spawn(parent, lifecycle: "launched")
      b = described_class.new(policy:, lane: "issue.demo.b").spawn(parent, lifecycle: "launched")

      expect(a.digest).not_to eq(b.digest)
      expect(a.body["lane"]).to eq("issue.demo.a")
    end

    it "writes no lane for the run's own unnamed lane, nor for a one-shot, so their digests stay as they were" do
      expect(described_class.new(policy:).spawn(parent, lifecycle: "launched").body).not_to have_key("lane")
      expect(described_class.new(policy:, lane: "issue.demo.a").spawn(parent).body).not_to have_key("lane")
    end

    it "counts per head, so an advanced parent starts over" do
      lineage.spawn(parent, lifecycle: "launched")
      advanced = parent.commit(role: :user, content: text("again"))

      expect(lineage.spawn(advanced, lifecycle: "launched").body.fetch("adoption"))
        .to eq(lineage.spawn(parent, lifecycle: "launched").body.fetch("adoption") - 1)
    end

    # Replay rebuilds an event from the record's OWN recorded body rather than
    # re-deriving the mark, so the identity has to survive that round trip --
    # this is the shape {Bench::Session::MessageReplay} verifies every journaled
    # :spawn with.
    it "still re-derives its recorded digest when rebuilt from its own recorded body" do
      spawn = lineage.spawn(parent, lifecycle: "launched")
      payload = Lain::Event::Payload.new(kind: spawn.kind, body: spawn.body)
      rebuilt = Lain::Event.new(kind: spawn.kind, carried_payload: payload, from: spawn.from,
                                to: spawn.to, render_parent: spawn.render_parent,
                                causal_parents: spawn.causal_parents, correlation: spawn.correlation)

      expect(rebuilt.digest).to eq(spawn.digest)
    end
  end

  # What makes the adoption count safe without a lock: nothing between its read
  # and its write suspends the fiber, so async's cooperative scheduler cannot
  # put a second adoption in the middle. Nothing else in the suite states that,
  # and losing it is silent -- two live twins handed one ordinal and one address
  # again, with nothing raised. Two REAL fibers, because the sequential pair
  # elsewhere in this file cannot fail this way.
  describe "two concurrent adoptions through one writer" do
    it "hands each fiber an ordinal of its own, so the twins still take distinct addresses" do
      spawns = Sync do |task|
        [task.async { lineage.spawn(parent, lifecycle: "launched") },
         task.async { lineage.spawn(parent, lifecycle: "launched") }].map(&:wait)
      end

      expect(spawns.map { |spawn| spawn.body.fetch("adoption") }).to contain_exactly(1, 2)
      expect(spawns.map(&:digest).uniq.size).to eq(2)
    end
  end

  # The idiom the completion mark was modelled on, and the one place the
  # ABSENCE of a mark is itself the meaning: a tell is conversation, a marked
  # message is a transition.
  describe "#note" do
    it "omits the key entirely when no lifecycle is given" do
      note = lineage.note(parent, from: "a", to: "b", text: "narrow to RCTs", causal_parents: [])

      expect(note.body).to eq("text" => "narrow to RCTs")
      expect(Lain::Telemetry::SpawnLifecycle.new(note)).not_to be_terminal
    end

    it "writes the mark when one is given" do
      note = lineage.note(parent, from: "a", to: "b", text: "done", causal_parents: [], lifecycle: "stopped")

      expect(note.body).to eq("text" => "done", "lifecycle" => "stopped")
    end
  end

  # The constructor's documented silent-failure invariant: an injected
  # observer must COMPOSE with the @log append, never replace it, or the
  # mailbox fold stops with nothing raised. Covered until now only at
  # dispatch level, which is a long way from the object that owns the rule.
  describe "#initialize" do
    it "feeds both the log and an injected observer, rather than spending the slot on one" do
      log = Lain::Tools::Subagent::Log.new
      seen = []
      lineage = described_class.new(policy:, log:, observer: seen.method(:push))

      spawn = lineage.spawn(parent)
      message = lineage.message(parent, spawn, child, response)

      expect(log.to_a).to eq([spawn, message])
      expect(seen).to eq([spawn, message])
    end
  end
end
