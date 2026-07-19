# frozen_string_literal: true

# OR-5: the spawn-time router oracle -- "which model (and shared sibling
# template, if any) should THIS child run under" -- answered from the task's
# own text, before any child exists. {Arm::AdaptiveRouter} is the one caller;
# this spec pins the baseline heuristic tier and the content-addressed
# Definition, the same shape {PruneScoring}/{MemorySave} already pin for their
# own questions.
RSpec.describe Lain::Oracle::Router do
  describe ".heuristic (the baseline arm)" do
    it "routes a short task to the short model, with no model call" do
      oracle = described_class.heuristic(short_model: "claude-haiku-4", long_model: "claude-opus-4-8",
                                         long_after_chars: 100)

      answer = Sync { oracle.ask(task: "fix the typo").await }

      expect(answer.model).to eq("claude-haiku-4")
      expect(oracle.model).to be_nil
      expect(oracle.usage).to eq({})
    end

    it "routes a long task to the long model once it crosses the length threshold" do
      oracle = described_class.heuristic(short_model: "claude-haiku-4", long_model: "claude-opus-4-8",
                                         long_after_chars: 20)

      answer = Sync { oracle.ask(task: "a" * 25).await }

      expect(answer.model).to eq("claude-opus-4-8")
    end

    it "treats the threshold itself as long (>=, not >)" do
      oracle = described_class.heuristic(short_model: "s", long_model: "l", long_after_chars: 10)

      answer = Sync { oracle.ask(task: "a" * 10).await }

      expect(answer.model).to eq("l")
    end

    it "defaults the sibling template to blank -- fresh isolation, not a shared prefix" do
      oracle = described_class.heuristic(short_model: "s", long_model: "l", long_after_chars: 100)

      answer = Sync { oracle.ask(task: "short").await }

      expect(answer.template).to eq("")
    end

    it "carries a caller-supplied sibling template through both branches" do
      oracle = described_class.heuristic(short_model: "s", long_model: "l", long_after_chars: 10,
                                         template: "shared role prelude")

      short_answer = Sync { oracle.ask(task: "hi").await }
      long_answer = Sync { oracle.ask(task: "a" * 20).await }

      expect(short_answer.template).to eq("shared role prelude")
      expect(long_answer.template).to eq("shared role prelude")
    end

    it "is a Heuristic tier, matching the same interface a model tier would" do
      oracle = described_class.heuristic(short_model: "s", long_model: "l", long_after_chars: 10)

      expect(oracle).to be_a(Lain::Oracle::Heuristic)
      expect(oracle.ask(task: "hi")).to be_a(Lain::Promise)
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
