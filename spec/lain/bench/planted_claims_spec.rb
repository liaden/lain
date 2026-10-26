# frozen_string_literal: true

require "tmpdir"

# The committed corpus under spec/fixtures/compaction/planted is synthetic sessions that each
# carry one fact inside a single tool result, so a compaction sweep can ask whether a strategy
# kept it. The bytes are code's output under a fixed clock; this file proves they are real
# sessions, that the planted fact is findable and only ever came from a tool, and that
# regenerating reproduces them.
RSpec.describe Lain::Bench::PlantedClaims do
  # Each request_sent record carries the whole prompt so far, which DryReplay needs one-to-one.
  small_session_bytes = 80_000
  committed = File.expand_path("../../fixtures/compaction/planted", __dir__)

  let(:fixtures) { described_class.in(committed) }

  def human_texts(recording)
    recording.timeline.to_a.select { |turn| turn.role == "user" }
             .flat_map { |turn| turn.content.filter_map { |block| block["text"] if block["type"] == "text" } }
  end

  it "ships about 6 small sessions" do
    expect(fixtures.size).to eq(6)
    expect(fixtures.map { |fixture| File.size(fixture.path) }).to all(be < small_session_bytes)
  end

  it "loads every fixture as a real session of at least 30 turns" do
    fixtures.each do |fixture|
      recording = Lain::Bench::Session.load(fixture.path)
      expect(recording.timeline.to_a.size).to be >= 30
    end
  end

  it "names each planted claim and the tool-result turn carrying it" do
    fixtures.each do |fixture|
      recording = Lain::Bench::Session.load(fixture.path)
      carrier = recording.timeline.to_a.find { |turn| turn.digest == fixture.carrier_digest }
      results = carrier.content.select { |block| block["type"] == "tool_result" }
      expect(results.map { |block| block["content"] }).to include(a_string_including(fixture.claim))
    end
  end

  it "plants each claim in exactly one turn, never a human-typed one" do
    fixtures.each do |fixture|
      recording = Lain::Bench::Session.load(fixture.path)
      mentions = recording.timeline.to_a.select { |turn| turn.content.to_s.include?(fixture.claim) }
      expect(mentions.map(&:digest)).to eq([fixture.carrier_digest])
      expect(human_texts(recording).join("\n")).not_to include(fixture.claim)
    end
  end

  it "gives each fixture a claim of its own" do
    expect(fixtures.map(&:claim).uniq.size).to eq(fixtures.size)
  end

  it "is frozen data" do
    expect(Ractor.shareable?(fixtures.first)).to be(true)
  end

  describe ".generate" do
    it "writes the committed fixtures byte for byte" do
      Dir.mktmpdir do |tmp|
        described_class.generate(tmp)
        expect(Dir.children(tmp).sort).to eq(Dir.children(committed).sort)
        Dir.children(tmp).each do |name|
          expect(File.binread(File.join(tmp, name))).to eq(File.binread(File.join(committed, name)))
        end
      end
    end

    it "differs only in timestamps under another clock" do
      Dir.mktmpdir do |tmp|
        described_class.generate(tmp, clock: -> { "2031-02-03T04:05:06Z" })
        Dir.children(tmp).each do |name|
          fresh = File.read(File.join(tmp, name)).gsub("2031-02-03T04:05:06Z", "1970-01-01T00:00:00Z")
          expect(fresh).to eq(File.read(File.join(committed, name)))
        end
      end
    end

    it "replaces a corpus already there instead of doubling it" do
      Dir.mktmpdir do |tmp|
        2.times { described_class.generate(tmp) }
        expect(described_class.in(tmp).map(&:carrier_digest)).to eq(fixtures.map(&:carrier_digest))
      end
    end
  end

  it "names no path under a home directory" do
    home = Dir.home
    Dir.glob(File.join(committed, "*")).each do |path|
      text = File.read(path)
      expect(text).not_to match(%r{/(home|Users|root)/})
      expect(text).not_to include(home) if home.length >= 4
    end
  end
end
