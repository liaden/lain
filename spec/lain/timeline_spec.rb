# frozen_string_literal: true

RSpec.describe Lain::Timeline do
  subject(:timeline) { described_class.empty(store:) }

  let(:store) { Lain::Store.new }

  def text(body) = [{ "type" => "text", "text" => body }]

  def say(from, body, role: :user) = from.commit(role:, content: text(body))

  # A fan-in (synthesis) event: it CONTINUES `from`'s render chain and names
  # the heads of `folds` as causal parents -- the cross-chain edges that make
  # the object graph a DAG.
  def fan_in(from, folds, body: "synthesis")
    from.commit(role: :assistant, content: text(body), causal_parents: folds.map(&:head_digest))
  end

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

    # T4: the envelope's payload_digest is an edge the Store enforces, so
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

    # Review fix (T4): commit is the hottest per-turn path, and its digest work
    # is exactly two Canonical.digest passes -- the payload once (inside
    # Event.turn) and the envelope once. A third call means the payload was
    # rebuilt from turn.body instead of reusing the object Event.turn built.
    it "digests exactly twice per commit: the payload once, the envelope once" do
      allow(Lain::Canonical).to receive(:digest).and_call_original
      say(timeline, "a")
      expect(Lain::Canonical).to have_received(:digest).twice
    end
  end

  # T6/decision 2: the assistant commit records the messages a render folded as
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

  describe "the meet semilattice under ancestry" do
    let(:base) { say(say(timeline, "a"), "b", role: :assistant) }
    let(:left) { say(say(base, "l1"), "l2", role: :assistant) }
    let(:right) { say(base, "r1") }

    it "finds the greatest common ancestor" do
      expect(left.meet(right)).to eq(base)
    end

    it "exposes the divergence turn, which is what cache-break localization needs" do
      expect(left.diverge_at(right)).to eq(base.head)
    end

    it "aliases #& to #meet" do
      expect(left & right).to eq(base)
    end

    it "meets to the empty timeline when two roots share no history" do
      other_root = say(described_class.empty(store:), "unrelated")
      expect(left.meet(other_root)).to be_empty
    end

    it "returns nil from #diverge_at when there is no shared history" do
      other_root = say(described_class.empty(store:), "unrelated")
      expect(left.diverge_at(other_root)).to be_nil
    end

    it "refuses to compare across stores" do
      stranger = say(described_class.empty(store: Lain::Store.new), "x")
      expect { left.meet(stranger) }.to raise_error(described_class::CrossStore)
    end

    describe "the laws" do
      # Build a random render forest, then fan-in events whose causal parents
      # cross-link the chains, and assert the meet laws on randomly chosen
      # members. To be precise about what this guards: #meet walks the render
      # edge only, and the fan-in members sit as leaves ON that render tree, so
      # no meet here ever traverses a causal edge -- this population does not
      # (cannot) exercise meet "over a DAG". What it pins is that ADDING causal
      # cross-links to the Store leaves the render-tree meet unperturbed.
      # Randomized because a hand-picked shape is exactly where an
      # associativity bug hides.
      let(:population) do
        timelines = [say(timeline, "root")]
        30.times { |i| timelines << say(timelines.sample, "n#{i}") }
        timelines + Array.new(10) { fan_in(timelines.sample, timelines.sample(2)) }
      end

      include_examples "a meet semilattice under ancestry", population: -> { population }
    end
  end

  # TL-3 ruling (Joel, 2026-07-17): three operators, each honest about its
  # question. #meet/#diverge_at stay render-edge and byte-unchanged (cache-break
  # localization); #causal_meets is the SET of maximal lower bounds of the
  # causal ancestry order -- reachability over BOTH parent edges, git's "all
  # parents" -- in git merge-base's shape, plural under criss-cross. It is
  # deliberately NOT under the MeetSemilattice law group: a set-valued operator
  # makes no semilattice claim (that is dominator_meet's job, a different
  # operator).
  describe "#causal_meets" do
    let(:base) { say(say(timeline, "a"), "b", role: :assistant) }
    let(:left) { say(say(base, "l1"), "l2", role: :assistant) }
    let(:right) { say(base, "r1") }

    it "returns the maximal common causal ancestors as a frozen, digest-ordered set" do
      # base's whole chain is common ancestry, but only its head is maximal:
      # everything below it is an ancestor of another common ancestor.
      expect(left.causal_meets(right)).to eq([base.head_digest])
      expect(left.causal_meets(right)).to be_frozen
    end

    it "follows causal edges, seeing ancestry the render walk cannot" do
      synthesis = fan_in(left, [right])
      # right's head IS a causal ancestor of the synthesis (via the fold), so
      # the meet set reaches it -- while the render meet still stops at base.
      expect(synthesis.causal_meets(right)).to eq([right.head_digest])
      expect(synthesis.meet(right)).to eq(base)
    end

    it "returns both maximal ancestors of a criss-cross, never an arbitrary singleton" do
      x = say(base, "x")
      y = say(base.fork, "y", role: :assistant)
      cross_a = fan_in(x, [y])
      cross_b = fan_in(y, [x])
      # x and y are incomparable (neither reaches the other), and every deeper
      # common ancestor sits below both -- git merge-base's plural case.
      expect(cross_a.causal_meets(cross_b)).to eq([x.head_digest, y.head_digest].sort)
      expect(cross_b.causal_meets(cross_a)).to eq(cross_a.causal_meets(cross_b))
    end

    it "collapses to the ancestor's own head when one timeline is an ancestor of the other" do
      expect(base.causal_meets(left)).to eq([base.head_digest])
    end

    # The set-valued analog of idempotence -- the one law this operator still
    # owes after opting out of the MeetSemilattice group (plural codomain).
    it "is reflexive: a timeline's meet set with itself is its own head" do
      expect(left.causal_meets(left)).to eq([left.head_digest])
      synthesis = fan_in(left, [right])
      expect(synthesis.causal_meets(synthesis)).to eq([synthesis.head_digest])
    end

    it "is empty when the causal ancestries share nothing, and on the empty timeline" do
      stranger = say(described_class.empty(store:), "unrelated")
      expect(left.causal_meets(stranger)).to eq([])
      expect(timeline.causal_meets(left)).to eq([])
    end

    it "never mutates: no Store put, no Timeline commit" do
      synthesis = fan_in(left, [right])
      allow(store).to receive(:put).and_call_original
      before = store.size
      synthesis.causal_meets(right)
      expect(store).not_to have_received(:put)
      expect(store.size).to eq(before)
    end

    it "refuses to compare across stores" do
      stranger = say(described_class.empty(store: Lain::Store.new), "x")
      expect { left.causal_meets(stranger) }.to raise_error(described_class::CrossStore)
    end
  end

  # #meet and #diverge_at walk the render edge only; causal edges landing in
  # the Store must not perturb them. On single-parent render chains they return
  # exactly what they returned before causal edges existed -- the ruling's
  # premise, pinned as a strict regression.
  describe "the render meet under causal-edge insertion" do
    let(:base) { say(say(timeline, "a"), "b", role: :assistant) }
    let(:left) { say(say(base, "l1"), "l2", role: :assistant) }
    let(:right) { say(base, "r1") }

    it "leaves #meet and #diverge_at exactly as before" do
      fan_in(left, [right]) # a causal edge now exists in the store
      expect(left.meet(right)).to eq(base)
      expect(left.diverge_at(right)).to eq(base.head)
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

  # TL-2 (pinned): correlation is DERIVED by chain construction, not new id
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
      expect(child.meet(parent)).to be_empty
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
