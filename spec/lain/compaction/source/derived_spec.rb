# frozen_string_literal: true

require "delegate"

RSpec.describe Lain::Compaction::Source::Derived do
  let(:derived) { described_class.new(keep_last: 2) }
  let(:summarizing) do
    Class.new(Lain::Compaction::Strategy::Base) do
      def propose_ranges(_messages, span:) = [span]

      def blocks(messages) = [{ "type" => "text", "text" => "[#{messages.size} messages summarized]" }]
    end.new.freeze
  end

  def timeline(size, from: Lain::Timeline.empty)
    (from.length...size).inject(from) do |line, index|
      line.commit(role: index.even? ? "user" : "assistant", content: [{ "type" => "text", "text" => "turn #{index}" }])
    end
  end

  def walk(line) = Lain::Compaction::Derivation::Walk.of(line)

  def over(subject, line, cut: Lain::Compaction::Derivation::UNCUT)
    snapshot = Lain::Compaction::SummarySnapshot.take(messages: walk(line).messages,
                                                      eager: Lain::Compaction::Source::NoSummaries)
    subject.over(line, walk: walk(line), pins: Lain::Context::PinnedMessages::NONE, snapshot:, cut:)
  end

  def held(subject, line, cut) = subject.held(line, walk: walk(line), cut:)

  # The resume each derivation was handed. {Lain::Compaction::Derivation} freezes
  # itself, so it is wrapped rather than stubbed.
  def resumes_handed
    resumes = []
    recorder = Class.new(SimpleDelegator) do
      define_method(:derive) do |source, resume: nil, **options, &block|
        resumes << resume
        __getobj__.derive(source, resume:, **options, &block)
      end
    end
    allow(Lain::Compaction::Derivation).to receive(:new).and_wrap_original do |original, **options|
      recorder.new(original.call(**options))
    end
    resumes
  end

  describe "holding a cut across turns" do
    let(:earlier) { timeline(8) }
    let!(:cut) { over(described_class.new(keep_last: 2, strategy: summarizing), earlier).seam }

    it "renders what a fresh derivation renders, turn after turn" do
      held(derived, earlier, cut)
      later = timeline(11, from: earlier)

      expect(held(derived, later, cut).messages).to eq(held(described_class.new(keep_last: 2), later, cut).messages)
    end

    it "passes a resume to the derivation only under the holding policy" do
      resumes = resumes_handed
      later = timeline(10, from: earlier)

      held(derived, earlier, cut)
      held(derived, later, cut)
      over(derived, earlier, cut:)
      over(derived, later, cut:)

      expect(resumes.map(&:class)).to eq([NilClass, Lain::Compaction::Derivation::Resume, NilClass, NilClass])
    end

    it "forgets its resume once another policy derives" do
      resumes = resumes_handed

      held(derived, earlier, cut)
      over(derived, earlier, cut:)
      held(derived, timeline(10, from: earlier), cut)

      expect(resumes.last).to be_nil
    end
  end

  # What a head measures: the ranges this run's policy could claim, cut at the
  # pins exactly as a derivation cuts them, and never paid for.
  describe "the claimant a head measures through" do
    def message(index)
      { "role" => index.even? ? "user" : "assistant", "content" => [{ "type" => "text", "text" => "turn #{index}" }] }
    end

    let(:messages) { (0..3).map { |index| message(index) } }
    let(:pins) { Lain::Context::PinnedMessages.new([messages[1]]) }
    let(:unaskable) { Class.new { def ask(_inputs) = raise("the oracle was asked") }.new }

    it "claims every unpinned turn under the default policy" do
      expect(derived.claimant(pins:).claims(messages, span: 0..3)).to eq([0..0, 2..3])
    end

    it "claims a summarizing policy's runs between the pins without asking its oracle" do
      policy = Lain::Compaction::Strategy::SummarizeConversation.new(oracle: unaskable)
      claimant = described_class.new(keep_last: 2, strategy: policy).claimant(pins:)

      expect(claimant.claims(messages, span: 0..3)).to eq([2..3])
    end

    it "widens to tool rounds and conversational runs between the pins, asking no oracle" do
      tool = [{ "role" => "assistant",
                "content" => [{ "type" => "tool_use", "id" => "t", "name" => "r", "input" => {} }] },
              { "role" => "user", "content" => [{ "type" => "tool_result", "tool_use_id" => "t", "content" => "ok" }] }]
      history = messages + tool

      widening = described_class.new(keep_last: 2, widening: Lain::CLI::CompactionStrategy.claiming_pair)

      expect(widening.widening(pins:).claims(history, span: 0..5)).to eq([2..3, 4..5])
    end

    it "widens to nothing when no wider arm was given" do
      expect(derived.widening(pins:)).to be(Lain::Compaction::Head::Nothing)
    end

    it "answers the policy's name, as the derivation's wrapper does" do
      policy = Lain::Compaction::Strategy::Elide.new

      expect(described_class.new(keep_last: 2, strategy: policy).claimant(pins:).name).to eq(policy.name)
    end
  end
end
