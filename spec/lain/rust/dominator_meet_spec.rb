# frozen_string_literal: true

# The checkpoint primitive on the Rust timeline -- the deepest common dominator
# over the UNION graph (render and causal edges together, under a virtual root)
# -- and the dominance order that meet is taken over. Rust is the only
# implementation of either, and the safe-compaction checkpoint the architecture
# specifies is this operator.
#
# So no answer below is derived from a second implementation. Every fixture is
# small enough to check by hand, and every expectation names the event it must
# land on by the body that event was committed with. The law run's `dominates?`
# comes from the same implementation as the meet, which proves the two
# self-consistent and nothing more. The INDEPENDENT checks are the brute-force
# group here, which takes dominance from its definition by enumerating every
# root path, and the named fixtures in `ext/lain/src/graph.rs`, which pin the
# algorithm beneath the binding.
RSpec.describe Lain::Ext::Timeline do
  let(:store) { Lain::Ext::Store.new }
  let(:empty) { described_class.empty(store:) }
  let(:graph) { bottleneck }
  let(:elsewhere) { described_class.empty(store: Lain::Ext::Store.new) }
  let(:refusal) { "cannot compare Timelines backed by different stores" }

  def text(body) = [{ "type" => "text", "text" => body }]

  def say(from, body, causal: [])
    from.commit(role: :user, content: text(body), causal_parents: causal)
  end

  # A fresh render root causally anchored at `anchor`'s head: the
  # dominance-relevant collapse of the production spawn, whose :spawn event
  # names the parent's head.
  def spawn_child(anchor, task)
    empty.commit(role: :user, content: text(task), causal_parents: [anchor.head_digest],
                 meta: { "spawned_from" => anchor.head_digest })
  end

  # `a -> b`, b forking to `left` and `right`, and two tips that each render off
  # one fork while causally folding the other. Every path from the virtual root
  # to either tip runs through `b`, so `b` is the deepest common dominator --
  # while `left` and `right` are common ancestors that dominate neither tip.
  def bottleneck
    b = say(say(empty, "a"), "b")
    left = say(b, "left")
    right = say(b, "right")
    { b:, left:, right:,
      tip_left: say(left, "tip_left", causal: [right.head_digest]),
      tip_right: say(right, "tip_right", causal: [left.head_digest]) }
  end

  # The bottleneck answers `b` under the union-graph meet AND under the
  # render-only one, so no example over it can tell the two operators apart.
  # This shape separates them: BOTH tips render off `left`, and only `tip_right`
  # folds `right` causally. The render meet is therefore `left`, while the
  # dominator meet is `b`, because the union-graph path
  # root -> b -> right -> tip_right bypasses `left` entirely.
  def bypass
    b = say(say(empty, "a"), "b")
    left = say(b, "left")
    right = say(b, "right")
    { b:, left:, right:,
      tip_left: say(left, "tip_left"),
      tip_right: say(left, "tip_right", causal: [right.head_digest]) }
  end

  # trunk: root -> spawn-point, two children spawned at the spawn point, a join
  # on the trunk folding both results, and one turn past the join. Paths from
  # the virtual root reach the post-join head through the trunk AND through
  # each child, and the join is where they all converge.
  def checkpoint
    trunk = say(say(empty, "root"), "spawn-point")
    child_a = say(spawn_child(trunk, "task a"), "result a")
    child_b = say(spawn_child(trunk, "task b"), "result b")
    join = say(trunk, "fold both results", causal: [child_a.head_digest, child_b.head_digest])
    { trunk:, child_a:, child_b:, join:, post_join: say(join, "onward") }
  end

  describe "#dominator_meet" do
    it "answers the bottleneck, not either fork" do
      meet = graph[:tip_left].dominator_meet(graph[:tip_right])
      expect(meet).to eq(graph[:b])
      expect(meet).not_to eq(graph[:left])
      expect(meet).not_to eq(graph[:right])
    end

    it "answers the union-graph meet, not the render meet" do
      shape = bypass
      expect(shape[:tip_left].dominator_meet(shape[:tip_right])).to eq(shape[:b])
      expect(shape[:tip_left].meet(shape[:tip_right])).to eq(shape[:left])
    end

    it "answers a timeline over the receiver's own store" do
      meet = graph[:tip_left].dominator_meet(graph[:tip_right])
      expect(meet).to be_a(described_class)
      expect(meet.store).to be(store)
    end

    describe "the checkpoint (a fan-out that fully joins back)" do
      let(:shape) { checkpoint }

      it "collapses to the join when the join dominates the other head" do
        expect(shape[:post_join].dominator_meet(shape[:join])).to eq(shape[:join])
        expect(shape[:join].dominator_meet(shape[:post_join])).to eq(shape[:join])
      end

      it "meets two heads past the join at the join" do
        expect(say(shape[:join], "x").dominator_meet(say(shape[:join], "y"))).to eq(shape[:join])
      end

      # A meet sits below BOTH operands, and no pre-join event is dominated by
      # the later join -- so a pre-join operand meets at the spawn point, where
      # the fan-out's paths last agreed.
      it "meets a pre-join head at the spawn point, never later" do
        expect(shape[:post_join].dominator_meet(shape[:child_a])).to eq(shape[:trunk])
        expect(shape[:post_join].dominator_meet(shape[:trunk])).to eq(shape[:trunk])
      end
    end

    # The causal-stability caveat, pinned as documented behaviour: one quiet
    # participant stalls the checkpoint frontier.
    describe "a quiet branch freezes the frontier" do
      let(:trunk) { say(say(empty, "root"), "spawn-point") }
      let(:child) { say(spawn_child(trunk, "task"), "result") }

      it "answers at the spawn point while a spawned branch stays open, however far the parent advances" do
        parent = say(say(trunk, "keeps"), "working")
        expect(parent.dominator_meet(child)).to eq(trunk)
      end

      it "answers the empty timeline when the child is linked by meta alone" do
        orphan = empty.commit(role: :user, content: text("task"), meta: { "spawned_from" => trunk.head_digest })
        expect(trunk.dominator_meet(orphan)).to be_empty
      end
    end

    it "answers the empty timeline, never the virtual root, for heads sharing no history" do
      meet = graph[:tip_left].dominator_meet(say(empty, "stranger"))
      expect(meet).to be_empty
      expect(meet.head_digest).to be_nil
      expect(meet.head).to be_nil
    end

    it "absorbs the empty timeline from either side" do
      expect(graph[:tip_left].dominator_meet(empty)).to be_empty
      expect(empty.dominator_meet(graph[:tip_left])).to be_empty
    end

    it "reads the store and never writes it" do
      shape = checkpoint
      expect { shape[:post_join].dominator_meet(shape[:child_a]) }.not_to change(store, :size)
    end

    it "refuses a meet across two stores, in the Rust class's own words" do
      expect { graph[:tip_left].dominator_meet(elsewhere) }
        .to raise_error(described_class::CrossStore, refusal)
    end
  end

  # The order the meet is taken over, and the reason it is exposed at all: the
  # fourth semilattice law says a meet sits BELOW both operands, and below means
  # dominated. `ancestor_of?` is strictly weaker -- it asks whether SOME path
  # arrives, dominance whether EVERY one does -- so a law checked with it passes
  # vacuously.
  describe "#dominates?" do
    it "answers false where render ancestry answers true" do
      expect(graph[:left].ancestor_of?(graph[:tip_left])).to be(true)
      expect(graph[:left].dominates?(graph[:tip_left])).to be(false)
    end

    # Over the bottleneck `b` dominates every named event, and each other
    # event dominates only itself: each fork and each tip is reachable around
    # every event but `b` and itself.
    it "answers the bottleneck's dominance over every pair" do
      names = graph.keys
      answers = names.product(names).to_h { |a, b| [[a, b], graph[a].dominates?(graph[b])] }
      expect(answers).to eq(names.product(names).to_h { |a, b| [[a, b], a == b || a == :b] })
    end

    it "names the join, and neither child, as dominating the post-join head" do
      shape = checkpoint
      expect(shape[:join].dominates?(shape[:post_join])).to be(true)
      expect(shape[:child_a].dominates?(shape[:post_join])).to be(false)
      expect(shape[:child_b].dominates?(shape[:post_join])).to be(false)
    end

    it "puts the empty timeline below everything and above only itself" do
      expect(empty.dominates?(graph[:tip_left])).to be(true)
      expect(graph[:tip_left].dominates?(empty)).to be(false)
      expect(empty.dominates?(empty)).to be(true)
    end

    it "is reflexive" do
      expect(graph[:tip_left].dominates?(graph[:tip_left])).to be(true)
    end

    it "reads the store and never writes it" do
      shape = checkpoint
      expect { shape[:join].dominates?(shape[:post_join]) }.not_to change(store, :size)
    end

    it "refuses a question across two stores, in the Rust class's own words" do
      expect { graph[:tip_left].dominates?(elsewhere) }
        .to raise_error(described_class::CrossStore, refusal)
    end
  end

  describe "against brute force (small random union graphs)" do
    # Kept to about a dozen events so exhaustive root-to-node path enumeration
    # stays tractable.
    let(:population) do
      pop = [say(empty, "root")]
      5.times { |i| pop << say(pop.sample, "c#{i}") }
      pop << spawn_child(pop.sample, "spawned")
      2.times { |i| pop << say(pop.sample, "d#{i}") }
      2.times do |i|
        from, *folds = pop.sample(3)
        pop << say(from, "f#{i}", causal: folds.map(&:head_digest))
      end
      pop
    end

    def union_parents(digest)
      event = store.fetch(digest)
      parents = [event.render_parent, *event.causal_parents].compact.uniq
      parents.empty? ? [:virtual_root] : parents
    end

    def union_nodes(heads)
      seen = {}
      frontier = heads.dup
      while (digest = frontier.pop)
        unless seen.key?(digest)
          seen[digest] = true
          frontier.concat(union_parents(digest) - [:virtual_root])
        end
      end
      seen.keys
    end

    # Every virtual-root-to-node path, enumerated backward over parent edges --
    # exponential in general, tractable at this size.
    def every_path(digest)
      return [[:virtual_root]] if digest == :virtual_root

      union_parents(digest).flat_map { |parent| every_path(parent).map { |path| path + [digest] } }
    end

    # The nodes present on EVERY root path: the meet-over-all-paths definition
    # of dominance, independent of any dominator tree.
    def brute_dominators(digest)
      every_path(digest).reduce(:&)
    end

    it "agrees with exhaustive path enumeration on every node's dominator set" do
      nodes = union_nodes(population.map(&:head_digest))
      nodes.each do |node|
        brute = brute_dominators(node)
        nodes.each do |candidate|
          expect(empty.checkout(candidate).dominates?(empty.checkout(node))).to eq(brute.include?(candidate)),
                                                                                "dominates?(#{candidate}, #{node})"
        end
      end
    end

    it "returns the deepest member of the brute-force dominator intersection for random pairs" do
      10.times do
        a, b = population.sample(2)
        common = brute_dominators(a.head_digest) & brute_dominators(b.head_digest)
        deepest = common.find { |candidate| (common - brute_dominators(candidate)).empty? }
        expect(a.dominator_meet(b).head_digest).to eq(deepest == :virtual_root ? nil : deepest)
      end
    end
  end

  # The dominator meet held to the four laws through the shared group, over the
  # UNION graph and not a render forest: `#meet`'s laws hold over a forest
  # where the causal edge is invisible, and reading these laws over the same
  # forest would prove the render meet a second time.
  describe "#dominator_meet, the laws (dominance order injected)" do
    # ONE definition of the knobs, read by the guards below AND splatted into
    # the include -- a Hash rather than three locals named at the include site,
    # because a guard has to hold the very knob the group receives. Named
    # separately there, the include is free to hand the group a weaker operator
    # while the guards go on passing about the ones they hold, and the guards
    # are then guarding a copy. Measured, which is why it is a Hash: weakening
    # `meet:` at the include alone went red in 9 seeds of 20 with both guards
    # green, and weakening it here goes red in 20 of 20.
    knobs = { population: -> { population },
              meet: ->(a, b) { a.dominator_meet(b) },
              ancestor_of: ->(m, a) { m.dominates?(a) } }
    meet = knobs[:meet]
    below = knobs[:ancestor_of]
    lower_bound = ->(m, a, b) { below.call(m, a) && below.call(m, b) }

    let(:population) { MeetSemilatticePopulations.union_graph(empty) }

    let(:folded) { population.select { |member| member.head.causal_parents.any? } }

    # The group cannot see what it quantifies over, and a population that came
    # out a pure render forest would satisfy all four laws while saying nothing
    # about the operator under test -- the render meet already satisfies them.
    # Both shapes that separate dominance from render ancestry are named here: a
    # fold whose causal parents are not merely a restatement of its render
    # parent, and a fresh render root anchored causally (the subagent spawn),
    # which a render walk does not reach at all.
    it "is read over a union graph rather than a render forest" do
      cross_chain, anchored_roots = folded.partition { |member| member.head.parent }
      expect(cross_chain.count { |member| member.head.causal_parents != [member.head.parent] }).to be_positive
      expect(anchored_roots).not_to be_empty
    end

    # The order knob, asserted as the mutation rather than as prose: over this
    # population the two predicates genuinely disagree about the meets the
    # fourth law examines, so weakening `below` to `#ancestor_of?` turns this
    # example RED instead of leaving the fourth law green and vacuous -- and
    # dropping the knob from the Hash leaves nothing here to call.
    it "would fail its fourth law under render ancestry, which is why the order is dominance" do
      unseen = population.permutation(2).count do |a, b|
        lower = meet.call(a, b)
        below.call(lower, a) && !lower.ancestor_of?(a)
      end
      expect(unseen).to be_positive
    end

    # The meet knob, the same way -- and it needs saying separately, because the
    # render meet passes all four laws under this population often enough that
    # the group's ten random draws catch the substitution only about half the
    # time (measured). Exhaustive over the ordered pairs, so the distinction is
    # certain rather than sampled: the render meet is not a lower bound of the
    # union order for some pair here, and the operator the group is given is.
    #
    # That there IS such a pair is MEASURED, not proved -- no build of 3300 came
    # out with none, but the tail reaches a single unordered pair, so read the
    # margin as evidence about this builder rather than as a structural
    # guarantee. A builder change that narrowed it further would show up here.
    it "hands the group the union-graph meet, which this population separates from the render meet" do
      escaping = population.permutation(2).reject { |a, b| lower_bound.call(a.meet(b), a, b) }
      expect(escaping).not_to be_empty
      expect(escaping.count { |a, b| lower_bound.call(meet.call(a, b), a, b) }).to eq(escaping.size)
    end

    include_examples "a meet semilattice under ancestry", **knobs
  end
end
