# frozen_string_literal: true

RSpec.describe Lain::Timeline do
  subject(:timeline) { described_class.empty(store:) }

  let(:store) { Lain::Store.new }

  def text(body) = [{ "type" => "text", "text" => body }]

  def say(from, body, role: :user) = from.commit(role:, content: text(body))

  describe "an empty timeline" do
    it "has no head" do
      expect(timeline).to be_empty
      expect(timeline.head).to be_nil
      expect(timeline.length).to eq(0)
    end

    it "rewinds to itself" do
      expect(timeline.rewind).to eq(timeline)
    end
  end

  describe "#commit" do
    it "advances the head" do
      one = say(timeline, "a")
      expect(one.head.content).to eq(text("a"))
      expect(one.length).to eq(1)
    end

    it "leaves the receiver untouched" do
      say(timeline, "a")
      expect(timeline).to be_empty
    end

    it "chains parents" do
      two = say(say(timeline, "a"), "b", role: :assistant)
      expect(two.head.parent).to eq(two.rewind.head_digest)
    end

    it "orders #to_a root first, which is the order a provider wants" do
      three = say(say(say(timeline, "a"), "b", role: :assistant), "c")
      expect(three.to_a.map { |t| t.content.first["text"] }).to eq(%w[a b c])
    end

    it "orders #ancestors head first" do
      three = say(say(say(timeline, "a"), "b", role: :assistant), "c")
      expect(three.ancestors.map { |t| t.content.first["text"] }).to eq(%w[c b a])
    end

    # The envelope's payload_digest is an edge the Store enforces, so
    # #commit puts the body BEFORE the envelope -- a committed turn's payload
    # is retrievable, and the carried body still answers fetch_body without a
    # round trip.
    it "stores a committed turn's body in the store, retrievable under payload_digest" do
      head = say(timeline, "a").head
      stored = store.fetch(head.payload_digest)
      expect(stored).to be_a(Lain::Event::Payload)
      expect(stored.digest).to eq(head.payload_digest)
      expect(head.content).to eq(text("a"))
    end

    # Review fix: commit is the hottest per-turn path, and its digest work
    # is exactly two Canonical.digest passes -- the payload once (inside
    # Event.turn) and the envelope once. A third call means the payload was
    # rebuilt from turn.body instead of reusing the object Event.turn built.
    it "digests exactly twice per commit: the payload once, the envelope once" do
      allow(Lain::Canonical).to receive(:digest).and_call_original
      say(timeline, "a")
      expect(Lain::Canonical).to have_received(:digest).twice
    end
  end

  # Decision 2: the assistant commit records the messages a render folded as
  # the turn's causal_parents -- the first production writer of causal edges on
  # turns. The default (no mailbox) path passes none, and its digest must stay
  # byte-identical to a pre-mailbox turn.
  describe "#commit with causal_parents" do
    it "threads the given causal parents onto the committed turn" do
      base = say(timeline, "a")
      folded = base.commit(role: :assistant, content: text("b"), causal_parents: [base.head_digest])
      expect(folded.head.causal_parents).to eq([base.head_digest])
    end

    it "changes the turn digest, because causal_parents are hashed content" do
      base = say(timeline, "a")
      plain = base.commit(role: :assistant, content: text("b"))
      causal = base.fork.commit(role: :assistant, content: text("b"), causal_parents: [base.head_digest])
      expect(causal.head_digest).not_to eq(plain.head_digest)
    end

    it "records no causal parents by default" do
      expect(say(timeline, "a").head.causal_parents).to eq([])
    end

    it "refuses a causal parent the store has never seen, the same edge Store enforces" do
      base = say(timeline, "a")
      expect { base.commit(role: :assistant, content: text("b"), causal_parents: ["blake3:ghost"]) }
        .to raise_error(Lain::Store::MissingObject)
    end
  end

  describe "time travel" do
    let(:three) { say(say(say(timeline, "a"), "b", role: :assistant), "c") }

    it "rewinds one turn by default" do
      expect(three.rewind.head.content).to eq(text("b"))
    end

    it "rewinds n turns" do
      expect(three.rewind(2).head.content).to eq(text("a"))
    end

    it "rewinds past the root to the empty timeline rather than raising" do
      expect(three.rewind(99)).to be_empty
    end

    it "checks out any digest in the store" do
      expect(three.checkout(three.rewind(2).head_digest).head.content).to eq(text("a"))
    end

    it "refuses to check out a digest the store has never seen" do
      expect { three.checkout("blake3:nope") }.to raise_error(Lain::Store::MissingObject)
    end
  end

  describe "#fork" do
    it "is identity, because the value is immutable" do
      one = say(timeline, "a")
      expect(one.fork).to equal(one)
    end

    # The reason the Store is a separate object: a shared prefix is stored once,
    # so branching allocates nothing.
    it "stores a shared prefix exactly once" do
      base = say(say(timeline, "a"), "b", role: :assistant)
      left = say(base.fork, "left")
      right = say(base.fork, "right")

      # Four turns, each with its out-of-line payload -- eight objects. The
      # shared prefix (a, b and their payloads) is still stored exactly once
      # despite the two branches, which is the property under test.
      expect(store.size).to eq(8)
      expect(left.rewind).to eq(right.rewind)
      expect(left).not_to eq(right)
    end
  end

  # A Timeline is an element of the DAG's render order, not its owner: the
  # meet and the divergence are {Lain::Dag::RenderAncestry}'s to answer.
  describe "the render meet" do
    it "is not a message a timeline answers" do
      expect(timeline).not_to respond_to(:meet)
      expect(timeline).not_to respond_to(:&)
      expect(timeline).not_to respond_to(:diverge_at)
    end
  end

  # Dominance and causal ancestry are implemented once, in Rust, on
  # `Lain::Ext::Timeline` and `Lain::Ext::Dag`; their specs stand on fixtures
  # under spec/lain/rust/.
  describe "the dominance and causal orders" do
    it "are not messages a timeline answers" do
      expect(timeline).not_to respond_to(:dominator_meet)
      expect(timeline).not_to respond_to(:causal_meets)
    end
  end

  describe "#ancestor_of?" do
    let(:base) { say(timeline, "a") }
    let(:child) { say(base, "b", role: :assistant) }

    it "is true for a prefix" do
      expect(base.ancestor_of?(child)).to be(true)
    end

    it "is false for a descendant" do
      expect(child.ancestor_of?(base)).to be(false)
    end

    it "is reflexive" do
      expect(base.ancestor_of?(base)).to be(true)
    end

    it "puts the empty timeline below everything" do
      expect(timeline.ancestor_of?(child)).to be(true)
    end
  end

  # #include? and #ancestor_of? (which delegates to it) used to
  # materialize the whole ancestor chain before asking whether the digest was
  # among it -- correct, but paid for the far side of the chain even when the
  # answer sat one hop from head. `store_fetch_count` is what tells the two
  # shapes apart: a bounded walk and a full re-walk return the identical
  # `true`/`false`, so only the COST of getting there can distinguish them.
  describe "cost: the walk stops at the answer" do
    let(:chain_length) { 60 }
    let(:chain) { (1...chain_length).inject(say(timeline, "0")) { |acc, i| say(acc, i.to_s) } }

    it "include? visits only the turns between head and a nearby answer" do
      target = chain.rewind.head_digest # one hop below head

      tally = count_store_fetches(store) { chain.include?(target) }

      expect(tally.count).to eq(2)
    end

    it "include? still walks the whole chain when the digest is genuinely absent" do
      chain # build the chain before arming the tally -- #commit's own fetches are not this walk's cost

      tally = count_store_fetches(store) { chain.include?("blake3:absent") }

      expect(tally.count).to eq(chain_length)
    end

    it "ancestor_of? visits only the turns between head and a nearby answer" do
      near_ancestor = chain.rewind # one hop below head

      tally = count_store_fetches(store) { near_ancestor.ancestor_of?(chain) }

      expect(tally.count).to eq(2)
    end
  end

  describe "equality (Regular)" do
    include_examples "a Regular value",
                     equal_pair: lambda {
                       one = say(timeline, "a")
                       [one, one.fork]
                     },
                     unequal: -> { say(timeline, "b") },
                     dedup: lambda {
                       one = say(timeline, "a")
                       [one, one.fork]
                     },
                     dedup_size: 1
  end

  # A dangling parent digest (corrupt chain) used to be constructible through
  # the public API -- `Event.turn(parent: absent) -> store.put -> checkout` --
  # and every Timeline walk (ancestors, to_a, rewind, ...) had to raise
  # MissingObject loudly rather than silently truncate at the dangle. That
  # recipe now raises at `put` itself: referential integrity is checked at
  # the API boundary, so a corrupt chain can no longer be built there at all.
  # Prevention at #put is what these examples pin; the walk arms that used to
  # be exercised here stay loud as the backstop (Store#fetch already raises
  # on any missing digest, and the Rust pure-layer `dag.rs` cargo tests keep
  # covering the walk arms directly, since they are unreachable via public
  # API but not deleted).
  describe "a dangling parent digest (corrupt chain)" do
    let(:missing) { "blake3:absent" }
    let(:head) { Lain::Event.turn(role: :user, content: text("head"), parent: missing) }

    it "put refuses the dangling turn before it ever reaches the store" do
      expect { store.put(head) }
        .to raise_error(Lain::Store::MissingObject,
                        %(no object #{missing.inspect} in store: putting #{head.digest.inspect} would dangle))
    end
  end

  # A pinned ruling: correlation is DERIVED by chain construction, not new id
  # machinery -- a chain is named by its root event's digest. The root itself
  # carries nil (its digest IS the identity, and a content address cannot
  # contain itself); every descendant carries the root digest.
  describe "correlation" do
    let(:root) { say(timeline, "a") }
    let(:child) { say(root, "b", role: :assistant) }

    it "leaves the root's correlation nil" do
      expect(root.head.correlation).to be_nil
    end

    it "stamps the root digest on the first descendant" do
      expect(child.head.correlation).to eq(root.head_digest)
    end

    it "is inherited unchanged down the chain" do
      expect(say(child, "c").head.correlation).to eq(root.head_digest)
    end

    it "is shared across forks, which stay one conversation" do
      expect(say(child.fork, "left").head.correlation).to eq(root.head_digest)
      expect(say(child.fork, "right").head.correlation).to eq(root.head_digest)
    end

    it "survives a rewind-and-recommit, which resumes the same chain" do
      expect(say(child.rewind, "redo", role: :assistant).head.correlation).to eq(root.head_digest)
    end

    it "starts fresh on a subagent's fresh root over the shared store" do
      other = say(described_class.empty(store:), "child task")
      expect(other.head.correlation).to be_nil
      expect(say(other, "reply", role: :assistant).head.correlation).to eq(other.head_digest)
    end
  end

  # Subagents get a fresh root over the shared store; the parent's head is
  # recorded in meta, not as a Turn parent, so it never renders into the prompt.
  describe "subagent lineage" do
    let(:parent) { say(timeline, "parent work") }

    let(:child) do
      described_class.empty(store:)
                     .commit(role: :user, content: text("child task"),
                             meta: { "spawned_from" => parent.head_digest })
    end

    it "gives the child a root that does not chain to the parent" do
      expect(child.head).to be_root
      expect(child.length).to eq(1)
    end

    it "shares no prompt history with the parent" do
      expect(Lain::Dag::RenderAncestry.meet(child, parent)).to be_empty
    end

    it "keeps causal lineage recoverable from meta" do
      expect(child.head.meta["spawned_from"]).to eq(parent.head_digest)
    end

    it "shares the store, so the forest is one object database" do
      expect(store.key?(parent.head_digest)).to be(true)
      expect(store.key?(child.head_digest)).to be(true)
    end
  end
end
