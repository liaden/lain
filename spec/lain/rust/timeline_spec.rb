# frozen_string_literal: true

# The Rust Timeline behind the same duck as `Lain::Timeline`, driving the SAME
# `meet_semilattice` and `regular` shared groups the Ruby render order and
# Timeline run under -- the port's acceptance oracle. Behaviour mirrors
# timeline_spec.rb against `Lain::Ext::Timeline`/`Store`. The dominance and
# causal orders exist only here, and their specs are dominator_meet_spec.rb
# and causal_meets_spec.rb beside this one.
RSpec.describe Lain::Ext::Timeline do
  subject(:timeline) { described_class.empty(store:) }

  let(:store) { Lain::Ext::Store.new }
  let(:three) { say(say(say(timeline, "a"), "b", role: :assistant), "c") }

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

  describe ".new" do
    it "builds a timeline at a head already in the store" do
      middle = described_class.new(head_digest: three.rewind.head_digest, store:)
      expect(middle.head).to eq(three.rewind.head)
      expect(middle.length).to eq(2)
    end

    it "builds an empty timeline from a nil head" do
      expect(described_class.new(head_digest: nil, store:)).to be_empty
    end

    it "refuses a head the store does not hold" do
      expect { described_class.new(head_digest: "blake3:nope", store:) }
        .to raise_error(Lain::Ext::Store::MissingObject, /no object "blake3:nope"/)
    end

    it "refuses a head that is not an event, though the store holds it" do
      payload = three.head.carried_payload

      expect(store.key?(payload.digest)).to be(true)
      expect { described_class.new(head_digest: payload.digest, store:) }
        .to raise_error(Lain::Ext::Store::MissingObject, "no event #{payload.digest.inspect}")
    end

    it "refuses a store that is not a Store" do
      expect { described_class.new(head_digest: nil, store: Object.new) }.to raise_error(TypeError)
    end
  end

  describe "#correlation" do
    it "is nil on an empty timeline" do
      expect(timeline.correlation).to be_nil
    end

    it "names a chain by its root digest, at the root and above it" do
      root = three.to_a.first.digest
      expect([three.rewind(2).correlation, three.correlation]).to eq([root, root])
    end

    it "equals the Ruby timeline's answer over the same chain" do
      ruby = Lain::Timeline.empty(store: Lain::Store.new).commit(role: :user, content: text("a"))
                           .commit(role: :assistant, content: text("b"))
      ext = described_class.empty(store:).commit(role: :user, content: text("a"))
                           .commit(role: :assistant, content: text("b"))
      expect(ext.correlation).to eq(ruby.correlation)
    end
  end

  describe "#commit" do
    it "writes nothing when it is refused" do
      base = three
      before = store.size

      expect { base.commit(role: :user, content: text("d"), causal_parents: ["blake3:absent"]) }
        .to raise_error(Lain::Ext::Store::MissingObject)
      expect(store.size).to eq(before)
    end

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
      expect(three.to_a.map { |t| t.content.first["text"] }).to eq(%w[a b c])
      expect(three.ancestors.map { |t| t.content.first["text"] }).to eq(%w[c b a])
    end
  end

  # The causal edge is what a render walk cannot see: the assistant turn that
  # folded a set of messages names them here, and they are hashed into the
  # envelope like any other content. Mirrors timeline_spec.rb's "#commit with
  # causal_parents", against the same duck.
  describe "#commit with causal_parents" do
    let(:base) { say(timeline, "a") }
    let(:sibling) { say(described_class.empty(store:), "elsewhere") }

    it "threads every named causal parent onto the committed turn" do
      folded = base.commit(role: :assistant, content: text("b"),
                           causal_parents: [base.head_digest, sibling.head_digest])
      expect(folded.head.causal_parents).to contain_exactly(base.head_digest, sibling.head_digest)
    end

    it "answers a repeated, unordered set once each and sorted" do
      unsorted = [sibling.head_digest, base.head_digest, sibling.head_digest].sort.reverse
      folded = base.commit(role: :assistant, content: text("b"), causal_parents: unsorted)
      expect(folded.head.causal_parents).to eq(unsorted.uniq.sort)
    end

    it "records no causal parents when none are named" do
      expect(say(timeline, "a").head.causal_parents).to eq([])
    end

    it "changes the turn digest, because causal_parents are hashed content" do
      plain = base.commit(role: :assistant, content: text("b"))
      causal = base.commit(role: :assistant, content: text("b"), causal_parents: [base.head_digest])
      expect(causal.head_digest).not_to eq(plain.head_digest)
    end

    # An absent keyword is the empty set; an explicit nil is a caller who
    # believes they are naming something. Reading the second as the first
    # accepts input the Ruby timeline refuses outright, and this codebase's
    # premise is that an unknown value fails loudly.
    it "refuses an explicit nil rather than reading it as the empty set" do
      expect { base.commit(role: :assistant, content: text("b"), causal_parents: nil) }
        .to raise_error(TypeError, /causal_parents must be an Array of digest Strings/)
    end

    it "refuses a nil element inside the set" do
      expect { base.commit(role: :assistant, content: text("b"), causal_parents: [nil]) }
        .to raise_error(TypeError, /causal_parents must contain only digest Strings/)
    end

    it "addresses a causally-parented turn exactly as the Ruby timeline does" do
      expect(causal_head_digest(described_class.empty(store: Lain::Ext::Store.new)))
        .to eq(causal_head_digest(Lain::Timeline.empty(store: Lain::Store.new)))
    end

    it "refuses a causal parent the store has never seen" do
      expect { base.commit(role: :assistant, content: text("b"), causal_parents: ["blake3:ghost"]) }
        .to raise_error(Lain::Ext::Store::MissingObject)
    end

    it "renders that refusal byte-identical to the Ruby commit" do
      expect(commit_refusal_message(described_class.empty(store: Lain::Ext::Store.new), Lain::Ext::Store))
        .to eq(commit_refusal_message(Lain::Timeline.empty(store: Lain::Store.new), Lain::Store))
    end
  end

  # Commit a turn naming SEVERAL causal parents, duplicated and reverse-sorted,
  # onto a two-turn timeline. Both implementations are driven through the
  # identical public calls, so the head digest is a cross-implementation address
  # comparison and nothing else.
  #
  # The shape of the input is what gives the comparison teeth. One parent that
  # is also the render parent would agree across any two normalizations at all;
  # two distinct parents, one of them repeated and the pair handed over in
  # descending order, disagree the moment either side dedups differently or
  # sorts under a different collation.
  def causal_head_digest(empty)
    first = empty.commit(role: :user, content: text("a"))
    second = first.commit(role: :assistant, content: text("b"))
    parents = [first.head_digest, second.head_digest, first.head_digest].sort.reverse
    second.commit(role: :user, content: text("c"), causal_parents: parents).head_digest
  end

  # The MissingObject message a commit naming an unstored causal parent refuses
  # with. The refused turn's digest appears in that message, so this compares
  # the addressing and the wording at once.
  def commit_refusal_message(empty, store_class)
    empty.commit(role: :user, content: text("a"))
         .commit(role: :assistant, content: text("b"), causal_parents: ["blake3:ghost"])
    raise "expected #{store_class}::MissingObject to be raised"
  rescue store_class::MissingObject => e
    e.message
  end

  # `#ancestors` has two forms and the Rust binding only ever answered one of
  # them: it is registered at arity 0, which says nothing about a block, so a
  # block-passing caller got a silently discarded Array. Ledger#unique_turns is
  # that caller, and a bench whose whole cost column reads zero raises nothing.
  # These four pin both forms against Lain::Timeline#ancestors, the return
  # value included.
  describe "#ancestors" do
    it "yields every ancestor to a block, head first" do
      seen = []
      three.ancestors { |turn| seen << turn }

      expect(seen.length).to eq(3)
      expect(seen.first.digest).to eq(three.head_digest)
      expect(seen.map { |turn| turn.content.first["text"] }).to eq(%w[c b a])
    end

    # The Rust doc comment promises both of these, and a promise with no test
    # is what this codebase otherwise refuses. The nil is Ruby's own answer
    # (its body ends on a `while`); the valued `break` is the one thing a
    # `?`-propagating yield loop could plausibly swallow.
    it "answers nil, and hands a valued break straight back to the caller" do
      expect(three.ancestors { |_turn| :ignored }).to be_nil
      expect(three.ancestors { |turn| break turn.digest }).to eq(three.head_digest)
    end

    it "returns an enumerator when no block is given" do
      walk = three.ancestors

      expect(walk).to be_a(Enumerator)
      expect(walk.take(2).map { |turn| turn.content.first["text"] }).to eq(%w[c b])
    end

    # An enumerator stepped from outside walks on a fiber of its own, and one
    # dropped mid-walk is collected without unwinding that fiber. So the walk's
    # snapshot has to be freed by Ruby's collector, never held by a frame that
    # will not return; `Walk.live` counts the snapshots on the Rust side, where
    # the memory is. The steps run on a thread of their own, ended before the
    # count, because the collector scans live stacks conservatively and a
    # stale word on this one could keep a walk reachable.
    it "frees every walk behind enumerators dropped mid-walk" do
      line = three
      before = live_walks
      Thread.new { 20.times { step_once(line) } }.join

      expect(live_walks).to eq(before)
    end

    def step_once(line) = line.ancestors.tap(&:next) && nil

    def live_walks
      GC.start(full_mark: true, immediate_sweep: true)
      described_class::Walk.live
    end

    # The digests are content addresses, so agreeing on them is agreeing on
    # both the walk order and what each node is -- the port's own oracle.
    it "yields the same digests the Ruby timeline yields for the same commits" do
      rust = []
      ruby = []
      three.ancestors { |turn| rust << turn.digest }
      say(say(say(Lain::Timeline.empty(store: Lain::Store.new), "a"), "b", role: :assistant), "c")
        .ancestors { |turn| ruby << turn.digest }

      expect(rust).to eq(ruby)
    end
  end

  describe "#messages" do
    let(:toolset) { Lain::Toolset.new }
    let(:context) { CoreGraph.context }

    def chain(count, on: timeline)
      count.times.inject(on) { |line, index| say(line, "turn #{index}", role: index.even? ? :user : :assistant) }
    end

    def recording(line)
      Class.new(SimpleDelegator) do
        attr_reader :asked

        def initialize(target)
          super
          @asked = []
        end

        def method_missing(name, *args, **kwargs, &block)
          super.tap { |answer| @asked << [name, kwargs, answer] }
        end

        def respond_to_missing?(name, include_private = false) = super
      end.new(line)
    end

    it "answers the role and content of every turn, root first, deep frozen" do
      messages = three.messages

      expect(messages).to eq([{ "role" => "user", "content" => text("a") },
                              { "role" => "assistant", "content" => text("b") },
                              { "role" => "user", "content" => text("c") }])
      expect(Ractor.shareable?(messages)).to be(true)
    end

    it "answers only the turns after an ancestor, as the Ruby timeline does" do
      ruby = chain(5, on: Lain::Timeline.empty(store: Lain::Store.new))
      ext = chain(5)

      expect(ext.messages(after: ext.rewind(2).head_digest)).to eq(ext.messages.last(2))
      expect(ext.messages(after: ext.rewind(2).head_digest)).to eq(ruby.messages(after: ruby.rewind(2).head_digest))
    end

    it "answers the full walk for a digest that is not an ancestor" do
      line = chain(4)
      moved = say(line.rewind(2), "elsewhere")

      expect(moved.messages(after: line.head_digest)).to eq(moved.messages)
      expect(moved.messages(after: "blake3:nope")).to eq(moved.messages)
    end

    it "lets a context render a long chain in one crossing, with no per-turn reader" do
      line = recording(chain(1000))
      readers = []
      trace = TracePoint.new(:c_call) { |point| readers << point.method_id if point.defined_class == Lain::Ext::Turn }

      trace.enable { context.render(timeline: line, toolset:) }

      expect(line.asked.map(&:first)).to eq([:messages])
      expect(readers).to be_empty
    end

    it "renders the request the Ruby timeline renders, byte for byte" do
      blocks = lambda do |index|
        [{ "type" => "text", "text" => "turn #{index}" },
         { "type" => "tool_use", "id" => "tu_#{index}", "name" => "echo",
           "input" => { "ratio" => index / 4.0, "counts" => [index, -index, 2**70], "flag" => nil } }]
      end
      build = ->(line) { 6.times.inject(line) { |acc, at| acc.commit(role: :assistant, content: blocks.call(at)) } }
      ruby = build.call(Lain::Timeline.empty(store: Lain::Store.new))
      ext = build.call(timeline)

      expect(context.render(timeline: ext, toolset:).digest).to eq(context.render(timeline: ruby, toolset:).digest)
    end

    it "extends a prefix it is handed past an ancestor, and ignores it past anything else" do
      line = chain(4)
      prefix = line.rewind(2).messages
      moved = say(line.rewind(2), "elsewhere")

      expect(line.messages(after: line.rewind(2).head_digest, onto: prefix)).to eq(line.messages)
      expect(line.messages(after: line.rewind(2).head_digest, onto: prefix).first).to equal(prefix.first)
      expect(moved.messages(after: line.head_digest, onto: prefix)).to eq(moved.messages)
    end

    it "materialises only the turn a prefix has not seen, in one crossing" do
      line = chain(1000)
      prefix = Lain::Agent::RenderedPrefix.none.over(line)
      longer = recording(say(line, "next"))

      extended = prefix.over(longer)
      fresh = extended.messages.reject.with_index { |message, at| message.equal?(prefix.messages[at]) }

      expect(longer.asked.map(&:first)).to eq(%i[head_digest messages])
      expect(fresh.size).to eq(1)
      expect(extended.messages).to eq(longer.__getobj__.messages)
    end

    it "never splices a rewound head onto a stale prefix" do
      line = chain(10)
      prefix = Lain::Agent::RenderedPrefix.none.over(line)
      moved = say(line.rewind(2), "after the rewind")

      expect(prefix.over(moved).messages).to eq(moved.messages)
    end
  end

  describe "time travel" do
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

      # Four turns, each with its out-of-line payload -- eight objects, the
      # count the Ruby store holds for the same commits.
      expect(store.size).to eq(8)
      expect(store.key?(left.head.payload_digest)).to be(true)
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
        ext_msg = put_refusal_message(Lain::Ext::Store, ->(**args) { Lain::Ext::Turn.new(**args) }, digest)
        ruby_msg = put_refusal_message(Lain::Store, ->(**args) { Lain::Event.turn(**args) }, digest)
        expect(ext_msg).to eq(ruby_msg)
      end
    end
  end

  # Put a head whose parent digest was never stored into a fresh store of the
  # given implementation, and return the MissingObject message the put refuses
  # with. `build_turn` is a factory because the two impls construct differently
  # (Ext::Turn.new vs Event.turn).
  def put_refusal_message(store_class, build_turn, digest)
    a_head = build_turn.call(role: :user, content: text("head"), parent: digest)
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

  # to_s is the human-facing projection; inspect keeps the class-tagged,
  # debug-oriented form -- the same convention Ruby's DegradedSet uses (see
  # capability/degraded_set_spec.rb), now held on both sides of the FFI
  # boundary.
  describe "string conversions" do
    it "renders an empty timeline's to_s untagged" do
      expect(timeline.to_s).to eq("empty")
    end

    it "renders an empty timeline's inspect class-tagged" do
      expect(timeline.inspect).to eq("#<Lain::Ext::Timeline empty>")
    end

    it "renders a non-empty timeline's to_s as a truncated digest and length, untagged" do
      one = say(timeline, "a")
      expect(one.to_s).to eq("#{one.head_digest[0, 19]}... (1)")
    end

    it "renders a non-empty timeline's inspect class-tagged" do
      one = say(timeline, "a")
      expect(one.inspect).to eq("#<Lain::Ext::Timeline #{one}>")
    end
  end
end
