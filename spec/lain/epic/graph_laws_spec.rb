# frozen_string_literal: true

# The scheduling laws over an epic's issue graph, read over a generated
# population rather than over hand-built examples. Four claims carry it.
#
# `#ready` grows under LANDINGS and may shrink under EDITS. Those two are one
# statement about what an epic is allowed to do to its author: finishing work
# never takes other work off the board, but recording newly discovered work can.
# The second is deliberately EXHIBITED rather than generated -- an existence
# claim over a random population is flaky by construction, and a draw that
# happened to hold no witness would report the opposite of what it states.
#
# `#waves` partition the issues into antichains AND put those antichains in
# order. The two together are what make a plan runnable rather than merely
# decomposed: a wave is a set an author may start in parallel, and nothing in it
# waits on anything in it or after it. Both are read over the TRANSITIVE
# relation, because `a -> b -> c` makes `a` and `c` comparable with no direct
# edge between them for a direct-edge reading to find.
#
# `#split` and `#merge` preserve blocking reachability under the substitution
# they perform -- the Revision doc's own claim in lib/lain/epic/graph.rb, said
# here over the TRANSITIVE relation. Its converse is a SEPARATE law and is
# deliberately the weaker of the two: a merge legitimately fuses two dependency
# cones, so "invents no reachability" is false of a correct merge, while
# "invents no edge without a preimage" is exactly true.
#
# Every law is paired with an anti-vacuity guard over the same population. A law
# read over an empty ready set, over waves that are all singletons, or over a
# revision that always raises passes without saying anything, and that is the
# failure a generated population reaches silently rather than loudly.
RSpec.describe Lain::Epic::Graph do
  # A population that is a function of the RSpec SEED alone. Kernel#rand is
  # seeded once for the whole suite, so what it has drawn by the time this file
  # runs depends on file order -- a private Random is what makes the seed the
  # runner prints enough to reproduce a failure.
  let(:graphs) do
    source = Random.new(RSpec.configuration.seed)
    Array.new(50) { generated_graph(source) }
  end

  # Ids are drawn in order and every edge points forward, so `blocks` is acyclic
  # by construction and the generator never has to reject a draw. Statuses are
  # weighted toward pending: `#ready` is the subject of two laws here, and a
  # mostly-finished population would read them over an empty set. Four issues is
  # the floor rather than one, because a two-issue graph has one wave, one
  # landing round, and one mergeable pair -- it satisfies every law below while
  # exercising none of them.
  def generated_graph(source)
    ids = Array.new(source.rand(4..8)) { |i| format("i%02d", i) }
    described_class.new(issues: ids.each_with_index.map { |id, i| generated_issue(id, ids.drop(i + 1), source) })
  end

  def generated_issue(id, later, source)
    issue(id, status: %w[pending pending pending in_flight done abandoned].sample(random: source),
              blocks: later.select { source.rand < 0.4 }, related: later.select { source.rand < 0.2 })
  end

  def issue(id, **overrides) = Lain::Epic::Issue.new(id:, title: "Issue #{id}", **overrides)

  describe "#ready under landings" do
    # AC: marking any ready issue done never removes another issue from ready.
    # Read at every state of an epic run to completion rather than only at the
    # drawn one: monotonicity composes, so each state the cascade passes through
    # is a graph the law is owed over, and the later states are the interesting
    # ones -- an issue whose blockers are half finished is where a landing has
    # something to move.
    it "never takes another issue off the ready set" do
      lost = graphs.flat_map { |value| landings(value).flat_map { |state, landed| unreadied(state, landed) } }

      expect(lost).to eq([])
    end

    # The anti-vacuity guard, and the reason it is not optional: the law above is
    # satisfied by a population whose ready sets are empty, singleton, or never
    # move, which is the shape a generator drifts into without saying so. A
    # cascade running more than one round IS "a landing admitted work that was
    # not ready before"; a state holding two ready issues IS "the law had
    # something to preserve".
    it "is read over ready sets that hold more than one issue and that landings move" do
      moved = graphs.count { |value| cascade(value).count > 1 }
      plural = graphs.sum { |value| cascade(value).count { |state| state.ready.size > 1 } }

      expect([moved, plural]).to all(be > 5)
    end
  end

  # Every (state, issue) pair a run of this epic could land: each state the
  # cascade passes through, paired with each issue ready in it.
  def landings(value) = cascade(value).flat_map { |state| state.ready.map { |landed| [state, landed] } }

  # The states an epic passes through when its whole ready set lands, over and
  # over, until nothing is ready.
  def cascade(value)
    Enumerator.produce(value) { |current| land(current, current.ready) }
              .take_while { |current| current.ready.any? }
  end

  # The ids ready before +landed+ was marked done and not ready after. +landed+
  # itself is excluded because it leaves `ready` by no longer being pending,
  # which is the landing working rather than the law breaking.
  def unreadied(value, landed)
    (value.ready.map(&:id) - [landed.id]) - land(value, [landed]).ready.map(&:id)
  end

  # +finished+ marked done, through the same constructor any caller would reach
  # for. `ready` is derived, so a landing is a status edit and nothing else.
  def land(value, finished)
    landed = finished.map(&:id)
    described_class.new(issues: value.map { |member| landed.include?(member.id) ? member.with_status("done") : member })
  end

  describe "#ready under graph edits" do
    # AC: an issue added with discovered_from may un-ready the issue it was
    # discovered from. Mid-flight discovery is the shape -- work found while
    # doing `a` turns out to be work `a` waits on, so `a` stops being ready the
    # moment the author records it. Constructed, for the reason at the top of
    # this file.
    it "loses an issue from ready when a discovered issue is added blocking it" do
      before = described_class.new(issues: [issue("a"), issue("b")])
      after = before.add(issue("found", blocks: %w[a]), discovered_from: "a")

      expect([before.ready.map(&:id), after.ready.map(&:id)]).to eq([%w[a b], %w[b found]])
    end

    it "stamps the discovery on the issue that un-readied it" do
      after = described_class.new(issues: [issue("a")]).add(issue("found", blocks: %w[a]), discovered_from: "a")

      expect(after.fetch("found").discovered_from).to eq("a")
    end
  end

  describe "#waves" do
    # Sorted-multiset equality says both halves at once: no id appears twice
    # across the waves, and none is missing. `#ids` holds no duplicates, so the
    # two directions of this equality ARE disjoint and exhaustive.
    it "partitions the issue set -- disjoint and exhaustive" do
      unpartitioned = graphs.reject { |value| value.waves.flatten.map(&:id).sort == value.ids.sort }

      expect(unpartitioned).to eq([])
    end

    it "holds no comparable pair inside a single wave" do
      internal = graphs.flat_map do |value|
        closure = blocker_closure(value)
        value.waves.flat_map { |wave| comparable_within(wave, closure) }
      end

      expect(internal).to eq([])
    end

    # The detector's own negative control. The law above passes by
    # `#comparable_within` answering nothing, so a wave that DOES hold two
    # comparable issues has to be shown to report -- otherwise a detector quietly
    # reduced to `[]` would carry the law forever. The witness is the pair a
    # direct-edge reading would miss: `a` and `c` two layers apart, with `b`
    # between them and no edge of their own.
    it "is read by a detector that reports a wave holding a transitively comparable pair" do
      chain = described_class.new(issues: [issue("a", blocks: %w[b]), issue("b", blocks: %w[c]), issue("c")])

      expect(comparable_within([chain.fetch("a"), chain.fetch("c")], blocker_closure(chain))).to eq([%w[a c]])
    end

    # A partition into antichains is a decomposition into locally independent
    # sets. It is not yet a plan an author can execute, and nothing above says it
    # is: a plan handed back end-to-end partitions just as well and has every
    # wave preceding its own blockers. The ORDER is the claim that makes a wave
    # plan worth emitting.
    #
    # This law strictly contains the antichain one -- a comparable pair sharing a
    # wave has equal indices, so it fails `<` too. Both are named because they
    # answer different questions: whether a wave is safe to start in parallel,
    # and whether the waves are in a runnable order.
    it "orders the waves -- every blocker sits in an earlier wave than what it blocks" do
      misplaced = graphs.flat_map { |value| out_of_order(value.waves, blocker_closure(value)) }

      expect(misplaced).to eq([])
    end

    # That detector's negative control: a two-wave plan handed back to front. The
    # plan is built by hand rather than by reversing `#waves`, because what is on
    # trial here is the detector, and a control that reads its answer out of the
    # subject goes quiet exactly when the subject is what broke.
    it "is read by a detector that reports a plan whose waves run backwards" do
      chain = described_class.new(issues: [issue("a", blocks: %w[b]), issue("b")])
      backwards = [[chain.fetch("b")], [chain.fetch("a")]]

      expect(out_of_order(backwards, blocker_closure(chain))).to eq([%w[a b]])
    end

    # The guard for the laws above. A partition over one-issue waves, an
    # antichain over singletons and an order over one wave are each trivially
    # true, so the population has to be shown WIDE (a wave holding more than one
    # issue) and DEEP (more than one wave) before any of them is worth reading.
    it "is read over waves that are both wider and deeper than one" do
      plans = graphs.map(&:waves)

      expect([plans.count { |plan| plan.size > 1 },
              plans.count { |plan| plan.any? { |wave| wave.size > 1 } }]).to all(be > 20)
    end
  end

  # The (blocker, blocked) pairs a wave holds both ends of, read over the
  # transitive relation. An antichain is a set no two of whose members are
  # COMPARABLE, and comparability is not the direct edge: `a -> b -> c` places
  # `a` and `c` two layers apart with nothing between them to see.
  def comparable_within(wave, closure)
    ids = wave.map(&:id)
    ids.flat_map { |id| (closure.fetch(id) & ids).map { |blocker| [blocker, id] } }
  end

  # The (blocker, blocked) pairs whose blocker does not sit strictly earlier in
  # +plan+ than what it blocks. Transitive for the reason above, and indexed by
  # the plan rather than by the graph, so a plan can be handed here reordered.
  def out_of_order(plan, closure)
    index = plan.each_with_index.flat_map { |wave, at| wave.map { |member| [member.id, at] } }.to_h
    index.keys.flat_map do |id|
      closure.fetch(id).reject { |blocker| index.fetch(blocker) < index.fetch(id) }
                       .map { |blocker| [blocker, id] }
    end
  end

  describe "#split and #merge" do
    # Every split of one issue into two fresh parts, and every merge of a
    # distinct pair, over every graph. Exhaustive rather than sampled: a sample
    # would make the coverage counts below depend on a second draw. An outcome is
    # `[before, after, substitution]`, where `after` is the refusal when the
    # operation raised -- both halves are the laws' subject.
    let(:outcomes) { graphs.flat_map { |value| splits(value) + merges(value) } }
    let(:revised) { outcomes.select { |_before, after, _map| after.is_a?(described_class) } }
    let(:refused) { outcomes.map { |_before, after, _map| after }.grep(Lain::Epic::MalformedGraph) }

    # AC: a revision never dangles an edge. Graph.new re-runs its own validation
    # over every result, so this states the law rather than discovering it --
    # which is the point: the claim belongs to the operation, and a revision that
    # stopped ending in Graph.new would break here.
    it "returns a graph whose every edge names an issue it holds" do
      dangling = revised.reject { |_before, after, _map| (edge_targets(after) - after.ids).empty? }

      expect(dangling).to eq([])
    end

    # Half of this is stated rather than discovered, as the dangling law above
    # is: every member of `revised` came back from `Graph.new`, which has already
    # run `acyclic!` over it, so no cyclic graph can reach this line. The other
    # half is not tautological -- `#waves` re-derives the layering, and asking
    # that it still cover the issue set catches a plan that lost a wave, which
    # construction has no opinion about.
    it "returns a graph whose blocks relation is still a DAG it can lay out whole" do
      cyclic = revised.reject { |_before, after, _map| after.waves.flatten.map(&:id).sort == after.ids.sort }

      expect(cyclic).to eq([])
    end

    # Where acyclicity survives when it cannot be preserved: a merge whose two
    # sides sit at either end of a path closes a loop, and the only correct
    # answer is to refuse. What this pins is that a refusal is ALWAYS that --
    # never a dangling edge and never a duplicate id, either of which would mean
    # the rewrite malformed a graph the author wrote correctly.
    it "refuses a revision only for closing a cycle" do
      expect(refused.map(&:message)).to all(include("cycle"))
    end

    # AC: after any split or merge every former transitive blocker still blocks.
    it "keeps every transitive blocker blocking, under the substitution it performed" do
      broken = revised.flat_map { |before, after, map| lost_blockers(before, after, map) }

      expect(broken).to eq([])
    end

    # That law's negative control, for the reason the wave one has it: it passes
    # by `#lost_blockers` reporting nothing. The witness is a split that dropped
    # its inbound edge instead of rewriting it -- `x` waited on `y`, and on `z`
    # through it, and after the botched split it waits on neither part nor on
    # anything beyond them.
    it "is read by a detector that reports a split which dropped an inbound edge" do
      before = described_class.new(issues: [issue("x", blocks: %w[y]), issue("y", blocks: %w[z]), issue("z")])
      botched = described_class.new(issues: [issue("x"), issue("y1", blocks: %w[z]),
                                             issue("y2", blocks: %w[z]), issue("z")])

      expect(lost_blockers(before, botched, substitution(before, "y" => %w[y1 y2])))
        .to contain_exactly(%w[x y1], %w[x y2], %w[x z])
    end

    # The converse, and the reason the law above is only half a claim: "every
    # former blocker still blocks" is satisfied in full by an operation that also
    # invents blocking nobody wrote.
    #
    # Said over EDGES rather than over the closure, because a merge legitimately
    # fuses two dependency cones -- `x` waiting on `left` and `right` waiting on
    # `y` makes `x` wait on `y` for the first time, and no statement over
    # reachability can call that wrong. What is wrong is an edge with no
    # preimage: a revision rewrites the edges it was handed and authors none of
    # its own. `into:` does let an arriving part declare edges of its own, which
    # would be a legitimate exception; the arrivals below declare none, so over
    # this population the law is exact.
    it "invents no blocks edge that no edge before it maps onto" do
      fabricated = revised.flat_map { |before, after, map| invented_edges(before, after, map) }

      expect(fabricated).to eq([])
    end

    # That detector's negative control: a correct split with one extra edge
    # nobody wrote. `x` still waits on both parts, so the reachability law above
    # stays silent, which is exactly the hole this one fills.
    it "is read by a detector that reports a split which invented an edge" do
      before = described_class.new(issues: [issue("x", blocks: %w[y]), issue("y"), issue("z")])
      inflated = described_class.new(issues: [issue("x", blocks: %w[y1 y2]), issue("y1", blocks: %w[z]),
                                              issue("y2"), issue("z")])

      expect(invented_edges(before, inflated, substitution(before, "y" => %w[y1 y2]))).to eq([%w[y1 z]])
    end

    # The guard. Splits cannot be refused -- their parts carry fresh ids and no
    # edges of their own -- so `refused` is merges alone, and a population that
    # drew none would read the cycle law over nothing. The pair count is the one
    # the reachability laws need: a population of edgeless graphs would satisfy
    # them while relating nothing to anything.
    #
    # The numbers are catastrophe detectors, not measured floors. Observed minima
    # over 600 seeds are 774 / 125 / 6155, so `> 20` will not notice the
    # population thinning by half; it fires when a generator change empties one
    # of the three, which is the failure that would take a law down with it.
    it "is read over revisions that both succeed and are refused, over pairs that exist" do
      pairs = revised.sum { |before, _after, _map| blocker_closure(before).sum { |_id, set| set.size } }

      expect([revised.size, refused.size, pairs]).to all(be > 20)
    end
  end

  def splits(value)
    value.ids.map do |id|
      parts = [issue("#{id}~1"), issue("#{id}~2")]
      attempt(value, substitution(value, id => parts.map(&:id))) { value.split(id, into: parts) }
    end
  end

  def merges(value)
    value.ids.combination(2).map do |left, right|
      merged = issue("#{left}+#{right}")
      attempt(value, substitution(value, left => [merged.id], right => [merged.id])) do
        value.merge(left, right, as: merged)
      end
    end
  end

  def attempt(before, map)
    [before, yield, map]
  rescue Lain::Epic::MalformedGraph => e
    [before, e, map]
  end

  # Identity on every id the revision keeps and the arriving ids on the ones it
  # removes -- the map a former edge is read THROUGH.
  def substitution(value, replacements) = value.ids.to_h { |id| [id, [id]] }.merge(replacements)

  # The pairs that waited before and do not wait after. The `from == to` case is
  # the one exception the substitution itself creates: a merge maps both its
  # sides onto one id, and a merged issue holds no edge to itself.
  def lost_blockers(before, after, map)
    closure = blocker_closure(after)
    blocker_closure(before).flat_map do |blocked, blockers|
      blockers.flat_map { |blocker| map.fetch(blocker).product(map.fetch(blocked)) }
              .reject { |from, to| from == to || closure.fetch(to).include?(from) }
    end
  end

  # The `blocks` edges of +after+ that no edge of +before+ maps onto. σ is not
  # injective -- a merge folds two ids into one -- so a preimage is a SET, and
  # one witness anywhere in it is enough to say the edge was inherited rather
  # than invented.
  def invented_edges(before, after, map)
    sources = preimage(map)
    blocks_edges(after).reject do |from, to|
      sources.fetch(from).product(sources.fetch(to))
             .any? { |owner, target| owner != target && before.fetch(owner).blocks.include?(target) }
    end
  end

  # σ turned around: each arriving id to the ids it replaced. σ's values are
  # exactly the ids the revision holds, so every edge below finds its entry.
  def preimage(map)
    map.flat_map { |id, arrivals| arrivals.map { |arrival| [arrival, id] } }
       .group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
  end

  def blocks_edges(value) = value.flat_map { |member| member.blocks.map { |target| [member.id, target] } }

  # Transitive blockers per id, expanded from ONE `#blocked_by` each. The query
  # rebuilds its relation index per call, so asking it once per closure edge
  # instead would cost a walk of the whole relation per edge for no more
  # coverage.
  def blocker_closure(value)
    direct = value.ids.to_h { |id| [id, value.blocked_by(id)] }
    direct.keys.to_h { |id| [id, reachable(direct, id, Set.new)] }
  end

  def reachable(direct, id, found)
    direct.fetch(id).inject(found) do |seen, blocker|
      seen.include?(blocker) ? seen : reachable(direct, blocker, seen << blocker)
    end
  end

  def edge_targets(value) = value.flat_map { |member| member.blocks + member.related }.uniq
end
