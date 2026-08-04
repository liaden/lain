# frozen_string_literal: true

# prop_check is the property-testing engine for the algebra specs.
#
# What it gives that the previous engine could not: SHRINKING. A failing law
# reports a MINIMAL counterexample. The previous engine's every call site here
# was `property_of { true }.check do ... end` -- the generator handed to the
# engine was the constant `true`, and the real values were drawn inside the
# block by a thunk the engine never saw, so there was nothing to shrink.
#
# What it does NOT give, measured rather than assumed: seeded replay.
# `PropCheck::Property#run` does a bare `rng = Random.new` (property.rb:334)
# with no configuration hook, so prop_check's stream cannot be pinned to
# RSpec's `--seed`. A minimal counterexample is usually reproducible by hand
# where a large random one is not, which is what compensates.
#
# The hazard that voids the whole point, measured rather than assumed: every
# `it` calling `forall` MUST carry `aggregate_failures: false`. The suite's
# default (spec/spec_helper.rb, `config.define_derived_metadata`) collects
# failures instead of raising the first one, which stops shrinking before it
# starts -- prop_check shrinks by catching the exception a failing draw
# raises, and a collected-not-raised failure never gets caught. Measured
# side by side on the same broken law: with the opt-out, `Shrunken input
# (after 2 shrink steps)`; without it, `Got 86 failures` and no shrinking at
# all. spec_helper.rb documents the opt-out; this is the one place that
# explains why it is mandatory here.
require "prop_check"

module PropCheckSetup
  # Bound the work: these run inside `rake pspec`, and the suite's wall clock is
  # already floored by one file (root CLAUDE.md). 100 draws per law is
  # prop_check's own default and matches the count the previous engine ran,
  # which keeps the swap honest as a comparison.
  DEFAULT_RUNS = 100

  def forall(**generators, &block)
    PropCheck.forall(**generators).with_config(n_runs: DEFAULT_RUNS, verbose: false, &block)
  end

  # `generator` config values across the algebra specs are usually a real
  # `PropCheck::Generator` -- used as-is, this is what buys shrinking. A
  # handful of consumers still pass a plain callable instead (the shape every
  # consumer used before this engine): an arity-0 Proc built from the
  # including group's own helpers, resolved via `instance_exec` once per
  # draw. This wraps that shape into a trivial, non-shrinking
  # `PropCheck::Generator` so both shapes can flow through the same `forall`
  # call. There is deliberately no shrinking on the wrapped path: prop_check
  # can only shrink a draw it can see, and an opaque callable never hands one
  # over.
  #
  # An included instance method, not a class-level `self.coerce`, on purpose:
  # `instance_exec` needs a real receiver, and the block built here closes
  # over `self` from wherever `coerce` was called -- always a real example
  # instance, since `coerce` is only ever called from inside an `it` block.
  def coerce(generator)
    return generator if generator.is_a?(PropCheck::Generator)

    PropCheck::Generator.new { PropCheck::LazyTree.wrap(instance_exec(&generator)) }
  end
end

RSpec.configure { |config| config.include PropCheckSetup }
