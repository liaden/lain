# frozen_string_literal: true

require "json"
require "stringio"

require "lain/agent"
require "lain/context"
require "lain/event"
require "lain/journal"
require "lain/memory/index"
require "lain/memory/item"
require "lain/memory/journal_memory_root"
require "lain/memory/manifest"
require "lain/memory/recorder"
require "lain/provider/mock"
require "lain/tools/memory_write"
require "lain/toolset"

# The 5-3.1 acceptance: pair each committed assistant turn with the
# Memory::Index root in force at that moment, journal the pair as
# Event::MemoryRoot, and the recorded journal ALONE -- parsed back out of its
# NDJSON bytes -- suffices to reproduce recall exactly, however far the live
# index has moved since. Snapshot purity is what makes dry-replay recall
# possible later, so every checkout below is driven from PARSED values, never
# from an in-memory root the spec happened to keep.
#
# Wired for real, not simulated: {Memory::JournalMemoryRoot} is the ONLY
# journal-side machinery under test, handed to the Agent as its `journal:`
# with ZERO Agent changes -- it stays memory-blind throughout. What advances
# the recorder between the two committed turns is the Agent's own
# `memory_write` tool, called by the scripted model turn and run through the
# real ToolRunner -- there is no bench-side scripted write standing in for it.
RSpec.describe "Memory snapshot x Journal seam" do
  def item(id, description)
    Lain::Memory::Item.new(id: id, description: description, body: "body of #{id}")
  end

  def write_call(tool_use_id, memory_item)
    [tool_use_id, "memory_write",
     { "id" => memory_item.id, "description" => memory_item.description, "body" => memory_item.body }]
  end

  let(:io) { StringIO.new }
  let(:real_journal) { Lain::Journal.new(io: io) }
  let(:recorder) { Lain::Memory::Recorder.new }
  let(:journal) { Lain::Memory::JournalMemoryRoot.new(journal: real_journal, recorder: recorder) }
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024) }
  let(:toolset) { Lain::Toolset.new([Lain::Tools::MemoryWrite.new(recorder: recorder)]) }

  let(:first_gap_writes) do
    [item("aspirin-dosing", "Aspirin dosing bounds for adults"),
     item("warfarin-inr", "Warfarin target INR range")]
  end

  let(:provider) do
    Lain::Provider::Mock.new(
      responses: [
        tool_response(write_call("tu_1", first_gap_writes[0]), write_call("tu_2", first_gap_writes[1])),
        text_response("done")
      ]
    )
  end

  let(:agent) { Lain::Agent.new(provider: provider, toolset: toolset, context: context, journal: journal) }

  before { agent.ask("what is the aspirin dosing?") }

  # The real round trip: every value asserted or checked out below came back
  # through Journal.parse over the journal's NDJSON bytes.
  def parsed_records
    io.string.each_line.map { |line| Lain::Journal.parse(line) }
  end

  def memory_roots
    parsed_records.select { |record| record.fetch("type") == "memory_root" }
  end

  def assistant_digests
    agent.timeline.to_a.select { |turn| turn.role == "assistant" }.map(&:digest)
  end

  describe "roots journal per turn" do
    it "holds one memory_root record per committed assistant turn, in commit order" do
      expect(memory_roots.map { |record| record.fetch("turn_digest") }).to eq(assistant_digests)
    end

    it "pairs each turn with the index root in force at that turn" do
      # An independent oracle, decoupled from the recorder under test: content
      # addressing means replaying the same writes into a fresh Index yields
      # the identical root. Turn 1 committed before any write; turn 2 under
      # the root the memory_write tool calls from turn 1 produced.
      replayed = first_gap_writes.inject(Lain::Memory::Index.empty) { |index, gap_item| index.write(gap_item) }

      expect(memory_roots.map { |record| record.fetch("root") }).to eq([nil, replayed.root])
    end

    it "agrees with the Agent's own turn_usage records about which turns were committed" do
      usage_digests = parsed_records.select { |record| record.fetch("type") == "turn_usage" }
                                    .map { |record| record.fetch("digest") }
      expect(memory_roots.map { |record| record.fetch("turn_digest") }).to eq(usage_digests)
    end
  end

  describe "recall against a recorded root is pure (the 5-3.1 acceptance)" do
    # The live index moves on after the run: one id rewritten, one brand new.
    # Purity means neither is visible through the recorded root.
    let(:moved_on) do
      recorder.index
              .write(item("aspirin-dosing", "REVISED dosing, superseding the original"))
              .write(item("heparin-monitoring", "Heparin aPTT monitoring"))
    end

    let(:recorded_root) { memory_roots.last.fetch("root") }

    it "reproduces exactly the snapshot as of turn k; later writes are invisible" do
      snapshot = moved_on.checkout(recorded_root)

      expect(snapshot.to_h.keys).to match_array(%w[aspirin-dosing warfarin-inr])
      expect(snapshot.fetch("aspirin-dosing")).to eq(first_gap_writes.first)
      expect(snapshot.key?("heparin-monitoring")).to be(false)
    end

    # Determinism alone (the example below) would pass even if a checkout
    # deterministically leaked live writes; isolation must be proven through
    # the recall surface itself, not only through #to_h.
    it "keeps later writes invisible to search over the recalled snapshot" do
      manifest = Lain::Memory::Manifest.new(moved_on.checkout(recorded_root))

      expect(manifest.search("heparin aPTT monitoring")).to be_empty
      expect(manifest.search("aspirin dosing").first.description).to eq(first_gap_writes.first.description)
    end

    it "yields equal recall from two checkouts of the same recorded root" do
      one = moved_on.checkout(recorded_root)
      two = moved_on.checkout(recorded_root)

      expect(one.to_h).to eq(two.to_h)

      hits_one = Lain::Memory::Manifest.new(one).search("aspirin dosing")
      hits_two = Lain::Memory::Manifest.new(two).search("aspirin dosing")
      expect(hits_one).not_to be_empty
      expect(hits_one).to eq(hits_two)
    end
  end

  describe "the empty root round-trips" do
    it "records the pre-write turn's root as JSON null on the wire" do
      line = io.string.each_line.find { |candidate| JSON.parse(candidate).fetch("type") == "memory_root" }
      expect(line).to include('"root":null')
    end

    it "checks out the parsed null back to the empty Index" do
      resumed = recorder.index.checkout(memory_roots.first.fetch("root"))

      expect(resumed).to be_empty
      expect(resumed.to_h).to eq({})
      expect(resumed).to eq(Lain::Memory::Index.empty)
    end
  end
end
