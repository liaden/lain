# frozen_string_literal: true

# Associativity and a pass-through identity, property-tested via prop_check
# (see spec/support/prop_check_setup.rb). `Usage` (a commutative monoid over
# `Data.define`) and `Middleware` (a monoid over composed procs, compared by
# observed behavior rather than `==`) satisfy the SAME two laws -- this file
# is what proves the shared group is reusable rather than merely written:
# usage_spec.rb and middleware_spec.rb both consume it instead of duplicating
# the property-testing machinery. So do seven further consumers elsewhere in
# the suite (repl_middleware_spec.rb, agent_turn_middleware_spec.rb,
# context/base_spec.rb, context/dedupe_tool_calls_spec.rb,
# context/purge_failed_inputs_spec.rb, middleware/skill_dispatch_spec.rb,
# mode/layer_spec.rb) -- see the generator note below for what that means for
# this file's contract.
#
# Include with a Hash:
#
#   operation  [#call(a, b) -> c]        the binary op under test
#   identity   [c]                       the monoid's unit
#   generator  [PropCheck::Generator, or a #call(-> c) resolved via
#              #monoid_call]             a VALUE the engine owns, drawing one
#                                        fresh element per call, is what
#                                        gets shrinking on a broken law.
#                                        usage_spec.rb and middleware_spec.rb
#                                        pass one. Every OTHER consumer still
#                                        passes an arity-0 Proc built from
#                                        its own group's helpers -- the shape
#                                        this file itself used before
#                                        adopting prop_check -- and is
#                                        coerced (see
#                                        `PropCheckSetup#coerce`) so none of
#                                        them needed rewriting for this file
#                                        to change engines.
#   equal      [#call(a, b) -> bool]     defaults to `==`. Override when
#                                        equality must be OBSERVATIONAL: two
#                                        composed Middlewares are never `==`
#                                        as objects, so middleware_spec.rb
#                                        passes a comparator that runs both
#                                        through the same probe.
#
# == Why operation/equal run through #monoid_call instead of a bare `.call`
#
# `operation`/`equal` are built where `include_examples` is called -- inside a
# `describe` body, so a Proc literal written there closes over `self` = the
# example GROUP (a Class), not an example instance. A bare `.call` would try
# to resolve helper methods against that class and raise NoMethodError.
# `#monoid_call` runs the callable via `instance_exec` instead, which rebinds
# `self` to whatever called it -- always a real example instance here, since
# `#monoid_call` is only ever invoked from inside a `forall` block.
#
# == Why the generator coercion lives in PropCheckSetup, not a define_method here
#
# An earlier version of this file gave each shared group its own
# `define_method(:prop_check_generator)`, closing over that group's
# `raw_generator`. Both groups define the SAME method name on the SAME
# including class, so a spec that includes both (none currently do, but
# nothing stops one) would silently run the earlier group's law against the
# LATER group's generator -- the second `define_method` wins, and the first
# group's closure is gone. `#monoid_call` above looks like the same shape but
# is safe: it takes its callable as an ARGUMENT, so redefining it twice is a
# harmless no-op. `PropCheckSetup#coerce` fixes the generator the same way --
# called fresh with `raw_generator` passed in, per `it` block, so there is
# nothing left to close over and nothing for a second `include_examples` to
# clobber.
#
# Converting the seven plain-callable consumers into real generators (so
# they gain shrinking too) is real, per-file work -- each needs a generator
# built the way middleware_spec.rb's `build_tag` local is, without depending
# on `self`. That conversion is deliberately deferred, not done piecemeal
# here, and is tracked as a follow-up rather than left open-ended.
#
# == Every example carries `aggregate_failures: false`
#
# The suite's default (spec/spec_helper.rb:57) collects failures instead of
# raising on the first one, which defeats shrinking outright: prop_check
# shrinks by catching the raised exception from a failing draw and retrying
# smaller inputs, so a collected-not-raised failure looks like success and
# shrinking never starts. spec_helper.rb documents this exact opt-out, and
# prop_check_setup.rb documents the stakes.
RSpec.shared_examples "a monoid" do |config|
  operation = config.fetch(:operation)
  identity = config.fetch(:identity)
  raw_generator = config.fetch(:generator)
  equal = config.fetch(:equal, ->(a, b) { a == b })

  define_method(:monoid_call) { |callable, *args| instance_exec(*args, &callable) }

  it "identity is a left and right unit", aggregate_failures: false do
    forall(value: coerce(raw_generator)) do |value:|
      expect(monoid_call(equal, monoid_call(operation, identity, value), value)).to be(true)
      expect(monoid_call(equal, monoid_call(operation, value, identity), value)).to be(true)
    end
  end

  it "is associative", aggregate_failures: false do
    generator = coerce(raw_generator)
    forall(a: generator, b: generator, c: generator) do |a:, b:, c:|
      left = monoid_call(operation, monoid_call(operation, a, b), c)
      right = monoid_call(operation, a, monoid_call(operation, b, c))
      expect(monoid_call(equal, left, right)).to be(true)
    end
  end
end

# Opt-in, and deliberately separate from "a monoid" above: not every monoid
# here is commutative. Middleware composition is order-sensitive BY DESIGN --
# that is the entire reason Stack exposes insert_before/insert_after -- so
# middleware_spec.rb must never be asked to satisfy this law. Usage includes
# both; Middleware includes only "a monoid".
RSpec.shared_examples "a commutative monoid" do |config|
  operation = config.fetch(:operation)
  raw_generator = config.fetch(:generator)
  equal = config.fetch(:equal, ->(a, b) { a == b })

  define_method(:monoid_call) { |callable, *args| instance_exec(*args, &callable) }

  it "is commutative", aggregate_failures: false do
    generator = coerce(raw_generator)
    forall(a: generator, b: generator) do |a:, b:|
      expect(monoid_call(equal, monoid_call(operation, a, b), monoid_call(operation, b, a))).to be(true)
    end
  end
end
