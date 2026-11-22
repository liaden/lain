# frozen_string_literal: true

require "json"

# An additive session-record type, its discriminator pinned here as the on-disk
# contract -- additive by construction, so the turn-chain loader's `of_type`
# narrowing skips it and an older reader stays unaffected.
RSpec.describe Lain::Telemetry::RunInterrupted do
  it "journals as run_interrupted anchored at the last committed turn, naming what stopped it" do
    event = described_class.new(head: "blake3:def", reason: :interrupted)
    expect(event.journal_type).to eq("run_interrupted")
    expect(event.to_journal)
      .to eq("type" => "run_interrupted", "head" => "blake3:def", "reason" => :interrupted)
    expect(described_class.new(head: nil, reason: :torn)).to be_deeply_frozen
  end

  it "carries the status a rejected request earned, and leaves it off a record that has none" do
    expect(described_class.new(head: nil, reason: :rejected, status: 404).to_journal)
      .to include("reason" => :rejected, "status" => 404)
    expect(described_class.new(head: nil, reason: :torn).to_journal).not_to have_key("status")
    expect(described_class.new(head: nil, reason: :torn).status).to be_nil
  end

  it "carries the provider's words and reset for a quota, and leaves both off a record without them" do
    record = described_class.new(head: nil, reason: :quota, detail: "usage limit", reset_at: "2026-11-01T10:00:00Z")

    expect(record.to_journal).to include("reason" => :quota, "detail" => "usage limit",
                                         "reset_at" => "2026-11-01T10:00:00Z")
    expect(record).to be_deeply_frozen
    expect(described_class.new(head: nil, reason: :torn).to_journal).not_to include("detail", "reset_at")
  end

  # Its own enum, NOT {SessionClosed}'s. That one has nowhere to put a
  # provider stall, and its `:exit`/`:salvaged` describe how a SESSION ended,
  # which no interrupted run can be. The overlap is exactly
  # {CLI::Conductor::INTERRUPT_REASONS}, the two a signal-driven close carries.
  it "pins its own reason enum, distinct from a session's" do
    expect(described_class::REASONS)
      .to eq(%i[interrupted grace_expired stopped ceiling over_window transport rejected stalled_stream torn
                middleware max_tokens context_full refusal truncated malformed unknown quota])
    expect(described_class::REASONS).not_to eq(Lain::Telemetry::SessionClosed::REASONS)
    expect(described_class::REASONS).to include(*Lain::CLI::Conductor::INTERRUPT_REASONS)
  end

  it "refuses a reason outside the enum at construction, echoing the offender" do
    expect { described_class.new(head: nil, reason: :nonsense) }
      .to raise_error(ArgumentError,
                      "reason must be one of [:interrupted, :grace_expired, :stopped, :ceiling, :over_window, " \
                      ":transport, :rejected, :stalled_stream, :torn, :middleware, :max_tokens, :context_full, " \
                      ":refusal, :truncated, :malformed, :unknown, :quota], " \
                      "got :nonsense")
  end

  it "refuses a nil reason the same way, for the reason SessionClosed's twin gives" do
    expect { described_class.new(head: nil, reason: nil) }
      .to raise_error(ArgumentError,
                      "reason must be one of [:interrupted, :grace_expired, :stopped, :ceiling, :over_window, " \
                      ":transport, :rejected, :stalled_stream, :torn, :middleware, :max_tokens, :context_full, " \
                      ":refusal, :truncated, :malformed, :unknown, :quota], " \
                      "got nil")
  end

  # The generic value is the default because it is the one thing every torn
  # run has in common -- a record built without a classification says the
  # unclassified thing rather than borrowing a narrower one it cannot support.
  it "defaults to the unclassified reason" do
    expect(described_class.new(head: nil).reason).to eq(:torn)
  end

  describe "the journal line" do
    it "matches the line the record has always written" do
      expect(JSON.generate(described_class.new(head: "blake3:h", reason: :rejected, status: 404).to_journal))
        .to eq('{"type":"run_interrupted","head":"blake3:h","reason":"rejected","status":404}')
    end

    it "carries no head key for a record built without one" do
      expect(JSON.generate(described_class.new(head: nil, reason: :transport).to_journal))
        .to eq('{"type":"run_interrupted","reason":"transport"}')
    end

    it "names the spawn a child's pause belongs to, and leaves it off main's own" do
      paused = described_class.new(head: nil, reason: :quota, spawn: "blake3:#{"c" * 64}")

      expect(JSON.generate(paused.to_journal))
        .to eq(%({"type":"run_interrupted","reason":"quota","spawn":"blake3:#{"c" * 64}"}))
      expect(paused).to be_deeply_frozen
      expect(described_class.new(head: nil, reason: :quota).to_journal).not_to have_key("spawn")
    end

    it "reads a line with no spawn, as every older session file holds, as main's" do
      line = JSON.parse('{"type":"run_interrupted","reason":"quota","reset_at":"2026-11-01T10:00:00Z"}')

      expect(Lain::Telemetry.read(line, strict: false)["spawn"]).to be_nil
    end

    it "carries only the default reason when nothing else was known" do
      expect(JSON.generate(described_class.new(head: nil).to_journal))
        .to eq('{"type":"run_interrupted","reason":"torn"}')
    end
  end

  it "reads a String reason as its Symbol" do
    expect(described_class.new(head: nil, reason: "stopped").reason).to eq(:stopped)
  end

  it "refuses an unknown keyword as an ArgumentError" do
    expect { described_class.new(head: nil, extra: 1) }.to raise_error(ArgumentError, /extra/)
  end
end
