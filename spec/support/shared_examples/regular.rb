# frozen_string_literal: true

# "Regular" equality: `==`/`eql?` are structural rather than by object
# identity, `#hash` agrees with them, and both facts together are what let a
# value type dedupe in a Set and work as a Hash key. `Turn` and `Timeline`
# both satisfy this the same way (equality is a content address, hash is that
# address's `#hash`), which is what makes the property-testing machinery
# below reusable instead of duplicated per class.
#
# Include with a Hash:
#
#   equal_pair    [#call -> [x, y]]   two instances that must be `==` to each
#                                     other (need not be distinct objects --
#                                     Timeline's `#fork` is identity, and that
#                                     is itself part of the contract).
#   unequal       [#call -> z]        an instance not equal to either member of
#                                     `equal_pair`.
#   hash_key      [bool]              whether "works as a Hash key" applies.
#                                     Defaults to true.
#   non_member    [#call -> w]        OPTIONAL. Some non-member type (e.g. the
#                                     value's own digest String) that equality
#                                     must reject without raising. Omit when
#                                     there is nothing meaningful to compare
#                                     against.
#   dedup         [#call -> Array]    the members handed to `Set[]` for the
#                                     dedup law. Defaults to `equal_pair` plus
#                                     `unequal`.
#   dedup_size    [Integer]           the expected `Set` size for `dedup`.
#                                     Defaults to 2 (one collapsed pair, one
#                                     distinct member).
#
# == Why every callable runs through #regular_call instead of a bare call
#
# Same reason as "a monoid" (see monoid.rb): the config Hash is built inside a
# `describe` body, so a Proc literal there closes over the example GROUP, not
# an instance. `instance_exec` rebinds `self` to the real example, where any
# `let`-backed helpers the factory references actually live.
RSpec.shared_examples "a Regular value" do |config|
  equal_pair = config.fetch(:equal_pair)
  unequal = config.fetch(:unequal)
  hash_key = config.fetch(:hash_key, true)
  non_member = config[:non_member]
  dedup = config.fetch(:dedup) { -> { [*regular_call(equal_pair), regular_call(unequal)] } }
  dedup_size = config.fetch(:dedup_size, 2)

  define_method(:regular_call) { |callable, *args| instance_exec(*args, &callable) }

  it "is structural: equal to its pair, not equal to a different instance" do
    x, y = regular_call(equal_pair)
    expect(x).to eq(y)
    expect(x).not_to eq(regular_call(unequal))
  end

  # Object#hash must stay an Integer or Hash and Set bucketing silently breaks.
  it "returns an Integer from #hash" do
    x, = regular_call(equal_pair)
    expect(x.hash).to be_a(Integer)
  end

  if hash_key
    it "works as a Hash key" do
      x, y = regular_call(equal_pair)
      expect({ x => :found }[y]).to eq(:found)
    end
  end

  it "deduplicates in a Set" do
    expect(Set[*regular_call(dedup)].size).to eq(dedup_size)
  end

  if non_member
    it "is not equal to a non-member type" do
      x, = regular_call(equal_pair)
      expect(x).not_to eq(regular_call(non_member))
    end
  end
end
