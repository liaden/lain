# frozen_string_literal: true

require "stringio"

# The decorator's own contract, independent of any Agent: it is hand-fed
# events directly, so these specs pin exactly what {Agent::Accounting} and
# {Middleware::JournalRequests} rely on (`#<<` forwarding) plus the one
# behaviour layered on top of it (see spec/lain/seams/memory_snapshot_seam_spec.rb
# for the same acceptance exercised through a real Agent run).
RSpec.describe Lain::Memory::JournalMemoryRoot do
  def item(id) = Lain::Memory::Item.new(id:, description: "desc of #{id}", body: "body of #{id}")

  def turn_usage(digest)
    Lain::Telemetry::TurnUsage.new(digest:, model: "claude-opus-4-8", stop_reason: :end_turn, usage: {})
  end

  let(:io) { StringIO.new }
  let(:real_journal) { Lain::Journal.new(io:) }
  let(:recorder) { Lain::Memory::Recorder.new }
  let(:decorator) { described_class.new(journal: real_journal, recorder:) }

  def parsed_records
    io.string.each_line.map { |line| Lain::Journal.parse(line) }
  end

  describe "#<<" do
    it "forwards a non-TurnUsage event to the real journal untouched" do
      decorator << Lain::Telemetry::CapabilityDegraded.new(capability: :bash, requirer: "x", provider: "mock")

      expect(parsed_records.map { |record| record.fetch("type") }).to eq(["capability_degraded"])
    end

    it "forwards a plain Hash entry untouched, adding no memory_root" do
      decorator << { "type" => "custom" }

      expect(parsed_records.map { |record| record.fetch("type") }).to eq(["custom"])
    end

    it "follows a turn_usage record with a memory_root pairing the SAME digest" do
      decorator << turn_usage("blake3:aaa")

      types = parsed_records.map { |record| record.fetch("type") }
      expect(types).to eq(%w[turn_usage memory_loaded memory_root])
      expect(parsed_records.last.fetch("turn_digest")).to eq("blake3:aaa")
    end

    it "pairs the memory_root with the recorder's CURRENT root, read at call time" do
      recorder.write(item("a"))
      decorator << turn_usage("blake3:bbb")

      expect(io).to include_journal_record("memory_root", root: recorder.root)
    end

    it "does not cache the root read at construction -- a later write is visible to the next record" do
      decorator << turn_usage("blake3:ccc")
      recorder.write(item("b"))
      decorator << turn_usage("blake3:ddd")

      roots = parsed_records.select { |record| record.fetch("type") == "memory_root" }
                            .map { |record| record.fetch("root") }
      expect(roots).to eq([nil, recorder.root])
    end

    it "journals a nil root as JSON null while the recorder is still empty" do
      decorator << turn_usage("blake3:eee")

      expect(io).to include_journal_record("memory_root", root: nil)
    end

    it "returns itself, matching the real Journal's #<< contract" do
      expect(decorator << turn_usage("blake3:fff")).to be(decorator)
    end
  end

  # The session's ONE memory_loaded, ahead of the first root it explains: a
  # root means nothing without the view it was taken over, and a reader
  # scanning forward has to meet the load first.
  describe "the load it announces" do
    it "names the view's version and its items, once, before the first root" do
      recorder.write(item("a"))
      decorator << turn_usage("blake3:h1")
      decorator << turn_usage("blake3:h2")

      types = parsed_records.map { |record| record.fetch("type") }
      expect(types).to eq(%w[turn_usage memory_loaded memory_root turn_usage memory_root])
      expect(parsed_records[1].fetch("version")).to eq(recorder.loaded.version)
    end

    it "carries the loaded items' ids, descriptions and bodies" do
      seeded = Lain::Memory::ProjectStore::Loaded.of([item("db-conventions")])
      described_class.new(journal: real_journal,
                          recorder: Lain::Memory::Recorder.new(index: seeded.index,
                                                               loaded: seeded)) << turn_usage("blake3:h3")

      expect(parsed_records[1].fetch("items"))
        .to eq([{ "id" => "db-conventions", "description" => "desc of db-conventions",
                  "body" => "body of db-conventions" }])
    end

    it "writes nothing at all for a session that never committed a turn" do
      decorator << { "type" => "custom" }

      expect(parsed_records.map { |record| record.fetch("type") }).to eq(["custom"])
    end
  end

  describe "#record" do
    it "is the same behaviour as #<<, matching Journal's own record/<< duck" do
      decorator.record(turn_usage("blake3:ggg"))

      expect(parsed_records.map { |record| record.fetch("type") }).to eq(%w[turn_usage memory_loaded memory_root])
    end
  end
end
