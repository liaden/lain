# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

module HudCutSeamSupport
  Answer = Struct.new(:summary) do
    def await = self
  end

  class CountingSummarizer
    def ask(_inputs = {}) = Answer.new("what came before")
  end

  class HandClock
    def initialize(now) = @now = now

    def call = @now

    def advance(seconds) = @now += seconds
  end
end

# A cut reaches the HUD only through the tee, and the Session was handed the raw
# journal: this runs a real Chronicle, LiveViews, Session and StatusFeed so a cut
# is counted once in the feed and written once to the record.
RSpec.describe "compaction cuts on the HUD", :seam do
  let(:journal_io) { StringIO.new }
  let(:chronicle) { Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: journal_io)) }
  let(:now) { [0.0] }
  let(:run_clock) { Lain::RunClock.new(clock: -> { now.first }) }
  let(:dir) { Dir.mktmpdir("hud-cut") }
  let(:feed) { Lain::StatusFeed.new(path: File.join(dir, "status.json"), run_clock:) }
  let(:session) do
    Lain::CLI::LiveViews.new(options: {}, chronicle:, status_feed: feed)
    chronicle.wrap_session(Lain::Session.new)
  end

  after { FileUtils.remove_entry(dir) }

  def cut(kind, digest: "blake3:a")
    Lain::Telemetry::CompactionCut.new(digest:, head: "blake3:h", strategy: "spans", kind:, parent: nil,
                                       supersedes: [], plan_step_completions: 0,
                                       collapses: [{ "span" => [digest, "blake3:b"], "content" => [] }])
  end

  def published = JSON.parse(File.read(File.join(dir, "status.json")))
  def cuts_in_record = journal_records(journal_io, "compaction_cut")

  it "counts a handoff, resets the age, and writes the cut to the record once" do
    session.record_compaction_cut(cut("handoff"))
    now[0] = 7.0
    feed << Lain::Event.new(kind: :spawn, payload_digest: "blake3:s", from: "p", to: nil)

    expect([published["compactions"], published["since_compaction"], cuts_in_record.size]).to eq([1, 7, 1])
  end

  it "counts an advance and its Compaction record once" do
    compaction = Lain::Telemetry::Compaction.new(trigger: "token_threshold", cache_state: :cold, bytes_before: 100,
                                                 collapse_strategy: "eager",
                                                 bytes_after: 10, cost_saved: nil, cost_spent: nil, model: nil)
    session.record_compaction_cut(cut("advance"))
    feed << compaction

    expect(published["compactions"]).to eq(1)
  end

  describe "an idle prepare" do
    let!(:views) { Lain::CLI::LiveViews.new(options: {}, chronicle:, status_feed: feed) }
    let(:live_session) { views && chronicle.wrap_session(Lain::Session.new) }
    let(:clock) { HudCutSeamSupport::HandClock.new(Time.at(1_700_000_000).utc) }
    let(:source) do
      Lain::Compaction::Source.new(
        need: Lain::Compaction::Need.new(byte_threshold: 1_000_000, approaching_ratio: 0.9),
        cold: Lain::Compaction::Cold.new(cache_profile: { ttl: nil }, journal: chronicle.record_journal),
        hard_cap: 1_000_000, keep_last: 2,
        eager: Lain::Compaction::Source::NoSummaries, journal: chronicle.record_journal,
        clock:,
        context_window: Lain::ContextWindow.new(windows: { "claude" => 10_000 }),
        strategy: Lain::Compaction::Strategy::Summarizing.new(oracle: HudCutSeamSupport::CountingSummarizer.new)
      )
    end
    let(:agent) do
      replies = [100, 100, 100, 9_500].map do |tokens|
        text_response("a considered answer " * 40, usage: Lain::Usage.new(input_tokens: tokens))
      end
      Lain::Agent.new(provider: Lain::Provider::Mock.new(responses: replies),
                      toolset: Lain::Toolset.new([]),
                      context: Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "a system prompt"),
                      journal: Lain::CLI::JournalTee.new(chronicle.record_journal, source), session: live_session,
                      pipeline_source: source)
    end

    it "counts the prepared cut on the HUD exactly as many times as the record holds cuts" do
      4.times { |index| agent.ask("turn #{index} " * 20) }
      clock.advance(Lain::Compaction::Source::IdleGate::FLOOR)
      Lain::CLI::Repl::IdleCompaction.new(agent:, sink: StringIO.new, sleeper: ->(_seconds) {}).tick

      expect(cuts_in_record.size).to be_positive
      expect(published["compactions"]).to eq(cuts_in_record.size)
    end
  end
end
