# frozen_string_literal: true

require "json"
require "stringio"

# What a resume does with a committed compaction cut. The summary a model wrote
# for the cut's range lives in {Lain::Compaction::Strategy::Summarizing}'s
# in-memory memo, which a resumed process does not have and which forgets a
# failure -- so the one part of a cut a resume cannot recompute is exactly the
# part the record carries, and the replayed Session is how it reaches the
# Source.
RSpec.describe Lain::SessionRecord::Replay do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:base) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "a system prompt") }
  let(:clock) { -> { Time.at(1_700_000_000).utc } }

  # Counts its asks and numbers its answers, so a second ask for the same range
  # cannot come back byte-identical by coincidence.
  let(:counting_oracle_class) do
    Class.new do
      attr_reader :asks

      def initialize = (@asks = 0)

      def ask(_inputs = {})
        @asks += 1
        Struct.new(:summary) { def await = self }.new("what the stretch decided (answer #{@asks})")
      end
    end
  end

  def text(index) = { "type" => "text", "text" => "turn #{index}: #{"the lazy dog slept through it. " * 30}" }

  def timeline(size)
    (1..size).inject(Lain::Timeline.empty(store: Lain::Store.new)) do |line, index|
      line.commit(role: index.odd? || index == 2 ? "user" : "assistant", content: [text(index)])
    end
  end

  def source(oracle:, need:, hard_cap:, journal: Lain::Channel::Null.instance)
    Lain::Compaction::Source.new(
      need:, cold: Lain::Compaction::Cold.new(cache_profile: { ttl: 300 }, journal:), hard_cap:, keep_last: 2,
      journal:, clock:, strategy: Lain::Compaction::Strategy::SummarizeConversation.new(oracle:)
    )
  end

  # Plan steps compact and nothing else does, forced even while warm.
  def stepping(oracle, journal)
    source(oracle:, need: Lain::Compaction::Need.new(byte_threshold: 1_000_000), hard_cap: 1, journal:)
  end

  def rendered(built, line, session)
    built.context_for(base:, timeline: line, usage: nil, session:)
         .render(timeline: line, toolset: Lain::Toolset.new([]), workspace: Lain::Workspace.empty)
         .messages
  end

  def records = journal_io.string.each_line.map { |line| JSON.parse(line) }

  describe "a committed compaction cut" do
    it "renders the recorded replacement on resume without asking the summarizer again" do
      line = timeline(6)
      recording = Lain::Session.new(journal:)
      recording.write_todos([Struct.new(:content, :status).new("summarize", "completed")])
      recorded_oracle = counting_oracle_class.new
      recorded = rendered(source(oracle: recorded_oracle, need: Lain::Compaction::Need.new(byte_threshold: 1_000_000),
                                 hard_cap: 1, journal:), line, recording)
      resumed_oracle = counting_oracle_class.new
      resumed_source = source(oracle: resumed_oracle, need: Lain::Compaction::Need.new(byte_threshold: 1_000_000),
                              hard_cap: 1_000_000)

      resumed = rendered(resumed_source, line, described_class.new(journal_io.string.each_line).session)

      expect(records.map { |record| record["type"] }).to include("compaction_cut")
      expect(recorded_oracle.asks).to eq(1)
      expect(Lain::Canonical.dump(resumed.first)).to eq(Lain::Canonical.dump(recorded.first))
      expect(resumed.size).to eq(recorded.size)
      expect(resumed_oracle.asks).to eq(0)
    end

    # The plan-step latch is part of what a cut records: the completions a
    # commit consumed. A resume that forgot it would fire the step again, ask
    # the summarizer, and commit a cut the recording never made.
    it "does not fire a plan step the recording already consumed, at a head with history past the cut" do
      line = timeline(8)
      recording = Lain::Session.new(journal:)
      recording.write_todos([Struct.new(:content, :status).new("summarize", "completed")])
      recorder = stepping(counting_oracle_class.new, journal)
      rendered(recorder, line, recording)
      grown = %w[user assistant].each_with_index.inject(line) do |chain, (role, index)|
        chain.commit(role:, content: [text(9 + index)])
      end
      recorded = rendered(recorder, grown, recording)
      resumed_oracle = counting_oracle_class.new
      resumed_session = described_class.new(journal_io.string.each_line).session

      resumed = rendered(stepping(resumed_oracle, Lain::Channel::Null.instance), grown, resumed_session)

      expect(resumed_oracle.asks).to eq(0)
      expect(resumed_session.compaction_cuts.size).to eq(1)
      expect(Lain::Canonical.dump(resumed)).to eq(Lain::Canonical.dump(recorded))
    end

    it "folds every cut in recorded order, parent before child" do
      writer = Lain::Session.new(journal:)
      %w[blake3:one blake3:two].inject(nil) do |parent, digest|
        cut = Lain::Telemetry::CompactionCut.new(digest:, head: digest, strategy: "eager", parent:,
                                                 plan_step_completions: 0,
                                                 collapses: [{ "span" => [digest, digest], "content" => [] }])
        writer.record_compaction_cut(cut)
        cut.address
      end

      expect(described_class.new(journal_io.string.each_line).session.compaction_cuts)
        .to eq(writer.compaction_cuts)
    end

    # A truncated or hand-edited file that lost a parent is a seam with a hole
    # in it; folding the child anyway would render the wrong replacement. It
    # is refused as a corrupt session record, which resume and fork already
    # report as "cannot resume <file>".
    it "refuses a cut whose parent the record does not hold, as a corrupt session record" do
      Lain::Session.new(journal:).record_compaction_cut(
        Lain::Telemetry::CompactionCut.new(digest: "blake3:one", head: "blake3:one", strategy: "eager", parent: nil,
                                           plan_step_completions: 0,
                                           collapses: [{ "span" => %w[blake3:one blake3:one], "content" => [] }])
      )
      orphaned = journal_io.string.each_line.map { |line| JSON.parse(line).merge("parent" => "blake3:lost") }

      expect { described_class.new(orphaned).session }
        .to raise_error(Lain::Bench::Session::Corrupt, /record chain is incomplete.*blake3:lost/)
    end

    it "replays a record with no cut to a session holding none" do
      Lain::Session.new(journal:).record_read("/tmp/a.rb")

      expect(described_class.new(journal_io.string.each_line).session.compaction_cuts).to eq([])
    end
  end
end
