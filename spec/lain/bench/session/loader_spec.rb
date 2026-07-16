# frozen_string_literal: true

require "json"
require "stringio"

# Loader is the collaborator Session.load delegates the rebuild to: it folds
# parsed journal records back into a Recording, re-committing every turn so
# content-addressing doubles as the integrity check. Session_spec covers the
# seam end to end; this pins the Loader directly -- constructed from entries,
# not reached through Session.load -- so the unit has its own coverage.
RSpec.describe Lain::Bench::Session::Loader do
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse") }
  let(:workspace) { Lain::Workspace.empty }
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:usage) { Lain::Usage.new(input_tokens: 120, output_tokens: 30) }

  let(:run) do
    responses = [tool_response(["tu_1", "echo", { "text" => "hi" }], usage:, model: "claude-opus-4-8"),
                 text_response("done", usage:, model: "claude-opus-4-8")]
    record_journaled_run(responses, journal:, toolset:, context:, workspace:)
  end

  let(:agent) { run.first }
  let(:provider) { run.last }

  # The Loader's own input duck: the Journal.parse entries, here the raw NDJSON
  # lines Session.load hands it from a file.
  def entries
    Lain::Bench::Session.write(journal, timeline: agent.timeline, context:, toolset:, workspace:)
    journal_io.string.each_line
  end

  def recording = described_class.new(entries).recording

  describe "#recording round-trips a recorded session" do
    it "rebuilds the timeline to the recorded head digest" do
      expect(recording.timeline.head_digest).to eq(agent.timeline.head_digest)
    end

    it "rebuilds the baseline to the requests the provider actually received, in order" do
      expect(recording.baseline).to eq(provider.requests)
    end

    it "rebuilds a toolset answering the recorded schema and the recorded context inputs" do
      rebuilt = recording
      expect(rebuilt.toolset.to_schema).to eq(toolset.to_schema)
      expect(rebuilt.context.model).to eq("claude-opus-4-8")
      expect(rebuilt.context.system).to eq("be terse")
      expect(rebuilt.context_class).to eq("Lain::Context")
    end

    it "folds capability_degraded records into the degraded set" do
      degraded = { "type" => "capability_degraded", "capability" => "prompt_caching" }
      lines = entries.to_a + ["#{JSON.generate(degraded)}\n"]
      expect(described_class.new(lines).recording.degraded).to include(:prompt_caching)
    end

    it "accepts already-parsed Hash entries, not only raw lines" do
      hashes = entries.map { |line| JSON.parse(line) }
      expect(described_class.new(hashes).recording.timeline.head_digest).to eq(agent.timeline.head_digest)
    end

    it "skips foreign records the parse duck answers nil for" do
      lines = ["not json at all\n", "[1, 2, 3]\n"] + entries.to_a
      expect(described_class.new(lines).recording.timeline.head_digest).to eq(agent.timeline.head_digest)
    end
  end

  describe "the injectable context factory" do
    it "defaults to rebuilding a plain Context with the recorded transport fields (byte-identical)" do
      ctx = recording.context
      expect(ctx).to be_a(Lain::Context)
      expect(ctx.model).to eq("claude-opus-4-8")
      expect(ctx.system).to eq("be terse")
      expect(ctx.max_tokens).to eq(1024)
    end

    it "hands the recorded transport fields to a custom factory and uses the Context it returns" do
      seen = nil
      sentinel = Lain::Context.new(model: "custom-pipeline", max_tokens: 7)
      factory = lambda do |**fields|
        seen = fields
        sentinel
      end

      rebuilt = described_class.new(entries, context_factory: factory).recording

      expect(rebuilt.context).to be(sentinel)
      expect(seen).to include(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse")
    end
  end

  describe "integrity" do
    def forge(type)
      records = entries.map { |line| JSON.parse(line) }
      target = records.select { |record| record["type"] == type }.last
      yield target
      records
    end

    it "raises Corrupt naming the recorded digest when a turn's content was edited under it" do
      records = forge("turn") { |turn| turn["content"] = [{ "type" => "text", "text" => "forged" }] }
      digest = records.select { |r| r["type"] == "turn" }.last.fetch("digest")
      expect { described_class.new(records).recording }
        .to raise_error(Lain::Bench::Session::Corrupt, /#{Regexp.escape(digest)}/)
    end

    it "raises Corrupt naming the expected head when the tail turn is truncated" do
      records = entries.map { |line| JSON.parse(line) }
      records.delete(records.select { |r| r["type"] == "turn" }.last)
      records.delete(records.select { |r| r["type"] == "request_sent" }.last)
      expect { described_class.new(records).recording }
        .to raise_error(Lain::Bench::Session::Corrupt, /#{Regexp.escape(agent.timeline.head_digest)}/)
    end

    it "raises Corrupt when two session headers claim one journal" do
      records = entries.map { |line| JSON.parse(line) }
      duplicate = records.find { |record| record["type"] == "session" }
      expect { described_class.new(records + [duplicate]).recording }
        .to raise_error(Lain::Bench::Session::Corrupt, /header/)
    end

    it "raises Corrupt rather than fabricating a context when no header is present" do
      expect { described_class.new([]).recording }.to raise_error(Lain::Bench::Session::Corrupt, /header/)
    end
  end

  # The memory read path, event-sourced from the recording itself: successful
  # memory_write tool_use inputs ARE the write log, and content addressing
  # makes the journaled memory_root chain the proof -- replaying the same
  # writes into a fresh Index must land on the same roots, byte for byte.
  describe "memory replay" do
    def memory_input(id)
      { "id" => id, "description" => "notes on #{id}", "body" => "body of #{id}" }
    end

    let(:recorder) { Lain::Memory::Recorder.new }
    let(:memory_toolset) { Lain::Toolset.new([Lain::Tools::MemoryWrite.new(recorder:)]) }
    let(:memory_journal) { Lain::Memory::JournalMemoryRoot.new(journal:, recorder:) }

    let(:memory_responses) do
      [tool_response(["tu_1", "memory_write", memory_input("aspirin-dosing")], usage:, model: "claude-opus-4-8"),
       tool_response(["tu_2", "memory_write", memory_input("warfarin-inr")], usage:, model: "claude-opus-4-8"),
       text_response("done", usage:, model: "claude-opus-4-8")]
    end

    # One recorded memory-bearing run: the live records (request_sent /
    # turn_usage, plus memory_root when run_journal is the decorator) and the
    # session header and turn records Session.write appends.
    def record_memory_run(run_journal)
      agent, = record_journaled_run(memory_responses, journal: run_journal,
                                                      toolset: memory_toolset, context:, workspace:)
      Lain::Bench::Session.write(journal, timeline: agent.timeline, context:, toolset: memory_toolset, workspace:)
    end

    def parsed_records
      journal_io.string.each_line.map { |line| JSON.parse(line) }
    end

    def memory_records
      record_memory_run(memory_journal)
      parsed_records
    end

    def journaled_roots(records)
      records.select { |record| record["type"] == "memory_root" }
    end

    it "replays roots equal to the journaled memory_root chain, answered by #memory_root_at" do
      records = memory_records
      loaded = described_class.new(records).recording

      roots = journaled_roots(records)
      expect(roots.size).to eq(3)
      roots.each do |record|
        expect(loaded.memory_root_at(record.fetch("turn_digest"))).to eq(record.fetch("root"))
      end
    end

    it "checks out as-of-turn-N: turn 3 sees the turn-2 write and not the turn-4 write" do
      loaded = described_class.new(memory_records).recording
      between = loaded.timeline.to_a[2] # the tool_result turn between the two writes

      snapshot = loaded.memory_at(between.digest)
      expect(snapshot.fetch("aspirin-dosing").body).to eq("body of aspirin-dosing")
      expect(snapshot.key?("warfarin-inr")).to be(false)
    end

    context "when one memory_write was refused (its tool_result is an error)" do
      let(:memory_responses) do
        # A multi-line description fails Memory::Item's one-line invariant, so
        # the tool answers an error Result and the recorder never advances.
        refused = { "id" => "leaky-item", "description" => "two\nlines", "body" => "b" }
        [tool_response(["tu_1", "memory_write", memory_input("aspirin-dosing")],
                       ["tu_2", "memory_write", refused], usage:, model: "claude-opus-4-8"),
         text_response("done", usage:, model: "claude-opus-4-8")]
      end

      it "keeps the refused id out of every checkout while roots still verify" do
        records = memory_records
        loaded = described_class.new(records).recording

        journaled_roots(records).each do |record|
          expect(loaded.memory_root_at(record.fetch("turn_digest"))).to eq(record.fetch("root"))
        end
        loaded.timeline.to_a.each do |turn|
          expect(loaded.memory_at(turn.digest).key?("leaky-item")).to be(false)
        end
      end
    end

    it "raises Corrupt naming the turn digest when a memory_root record was altered on disk" do
      records = memory_records
      target = journaled_roots(records).last
      target["root"] = "blake3:#{"0" * 64}"

      expect { described_class.new(records).recording }
        .to raise_error(Lain::Bench::Session::Corrupt, /#{Regexp.escape(target.fetch("turn_digest"))}/)
    end

    it "loads a memory-free journal with an empty index at every turn" do
      loaded = recording
      loaded.timeline.to_a.each do |turn|
        expect(loaded.memory_root_at(turn.digest)).to be_nil
        expect(loaded.memory_at(turn.digest)).to be_empty
      end
    end

    context "when the recording predates the memory_root decorator" do
      it "replays writes unverified and checkouts reflect them" do
        record_memory_run(journal)
        records = parsed_records
        expect(journaled_roots(records)).to be_empty

        loaded = described_class.new(records).recording
        head = loaded.timeline.to_a.last
        expect(loaded.memory_at(head.digest).to_h.keys).to match_array(%w[aspirin-dosing warfarin-inr])
      end
    end

    it "raises Corrupt when the memory_root chain covers only some write-bearing turns" do
      records = memory_records
      records.delete(journaled_roots(records).first)

      expect { described_class.new(records).recording }
        .to raise_error(Lain::Bench::Session::Corrupt, /memory_root/)
    end
  end
end
