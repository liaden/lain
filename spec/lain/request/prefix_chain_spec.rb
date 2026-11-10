# frozen_string_literal: true

require "objspace"

RSpec.describe Lain::Request::PrefixChain do
  subject(:chain) { described_class.new }

  let(:tools) { [{ "name" => "read_file" }.freeze].freeze }
  let(:messages) { Array.new(10) { |i| message("m#{i}") } }

  # Canonical wire form, as a Request hands its members to the chain.
  def message(text, **flags)
    Lain::Canonical.normalize("role" => "user", "content" => [{ "type" => "text", "text" => text, **flags }])
  end

  def walk(over, memo = chain, granted: tools)
    seed = memo.seed("claude-opus-4-8", granted, nil)
    over.each_with_index.with_object([seed.state]) do |(each, index), states|
      states << memo.entry(index, each, states.last).state
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

  it "remembers the seed against its 3 inputs, and digests a changed one" do
    chain.seed("claude-opus-4-8", tools, nil)

    expect(digests_during { chain.seed("claude-opus-4-8", tools.dup, nil) }).to eq(0)
    expect(digests_during { chain.seed("claude-opus-4-8", tools, "be terse") }).to eq(1)
  end

  it "rolls a message afresh when the state before it changed though the seed did not" do
    walk(messages)
    other = Lain::Canonical.digest("another branch")

    expect(chain.entry(5, messages[5], other).state).to eq(described_class::NONE.entry(5, messages[5], other).state)
  end

  it "remembers the seed on the same tools object without dumping it" do
    chain.seed("claude-opus-4-8", tools, nil)
    dumped = []
    allow(JSON).to receive(:generate).and_wrap_original do |original, value, *rest|
      dumped << value
      original.call(value, *rest)
    end

    chain.seed("claude-opus-4-8", tools, nil)

    expect(dumped.select { |value| value.equal?(tools) || (value.is_a?(Array) && value.include?(tools)) }).to eq([])
  end

  it "keeps the state of an equal but distinct message, digesting nothing" do
    walk(messages)
    replaced = messages.dup.tap { |copy| copy[5] = message("m5") }

    states = nil
    expect(digests_during { states = walk(replaced) }).to eq(0)
    expect(states).to eq(walk(replaced, described_class::NONE))
  end

  it "keeps a message's state when a cache marker moves onto it, and takes the marker" do
    walk(messages)
    marked = messages.dup.tap do |copy|
      copy[9] = message("m9", "cache" => true)
    end

    entry = nil
    expect(digests_during { entry = chain.entry(9, marked[9], walk(messages)[9]) }).to eq(0)
    expect(entry.state).to eq(walk(messages)[10])
    expect(entry.markers).to eq([[["content", 0], "cache", true]])
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

    states = nil
    expect(digests_during { states = walk(messages, granted: [*tools, { "name" => "bash" }]) }).to eq(11)
    expect(states).to eq(walk(messages, described_class::NONE, granted: [*tools, { "name" => "bash" }]))
  end

  it "keeps the markers a message gave up on its entry, beside its state" do
    marked = message("hi", "cache" => true)
    entry = chain.entry(0, marked, chain.seed("claude-opus-4-8", tools, nil).state)

    expect(entry.markers).to eq([[["content", 0], "cache", true]])
    expect(entry.state).to eq(chain.entry(0, message("hi"), chain.seed("claude-opus-4-8", tools, nil).state).state)
  end

  it "keeps the markers the seed's tools and system gave up" do
    system = [{ "type" => "text", "text" => "sys", "cache" => true }]

    expect(chain.seed("claude-opus-4-8", tools, system).markers).to eq([[["system", 0], "cache", true]])
  end

  it "lets go of a rewound branch's later messages once a walk diverges from it" do
    walk(messages)
    walk(messages.first(5) + [message("rewound")])

    held = reachable_from(chain, 3)
    expect(messages.first(5)).to all(satisfy { |kept| held.any? { |object| object.equal?(kept) } })
    expect(messages.drop(5)).to all(satisfy { |dropped| held.none? { |object| object.equal?(dropped) } })
  end

  it "computes every state with NONE" do
    expect(digests_during { walk(messages, described_class::NONE) }).to eq(11)
    expect(described_class::NONE).to be_deeply_frozen
  end

  describe "#roll" do
    let(:history) { Array.new(10) { |i| message("m#{i}", **(i == 4 ? { "cache" => true } : {})) } }

    def rolled(memo, over = history)
      memo.roll(over, memo.seed("claude-opus-4-8", tools, nil))
    end

    def stepped(memo, over = history)
      seed = memo.seed("claude-opus-4-8", tools, nil)
      over.each_with_index.inject([seed.state, seed.markers.dup]) do |(state, markers), (each, index)|
        entry = memo.entry(index, each, state)
        [entry.state, markers + entry.markers.map { |path, key, value| [["messages", index, *path], key, value] }]
      end
    end

    it "rolls NONE to the state and markers entry by entry gives, with a marked message mid-history" do
      state, markers = rolled(described_class::NONE)

      expect([state, markers]).to eq(stepped(described_class.new))
      expect(markers.map(&:first)).to eq([["messages", 4, "content", 0]])
    end

    it "rolls a fresh chain to the same answer as NONE" do
      expect(rolled(described_class.new)).to eq(rolled(described_class::NONE))
    end

    it "keeps the memo of a chain that rolled" do
      memo = described_class.new
      rolled(memo)

      expect(digests_during { rolled(memo) }).to eq(0)
    end

    it "builds an entry only for the marked messages with NONE" do
      seed = described_class::NONE.seed("claude-opus-4-8", tools, nil)
      allow(described_class::Entry).to receive(:new).and_call_original
      described_class::NONE.roll(history, seed)

      expect(described_class::Entry).to have_received(:new).once
    end
  end

  describe "a message rebuilt from bytes" do
    def rebuilt(message) = Lain::Canonical.normalize(JSON.parse(JSON.generate(message)))

    def strips_during
      count = 0
      allow(Lain::Request).to receive(:without_markers).and_wrap_original do |original, value|
        count += 1
        original.call(value)
      end
      yield
      count
    end

    it "hits by value, with no strip and no digest" do
      first = walk(messages)
      copies = messages.map { |each| rebuilt(each) }

      states = nil
      digested = nil
      stripped = strips_during { digested = digests_during { states = walk(copies) } }
      expect([stripped, digested]).to eq([0, 0])
      expect(states).to eq(first)
    end

    it "misses by value on 1.0 where 1 was, and rolls the memo-less state" do
      one = message("n").merge("input" => 1)
      seed = chain.seed("claude-opus-4-8", tools, nil).state
      chain.entry(0, Lain::Canonical.normalize(one), seed)
      after = rebuilt(one.merge("input" => 1.0))

      entry = nil
      expect(digests_during { entry = chain.entry(0, after, seed) }).to eq(1)
      expect(entry.state).to eq(described_class::NONE.entry(0, after, seed).state)
    end
  end

  describe "a number that == another but dumps to other bytes" do
    def call(input)
      Lain::Canonical.normalize("role" => "assistant", "content" => [{ "type" => "tool_use", "input" => input }])
    end

    [[1, 1.0], [0.0, -0.0], [2**53, 9_007_199_254_740_992.0]].each do |before, after|
      it "rolls #{after.inspect} at a position that held #{before.inspect} to the memo-less state" do
        seed = chain.seed("claude-opus-4-8", tools, nil).state
        chain.entry(0, call("n" => before), seed)

        expect(chain.entry(0, call("n" => after), seed).state)
          .to eq(described_class::NONE.entry(0, call("n" => after), seed).state)
      end

      it "seeds tools holding #{after.inspect} afresh after tools holding #{before.inspect}" do
        chain.seed("claude-opus-4-8", [{ "name" => "x", "n" => before }], nil)

        expect(chain.seed("claude-opus-4-8", [{ "name" => "x", "n" => after }], nil).state)
          .to eq(described_class::NONE.seed("claude-opus-4-8", [{ "name" => "x", "n" => after }], nil).state)
      end
    end
  end
end
