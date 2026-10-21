# frozen_string_literal: true

# Every method the Rust timeline binds, called from Ruby the way a caller calls
# it. A binding registered at the wrong arity compiles and passes `cargo test`,
# which never crosses `mod ffi`; only a Ruby call finds it, so a binding with no
# call here fails the enumeration below rather than waiting for a caller to.
#
# The answer each binding gives over `left` and `right`, which share `root`,
# beside the answer it must give. `right` also folds `left` causally, so
# `right` has a path from `root` that bypasses `left`.
module TimelineBindingCalls
  BINDING_CALLS = {
    correlation: ->(left, _right, _root) { [left.correlation, left.to_a.first.digest] },
    empty?: ->(left, _right, _root) { [left.empty?, false] },
    head: ->(left, _right, _root) { [left.head.digest, left.head_digest] },
    head_digest: ->(left, _right, _root) { [left.head_digest.class, String] },
    store: ->(left, right, _root) { [left.store.equal?(right.store), true] },
    commit: ->(left, _right, _root) { [left.commit(role: :user, content: [], meta: { "k" => 1 }).length, 3] },
    fork: ->(left, _right, _root) { [left.fork, left] },
    checkout: ->(left, _right, root) { [left.checkout(root.head_digest), root] },
    rewind: ->(left, _right, root) { [[left.rewind, left.rewind(1)], [root, root]] },
    ancestors: ->(left, _right, _root) { [left.ancestors.map(&:digest), left.ancestor_digests] },
    ancestor_digests: ->(left, _right, root) { [left.ancestor_digests.last, root.head_digest] },
    to_a: ->(left, _right, _root) { [left.to_a.map(&:role), %w[user assistant]] },
    messages: ->(left, _right, root) { [left.messages(after: root.head_digest, onto: []).size, 1] },
    consumed: ->(left, right, _root) { [right.consumed([left.head_digest]), [left.head_digest]] },
    length: ->(left, _right, _root) { [left.length, 2] },
    include?: ->(left, _right, root) { [left.include?(root.head_digest), true] },
    ancestor_of?: ->(left, _right, root) { [root.ancestor_of?(left), true] },
    meet: ->(left, right, root) { [left.meet(right), root] },
    "&": ->(left, right, root) { [left & right, root] },
    diverge_at: ->(left, right, root) { [left.diverge_at(right).digest, root.head_digest] },
    dominator_meet: ->(left, right, root) { [left.dominator_meet(right), root] },
    dominates?: ->(left, right, root) { [[root.dominates?(right), left.dominates?(right)], [true, false]] },
    causal_meets: ->(left, right, _root) { [left.causal_meets(right), [left.head_digest]] },
    "==": ->(left, _right, root) { [[left == left.fork, left == root], [true, false]] },
    eql?: ->(left, _right, _root) { [left.eql?(left.fork), true] },
    hash: ->(left, _right, _root) { [left.hash, left.fork.hash] },
    to_s: ->(left, _right, _root) { [left.to_s.class, String] },
    inspect: ->(left, _right, _root) { [left.inspect.start_with?("#<Lain::Ext::Timeline "), true] }
  }.freeze
end

RSpec.describe Lain::Ext::Timeline, "binding coverage" do
  let(:store) { Lain::Ext::Store.new }
  let(:empty) { described_class.empty(store:) }
  let(:root) { empty.commit(role: :user, content: text("a")) }
  let(:left) { root.commit(role: :assistant, content: text("b")) }
  let(:right) { root.commit(role: :assistant, content: text("c"), causal_parents: [left.head_digest]) }

  def text(body) = [{ "type" => "text", "text" => body }]

  it "calls every method the timeline binds, and nothing it does not" do
    expect(TimelineBindingCalls::BINDING_CALLS.keys).to match_array(described_class.instance_methods(false))
  end

  TimelineBindingCalls::BINDING_CALLS.each do |binding, call|
    it "answers ##{binding} as bound" do
      answer, expected = call.call(left, right, root)

      expect(answer).to eq(expected)
    end
  end
end
