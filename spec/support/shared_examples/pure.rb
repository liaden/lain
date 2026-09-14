# frozen_string_literal: true

# The laws of a pure operation: a function of its arguments alone, consulting no
# mutable collaborator, reading no clock, touching no I/O.
#
# Group and battery are the SAME object, as in
# spec/support/shared_examples/elementwise.rb, because both readings are needed
# at once: a compaction strategy obeys purity and a model-backed one does not,
# and that negative is confirmed by running the battery and requiring the named
# law to fail. Two transcriptions of one law set can drift; one cannot.
#
# == Which law carries the weight
#
# `shareable?` is the load-bearing one: `Ractor.shareable?` is CLAUDE.md's
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
# WHICH OPERATION. The operation is named as a Symbol and INVOKED here, rather
# than the includer supplying a lambda that calls whatever it likes. A call site
# that meant `#blocks` and exercised `#propose_ranges` would otherwise be green.
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
#   operation   [Symbol]                 the operation under test
#   population  [#call -> Array<input>]  the inputs, drawn FRESH per law
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

    # SENT rather than public_sent, so a private operation is judged too: "does
    # this class answer it?" stays a different question from "is it public?".
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

  # Nested, so the including group's own examples are exactly the three laws
  # above and the guards on the population read as guards.
  context "when reading those laws over these inputs" do
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
