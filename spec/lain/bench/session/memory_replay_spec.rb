# frozen_string_literal: true

# MemoryReplay event-sources the RecordedMemory surface from the turn records
# themselves: a successful memory_write tool_use IS the write log. Loader covers
# it end to end through a recorded run; this pins the unit directly -- built from
# hand-written records, so the fold and the coverage envelope can be exercised
# without a live agent.
RSpec.describe Lain::Bench::Session::MemoryReplay do
  def write_use(id)
    { "type" => "tool_use", "id" => "tu_#{id}", "name" => "memory_write",
      "input" => { "id" => id, "description" => "finding #{id}", "body" => "body #{id}" } }
  end

  def result(id, is_error: false) = { "type" => "tool_result", "tool_use_id" => "tu_#{id}", "is_error" => is_error }

  def turn(digest, content) = { "type" => "turn", "digest" => digest, "content" => content }

  def item(id) = Lain::Memory::Item.new(id:, description: "finding #{id}", body: "body #{id}")

  # The replay's expected snapshots, computed the way the fold computes them:
  # each turn's root is the index BEFORE its own writes apply.
  let(:snapshots) do
    empty = Lain::Memory::Index.empty
    after_a = empty.write(item("a"))
    [empty, after_a, after_a.write(item("b"))]
  end

  let(:turns) do
    [turn("d1", [write_use("a")]),
     turn("d2", [result("a"), write_use("b")]),
     turn("d3", [result("b")])]
  end

  let(:roots) do
    %w[d1 d2 d3].zip(snapshots).map do |digest, index|
      { "type" => "memory_root", "turn_digest" => digest, "root" => index.root }
    end
  end

  describe "#recorded_memory" do
    it "replays the successful writes and pairs each turn with its pre-write root" do
      memory = described_class.new(turns:, roots:).recorded_memory

      expect(memory.index.to_h.keys).to contain_exactly("a", "b")
      expect(memory.roots).to eq({ "d1" => snapshots[0].root, "d2" => snapshots[1].root,
                                   "d3" => snapshots[2].root })
    end

    it "skips a write whose paired result errored" do
      refused = [turn("d1", [write_use("a")]), turn("d2", [result("a", is_error: true)])]

      expect(described_class.new(turns: refused, roots: []).recorded_memory.index).to be_empty
    end

    it "raises Corrupt when a root record disagrees with the replay" do
      forged = roots.map { |record| record.merge("root" => "blake3:#{"0" * 64}") }

      expect { described_class.new(turns:, roots: forged).recorded_memory }
        .to raise_error(Lain::Bench::Session::Corrupt)
    end

    # A rewound session journals the SAME turn digest more than once, by
    # design: the scribe re-records the chain after each `rewound` record, so a
    # double rewind with identical re-commits leaves three turn records sharing
    # one digest (spec/lain/session_record_spec.rb pins exactly that), and
    # SessionRecord::Replay#turns hands them straight here. So the per-record
    # selection can never be keyed by digest -- one occurrence's writes would
    # vanish, and the coverage envelope would under-report, silently.
    describe "turn records sharing a digest (the rewind shape)" do
      let(:repeated) do
        [turn("d1", [write_use("a")]),
         turn("d1", [result("a"), write_use("b")]),
         turn("d2", [result("b")])]
      end

      it "replays every occurrence's writes, not just the last record under that digest" do
        memory = described_class.new(turns: repeated, roots: []).recorded_memory

        expect(memory.index.to_h.keys).to contain_exactly("a", "b")
      end

      it "names every write-bearing occurrence when the root chain covers none of them" do
        covering_nothing = [{ "type" => "memory_root", "turn_digest" => "d2", "root" => nil }]

        expect { described_class.new(turns: repeated, roots: covering_nothing).recorded_memory }
          .to raise_error(Lain::Bench::Session::Corrupt, /d1, d1/)
      end
    end

    # T18: the write-bearing coverage check and the write fold read the SAME
    # tool_use blocks out of the SAME records, so the selection runs once per
    # record rather than once per reader. Measured on the record's own
    # `content` reads: the outcome pairing needs one, the write selection needs
    # one, and nothing needs a third.
    it "selects each record's write calls once, not once per reader" do
      turns.each { |record| allow(record).to receive(:fetch).and_call_original }

      described_class.new(turns:, roots:).recorded_memory

      expect(turns).to all(have_received(:fetch).with("content").at_most(:twice))
    end
  end
end
