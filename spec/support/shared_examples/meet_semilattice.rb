# frozen_string_literal: true

# The Timelines over one Store form a meet semilattice under the ancestry
# relation: `a <= b` when a is an ancestor of b, `#meet` is the greatest
# common ancestor, and the bottom element (the empty Timeline) is what makes
# `#meet` total even for members that share no history. That gives four laws
# -- idempotent, commutative, associative, and "a meet sits below both
# operands" -- and they are asserted here against a randomly built forest
# rather than a hand-picked shape, because a hand-picked shape is exactly
# where an associativity bug hides.
#
# Include with a Hash:
#
#   population    [#call -> Array]        a forest of comparable members,
#                                          built once per example (typically a
#                                          memoized `let` referenced by a
#                                          zero-arg lambda, so every `.sample`
#                                          call within one example draws from
#                                          the same forest).
#   meet          [#call(a, b) -> c]       defaults to `a.meet(b)`.
#   ancestor_of   [#call(m, a) -> bool]    defaults to `m.ancestor_of?(a)`.
#   equal         [#call(a, b) -> bool]    defaults to `==`.
#
# == Why every callable runs through #semilattice_call instead of a bare call
#
# Same reason as "a monoid" (see monoid.rb): `population`/`meet`/etc. are
# built where `include_examples` is called, inside a `describe` body, so a
# Proc literal there closes over `self` = the example GROUP. `instance_exec`
# rebinds `self` to the real example instance, which is where `let(:population)`
# actually lives.
RSpec.shared_examples "a meet semilattice under ancestry" do |config|
  population = config.fetch(:population)
  meet = config.fetch(:meet, ->(a, b) { a.meet(b) })
  ancestor_of = config.fetch(:ancestor_of, ->(a, b) { a.ancestor_of?(b) })
  equal = config.fetch(:equal, ->(a, b) { a == b })

  define_method(:semilattice_call) { |callable, *args| instance_exec(*args, &callable) }

  it "is idempotent" do
    semilattice_call(population).sample(10).each do |a|
      expect(semilattice_call(equal, semilattice_call(meet, a, a), a)).to be(true)
    end
  end

  it "is commutative" do
    10.times do
      a, b = semilattice_call(population).sample(2)
      expect(semilattice_call(equal, semilattice_call(meet, a, b), semilattice_call(meet, b, a))).to be(true)
    end
  end

  it "is associative" do
    10.times do
      a, b, c = semilattice_call(population).sample(3)
      left = semilattice_call(meet, semilattice_call(meet, a, b), c)
      right = semilattice_call(meet, a, semilattice_call(meet, b, c))
      expect(semilattice_call(equal, left, right)).to be(true)
    end
  end

  it "orders a meet below both operands" do
    10.times do
      a, b = semilattice_call(population).sample(2)
      m = semilattice_call(meet, a, b)
      expect(semilattice_call(ancestor_of, m, a)).to be(true)
      expect(semilattice_call(ancestor_of, m, b)).to be(true)
    end
  end
end

# The population side of the law group, grown a UNION-GRAPH shape for the
# dominator meet (S3): render chains alone exercise the render meet, but the
# dominance order lives on render AND causal edges under a virtual root, so
# its laws need fan-ins and forest roots in the population. A new module
# rather than a change to the group or to the existing consumers' inline
# render-forest populations -- the generator gains a shape, it never changes
# the old one (the render-meet law runs, Ruby and Rust, are untouched).
module MeetSemilatticePopulations
  module_function

  # A random union graph over `empty`'s store: render chains, causal fan-in
  # events, fresh roots causally anchored mid-graph (the subagent spawn
  # shape), and one unanchored stranger so meets exercise the bottom
  # element. Spawns land mid-build so later chain growth extends them.
  def union_graph(empty)
    population = grow([commit(empty, "root")], 10, "a")
    3.times { |i| population << spawn(empty, population.sample, "s#{i}") }
    grow(population, 10, "b")
    5.times { |i| population << fan_in(population.sample(3), "f#{i}") }
    population << commit(empty, "stranger")
  end

  def grow(population, count, tag)
    count.times { |i| population << commit(population.sample, "#{tag}#{i}") }
    population
  end

  def commit(timeline, body)
    timeline.commit(role: :user, content: [{ "type" => "text", "text" => body }])
  end

  # A fan-in continues `from`'s render chain and names the other heads as
  # causal parents -- the cross-chain edges that make the union graph a DAG.
  def fan_in((from, *folds), body)
    from.commit(role: :assistant, content: [{ "type" => "text", "text" => body }],
                causal_parents: folds.map(&:head_digest))
  end

  # A fresh render root causally anchored at `anchor`'s head -- the
  # dominance-relevant collapse of the production spawn/message chain
  # ({Tools::Subagent::Lineage} writes a :spawn event naming the parent's
  # head; the anchored root carries that edge directly).
  def spawn(empty, anchor, body)
    empty.commit(role: :user, content: [{ "type" => "text", "text" => body }],
                 causal_parents: [anchor.head_digest],
                 meta: { "spawned_from" => anchor.head_digest })
  end
end
