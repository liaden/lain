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
end
