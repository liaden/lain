# frozen_string_literal: true

# Rantly reads RANTLY_VERBOSE exactly once, when `rantly/property.rb` loads
# (`Rantly::Property::VERBOSITY = ENV.fetch('RANTLY_VERBOSE', 1).to_i`), so the
# env var has to be set before that file's first require. This file is the
# first thing under spec/support to touch Rantly -- loaded by spec_helper.rb's
# Dir glob before any *_spec.rb runs -- so it is the one place this guard
# needs to live. Consumers (usage_spec.rb, middleware_spec.rb) just
# `include_examples` below and never touch Rantly directly.
ENV["RANTLY_VERBOSE"] ||= "0"

require "rantly"
require "rantly/rspec_extensions"

# Associativity and a pass-through identity, property-tested. `Usage` (a
# commutative monoid over `Data.define`) and `Middleware` (a monoid over
# composed procs, compared by observed behavior rather than `==`) satisfy the
# SAME two laws -- this file is what proves the shared group is reusable
# rather than merely written: usage_spec.rb and middleware_spec.rb both
# consume it instead of duplicating the property-testing machinery.
#
# Include with a Hash:
#
#   operation  [#call(a, b) -> c]     the binary op under test
#   identity   [c]                    the monoid's unit
#   generator  [#call -> c]           produces one fresh random element each
#                                     call, typically referencing helpers
#                                     defined on the including group (e.g.
#                                     `usage(...)`, `compose(...)`).
#   equal      [#call(a, b) -> bool]  defaults to `==`. Override when equality
#                                     must be OBSERVATIONAL: two composed
#                                     Middlewares are never `==` as objects, so
#                                     middleware_spec.rb passes a comparator
#                                     that runs both through the same probe.
#
# == Why every callable runs through #monoid_call instead of a bare `.call`
#
# `operation`/`generator`/`equal` are built where `include_examples` is
# called -- inside a `describe` body, so a Proc literal written there closes
# over `self` = the example GROUP (a Class), not an example instance. A bare
# `generator.call` would try to resolve `usage`/`compose` against that class
# and raise NoMethodError. `#monoid_call` runs the callable via
# `instance_exec` instead, which rebinds `self` to whatever called it --
# always a real example instance here, since `#monoid_call` itself is only
# ever invoked from inside an `it`/`.check` block.
RSpec.shared_examples "a monoid" do |config|
  operation = config.fetch(:operation)
  identity = config.fetch(:identity)
  generator = config.fetch(:generator)
  equal = config.fetch(:equal, ->(a, b) { a == b })

  define_method(:monoid_call) { |callable, *args| instance_exec(*args, &callable) }

  it "identity is a left and right unit" do
    property_of { true }.check do
      value = monoid_call(generator)
      expect(monoid_call(equal, monoid_call(operation, identity, value), value)).to be(true)
      expect(monoid_call(equal, monoid_call(operation, value, identity), value)).to be(true)
    end
  end

  it "is associative" do
    property_of { true }.check do
      a = monoid_call(generator)
      b = monoid_call(generator)
      c = monoid_call(generator)
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
  generator = config.fetch(:generator)
  equal = config.fetch(:equal, ->(a, b) { a == b })

  define_method(:monoid_call) { |callable, *args| instance_exec(*args, &callable) }

  it "is commutative" do
    property_of { true }.check do
      a = monoid_call(generator)
      b = monoid_call(generator)
      expect(monoid_call(equal, monoid_call(operation, a, b), monoid_call(operation, b, a))).to be(true)
    end
  end
end
