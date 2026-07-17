# frozen_string_literal: true

RSpec.describe Lain::Event::Projection do
  def block(text) = [{ "type" => "text", "text" => text }]

  def message(to:, from: "orchestrator")
    Lain::Event.new(kind: :message, payload_digest: "blake3:msg-#{to}-#{from}", from:, to:)
  end

  def snapshot(state)
    Lain::Event.new(kind: :snapshot, payload_digest: "blake3:snap-#{state}", body: { "workspace" => state })
  end

  def turn(text, causal_parents: [])
    Lain::Event.turn(role: "user", content: block(text)).then do |base|
      Lain::Event.new(kind: :turn, payload_digest: base.payload_digest, body: base.body,
                      causal_parents:)
    end
  end

  # TL-4: projections are pure folds over Store events plus injected data; a
  # projection holds no state, so folding the same log twice yields the same
  # answer and never mutates the log.
  describe "purity" do
    it "is a pure function of its inputs: two folds of the same log agree" do
      log = [message(to: "human"), message(to: "worker")]
      projection = described_class.new(log)
      expect(projection.mailbox(:human).to_a).to eq(projection.mailbox(:human).to_a)
    end

    it "does not mutate the log it folds over" do
      log = [message(to: "human"), snapshot("a")].freeze
      described_class.new(log).mailbox(:human).to_a
      expect(log).to be_frozen
    end
  end

  # Scenario: a mailbox is exactly a filter.
  describe "#mailbox" do
    it "yields exactly the events addressed to the recipient, in log order" do
      to_human_first = message(to: "human")
      to_worker = message(to: "worker")
      to_human_second = message(to: "human", from: "worker")
      projection = described_class.new([to_human_first, to_worker, to_human_second])

      expect(projection.mailbox(:human).to_a).to eq([to_human_first, to_human_second])
    end

    it "matches a Symbol recipient against the canonical (String) address" do
      to_human = message(to: "human")
      expect(described_class.new([to_human]).mailbox(:human).to_a).to eq([to_human])
    end

    it "yields nothing for a recipient no message names" do
      projection = described_class.new([message(to: "human"), message(to: "worker")])
      expect(projection.mailbox(:ghost).to_a).to be_empty
    end

    it "is a filter over :message events only, never turns or snapshots" do
      addressed = message(to: "human")
      log = [turn("hi"), addressed, snapshot("a")]
      expect(described_class.new(log).mailbox(:human).to_a).to eq([addressed])
    end

    it "streams lazily so a caller need not materialize the whole log" do
      expect(described_class.new([message(to: "human")]).mailbox(:human)).to be_a(Enumerator::Lazy)
    end
  end

  # Decision 2 / TL-4: "pending" is DERIVED, never a consumed queue. A :message
  # is pending iff no committed :turn in the log names it a causal parent -- so
  # render and commit, folding the same log, cannot disagree about what a turn
  # consumed. Pure: the same log yields the same set every time.
  describe "#pending" do
    it "lists the recipient's messages no committed turn has named a causal parent" do
      first = message(to: "parent")
      second = message(to: "parent", from: "worker")
      expect(described_class.new([first, second]).pending("parent").to_a).to eq([first, second])
    end

    it "drops a message a committed turn named among its causal parents" do
      consumed = message(to: "parent")
      kept = message(to: "parent", from: "worker")
      fold = turn("assistant answered", causal_parents: [consumed.digest])
      expect(described_class.new([consumed, kept, fold]).pending("parent").to_a).to eq([kept])
    end

    it "counts only :turn causal edges as consumption -- a message's own lineage never consumes" do
      addressed = message(to: "parent")
      # A later :message that names `addressed` among its causal parents is
      # lineage (a reply), not a turn, so `addressed` stays pending.
      reply = Lain::Event.new(kind: :message, payload_digest: "blake3:reply",
                              from: "parent", to: "worker", causal_parents: [addressed.digest])
      expect(described_class.new([addressed, reply]).pending("parent").to_a).to eq([addressed])
    end

    it "is diverge-safe: the same message is pending in a log lacking the consuming turn" do
      consumed = message(to: "parent")
      fold = turn("folded", causal_parents: [consumed.digest])
      expect(described_class.new([consumed, fold]).pending("parent").to_a).to be_empty
      expect(described_class.new([consumed]).pending("parent").to_a).to eq([consumed])
    end

    it "matches a Symbol recipient against the canonical (String) address" do
      to_parent = message(to: "parent")
      expect(described_class.new([to_parent]).pending(:parent).to_a).to eq([to_parent])
    end

    it "streams lazily so a caller need not materialize the whole log" do
      expect(described_class.new([message(to: "parent")]).pending("parent")).to be_a(Enumerator::Lazy)
    end
  end

  # Scenario: projection no longer aliases its input.
  describe "input isolation" do
    it "is unchanged when the caller appends to the Array it was constructed from" do
      log = [message(to: "human")]
      projection = described_class.new(log)
      log << message(to: "human", from: "worker")

      expect(projection.mailbox(:human).to_a.size).to eq(1)
      expect(projection.pending(:human).to_a.size).to eq(1)
    end
  end

  # Scenario: workspace at a point in time.
  describe "#workspace_at" do
    # Snapshots taken after the 2nd and the 5th turn in the log.
    subject(:projection) do
      log = []
      1.upto(6) do |n|
        log << turn("turn-#{n}")
        log << snapshot("at-#{n}") if [2, 5].include?(n)
      end
      described_class.new(log)
    end

    it "reflects the turn-2 snapshot at turn 4, the turn-5 snapshot not yet taken" do
      expect(projection.workspace_at(4).body).to eq("workspace" => "at-2")
    end

    it "reflects the turn-2 snapshot exactly at turn 2" do
      expect(projection.workspace_at(2).body).to eq("workspace" => "at-2")
    end

    it "reflects the later turn-5 snapshot once turn 5 has passed" do
      expect(projection.workspace_at(6).body).to eq("workspace" => "at-5")
    end

    it "reflects no workspace before the first snapshot is taken" do
      expect(projection.workspace_at(1)).to be_nil
    end
  end

  # Scenario: provenance reaches the source.
  describe "#provenance" do
    it "walks the causal chain back to the originating tool_result reference" do
      tool_result = { "type" => "tool_result", "tool_use_id" => "tu_1",
                      "content" => block("42"), "is_error" => false }
      source = Lain::Event.turn(role: "user", content: [tool_result])
      middle = turn("the model read the result", causal_parents: [source.digest])
      synthesis = turn("the model concluded", causal_parents: [middle.digest])
      projection = described_class.new([source, middle, synthesis])

      expect(projection.provenance(synthesis)).to contain_exactly(tool_result)
    end

    it "reaches every tool_result a synthesis folded, each once" do
      first = { "type" => "tool_result", "tool_use_id" => "tu_1", "content" => block("a") }
      second = { "type" => "tool_result", "tool_use_id" => "tu_2", "content" => block("b") }
      source_a = Lain::Event.turn(role: "user", content: [first])
      source_b = Lain::Event.turn(role: "user", content: [second])
      synthesis = turn("folded both", causal_parents: [source_a.digest, source_b.digest])
      projection = described_class.new([source_a, source_b, synthesis])

      expect(projection.provenance(synthesis)).to contain_exactly(first, second)
    end

    it "finds no reference when the causal chain reaches no tool_result" do
      source = turn("plain")
      leaf = turn("downstream", causal_parents: [source.digest])
      expect(described_class.new([source, leaf]).provenance(leaf)).to be_empty
    end

    # Panel fix #1: the walk must be iterative -- a long causal chain is a log
    # shape, not an error, and recursion turned 10,000 links into SystemStackError.
    # N stays at 10,000: recursive impls only reliably overflow >= ~8k links.
    # Only the root needs a real payload (the walk reads bodies solely at
    # tool_result hits); the links are detached envelopes naming their payloads
    # by literal digest, which costs one blake3 per link instead of three and
    # keeps the fixture build from dwarfing the 14ms walk under test.
    it "walks a 10,000-link causal chain without exhausting the stack" do
      tool_result = { "type" => "tool_result", "tool_use_id" => "tu_deep", "content" => block("root") }
      log = [Lain::Event.turn(role: "user", content: [tool_result])]
      9_999.times do |n|
        log << Lain::Event.new(kind: :turn, payload_digest: "blake3:link-#{n}", causal_parents: [log.last.digest])
      end

      expect(described_class.new(log).provenance(log.last)).to contain_exactly(tool_result)
    end
  end

  # Scenario: usage never double-counts a shared prefix.
  describe "#usage" do
    def usage(input) = Lain::Usage.new(input_tokens: input, output_tokens: 0)

    it "folds the injected map over unique reachable digests, counting a shared prefix once" do
      store = Lain::Store.new
      base = Lain::Timeline.empty(store:).commit(role: "user", content: block("shared"))
      branch_a = base.commit(role: "user", content: block("a"))
      branch_b = base.commit(role: "user", content: block("b"))

      injected = {
        base.head_digest => usage(100),
        branch_a.head_digest => usage(10),
        branch_b.head_digest => usage(20)
      }
      projection = described_class.new(usage: injected)

      expect(projection.usage(branch_a, branch_b)).to eq(usage(130))
    end

    it "counts a digest the injected map never priced as free" do
      store = Lain::Store.new
      timeline = Lain::Timeline.empty(store:).commit(role: "user", content: block("unpriced"))
      expect(described_class.new(usage: {}).usage(timeline)).to eq(Lain::Usage.zero)
    end
  end
end
