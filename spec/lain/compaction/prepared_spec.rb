# frozen_string_literal: true

require "json"
require "stringio"

# Shareable fixtures, mirroring SchedulerShareableFixtures in scheduler_spec:
# the composed pipeline must be Ractor-shareable (the T21 injected-pipeline
# contract), so whatever the module-scope COMPOSE lambda closes over -- the
# base pipeline here -- must already be shareable. Living in a module body is
# what lets `self` inside each lambda be the (shareable) module rather than
# an example instance.
module PreparedShareableFixtures
  BASE = Ractor.make_shareable(->(_workspace) { Lain::Context::Identity })
end

# A counting double standing in for the injected summarizer Compact.new
# takes (compact.rb:35) -- deterministic, and it remembers how many times it
# was actually asked to summarize, which is the one fact CAC-5's "two idle
# ticks, one summarization" claim needs proof of. Plain #call duck, same as
# Provider::Mock / Effect::Handler::Mock elsewhere. Top-level (not defined
# inside the RSpec.describe block) per Lint/ConstantDefinitionInBlock.
class CountingSummarizer
  attr_reader :calls

  def initialize
    @calls = 0
  end

  def call(_dropped)
    @calls += 1
    "SUMMARY-#{@calls}"
  end
end

RSpec.describe Lain::Compaction::Prepared do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }

  def records
    journal_io.string.each_line.map { |line| JSON.parse(line) }
  end

  let(:summarizer) { CountingSummarizer.new }
  let(:compact) { Lain::Context::Compact.new(threshold: 5, keep_last: 2, summarizer:) }

  # Six substantial messages: enough that Compact's keep_last(2) leaves a
  # head over its byte threshold, so a prepare actually rewrites it (the
  # same shape scheduler_spec's #history uses).
  def history(size = 6)
    (1...(size + 1)).map do |i|
      { "role" => "user", "content" => [{ "type" => "text", "text" => "the quick brown fox number #{i}" }] }
    end
  end

  def prepared(journal: Lain::Channel::Null.instance) = described_class.new(compact:, journal:)

  describe "#idle (compute-once, keyed on the timeline head digest)" do
    it "computes the compaction on the first idle tick" do
      result = prepared.idle(head_digest: "digest-a", messages: history)

      expect(result.size).to be < history.size
      expect(result).to include(a_hash_including("content" => [a_hash_including("text" => "SUMMARY-1")]))
    end

    it "makes exactly ONE summarization call across two idle ticks at the same head (CAC-5)" do
      instance = prepared

      instance.idle(head_digest: "digest-a", messages: history)
      instance.idle(head_digest: "digest-a", messages: history)

      expect(summarizer.calls).to eq(1)
    end

    it "reuses the held result byte-for-byte on the second tick, not a fresh (re)computation" do
      instance = prepared

      first = instance.idle(head_digest: "digest-a", messages: history)
      second = instance.idle(head_digest: "digest-a", messages: history)

      expect(second).to eq(first)
    end

    it "journals a prepared-compaction record on the first tick only" do
      instance = prepared(journal:)

      instance.idle(head_digest: "digest-a", messages: history)
      instance.idle(head_digest: "digest-a", messages: history)

      expect(records).to contain_exactly(
        a_hash_including("type" => "compaction_prepared", "head_digest" => "digest-a")
      )
    end

    it "discards and RECOMPUTES once a new turn advances the head (CAC-5)" do
      instance = prepared

      instance.idle(head_digest: "digest-a", messages: history)
      instance.idle(head_digest: "digest-b", messages: history(8))

      expect(summarizer.calls).to eq(2)
    end

    it "journals a second prepared record for the advanced head" do
      instance = prepared(journal:)

      instance.idle(head_digest: "digest-a", messages: history)
      instance.idle(head_digest: "digest-b", messages: history(8))

      expect(records.map { |r| r["head_digest"] }).to eq(%w[digest-a digest-b])
    end
  end

  describe "#current_for?" do
    it "is false before any idle tick has run" do
      expect(prepared.current_for?("digest-a")).to be(false)
    end

    it "is true for the head a compaction was just held against" do
      instance = prepared
      instance.idle(head_digest: "digest-a", messages: history)

      expect(instance.current_for?("digest-a")).to be(true)
    end

    it "is false for a digest that was never prepared, even once another IS held" do
      instance = prepared
      instance.idle(head_digest: "digest-a", messages: history)

      expect(instance.current_for?("digest-b")).to be(false)
    end
  end

  describe "#pipeline (apply on the next real turn -- CAC-5's 'apply on resume')" do
    def rendered(pipeline, messages)
      pipeline.call(Lain::Workspace.empty).call(messages)
    end

    it "hands the base back UNTOUCHED when nothing is held for this head" do
      pipeline = prepared.pipeline(head_digest: "digest-a", base: PreparedShareableFixtures::BASE)

      expect(pipeline).to equal(PreparedShareableFixtures::BASE)
    end

    it "hands the base back UNTOUCHED when the held compaction is for a DIFFERENT (stale) head" do
      instance = prepared
      instance.idle(head_digest: "digest-a", messages: history)

      pipeline = instance.pipeline(head_digest: "digest-b", base: PreparedShareableFixtures::BASE)

      expect(pipeline).to equal(PreparedShareableFixtures::BASE)
    end

    it "applies the held compaction ahead of the base when the head matches" do
      instance = prepared
      instance.idle(head_digest: "digest-a", messages: history)

      pipeline = instance.pipeline(head_digest: "digest-a", base: PreparedShareableFixtures::BASE)
      result = rendered(pipeline, history)

      expect(result.size).to be < history.size
      expect(result).to include(a_hash_including("content" => [a_hash_including("text" => "SUMMARY-1")]))
    end

    it "does NOT call the summarizer again while applying the held compaction" do
      instance = prepared
      instance.idle(head_digest: "digest-a", messages: history)

      pipeline = instance.pipeline(head_digest: "digest-a", base: PreparedShareableFixtures::BASE)
      rendered(pipeline, history)

      expect(summarizer.calls).to eq(1)
    end

    it "the composed pipeline is Ractor-shareable (the T21 injected-pipeline contract)" do
      instance = prepared
      instance.idle(head_digest: "digest-a", messages: history)

      pipeline = instance.pipeline(head_digest: "digest-a", base: PreparedShareableFixtures::BASE)

      expect(Ractor.shareable?(pipeline)).to be(true)
    end

    it "survives being stored in a Context via the injected-pipeline seam" do
      instance = prepared
      instance.idle(head_digest: "digest-a", messages: history)
      pipeline = instance.pipeline(head_digest: "digest-a", base: PreparedShareableFixtures::BASE)

      context = Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, pipeline:)

      expect(Ractor.shareable?(context)).to be(true)
    end
  end

  describe "the default journal" do
    it "is the Null channel, so a caller never has to guard `if journal`" do
      expect { prepared.idle(head_digest: "digest-a", messages: history) }.not_to raise_error
    end
  end
end
