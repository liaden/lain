# frozen_string_literal: true

# The Rust Timeline behind the same duck as `Lain::Timeline`, driving the SAME
# `meet_semilattice` and `regular` shared groups the Ruby Timeline does -- the
# port's acceptance oracle. Behaviour mirrors timeline_spec.rb against
# `Lain::Ext::Timeline`/`Store`.
RSpec.describe Lain::Ext::Timeline do
  subject(:timeline) { described_class.empty(store:) }

  let(:store) { Lain::Ext::Store.new }

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
    it "advances the head and leaves the receiver untouched" do
      one = say(timeline, "a")
      expect(one.head.content).to eq(text("a"))
      expect(one.length).to eq(1)
      expect(timeline).to be_empty
    end

    it "chains parents" do
      two = say(say(timeline, "a"), "b", role: :assistant)
      expect(two.head.parent).to eq(two.rewind.head_digest)
    end

    it "orders #to_a root first and #ancestors head first" do
      three = say(say(say(timeline, "a"), "b", role: :assistant), "c")
      expect(three.to_a.map { |t| t.content.first["text"] }).to eq(%w[a b c])
      expect(three.ancestors.map { |t| t.content.first["text"] }).to eq(%w[c b a])
    end
  end

  describe "time travel" do
    let(:three) { say(say(say(timeline, "a"), "b", role: :assistant), "c") }

    it "rewinds n turns and past the root to empty" do
      expect(three.rewind.head.content).to eq(text("b"))
      expect(three.rewind(2).head.content).to eq(text("a"))
      expect(three.rewind(99)).to be_empty
    end

    it "checks out any digest in the store" do
      expect(three.checkout(three.rewind(2).head_digest).head.content).to eq(text("a"))
    end

    it "refuses to check out a digest the store has never seen" do
      expect { three.checkout("blake3:nope") }.to raise_error(Lain::Ext::Store::MissingObject)
    end
  end

  describe "#fork" do
    it "is identity, because the value is immutable" do
      one = say(timeline, "a")
      expect(one.fork).to equal(one)
    end

    it "stores a shared prefix exactly once" do
      base = say(say(timeline, "a"), "b", role: :assistant)
      left = say(base.fork, "left")
      right = say(base.fork, "right")

      expect(store.size).to eq(4) # a, b, left, right
      expect(left.rewind).to eq(right.rewind)
      expect(left).not_to eq(right)
    end
  end

  describe "the meet semilattice under ancestry" do
    let(:base) { say(say(timeline, "a"), "b", role: :assistant) }
    let(:left) { say(say(base, "l1"), "l2", role: :assistant) }
    let(:right) { say(base, "r1") }

    it "finds the greatest common ancestor, exposes the divergence, aliases &" do
      expect(left.meet(right)).to eq(base)
      expect(left.diverge_at(right)).to eq(base.head)
      expect(left & right).to eq(base)
    end

    it "meets to empty and diverges to nil when two roots share no history" do
      other_root = say(described_class.empty(store:), "unrelated")
      expect(left.meet(other_root)).to be_empty
      expect(left.diverge_at(other_root)).to be_nil
    end

    it "refuses to compare across stores" do
      stranger = say(described_class.empty(store: Lain::Ext::Store.new), "x")
      expect { left.meet(stranger) }.to raise_error(described_class::CrossStore)
    end

    describe "the laws" do
      let(:population) do
        timelines = [say(timeline, "root")]
        30.times { |i| timelines << say(timelines.sample, "n#{i}") }
        timelines
      end

      include_examples "a meet semilattice under ancestry", population: -> { population }
    end
  end

  describe "#ancestor_of?" do
    let(:base) { say(timeline, "a") }
    let(:child) { say(base, "b", role: :assistant) }

    it "is a reflexive prefix relation with empty below everything" do
      expect(base.ancestor_of?(child)).to be(true)
      expect(child.ancestor_of?(base)).to be(false)
      expect(base.ancestor_of?(base)).to be(true)
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

  describe "a dangling parent digest (corrupt chain)" do
    # A corrupt chain used to be constructible through the public API -- build
    # a head Turn whose parent digest was never `put`, store JUST the head,
    # check out onto it -- and these examples pinned every ancestry walk to
    # raise MissingObject loudly at the dangle. That recipe now raises at
    # `put` itself: referential integrity is validated at the API boundary,
    # so prevention at put replaces public-API reachability of the walk
    # raises. The walk arms STAY loud as the backstop -- the pure-layer
    # `dag.rs` cargo tests hand-corrupt a StoreMap directly and remain the
    # coverage for them (same philosophy as classify_num's garbage arm:
    # unreachable via this surface is exactly why it must not fail silently).
    let(:missing) { "blake3:absent" }
    let(:head) { Lain::Ext::Turn.new(role: :user, content: text("head"), parent: missing) }

    it "put refuses the dangling turn before it ever reaches the store" do
      expect { store.put(head) }
        .to raise_error(Lain::Ext::Store::MissingObject,
                        %(no object #{missing.inspect} in store: putting #{head.digest.inspect} would dangle))
    end

    it "renders the refusal message byte-identical to the Ruby put" do
      # Ruby's String#inspect and Rust's {:?} must agree byte-for-byte. Plain
      # digests and a digest carrying a double-quote both escape identically;
      # deliberately out of scope are control characters AND Ruby's
      # interpolation guards ("#{", "#@", "#$", which String#inspect escapes to
      # "\#{" etc. and Rust's {:?} leaves bare) -- the escape styles genuinely
      # differ there, and both implementations still refuse.
      ["blake3:absent", 'blake3:a"b'].each do |digest|
        ext_msg = put_refusal_message(Lain::Ext::Store, Lain::Ext::Turn, digest)
        ruby_msg = put_refusal_message(Lain::Store, Lain::Turn, digest)
        expect(ext_msg).to eq(ruby_msg)
      end
    end
  end

  # Put a head whose parent digest was never stored into a fresh store of the
  # given implementation, and return the MissingObject message the put refuses
  # with.
  def put_refusal_message(store_class, turn_class, digest)
    a_head = turn_class.new(role: :user, content: text("head"), parent: digest)
    store_class.new.put(a_head)
    raise "expected #{store_class}::MissingObject to be raised"
  rescue store_class::MissingObject => e
    e.message
  end

  describe "subagent lineage" do
    let(:parent) { say(timeline, "parent work") }

    let(:child) do
      described_class.empty(store:)
                     .commit(role: :user, content: text("child task"),
                             meta: { "spawned_from" => parent.head_digest })
    end

    it "gives the child a fresh root that shares no prompt history with the parent" do
      expect(child.head).to be_root
      expect(child.length).to eq(1)
      expect(child.meet(parent)).to be_empty
      expect(child.head.meta["spawned_from"]).to eq(parent.head_digest)
    end
  end
end
