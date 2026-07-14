# frozen_string_literal: true

# `Ractor.shareable?(x)` is the mechanical statement of "no reachable mutable
# state" that CLAUDE.md pins on every value object. 31 call sites duplicated
# `expect(Ractor.shareable?(x)).to be(true)` before this matcher existed.
# On failure, ShareabilityMatcherSupport (see be_deeply_frozen.rb) walks the
# object graph and names the offending node's path.
RSpec::Matchers.define :be_ractor_shareable do
  match { |actual| Ractor.shareable?(actual) }

  failure_message do |actual|
    "expected #{actual.inspect} to be Ractor.shareable?, but it was not -- " \
      "first offender: #{ShareabilityMatcherSupport.offender(actual)}"
  end

  failure_message_when_negated do |actual|
    "expected #{actual.inspect} not to be Ractor.shareable?, but it was"
  end
end
