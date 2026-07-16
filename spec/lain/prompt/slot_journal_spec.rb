# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

# PS-2: the session-fixed prompt slots are attributed in the Journal by ONE
# slot_fills record, written at session start. It carries, per slot, the
# content address of the RENDERED bytes (the join key onto the system text a
# request_sent already journals in full) and the raw fill SOURCE (the bytes a
# reader diffs to explain why two runs' prompts differ). Pure attribution: the
# rendered prompt is recoverable from request_sent, so this record adds identity
# and diffability, never replay machinery.
RSpec.describe "Prompt slot journalling (PS-2)" do
  # A throwaway project dir with an optional .lain/slots/ tree, mirroring
  # slots_spec: slots are session-fixed, read once from disk here.
  def with_project(slots = {})
    Dir.mktmpdir do |root|
      slots.each do |name, body|
        path = File.join(root, ".lain", "slots", "#{name}.md")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, body)
      end
      yield root
    end
  end

  def journal_lines(&)
    io = StringIO.new
    Lain::Journal.new(io:).then(&)
    io.string.each_line
  end

  def records_of(lines, type)
    lines.map { |line| JSON.parse(line) }.select { |record| record["type"] == type }
  end

  describe "one header record pins the session's fills" do
    it "writes exactly one slot_fills record carrying the slot name, digest, and fill bytes" do
      with_project("system" => "PROJECT GUIDANCE 42: prefer haiku.") do |root|
        slots = Lain::Prompt::Slots.load(root:)
        lines = journal_lines { |journal| journal << Lain::Telemetry::SlotFills.from(slots) }

        fills = records_of(lines, "slot_fills")
        expect(fills.size).to eq(1)
        record = fills.first
        expect(record.fetch("digests").fetch("system")).to eq(Lain::Canonical.digest(slots.render("system")))
        expect(record.fetch("fills").fetch("system")).to eq("PROJECT GUIDANCE 42: prefer haiku.")
      end
    end

    it "is a deeply frozen, Ractor-shareable value" do
      with_project("system" => "steady") do |root|
        record = Lain::Telemetry::SlotFills.from(Lain::Prompt::Slots.load(root:))
        expect(record).to be_deeply_frozen
        expect(Ractor.shareable?(record)).to be(true)
      end
    end
  end

  describe "replay identifies the fills without touching .lain/slots" do
    it "reports the recorded fills, not the disk state, for that run" do
      with_project("system" => "AS RECORDED") do |root|
        slots = Lain::Prompt::Slots.load(root:)
        lines = journal_lines { |journal| journal << Lain::Telemetry::SlotFills.from(slots) }

        # The disk moves on after the run was recorded.
        File.write(File.join(root, ".lain", "slots", "system.md"), "CHANGED ON DISK")

        loaded = Lain::Bench::Session::Loader.new(lines).slot_fills
        expect(loaded.fills.fetch("system")).to eq("AS RECORDED")
        expect(loaded.digests.fetch("system")).to eq(Lain::Canonical.digest(slots.render("system")))
      end
    end

    it "answers an empty attribution for a journal written before the record existed" do
      loaded = Lain::Bench::Session::Loader.new([]).slot_fills
      expect(loaded.digests).to be_empty
      expect(loaded.fills).to be_empty
    end

    # Same discipline as the sibling sole_header: fills are session-fixed, so a
    # second record would make "which fills?" an accident of file order.
    it "raises Corrupt when two slot_fills records claim one journal" do
      with_project("system" => "steady") do |root|
        record = Lain::Telemetry::SlotFills.from(Lain::Prompt::Slots.load(root:))
        lines = journal_lines { |journal| 2.times { journal << record } }

        expect { Lain::Bench::Session::Loader.new(lines).slot_fills }
          .to raise_error(Lain::Bench::Session::Corrupt, /slot_fills/)
      end
    end
  end

  # The record's digests must stay joinable onto the system bytes a
  # request_sent journals in full -- that join IS the attribution's claim. The
  # default pipeline already wraps the system String into text blocks (the
  # cache-breakpoint marker rides one), so the joinable bytes are the blocks'
  # TEXT, not the raw payload value; if a later pipeline reshapes the system
  # further, this is the example that breaks loudly instead of the join
  # drifting apart in silence.
  describe "the digest joins onto the journaled request_sent system bytes" do
    def system_text(payload_system)
      return payload_system if payload_system.is_a?(String)

      payload_system.map { |block| block.fetch("text") }.join
    end

    it "recomputes to the same digest over the recorded request_sent's system text" do
      with_project("system" => "PROJECT GUIDANCE 42: prefer haiku.") do |root|
        slots = Lain::Prompt::Slots.load(root:)
        context = Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: slots.render)

        lines = journal_lines do |journal|
          journal << Lain::Telemetry::SlotFills.from(slots)
          record_journaled_run([text_response], journal:, toolset: Lain::Toolset.new([]), context:)
        end

        parsed = lines.to_a
        recorded_system = records_of(parsed, "request_sent").first.fetch("payload").fetch("system")
        expect(Lain::Canonical.digest(system_text(recorded_system)))
          .to eq(records_of(parsed, "slot_fills").first.fetch("digests").fetch("system"))
      end
    end
  end

  describe "attribution is diffable" do
    def slot_fills_for(fill)
      with_project("system" => fill) { |root| Lain::Telemetry::SlotFills.from(Lain::Prompt::Slots.load(root:)) }
    end

    it "gives two recordings with different fills different digests, with the fill bytes explaining the diff" do
      one = slot_fills_for("prefer haiku")
      two = slot_fills_for("prefer sonnets")

      expect(one.digests.fetch("system")).not_to eq(two.digests.fetch("system"))
      expect(one.fills.fetch("system")).to eq("prefer haiku")
      expect(two.fills.fetch("system")).to eq("prefer sonnets")
    end
  end
end
