# frozen_string_literal: true

RSpec.describe Lain::Compaction::Source::IdleGate do
  subject(:gate) { described_class.new }

  def read(elapsed:, ttl: 300, cold: false) = gate.reading(elapsed:, ttl:, cold:)

  describe "#reading" do
    it "is warm under the TTL whatever the flags say" do
      expect(read(elapsed: 299, cold: true)).to eq(:warm)
    end

    it "is still warm exactly at the TTL" do
      expect(read(elapsed: 300)).to eq(:warm)
    end

    it "does not take a pending flag" do
      expect { gate.reading(elapsed: 301, ttl: 300, cold: false, pending: true) }.to raise_error(ArgumentError)
    end

    it "is warm at 10 seconds and cold at 301 when the cache is confirmed cold" do
      expect([read(elapsed: 10, cold: true), read(elapsed: 301, cold: true)]).to eq(%i[warm cold])
    end

    it "presumes cold past the TTL when nothing confirmed it" do
      expect(read(elapsed: 301)).to eq(:presumed_cold)
    end

    it "waits for the floor when the provider has no TTL, whatever the cold flag says" do
      readings = [119, 120].map { |elapsed| read(elapsed:, ttl: nil, cold: true) }

      expect(readings).to eq(%i[warm cold])
    end

    it "treats a TTL of 0 as none" do
      expect([read(elapsed: 119, ttl: 0), read(elapsed: 120, ttl: 0)]).to eq(%i[warm presumed_cold])
    end

    it "takes its floor from the constructor" do
      expect(described_class.new(floor: 5).reading(elapsed: 5, ttl: nil, cold: true)).to eq(:cold)
    end
  end

  describe "#ready?" do
    it "is false while warm and true once cold" do
      expect([gate.ready?(:warm, "blake3:a"), gate.ready?(:cold, "blake3:a"), gate.ready?(:presumed_cold, "blake3:a")])
        .to eq([false, true, true])
    end

    it "is false for a latched head and true for a different one" do
      gate.latch("blake3:a")

      expect([gate.ready?(:cold, "blake3:a"), gate.ready?(:cold, "blake3:b")]).to eq([false, true])
    end
  end
end
