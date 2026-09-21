# frozen_string_literal: true

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

  # Its own enum, NOT {SessionClosed}'s. That one has nowhere to put a
  # provider stall, and its `:exit`/`:salvaged` describe how a SESSION ended,
  # which no interrupted run can be. The overlap is exactly
  # {CLI::Conductor::INTERRUPT_REASONS}, the two a signal-driven close carries.
  it "pins its own reason enum, distinct from a session's" do
    expect(described_class::REASONS)
      .to eq(%i[interrupted grace_expired stopped ceiling over_window transport stalled_stream torn])
    expect(described_class::REASONS).not_to eq(Lain::Telemetry::SessionClosed::REASONS)
    expect(described_class::REASONS).to include(*Lain::CLI::Conductor::INTERRUPT_REASONS)
  end

  it "refuses a reason outside the enum at construction, echoing the offender" do
    expect { described_class.new(head: nil, reason: :nonsense) }
      .to raise_error(ArgumentError,
                      "reason must be one of [:interrupted, :grace_expired, :stopped, :ceiling, :over_window, " \
                      ":transport, :stalled_stream, :torn], " \
                      "got :nonsense")
  end

  it "refuses a nil reason the same way, for the reason SessionClosed's twin gives" do
    expect { described_class.new(head: nil, reason: nil) }
      .to raise_error(ArgumentError,
                      "reason must be one of [:interrupted, :grace_expired, :stopped, :ceiling, :over_window, " \
                      ":transport, :stalled_stream, :torn], " \
                      "got nil")
  end

  # The generic value is the default because it is the one thing every torn
  # run has in common -- a record built without a classification says the
  # unclassified thing rather than borrowing a narrower one it cannot support.
  it "defaults to the unclassified reason" do
    expect(described_class.new(head: nil).reason).to eq(:torn)
  end
end
