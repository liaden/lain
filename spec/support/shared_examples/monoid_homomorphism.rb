# frozen_string_literal: true

# The law a span-collapse either satisfies or deliberately does not:
# `collapse(A ++ B) == collapse(A) ++ collapse(B)`, over the free monoid on
# content blocks whose unit is {Lain::Compaction::Strategy::DROP}.
#
# Both readings live here, and the positive and the negative are ONE object with
# two readings -- the shape spec/support/shared_examples/elementwise.rb
# established, for the same reason: two transcriptions of one law drift, and a
# drifted negative would quietly stop recording anything. The negative group
# exists for maintenance. Non-compositionality is INTENDED for a model-backed
# strategy (summarizing a concatenation is not the concatenation of summaries),
# and without an example saying so a later reader tidies it toward a shape it
# cannot have.
#
# == Why this is not the group elementwise.rb already ships
#
# That group asserts the CONDITIONAL law,
# `call(S) == S.flat_map { each(_1, analysis(S)) }`, and its doc explains why
# the plain form here is FALSE for a combinator declared `given:` an analysis:
# splitting a span splits the analysis, so `DedupeToolCalls` answers two
# messages for a span it answers four for in halves. A sweep testing the plain
# form would refute every correct `given:` declaration.
#
# So this group is scoped to UNCONDITIONAL strategies -- the
# {Lain::Algebra::Elementwise::Alone} shape, whose per-element map knows only
# its own element. That scoping is not a weakening. By the universal property of
# the free monoid, a map out of it is determined by its action on generators, so
# for an `Alone` declaration the plain law is exactly equivalent to the
# conditional one; there is nothing weaker being asked. What the scoping
# excludes is the family for which the plain law is false ON PURPOSE, and for
# those the conditional group is the right judge and this one is not offered.
#
# Include with a Hash, built at the `include_examples` site so its callables
# close over locals rather than over example-group methods -- the discipline
# spec/support/algebra_generators.rb documents:
#
#   collapse  [#call(span) -> replacement]  the map under test
#   unit      [replacement]                 the target monoid's unit, DROP
#   spans     [#call -> Array<span>]        the population, drawn once
#   combine   [#call(a, b) -> replacement]  defaults to `a + b`
#   equal     [#call(a, b) -> bool]         defaults to `==`
module AlgebraLaws
  MonoidHomomorphism = Data.define(:collapse, :combine, :unit, :spans, :same) do
    def self.from(config)
      new(collapse: config.fetch(:collapse), combine: config.fetch(:combine, ->(a, b) { a + b }),
          unit: config.fetch(:unit), spans: config.fetch(:spans).call,
          same: config.fetch(:equal, ->(a, b) { a == b }))
    end

    def to_h
      { "maps the empty span to the unit" => method(:preserves_unit?),
        "maps a concatenation of spans to the concatenation of their collapses" => method(:preserves_concatenation?) }
    end

    def preserves_unit? = same.call(collapse.call([]), unit)

    def preserves_concatenation? = pairs.all? { |pair| agrees?(*pair) }

    # The pair the law breaks on. Named in the negative group's failure message,
    # so a negative that has quietly become true says which spans stopped
    # distinguishing it rather than only that none did.
    def witness = pairs.reject { |pair| agrees?(*pair) }.first

    def agrees?(left, right)
      same.call(collapse.call(left + right), combine.call(collapse.call(left), collapse.call(right)))
    end

    def pairs = spans.product(spans)

    # Spans the collapse answers real content for. A law read only over spans
    # that collapse to the unit is a statement about the unit, which is exactly
    # the vacuum elementwise.rb's `rewritten` guard exists to refuse.
    def contentful = spans.reject { |span| same.call(collapse.call(span), unit) }
  end
end

RSpec.shared_examples "a monoid homomorphism" do |config|
  battery = AlgebraLaws::MonoidHomomorphism.from(config)

  battery.to_h.each { |law, holds| it(law) { expect(holds.call).to be(true) } }

  # Nested, so the including group's own `examples` are exactly the two laws
  # above -- the shape elementwise.rb uses, kept here so the two files read the
  # same way even though no registry sweep pins this one.
  context "the spans those laws are read over" do
    it "includes more than one, so a concatenation is a real one" do
      expect(battery.spans.size).to be > 1
    end

    it "includes one the collapse answers content for" do
      expect(battery.contentful).not_to be_empty
    end
  end
end

RSpec.shared_examples "not a monoid homomorphism" do |config|
  battery = AlgebraLaws::MonoidHomomorphism.from(config)

  it "collapses a concatenation differently from the concatenation of the collapses" do
    expect(battery.preserves_concatenation?).to be(false),
                                                -> { "every drawn pair of spans agreed; nothing exhibits the negative" }
  end

  context "the spans that law is read over" do
    it "includes one the collapse answers content for" do
      expect(battery.contentful).not_to be_empty
    end
  end
end
