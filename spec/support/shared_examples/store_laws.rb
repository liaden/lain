# frozen_string_literal: true

# A content-addressed store's whole contract is that the address IS the
# content: writing the same object twice, or two different-but-structurally-
# equal objects, cannot mean anything different from writing it once. That
# idempotence is what makes a Store safe to share across Timeline branches --
# a shared prefix costs one write no matter how many branches later commit
# through it.
#
# Include with a Hash:
#
#   store    [#call -> store]    a fresh, empty store, called once per example.
#   member   [#call -> member]   a fresh member with reproducible, content-
#                                derived identity (typically a `Turn` built
#                                from the same body each call) -- called
#                                multiple times per example, and every call
#                                must be accepted by the SAME address.
#
# == Why every callable runs through #store_call instead of a bare call
#
# Same reason as "a monoid" (see monoid.rb): the config Hash is built inside a
# `describe` body, so a Proc literal there closes over the example GROUP, not
# an instance. `instance_exec` rebinds `self` to the real example, where any
# helper methods the factories reference (e.g. a local `turn(body)`) live.
RSpec.shared_examples "a content-addressed store" do |config|
  store = config.fetch(:store)
  member = config.fetch(:member)

  define_method(:store_call) { |callable, *args| instance_exec(*args, &callable) }

  it "is idempotent: writing the same object twice does not grow the store" do
    s = store_call(store)
    object = store_call(member)
    s.put(object)
    s.put(object)
    expect(s.size).to eq(1)
  end

  it "treats structurally equal content as one object, because the address IS the content" do
    s = store_call(store)
    s.put(store_call(member))
    s.put(store_call(member))
    expect(s.size).to eq(1)
  end
end
