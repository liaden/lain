# frozen_string_literal: true

# T4 (OR-3), first oracle arm: "which spans are stale?" -- feeds
# cache-aware-compaction's cold-window work (T18, not yet built). Pins the
# heuristic baseline every richer arm (OR-4) must beat: no model call,
# decided purely from `age_turns` crossing a threshold.
RSpec.describe Lain::Oracle::PruneScoring do
  describe ".heuristic (the baseline arm)" do
    it "scores a span stale with no model call once it crosses the age threshold" do
      oracle = described_class.heuristic(stale_after_turns: 5)

      answer = Sync { oracle.ask(age_turns: 9, content: "old tool output").await }

      expect(answer.stale).to be(true)
      expect(oracle.model).to be_nil
      expect(oracle.usage).to eq({})
    end

    it "scores a recently referenced span as not stale" do
      oracle = described_class.heuristic(stale_after_turns: 5)

      answer = Sync { oracle.ask(age_turns: 1, content: "just said").await }

      expect(answer.stale).to be(false)
    end

    it "treats the threshold itself as stale (>=, not >)" do
      oracle = described_class.heuristic(stale_after_turns: 5)

      answer = Sync { oracle.ask(age_turns: 5, content: "borderline").await }

      expect(answer.stale).to be(true)
    end

    it "is a Heuristic tier, matching the same interface a model tier would" do
      oracle = described_class.heuristic(stale_after_turns: 5)

      expect(oracle).to be_a(Lain::Oracle::Heuristic)
      expect(oracle.ask(age_turns: 1)).to be_a(Lain::Promise)
    end
  end

  describe ".definition" do
    it "is content-addressed and stable across two builds" do
      expect(described_class.definition.digest).to eq(described_class.definition.digest)
    end

    it "addresses the heuristic and a model tier differently" do
      heuristic_digest = described_class.definition(tier: :heuristic).digest
      model_digest = described_class.definition(tier: :model).digest

      expect(heuristic_digest).not_to eq(model_digest)
    end
  end
end
