# frozen_string_literal: true

# The laws of an elementwise map -- {Lain::Algebra::Elementwise}'s structure,
# which is newer than the law files beside this one and so had none.
#
# Unlike "a monoid" and "a meet semilattice under ancestry", the group and the
# battery here are the SAME object: spec/algebra_laws_spec.rb refutes
# {Lain::Context::PurgeFailedInputs} with the very predicates this group
# asserts for {Lain::Context::DedupeToolCalls}, so the two readings cannot
# drift because there is only one. It lives in spec/support/shared_examples/
# with the others rather than inside the spec that walks the registry, so a
# future consumer -- a Rust-backed combinator, say, in the shape
# spec/lain/rust/timeline_spec.rb already has -- can reach it without
# depending on RSpec's file load order.
#
# == Which of the two laws carries weight, and which does not
#
# `concatenates?` -- `call(S) == S.flat_map { each(_1, analysis(S)) }` -- CANNOT
# FAIL for a well-formed includer, and saying so plainly is better than letting
# it look strong. {Lain::Algebra::Elementwise} *generates* `#call` as exactly
# that expression, deliberately: the approved ruling was that this structure be
# structural, so that an includer cannot be non-homomorphic through that door
# and `is_a?(Elementwise)` is the classification. The law re-derives its own
# subject. What it is still worth is a construction invariant: it fails if a
# generated `#call` is later overridden downstream, or if the registry's
# `analysis` and the generator's `each` name methods that do not compose.
#
# `functional?` is the load-bearing one. `#each` is HAND-WRITTEN, and the law
# says its images are a function of `(element, analysis)` alone -- no positional
# dependence, no state carried between elements. A `#each` that consulted an
# index or a counter breaks it, and the generated `#call` cannot save it.
#
# And it is the same law in both directions, which is the sweep earning its
# keep: two `==` messages taking different images inside one call is exactly
# what {Lain::Context::PurgeFailedInputs} does (its positional `turns:` window
# is the reason it records) and exactly what {Lain::Context::DedupeToolCalls}
# must not. ONE law separates the declaration from the refutation.
#
# Only the `given:` shape is transcribed, because only that shape is declared;
# an unconditional {Lain::Algebra::Elementwise::Alone} declaration would arrive
# with a nil analysis and say so loudly rather than quietly passing.
module AlgebraLaws
  Elementwise = Data.define(:instance, :spans, :each, :analysis) do
    def self.from(config)
      new(instance: config.fetch(:instance).call, spans: config.fetch(:spans).call,
          each: config.fetch(:each), analysis: config.fetch(:analysis))
    end

    def to_h
      { "concatenates its per-element map against the whole-span analysis" => method(:concatenates?),
        "gives two equal elements equal images within one call" => method(:functional?) }
    end

    # {Lain::Algebra::Elementwise::GivenAnalysis#map}, said as a law: the
    # analysis runs once per span and `flat_map` is the concatenation. No
    # `Array()` wrapper -- a per-element map that answers a bare Hash must stay
    # one element, and coercing it would fail the law for a reason of our own
    # making rather than the operation's.
    def concatenates?
      spans.all? do |span|
        found = instance.public_send(analysis, span)
        instance.call(span) == span.flat_map { |element| instance.send(each, element, found) }
      end
    end

    # A map that is a function of (element, analysis) cannot answer two things
    # for one argument.
    def functional?
      judged.all? do |span, images|
        span.each_index.all? do |i|
          span.each_index.all? { |j| span[i] != span[j] || images[i] == images[j] }
        end
      end
    end

    # Spans the call genuinely acts on. A law read only over spans the
    # combinator passes through untouched certifies nothing, so this is
    # asserted non-empty below rather than left to the generator's good
    # intentions.
    def rewritten = spans.reject { |span| instance.call(span) == span }

    # ...and of those, the ones `functional?` can actually read: images come
    # off BY POSITION, which needs a call that neither dropped nor added, and
    # there is nothing to compare unless some element repeats. Also asserted
    # non-empty -- this is the exact vacuum that let two identical untouched
    # messages stand in for a proof.
    def judged
      rewritten.map { |span| [span, instance.call(span)] }
               .select { |span, images| span.size == images.size && span.uniq.size < span.size }
    end
  end
end

RSpec.shared_examples "an elementwise map" do |config|
  battery = AlgebraLaws::Elementwise.from(config)

  battery.to_h.each { |law, holds| it(law) { expect(holds.call).to be(true) } }

  # Nested, so the including group's own `examples` are exactly the two laws
  # above -- which is what spec/algebra_laws_spec.rb's battery/group pin reads.
  context "the spans those laws are read over" do
    it "includes one the call genuinely rewrites" do
      expect(battery.rewritten).not_to be_empty
    end

    it "includes one that is rewritten, repeats an element, and preserves length" do
      expect(battery.judged).not_to be_empty
    end
  end
end
