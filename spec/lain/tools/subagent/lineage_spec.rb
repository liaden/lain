# frozen_string_literal: true

require "async"

# The causal record a spawn leaves behind, the vocabulary its bodies speak,
# and the identity an adopted actor is addressed by. A one-shot's completion
# used to be recognisable only by the presence of a "result" key while every
# other transition carried a body-level lifecycle mark; these pin that the
# completion now speaks the same closed vocabulary.
#
# A spawn digest IS an address, for an actor's `tell` and for the window and
# the watch view a one-shot is followed by, which is what makes the rest of this
# file's shape load-bearing: two live children launched from one head must take
# two addresses, and the same work from the same head must take the same one in
# every run, or two runs of one bench arm cannot be joined on a spawn digest.
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
      message = lineage.message(parent, lineage.spawn(parent, prompt: "go"), child, response)

      expect(message.body.fetch("lifecycle")).to eq(Lain::StatusFeed::SpawnLifecycle::STOPPED)
      expect(message.body.fetch("result")).to eq("child answer")
      expect(message.body.fetch("final")).to eq(child.head_digest)
    end

    it "still cites the :spawn and the child's final turn, at correlation grain" do
      spawn = lineage.spawn(parent, prompt: "go")
      message = lineage.message(parent, spawn, child, response)

      expect(message.kind).to eq(:message)
      expect(message.causal_parents).to contain_exactly(spawn.digest, child.head_digest)
      expect(message.from).to eq(lineage.correlation_of(child))
      expect(message.to).to eq(lineage.correlation_of(parent))
    end
  end

  describe "#spawn" do
    def spawn_from_another_run(prompt:, lifecycle: nil)
      other_parent = Lain::Timeline.empty(store: Lain::Store.new)
                                   .commit(role: :user, content: text("hi"))
                                   .commit(role: :assistant, content: text("yo"))
      described_class.new(policy:).spawn(other_parent, prompt:, lifecycle:)
    end

    def rebuilt_from_its_recorded_body(spawn)
      payload = Lain::Event::Payload.new(kind: spawn.kind, body: spawn.body)
      Lain::Event.new(kind: spawn.kind, carried_payload: payload, from: spawn.from,
                      to: spawn.to, render_parent: spawn.render_parent,
                      causal_parents: spawn.causal_parents, correlation: spawn.correlation)
    end

    it "writes no lifecycle mark for a one-shot, whose start is the :spawn itself" do
      expect(lineage.spawn(parent, prompt: "go").body).not_to have_key("lifecycle")
    end

    it "writes the mark an actor asks for" do
      expect(lineage.spawn(parent, prompt: "go", lifecycle: "launched").body)
        .to include("lifecycle" => Lain::StatusFeed::SpawnLifecycle::LAUNCHED)
    end

    # The digest and never the text: the record names the work without growing
    # by a prompt's size, and the prompt itself is already the child's first
    # turn, one citation away.
    it "names the work it was given by the digest of the prompt, not by the prompt's text" do
      body = lineage.spawn(parent, prompt: "survey the aspirin trials").body

      expect(body.fetch("task")).to eq(Lain::Canonical.digest("survey the aspirin trials"))
      expect(body.values).not_to include("survey the aspirin trials")
    end

    # Two parallel calls in one assistant turn spawn from one head, and before
    # the work was in the body their spawns were byte-identical: one window,
    # one fleet member, one watch view for two children, and the first
    # completion released the other's.
    it "gives two one-shots of different work from one head different addresses" do
      first = lineage.spawn(parent, prompt: "survey the aspirin trials")
      second = lineage.spawn(parent, prompt: "survey the statin trials")

      expect(second.digest).not_to eq(first.digest)
    end

    # Content-derived rather than counted, so no writer's state enters it:
    # a role spawn builds a new writer per call and a resumed run starts
    # another, and both still reproduce the address.
    it "re-derives the same one-shot address for the same work from the same head in another run" do
      first_run = lineage.spawn(parent, prompt: "survey the aspirin trials")

      expect(spawn_from_another_run(prompt: "survey the aspirin trials").digest).to eq(first_run.digest)
    end

    # Accepted rather than fixed: the same work from one head is the same
    # spawn. Nothing else rests on it -- the session record dedupes a child's
    # turns on their own digests, which never cite the spawn.
    it "leaves two one-shots of identical work from one head sharing one address" do
      expect(lineage.spawn(parent, prompt: "same").digest).to eq(lineage.spawn(parent, prompt: "same").digest)
    end

    it "gives a one-shot no adoption identity -- nothing adopts one" do
      expect(lineage.spawn(parent, prompt: "go").body).not_to have_key("adoption")
    end

    it "names the work in an actor's spawn too, beside its adoption" do
      body = lineage.spawn(parent, prompt: "watch the build", lifecycle: "launched").body

      expect(body).to include("task" => Lain::Canonical.digest("watch the build"), "adoption" => 1)
    end

    # An actor's address IS its :spawn digest, and two launches of one arm from
    # one head on the same work are otherwise byte-identical. Without a
    # per-adoption mark the two live children share one address, which is what
    # folds them into a single fleet entry and lets either child's farewell
    # retire both.
    it "gives two actors launched from one head on the same work different addresses" do
      first = lineage.spawn(parent, prompt: "go", lifecycle: "launched")
      second = lineage.spawn(parent, prompt: "go", lifecycle: "launched")

      expect(second.body.fetch("adoption")).not_to eq(first.body.fetch("adoption"))
      expect(second.digest).not_to eq(first.digest)
    end

    # Deterministic is the binding constraint, and it is why the mark is a
    # counter rather than a nonce: a nonce would separate the twins just as
    # well and cost exactly this, so two runs of one bench arm could no longer
    # be joined on a spawn digest.
    it "re-derives the same address for the same adoption in an identical run" do
      first_run = lineage.spawn(parent, prompt: "go", lifecycle: "launched")

      expect(spawn_from_another_run(prompt: "go", lifecycle: "launched").digest).to eq(first_run.digest)
    end

    # Two issues' actors are launched by two writers from the chat's one
    # head, so their per-writer counts both read 1 and only the lane can keep
    # their addresses apart.
    it "names its lane in an actor's spawn, so two lanes' first actors from one head differ" do
      a = described_class.new(policy:, lane: "issue.demo.a").spawn(parent, prompt: "go", lifecycle: "launched")
      b = described_class.new(policy:, lane: "issue.demo.b").spawn(parent, prompt: "go", lifecycle: "launched")

      expect(a.digest).not_to eq(b.digest)
      expect(a.body["lane"]).to eq("issue.demo.a")
    end

    it "writes no lane for the run's own unnamed lane, nor for a one-shot" do
      expect(described_class.new(policy:).spawn(parent, prompt: "go", lifecycle: "launched").body)
        .not_to have_key("lane")
      expect(described_class.new(policy:, lane: "issue.demo.a").spawn(parent, prompt: "go").body)
        .not_to have_key("lane")
    end

    # The counter is keyed by the head, so a second head starts its own
    # sequence -- what makes the mark a property of the scope collisions happen
    # in rather than of how many spawns this writer has ever made.
    it "counts per head, so an advanced parent starts over" do
      lineage.spawn(parent, prompt: "go", lifecycle: "launched")
      advanced = parent.commit(role: :user, content: text("again"))

      expect(lineage.spawn(advanced, prompt: "go", lifecycle: "launched").body.fetch("adoption"))
        .to eq(lineage.spawn(parent, prompt: "go", lifecycle: "launched").body.fetch("adoption") - 1)
    end

    # Replay rebuilds an event from the record's OWN recorded body rather than
    # re-deriving the marks, so the identity has to survive that round trip --
    # this is the shape {Bench::Session::MessageReplay} verifies every journaled
    # :spawn with. It is also why journals written before the work was in the
    # body still replay: each re-derives the digest its own body gives.
    it "re-derives a recorded one-shot's digest when rebuilt from its own recorded body" do
      spawn = lineage.spawn(parent, prompt: "survey the aspirin trials")

      expect(rebuilt_from_its_recorded_body(spawn).digest).to eq(spawn.digest)
    end

    it "re-derives a recorded actor's digest when rebuilt from its own recorded body" do
      spawn = lineage.spawn(parent, prompt: "go", lifecycle: "launched")

      expect(rebuilt_from_its_recorded_body(spawn).digest).to eq(spawn.digest)
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
        [task.async { lineage.spawn(parent, prompt: "go", lifecycle: "launched") },
         task.async { lineage.spawn(parent, prompt: "go", lifecycle: "launched") }].map(&:wait)
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
      expect(Lain::StatusFeed::SpawnLifecycle.new(note)).not_to be_terminal
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

      spawn = lineage.spawn(parent, prompt: "go")
      message = lineage.message(parent, spawn, child, response)

      expect(log.to_a).to eq([spawn, message])
      expect(seen).to eq([spawn, message])
    end
  end
end
