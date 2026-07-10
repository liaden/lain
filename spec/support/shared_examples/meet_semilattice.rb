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
