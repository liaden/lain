# frozen_string_literal: true

require "objspace"

RSpec.describe Lain::Request::PrefixChain do
  subject(:chain) { described_class.new }

  let!(:seed) { Lain::Canonical.digest("seed") }

  let(:messages) { Array.new(10) { |i| message("m#{i}") } }

  def message(text) = { "role" => "user", "content" => [{ "type" => "text", "text" => text }] }.freeze

  def walk(over, memo = chain)
    over.each_with_index.with_object([seed]) do |(each, index), states|
      states << memo.state(index, each, states.last) { Lain::Canonical.digest([states.last, each]) }
    end
  end

  def reachable_from(root, depth)
    (1..depth).reduce([root]) do |frontier, _|
      frontier.flat_map { |object| Array(ObjectSpace.reachable_objects_from(object)).grep_v(Module) }
    end
  end

  it "reuses every state when the same messages are walked again from the same seed" do
    first = walk(messages)

    again = nil
    expect(digests_during { again = walk(messages) }).to eq(0)
    expect(again).to eq(first)
  end

  it "recomputes only the state of an equal but distinct message, since the states after it hit" do
    walk(messages)
    replaced = messages.dup.tap { |copy| copy[5] = message("m5") }

    states = nil
    expect(digests_during { states = walk(replaced) }).to eq(1)
    expect(states).to eq(walk(replaced, described_class::NONE))
  end

  it "recomputes states 5 to 9 when message 5 changes, equal to the memo-less chain" do
    walk(messages)
    changed = messages.dup.tap { |copy| copy[5] = message("other") }

    states = nil
    expect(digests_during { states = walk(changed) }).to eq(5)
    expect(states).to eq(walk(changed, described_class::NONE))
  end

  it "recomputes every state from a different seed" do
    walk(messages)
    other_seed = Lain::Canonical.digest("other seed")

    recomputed = digests_during do
      messages.each_with_index.reduce(other_seed) do |previous, (each, index)|
        chain.state(index, each, previous) { Lain::Canonical.digest([previous, each]) }
      end
    end
    expect(recomputed).to eq(10)
  end

  it "lets go of a rewound branch's later messages once a walk diverges from it" do
    walk(messages)
    walk(messages.first(5) + [message("rewound")])

    held = reachable_from(chain, 3)
    expect(messages.first(5)).to all(satisfy { |kept| held.any? { |object| object.equal?(kept) } })
    expect(messages.drop(5)).to all(satisfy { |dropped| held.none? { |object| object.equal?(dropped) } })
  end

  it "computes every state with NONE" do
    expect(digests_during { walk(messages, described_class::NONE) }).to eq(10)
    expect(described_class::NONE).to be_deeply_frozen
  end
end
