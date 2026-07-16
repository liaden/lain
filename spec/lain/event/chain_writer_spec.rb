# frozen_string_literal: true

require "async"

# T5: the one home for message-writing and correlation. Before this, the
# `head && (head.correlation || head_digest)` derivation and the
# payload-then-envelope write lived as three separate copies (Timeline,
# Lineage, AskHuman). This pins that ChainWriter is the shared object all
# three now delegate to, and that nothing about their pinned behavior moved.
RSpec.describe Lain::Event::ChainWriter do
  let(:store) { Lain::Store.new }

  def text(body) = [{ "type" => "text", "text" => body }]

  let(:root) { Lain::Timeline.empty(store:).commit(role: :user, content: text("hi")) }
  let(:parent) { root.commit(role: :assistant, content: text("yo")) }

  describe ".correlation_of" do
    it "is nil for the empty chain" do
      expect(described_class.correlation_of(Lain::Timeline.empty(store:))).to be_nil
    end

    it "falls back to the head digest when the head carries no explicit correlation (the root)" do
      expect(root.head.correlation).to be_nil
      expect(described_class.correlation_of(root)).to eq(root.head_digest)
    end

    it "reads the head's explicit correlation once the chain has one" do
      expect(parent.head.correlation).to eq(root.head_digest)
      expect(described_class.correlation_of(parent)).to eq(root.head_digest)
    end

    # Scenario: one derivation, three callers.
    it "is what Timeline#correlation, Lineage#correlation_of, and AskHuman's asker identity all agree with" do
      policy = Lain::Tool::SpawnPolicy.new(prefix: :fresh, posture: :schema, only: [])
      lineage = Lain::Tools::Subagent::Lineage.new(policy:)
      ask_human = Lain::Tools::AskHuman.new(parent:)

      expected = described_class.correlation_of(parent)

      expect(parent.correlation).to eq(expected)
      expect(lineage.correlation_of(parent)).to eq(expected)

      Sync { ask_human.ask("which file?") }
      expect(ask_human.last_question.from).to eq(expected)
    end
  end

  describe "#put" do
    subject(:writer) { described_class.new }

    it "stores the payload before the envelope, fetchable under payload_digest (T4's edge validation)" do
      event = writer.put(parent, kind: :message, from: "a", to: "b", causal_parents: [], body: { "text" => "hi" })

      stored = store.fetch(event.payload_digest)
      expect(stored).to be_a(Lain::Event::Payload)
      expect(stored.digest).to eq(event.payload_digest)
      expect(stored.body).to eq(event.body)
    end

    it "correlates the written event to the parent chain's identity" do
      event = writer.put(parent, kind: :spawn, from: "a", to: nil, causal_parents: [parent.head_digest], body: {})
      expect(event.correlation).to eq(described_class.correlation_of(parent))
    end

    it "returns the event it wrote, already landed in the shared Store" do
      event = writer.put(parent, kind: :message, from: "a", to: "b", causal_parents: [], body: {})
      expect(store.key?(event.digest)).to be(true)
      expect(event.kind).to eq(:message)
      expect(event.from).to eq("a")
      expect(event.to).to eq("b")
    end
  end

  describe "the observer seam" do
    it "sees every event written, exactly once, in write order" do
      seen = []
      writer = described_class.new(observer: seen.method(:push))

      first = writer.put(parent, kind: :spawn, from: "a", to: nil, causal_parents: [], body: {})
      second = writer.put(parent, kind: :message, from: "a", to: "b", causal_parents: [], body: {})

      expect(seen).to eq([first, second])
    end

    it "leaves behavior unchanged when no observer is injected" do
      writer = described_class.new
      event = nil
      expect { event = writer.put(parent, kind: :message, from: "a", to: "b", causal_parents: [], body: {}) }
        .not_to raise_error
      expect(store.key?(event.digest)).to be(true)
    end

    it "never participates in identity or digest math -- a distinct observer changes nothing about the write" do
      quiet = writer_event(described_class.new)
      watched = writer_event(described_class.new(observer: ->(_event) {}))

      expect(watched.digest).to eq(quiet.digest)
    end

    # Orchestrator ruling: a raising observer raises. Swallowing a scribe
    # failure would BE silent record loss -- the failure class this chunk
    # exists to close. The write itself is already durable when the raise
    # surfaces, so a caller may re-put idempotently.
    it "lets an observer's raise propagate, with payload and envelope already landed in the Store" do
      captured = nil
      scribe = lambda { |event|
        captured = event
        raise "scribe down"
      }
      writer = described_class.new(observer: scribe)
      parent # force the chain into the Store before counting
      before = store.size

      expect { writer_event(writer) }.to raise_error(RuntimeError, "scribe down")

      expect(store.size).to eq(before + 2)
      expect(store.key?(captured.digest)).to be(true)
      expect(store.fetch(captured.payload_digest).body).to eq("text" => "x")
    end

    def writer_event(writer)
      writer.put(parent, kind: :message, from: "a", to: "b", causal_parents: [], body: { "text" => "x" })
    end
  end

  # Review fix (T5 panel, Metz): the observer seam is single-slot, and
  # Lineage's own @log wiring must not spend it -- T13's scribe attaches with
  # a one-line `observer:` at Lineage's call site, composed with (never
  # substituting) the @log append.
  describe "Lineage's injectable observer" do
    let(:policy) { Lain::Tool::SpawnPolicy.new(prefix: :fresh, posture: :schema, only: []) }
    let(:child) { Lain::Timeline.empty(store:).commit(role: :user, content: text("child task")) }

    it "sees every event Lineage writes, in addition to @log receiving them" do
      log = Lain::Tools::Subagent::Log.new
      seen = []
      lineage = Lain::Tools::Subagent::Lineage.new(policy:, log:, observer: seen.method(:push))

      spawn = lineage.spawn(parent)
      message = lineage.message(parent, spawn, child, Data.define(:text).new(text: "done"))

      expect(seen).to eq([spawn, message])
      expect(log.to_a).to eq([spawn, message])
    end

    it "defaults to no observer, leaving the @log wiring unchanged" do
      log = Lain::Tools::Subagent::Log.new
      lineage = Lain::Tools::Subagent::Lineage.new(policy:, log:)

      spawn = lineage.spawn(parent)

      expect(log.to_a).to eq([spawn])
    end
  end
end
