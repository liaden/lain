# frozen_string_literal: true

require "stringio"

RSpec.describe Lain::Bench::LandingMetrics do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }

  def entries = journal_io.string.lines

  def batch(keys:, landed: keys, ejected: [], waits: nil, verifies: 1, rebuilds: 0, wall: 10.0)
    waits ||= keys.to_h { |key| [key, 1.0] }
    journal.record(
      Lain::Telemetry::LandingBatch.new(branch: "main", desk: :candidate, verifier: "suite", worker_keys: keys,
                                        landed:, ejected:, declined: keys - landed - ejected, verifies:,
                                        rebuilds:, verify_wall_s: wall, queue_wait_s: waits,
                                        outcome: landed.empty? ? :none : :landed)
    )
  end

  def fold = described_class.from_journal(entries)

  describe "per-commit cost falls with batching" do
    it "reports 1.0 verifies per landed commit for 4 batches of 1 and 0.25 for 1 batch of 4" do
      4.times { |i| batch(keys: ["w#{i}"]) }
      single = fold.verifies_per_landed

      journal_io.truncate(0)
      journal_io.rewind
      batch(keys: %w[a b c d])

      expect([single, fold.verifies_per_landed]).to eq([1.0, 0.25])
    end

    it "divides verify wall time by landed commits" do
      batch(keys: %w[a b c d], wall: 20.0)

      expect(fold.verify_wall_per_landed).to eq(5.0)
    end
  end

  describe "an empty journal folds to absent figures, not zeros" do
    it "reports every figure as not measured" do
      metrics = fold

      expect([metrics.verifies_per_landed, metrics.queue_wait_p50, metrics.queue_wait_p95,
              metrics.rebuilds_per_batch, metrics.ejected_share, metrics.verify_wall_per_landed]).to all(be_nil)
    end

    it "reports no landed-based figure when batches landed nothing" do
      batch(keys: %w[a], landed: [], ejected: %w[a])

      metrics = fold

      expect([metrics.verifies_per_landed, metrics.queue_wait_p50, metrics.verify_wall_per_landed]).to all(be_nil)
    end
  end

  it "takes queue wait percentiles over landed members only" do
    batch(keys: %w[a b c d e], landed: %w[a b c d], ejected: %w[e],
          waits: { "a" => 1.0, "b" => 2.0, "c" => 3.0, "d" => 4.0, "e" => 99.0 })

    metrics = fold

    expect([metrics.queue_wait_p50, metrics.queue_wait_p95]).to eq([2.0, 4.0])
  end

  it "averages rebuilds per batch and reports the ejected share of members" do
    batch(keys: %w[a b], rebuilds: 2)
    batch(keys: %w[c d], landed: %w[c], ejected: %w[d], rebuilds: 0)

    metrics = fold

    expect([metrics.rebuilds_per_batch, metrics.ejected_share]).to eq([1.0, 0.25])
  end

  it "names the worker key when a landed member has no recorded wait" do
    batch(keys: %w[a b], waits: { "a" => 1.0 })

    expect { fold.queue_wait_p50 }.to raise_error(KeyError, /"b"/)
  end

  it "ignores other record types in the journal" do
    batch(keys: %w[a])
    journal_io.puts({ "type" => "something_else" }.to_json)

    expect(fold.verifies_per_landed).to eq(1.0)
  end
end
