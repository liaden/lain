# frozen_string_literal: true

require "json"
require "stringio"

RSpec.describe Lain::Compaction::Cold do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }

  def records
    journal_io.string.each_line.map { |line| JSON.parse(line) }
  end

  # A TTL-bearing profile shaped like Anthropic's real CACHE_PROFILE (T15).
  def ttl_profile(ttl: 300) = { ttl: }

  # The raw shape #observe reads internally -- a String-keyed Hash, the same
  # wire form Canonical.normalize produces on a real TurnUsage#usage. Specs
  # that only care about the warm/cold branch use this directly; specs that
  # pin the String-key contract itself build a REAL TurnUsage instead (below).
  def usage(cache_read:) = { "cache_read_input_tokens" => cache_read }

  # A real Telemetry::TurnUsage, built the way Agent::Accounting builds one
  # from a live Response -- #usage is Canonical-normalized (String keys),
  # exactly what a provider round-trip hands #observe in production.
  def turn_usage(cache_read:)
    Lain::Telemetry::TurnUsage.new(
      digest: "blake3:turn",
      model: "claude-opus-4-8",
      stop_reason: :end_turn,
      usage: { input_tokens: 10, output_tokens: 5, cache_read_input_tokens: cache_read,
               cache_creation_input_tokens: 0 }
    )
  end

  describe "a TTL-bearing provider (idle-past-TTL, confirmed by a zero cache-read)" do
    it "marks the cache pending once idle exceeds the TTL" do
      cold = described_class.new(cache_profile: ttl_profile)

      cold.idle!(301)

      expect(cold.pending?).to be(true)
      expect(cold.cold?).to be(false)
    end

    it "does not mark pending while idle stays within the TTL" do
      cold = described_class.new(cache_profile: ttl_profile)

      cold.idle!(299)

      expect(cold.pending?).to be(false)
    end

    it "does not mark pending exactly AT the TTL boundary (idle must exceed it)" do
      cold = described_class.new(cache_profile: ttl_profile)

      cold.idle!(300)

      expect(cold.pending?).to be(false)
    end

    it "confirms cold and journals the confirmation once the next response reads cache_read == 0" do
      cold = described_class.new(cache_profile: ttl_profile, journal:)

      cold.idle!(301)
      cold.observe(usage(cache_read: 0))

      expect(cold.cold?).to be(true)
      expect(cold.pending?).to be(false)
      expect(records.map { |r| r["type"] }).to eq(["cache_cold_confirmed"])
      expect(records.first["reason"]).to eq("idle_confirmed")
    end

    it "does not confirm cold on a zero cache-read with no pending idle mark" do
      cold = described_class.new(cache_profile: ttl_profile, journal:)

      cold.observe(usage(cache_read: 0))

      expect(cold.cold?).to be(false)
      expect(records).to be_empty
    end

    it "a warm hit cancels a pending cold mark, and journals nothing" do
      cold = described_class.new(cache_profile: ttl_profile, journal:)

      cold.idle!(301)
      cold.observe(usage(cache_read: 42))

      expect(cold.pending?).to be(false)
      expect(cold.cold?).to be(false)
      expect(records).to be_empty
    end

    it "a warm hit cancels an already-confirmed cold mark" do
      cold = described_class.new(cache_profile: ttl_profile, journal:)

      cold.idle!(301)
      cold.observe(usage(cache_read: 0))
      cold.observe(usage(cache_read: 10))

      expect(cold.cold?).to be(false)
      expect(cold.pending?).to be(false)
    end
  end

  describe "a TTL-less provider (falls back to the cache_read == 0 signal alone)" do
    it "never raises a pending mark from idle time when the profile has no :ttl key" do
      cold = described_class.new(cache_profile: {})

      cold.idle!(10_000_000)

      expect(cold.pending?).to be(false)
    end

    it "never raises a pending mark from idle time when ttl is 0 (Ollama's NO_CACHING_PROFILE)" do
      cold = described_class.new(cache_profile: { ttl: 0 })

      cold.idle!(10_000_000)

      expect(cold.pending?).to be(false)
    end

    it "confirms cold directly off a zero cache-read, without ever going through idle!" do
      cold = described_class.new(cache_profile: {}, journal:)

      cold.observe(usage(cache_read: 0))

      expect(cold.cold?).to be(true)
      expect(records.map { |r| r["type"] }).to eq(["cache_cold_confirmed"])
      expect(records.first["reason"]).to eq("signal_only")
    end

    it "does not confirm cold on a positive cache-read" do
      cold = described_class.new(cache_profile: { ttl: 0 }, journal:)

      cold.observe(usage(cache_read: 5))

      expect(cold.cold?).to be(false)
      expect(records).to be_empty
    end
  end

  describe "the String-key contract, pinned against a REAL Telemetry::TurnUsage" do
    # TurnUsage#usage is Canonical-normalized (String keys only) -- this is
    # what #observe must read internally so a caller can never silently pass
    # a symbol-keyed lookup's nil (which would misread a WARM turn as cold).
    it "confirms cold from a real TurnUsage reporting cache_read_input_tokens == 0" do
      cold = described_class.new(cache_profile: ttl_profile, journal:)

      cold.idle!(301)
      cold.observe(turn_usage(cache_read: 0))

      expect(cold.cold?).to be(true)
      expect(records.first["reason"]).to eq("idle_confirmed")
    end

    it "cancels (never confirms cold) from a real TurnUsage reporting a non-zero cache_read_input_tokens" do
      cold = described_class.new(cache_profile: ttl_profile, journal:)

      cold.idle!(301)
      cold.observe(turn_usage(cache_read: 128))

      expect(cold.cold?).to be(false)
      expect(cold.pending?).to be(false)
      expect(records).to be_empty
    end
  end

  describe "the default journal" do
    it "is the Null channel, so a caller never has to guard `if journal`" do
      expect { described_class.new(cache_profile: {}).observe(usage(cache_read: 0)) }.not_to raise_error
    end
  end
end
