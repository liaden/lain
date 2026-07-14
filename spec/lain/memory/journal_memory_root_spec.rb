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
    Lain::Event::TurnUsage.new(digest:, model: "claude-opus-4-8", stop_reason: :end_turn, usage: {})
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
      decorator << Lain::Event::CapabilityDegraded.new(capability: :bash, requirer: "x", provider: "mock")

      expect(parsed_records.map { |record| record.fetch("type") }).to eq(["capability_degraded"])
    end

    it "forwards a plain Hash entry untouched, adding no memory_root" do
      decorator << { "type" => "custom" }

      expect(parsed_records.map { |record| record.fetch("type") }).to eq(["custom"])
    end

    it "follows a turn_usage record with a memory_root pairing the SAME digest" do
      decorator << turn_usage("blake3:aaa")

      types = parsed_records.map { |record| record.fetch("type") }
      expect(types).to eq(%w[turn_usage memory_root])
      expect(parsed_records.last.fetch("turn_digest")).to eq("blake3:aaa")
    end

    it "pairs the memory_root with the recorder's CURRENT root, read at call time" do
      recorder.write(item("a"))
      decorator << turn_usage("blake3:bbb")

      expect(parsed_records.last.fetch("root")).to eq(recorder.root)
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

      line = io.string.each_line.to_a.last
      expect(line).to include('"root":null')
    end

    it "returns itself, matching the real Journal's #<< contract" do
      expect(decorator << turn_usage("blake3:fff")).to be(decorator)
    end
  end

  describe "#record" do
    it "is the same behaviour as #<<, matching Journal's own record/<< duck" do
      decorator.record(turn_usage("blake3:ggg"))

      expect(parsed_records.map { |record| record.fetch("type") }).to eq(%w[turn_usage memory_root])
    end
  end
end
