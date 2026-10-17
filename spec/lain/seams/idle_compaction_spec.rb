# frozen_string_literal: true

require "stringio"

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module IdleCompactionSeamSupport
  Answer = Struct.new(:summary) do
    def await = self
  end

  class CountingSummarizer
    attr_reader :asks

    def initialize = @asks = 0

    def ask(_inputs = {})
      @asks += 1
      Answer.new("what came before (#{@asks})")
    end
  end

  class HandClock
    def initialize(now) = @now = now

    def call = @now

    def advance(seconds) = @now += seconds
  end
end

# The returning human waits for no summarizer: a real Agent, a real Source and
# the real tick, nothing doubled but the model and the clock.
RSpec.describe Lain::CLI::Repl::IdleCompaction, :seam do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:clock) { IdleCompactionSeamSupport::HandClock.new(Time.at(1_700_000_000).utc) }
  let(:summarizer) { IdleCompactionSeamSupport::CountingSummarizer.new }
  let(:session) { Lain::Session.new(journal:) }

  # The window is what trips it: only the LAST reply reports a nearly full
  # context, so no render before the tick has any reason to cut.
  let(:window) { Lain::ContextWindow.new(windows: { "claude" => 10_000 }) }

  let(:source) do
    Lain::Compaction::Source.new(
      need: Lain::Compaction::Need.new(byte_threshold: 1_000_000, approaching_ratio: 0.9),
      cold: Lain::Compaction::Cold.new(cache_profile: { ttl: nil }, journal:),
      hard_cap: 1_000_000, keep_last: 2, eager: Lain::Compaction::Source::NoSummaries, journal:, clock:,
      context_window: window, strategy: Lain::Compaction::Strategy::Summarizing.new(oracle: summarizer)
    )
  end

  # The tee is how a real chat feeds the Source each turn's usage and its idle clock.
  let(:agent) do
    replies = [100, 100, 100, 9_500].map do |tokens|
      text_response("a considered answer " * 40, usage: Lain::Usage.new(input_tokens: tokens))
    end
    Lain::Agent.new(provider: Lain::Provider::Mock.new(responses: replies + [text_response("welcome back")]),
                    toolset: Lain::Toolset.new([]),
                    context: Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "a system prompt"),
                    journal: Lain::CLI::JournalTee.new(journal, source), session:, pipeline_source: source)
  end

  def types = journal_records(journal_io).map { |record| record["type"] }

  it "prepares on the tick, so the human's next line renders through the cut for free" do
    4.times { |index| agent.ask("turn #{index} " * 20) }
    expect(summarizer.asks).to eq(0)
    clock.advance(Lain::Compaction::Source::IdleGate::FLOOR)

    described_class.new(agent:, sink: StringIO.new, sleeper: ->(_seconds) {}).tick
    prepared = [summarizer.asks, types]
    agent.ask("the human is back")

    expect(prepared.first).to be_positive
    expect(prepared.last).to include("compaction_prepared")
    expect(prepared.last).not_to include("compaction_applied")
    expect(summarizer.asks).to eq(prepared.first)
    expect(types.index("compaction_applied")).to be > types.index("compaction_prepared")
  end
end
