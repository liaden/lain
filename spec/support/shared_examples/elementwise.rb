# frozen_string_literal: true

# The laws of an elementwise map: an operation over a span that is the
# concatenation of an operation over each element, optionally relative to one
# analysis of the whole span.
#
# Unlike "a monoid" and "a meet semilattice under ancestry", the group and the
# battery here are the SAME object: spec/lain/context/purge_failed_inputs_spec.rb
# refutes that combinator with the very predicates this group asserts for
# spec/lain/context/dedupe_tool_calls_spec.rb's, so the two readings cannot
# drift because there is only one.
#
# == The two laws
#
# `concatenates?` -- `call(S) == S.flat_map { each(_1, analysis(S)) }` -- is the
# claim that the whole-span operation IS that concatenation. Every includer
# writes its operation by hand as one `flat_map`, so this is what catches that
# line drifting from the per-element map it names.
#
# `functional?` says the per-element images are a function of
# `(element, analysis)` alone -- no positional dependence, no state carried
# between elements. A per-element map that consulted an index or a counter
# breaks it, and a correct concatenation cannot save it.
#
# And it is the same law in both directions: two `==` messages taking different
# images inside one call is exactly what the purge combinator does (its
# positional `turns:` window) and exactly what the dedupe combinator must not.
# ONE law separates the elementwise map from the one that is not.
#
# == Neither the operation nor the analysis is assumed
#
# The OPERATION is a knob: {Lain::Compaction::Strategy::Base} deliberately has
# NO `#call` (an endomorphism on the message array would lose the preimage its
# causal edges are), so a strategy's elementwise operation is `#blocks`, and a
# group hardcoding `#call` would die of NoMethodError -- which proves nothing
# about elementwise-ness.
#
# A nil ANALYSIS is the unconditional shape -- the per-element map knows only
# its own element -- and it is a real one, not a malformed one. The arity of the
# per-element call is settled once, here, from whether the analysis is nil.
module AlgebraLaws
  Elementwise = Data.define(:instance, :spans, :operation, :each, :analysis) do
    def self.from(config)
      new(instance: config.fetch(:instance).call, spans: config.fetch(:spans).call,
          operation: config.fetch(:operation), each: config.fetch(:each), analysis: config.fetch(:analysis))
    end

    def to_h
      { "concatenates its per-element map against the whole-span analysis" => method(:concatenates?),
        "gives two equal elements equal images within one call" => method(:functional?) }
    end

    # The analysis (when there is one) runs once per span and `flat_map` is the
    # concatenation. No `Array()` wrapper -- a per-element map
    # that answers a bare Hash must stay one element, and coercing it would fail
    # the law for a reason of our own making rather than the operation's.
    def concatenates?
      spans.all? { |span| image(span) == concatenated(span) }
    end

    # SENT rather than public_sent, so a private operation is judged too: "does
    # this class answer it?" stays a different question from "is it public?".
    def image(span) = instance.send(operation, span)

    def concatenated(span)
      return span.flat_map { |element| instance.send(each, element) } if analysis.nil?

      found = instance.public_send(analysis, span)
      span.flat_map { |element| instance.send(each, element, found) }
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
    def rewritten = spans.reject { |span| image(span) == span }

    # ...and of those, the ones `functional?` can actually read: images come
    # off BY POSITION, which needs a call that neither dropped nor added, and
    # there is nothing to compare unless some element repeats. Also asserted
    # non-empty -- this is the exact vacuum that let two identical untouched
    # messages stand in for a proof.
    def judged
      rewritten.map { |span| [span, image(span)] }
               .select { |span, images| span.size == images.size && span.uniq.size < span.size }
    end
  end
end

RSpec.shared_examples "an elementwise map" do |config|
  battery = AlgebraLaws::Elementwise.from(config)

  battery.to_h.each { |law, holds| it(law) { expect(holds.call).to be(true) } }

  # Nested, so the including group's own examples are exactly the two laws
  # above and the guards on the population read as guards.
  context "when reading those laws over these spans" do
    it "includes one the call genuinely rewrites" do
      expect(battery.rewritten).not_to be_empty
    end

    it "includes one that is rewritten, repeats an element, and preserves length" do
      expect(battery.judged).not_to be_empty
    end
  end
end
