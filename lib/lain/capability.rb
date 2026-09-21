# frozen_string_literal: true

module Lain
  # Machine-checked capabilities. A Context combinator declares what it
  # `#requires`; a Provider declares what it `#capabilities`. {Policy} resolves
  # the mismatch under a `:strict`/`:degrade` policy, {DegradedSet} names what a
  # run silently lost, and {Guard} refuses to compare two runs whose degraded
  # sets differ.
  module Capability
  end
end
