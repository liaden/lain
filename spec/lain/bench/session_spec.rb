# frozen_string_literal: true

require "json"
require "stringio"
require "tempfile"

# Session persists one run as NDJSON in the Journal's OWN format: the live run's
# journal (request_sent from an innermost JournalRequests, turn_usage from the
# Agent's journal:) plus one "session" header and one "turn" record per turn.
# From those bytes alone, Session.load rebuilds everything a DryReplay baseline
# needs -- so the determinism claim of the whole experiment survives a disk
# round trip, and content-addressing doubles as the integrity check over the
# CONTENT: the transport fields (stream, extra) sit outside Request#digest and
# load unverified.
RSpec.describe Lain::Bench::Session do
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse") }
  let(:workspace) { Lain::Workspace.empty }
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:usage) { Lain::Usage.new(input_tokens: 120, output_tokens: 30) }

  # A genuine two-model-call run (tool_use, then end_turn) whose journal already
  # carries the live-run records a Session extends: request_sent from an
  # INNERMOST JournalRequests (the bytes the provider actually received) and
  # turn_usage from the Agent's journal:.
  let(:run) do
    responses = [tool_response(["tu_1", "echo", { "text" => "hi" }], usage:, model: "claude-opus-4-8"),
                 text_response("done", usage:, model: "claude-opus-4-8")]
    record_journaled_run(responses, journal:, toolset:, context:, workspace:)
  end

  let(:agent) { run.first }
  let(:provider) { run.last }

  def write_session
    described_class.write(journal, timeline: agent.timeline, context:,
                                   toolset:, workspace:)
  end

  def load_session
    described_class.load(journal_io.string.each_line)
  end

  def parsed_records
    journal_io.string.each_line.map { |line| JSON.parse(line) }
  end

  describe ".write" do
    before { write_session }

    it "appends exactly one session header carrying the context, tools, reminders, and head anchor" do
      expect(parsed_records.count { |record| record["type"] == "session" }).to eq(1)
      expect(journal_io).to include_journal_record(
        "session",
        model: "claude-opus-4-8", max_tokens: 1024,
        system: "be terse", stream: true, reminders: [],
        head: agent.timeline.head_digest, context_class: "Lain::Context"
      )
      headers = parsed_records.select { |record| record["type"] == "session" }
      expect(headers.first.fetch("tools")).to eq(JSON.parse(JSON.generate(toolset.to_schema)))
    end

    # The silent failure mode of "the header captures exactly Lain::Context's
    # constructor inputs": Context grows a kwarg, the header records nothing,
    # every spec stays green, and an old recording reloads to a Context that
    # renders different bytes -- booked as DIVERGED instead of failing here.
    # The same members-pin idiom Telemetry::RequestSent uses against Request.
    it "records every Context constructor input, so a new kwarg cannot be dropped in silence" do
      header = parsed_records.find { |record| record["type"] == "session" }
      # `ts` is the Journal's own stamp on every record, not part of the header.
      recorded = header.keys - %w[type context_class head tools reminders ts]
      expect(recorded.map(&:to_sym))
        .to match_array(Lain::Context.instance_method(:initialize).parameters.map(&:last))
    end

    it "appends one turn record per turn, root to head, payload plus digest" do
      turns = parsed_records.select { |record| record["type"] == "turn" }
      expect(turns.map { |record| record.fetch("digest") }).to eq(agent.timeline.to_a.map(&:digest))
      expect(turns.map { |record| record.fetch("role") }).to eq(%w[user assistant user assistant])
      expect(turns.first.keys).to include("role", "content", "parent", "meta")
    end
  end

  describe "round trip" do
    before { write_session }

    it "rebuilds the timeline to the recorded head digest" do
      expect(load_session.timeline.head_digest).to eq(agent.timeline.head_digest)
    end

    it "rebuilds the baseline to the requests the provider actually received, in order" do
      baseline = load_session.baseline
      expect(baseline.map(&:digest)).to eq(provider.requests.map(&:digest))
      expect(baseline).to eq(provider.requests)
    end

    it "prices the ledger_index to the same totals as one built from the live journal directly" do
      recording = load_session
      loaded = Lain::Ledger.new(index: recording.ledger_index)
      direct = Lain::Ledger.from_journal(journal_io.string.each_line)
      expect(loaded.usage(recording.timeline)).to eq(direct.usage(agent.timeline))
      expect(loaded.cost(recording.timeline)).to eq(direct.cost(agent.timeline))
    end

    it "rebuilds a toolset that answers the recorded schema, which is all #render consumes" do
      expect(load_session.toolset.to_schema).to eq(toolset.to_schema)
    end

    # Pure data, never constantized: it lets a consumer (Bench::Variance) tell
    # a harness leak from a custom-pipeline recording reloaded as the default.
    it "surfaces the header's recorded context_class on the Recording" do
      expect(load_session.context_class).to eq("Lain::Context")
    end

    it "loads from a file path the same as from lines" do
      Tempfile.create("session") do |file|
        file.write(journal_io.string)
        file.flush
        expect(described_class.load(file.path).timeline.head_digest).to eq(agent.timeline.head_digest)
      end
    end

    it "skips foreign lines: a shared fd's non-JSON and non-object bytes are somebody else's records" do
      lines = ["not json at all\n", "[1, 2, 3]\n"] + journal_io.string.each_line.to_a
      expect(described_class.load(lines).timeline.head_digest).to eq(agent.timeline.head_digest)
    end

    # A Recording holds a Store (via its Timeline), so like Timeline itself it
    # cannot clear the Ractor.shareable? bar whole; the frozen shell plus
    # shareable members is the same guarantee Timeline gives.
    it "is a frozen Recording whose non-Timeline members are Ractor-shareable" do
      recording = load_session
      expect(recording).to be_frozen
      expect(recording.timeline).to be_frozen
      %i[context context_class toolset workspace baseline ledger_index degraded].each do |member|
        expect(recording.public_send(member)).to be_ractor_shareable
      end
    end
  end

  describe "identity replay from disk" do
    it "re-renders byte-identical requests under the rebuilt context" do
      write_session
      recording = load_session
      expect(recording.dry_replay.diff(recording.context)).to be_identical
    end

    context "with workspace reminders in effect at record time" do
      let(:workspace) { Lain::Workspace.empty.with("finish the audit") }

      it "round-trips the reminders and still replays to byte identity" do
        write_session
        recording = load_session
        expect(recording.workspace.reminders).to eq(["finish the audit"])
        expect(recording.dry_replay.diff(recording.context)).to be_identical
      end
    end
  end

  describe "tampering" do
    it "raises Session::Corrupt naming the recorded digest when a turn's content was edited under it" do
      write_session
      records = parsed_records
      forged = records.select { |record| record["type"] == "turn" }.last
      forged["content"] = [{ "type" => "text", "text" => "forged" }]

      expect { described_class.load(records) }
        .to raise_error(described_class::Corrupt, /#{Regexp.escape(forged.fetch("digest"))}/)
    end

    it "raises Session::Corrupt at load time when a request_sent payload was edited under its digest" do
      write_session
      records = parsed_records
      forged = records.select { |record| record["type"] == "request_sent" }.last
      forged["payload"] = forged["payload"].merge("max_tokens" => 999_999)

      expect { described_class.load(records) }
        .to raise_error(described_class::Corrupt, /#{Regexp.escape(forged.fetch("digest"))}/)
    end
  end

  # A Merkle chain self-verifies only its prefix: without the header's head
  # anchor, deleting the tail turn (and its request_sent) would load as a
  # shorter session whose dry replay is still IDENTICAL -- wrong invisibly, in
  # the direction that flatters the experiment.
  describe "truncation" do
    it "raises Session::Corrupt naming the expected head when the tail turn and its request_sent are deleted" do
      write_session
      records = parsed_records
      records.delete(records.select { |record| record["type"] == "turn" }.last)
      records.delete(records.select { |record| record["type"] == "request_sent" }.last)

      expect { described_class.load(records) }
        .to raise_error(described_class::Corrupt, /#{Regexp.escape(agent.timeline.head_digest)}/)
    end
  end

  describe "header multiplicity" do
    it "raises Session::Corrupt when two session headers claim one journal" do
      write_session
      records = parsed_records
      duplicate = records.find { |record| record["type"] == "session" }

      expect { described_class.load(records + [duplicate]) }
        .to raise_error(described_class::Corrupt, /header/)
    end
  end

  describe "a Context-subclass session (beyond the default pipeline)" do
    let(:context) do
      stub_const("PruningContext", Class.new(Lain::Context) do
        def self.pipeline(_workspace) = Lain::Context::Prune.new(keep_last: 1)
      end)
      PruningContext.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse")
    end

    it "records the class as data and round-trips the run, but loads as base Context, forfeiting identity" do
      write_session
      header = parsed_records.find { |record| record["type"] == "session" }
      expect(header.fetch("context_class")).to eq("PruningContext")

      recording = load_session
      expect(recording.timeline.head_digest).to eq(agent.timeline.head_digest)
      expect(recording.baseline.map(&:digest)).to eq(provider.requests.map(&:digest))
      expect(recording.context).to be_an_instance_of(Lain::Context)
      expect(recording.context_class).to eq("PruningContext")
      expect(recording.dry_replay.diff(recording.context)).not_to be_identical
    end
  end

  describe "degraded capabilities" do
    it "folds capability_degraded records into the Recording's degraded set" do
      write_session
      journal << Lain::Telemetry::CapabilityDegraded.new(
        capability: :prompt_caching, requirer: "CacheBreakpoints", provider: "Provider::Mock"
      )
      expect(load_session.degraded).to include(:prompt_caching)
    end
  end

  # A request_sent with no following turn_usage is how a failed call reads
  # (JournalRequests records BEFORE dispatch). The attempt is part of the
  # record, so loading must succeed; a consumer detects the failure because the
  # baseline outnumbers the DAG's assistant turns -- which is exactly the 1:1
  # guard DryReplay raises on, so a replay of a failed session is loud, not wrong.
  describe "a failed call" do
    it "still loads, and the surplus attempt surfaces through DryReplay's guard" do
      write_session
      attempt = provider.requests.last
      journal << Lain::Telemetry::RequestSent.new(digest: attempt.digest, payload: attempt.cache_payload,
                                                  stream: attempt.stream, extra: attempt.extra)

      recording = load_session
      expect(recording.baseline.size).to eq(3)
      expect(recording.timeline.to_a.count { |turn| turn.role == "assistant" }).to eq(2)
      expect { recording.dry_replay }.to raise_error(ArgumentError, /baseline/)
    end
  end

  describe "a journal with no session header" do
    it "raises Session::Corrupt rather than fabricating a context" do
      expect { described_class.load([]) }.to raise_error(described_class::Corrupt, /header/)
    end
  end
end
