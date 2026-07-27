# frozen_string_literal: true

# The laws of {Lain::Algebra::Pure} -- written by the structure's first
# consumer, which is what spec/algebra_laws_spec.rb said would happen: ":pure is
# in STRUCTURES and nothing declares it yet, so the first `pure on:` line will
# fail here, naming itself, until someone writes its laws. That failure is the
# feature."
#
# Group and battery are the SAME object, as in
# spec/support/shared_examples/elementwise.rb, because both readings are needed
# at once: a compaction strategy DECLARES purity and a model-backed one REFUTES
# it, and a refutation is confirmed by running a battery and requiring the named
# law to fail. Two transcriptions of one law set can drift; one cannot.
#
# == Which law carries the weight
#
# `shareable?` is the load-bearing one, and it is the mechanical proxy
# {Lain::Algebra::Pure}'s own doc names: `Ractor.shareable?` is CLAUDE.md's
# "mechanical statement of 'no reachable mutable state'", which is exactly the
# premise re-derivation needs -- nothing reachable can differ between two calls.
# It is a proxy and not a proof (nothing stops a method body reading a global),
# but it catches the failure that actually happens, which is a mutable
# collaborator quietly injected into a class that claimed to have none. It is
# also the law a strategy holding an oracle fails, which is what makes the
# impure cell of the 2x2 demonstrable rather than merely asserted.
#
# `deterministic?` is the claim said directly, and it catches the two impurities
# shareability cannot see: a body that reads a clock, and one that reads a
# mutable global.
#
# `non_mutating?` reads the other half of "a function of its arguments alone".
# An operation that rewrites the span it was handed is not one, and a caller
# re-deriving from the journalled edge would hand it different bytes the second
# time. Compared by `inspect` rather than by a deep copy: total for any input,
# and it is the arguments' CONTENTS that would have to change for a caller to
# notice.
#
# == Two things this group refuses to take on trust
#
# WHICH OPERATION. The declared operation is threaded in from the registry as
# evidence (spec/algebra_laws_spec.rb's `EVIDENCE`) and INVOKED here, rather than
# the generator supplying a lambda that calls whatever it likes. A generator that
# declared `pure on: :blocks` and exercised `#propose_ranges` would otherwise be
# green, which is the same hole spec/algebra_laws_spec.rb:293-296 closes for
# refutations by demanding they name the law they turn on.
#
# A FRESH POPULATION. `population` is held as a thunk and called once per law,
# never materialized once and shared. Three laws over one mutable population is
# an ORDERING bug, not a style point: `deterministic?` invokes the operation, so
# an operation that stamps its argument idempotently leaves the arguments already
# stamped by the time `non_mutating?` snapshots them, and that law then reports
# :holds. RSpec randomises example order, so the verdict was decided by the seed.
#
# Include with a Hash, built where `include_examples` is called so its callables
# close over locals rather than over example-group methods:
#
#   instance    [#call -> object]        the subject, built once
#   operation   [Symbol]                 the declared operation; the sweep folds
#                                        this in from the registry, so a
#                                        hand-written call site states it itself
#   population  [#call -> Array<input>]  the inputs, drawn FRESH per law. Named
#                                        `population` on purpose: that is one of
#                                        the two knobs spec/algebra_laws_spec.rb's
#                                        barren check reads, so an empty one
#                                        fails the sweep by name.
#   keywords    [#call(input) -> Hash]   keyword arguments for the operation,
#                                        derived from the input. Defaults to
#                                        none, which is the `#blocks(span)`
#                                        shape; `#propose_ranges(messages, span:)`
#                                        needs it.
#   equal       [#call(a, b) -> bool]    defaults to `==`
module AlgebraLaws
  Pure = Data.define(:instance, :operation, :draw, :keywords, :same) do
    def self.from(config)
      new(instance: config.fetch(:instance).call, operation: config.fetch(:operation),
          draw: config.fetch(:population), keywords: config.fetch(:keywords, ->(_input) { {} }),
          same: config.fetch(:equal, ->(a, b) { a == b }))
    end

    def to_h
      { "reaches no mutable state" => method(:shareable?),
        "answers the same thing twice for one input" => method(:deterministic?),
        "leaves its arguments as it found them" => method(:non_mutating?) }
    end

    def shareable? = Ractor.shareable?(instance)

    def deterministic? = population.all? { |input| same.call(answer(input), answer(input)) }

    def non_mutating?
      population.all? do |input|
        before = input.inspect
        answer(input)
        input.inspect == before
      end
    end

    # A fresh draw per law. See the doc above: sharing one materialized
    # population between the laws makes the third law's verdict depend on
    # whether the second ran first.
    def population = draw.call

    # SENT rather than public_sent: {Lain::Algebra.answers?} admits a private
    # operation, so "does this class answer it?" stays a different question from
    # "is it public?".
    def answer(input) = instance.send(operation, input, **keywords.call(input))

    # The inputs, without repeats. A population that is one input repeated
    # certifies determinism at a single point and calls it a law -- the same
    # vacuum elementwise.rb refuses when it insists its spans repeat an element
    # and are genuinely rewritten.
    def distinct = population.uniq

    # Inputs that two draws hand back as the SAME object and that could carry
    # something between them. Only a mutable one can: an Integer, a Symbol or a
    # frozen String is legitimately identical on every draw and is an ordinary
    # input to a pure operation, so demanding a fresh object for those would
    # refuse a correct generator for a reason that cannot apply to it.
    def shared_leavings
      redrawn = population.zip(population)
      redrawn.select { |drawn, again| drawn.equal?(again) && !drawn.frozen? }.map(&:first)
    end
  end
end

RSpec.shared_examples "a pure operation" do |config|
  battery = AlgebraLaws::Pure.from(config)

  battery.to_h.each { |law, holds| it(law) { expect(holds.call).to be(true) } }

  # Nested, so the including group's own `examples` are exactly the three laws
  # above -- which is what spec/algebra_laws_spec.rb's battery/group pin reads.
  context "the inputs those laws are read over" do
    it "includes more than one distinct input" do
      expect(battery.distinct.size).to be > 1
    end

    # Without this, the fresh-draw discipline above is unenforced from the
    # generator's side: a `population` answering the same MUTABLE input every
    # time reintroduces the ordering bug where this file cannot see it.
    it "draws a fresh population each time, so no law inherits another's leavings" do
      expect(battery.shared_leavings).to eq([])
    end
  end
end
