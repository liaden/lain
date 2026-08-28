# frozen_string_literal: true

# The causal record a spawn leaves behind, and the vocabulary its bodies
# speak. A one-shot's completion used to be recognisable only by the presence
# of a "result" key while every other transition carried a body-level
# lifecycle mark; these pin that the completion now speaks the same closed
# vocabulary, and that closing it moved nothing else -- the :spawn's bytes and
# the completion's causal edges are both asserted unchanged, because a spawn
# digest is an actor's address and both live-fleet readers key on it.
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
