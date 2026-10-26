# frozen_string_literal: true

RSpec.describe Lain::CLI::Backend::StartupNotices do
  def notices(provider: "anthropic", model: "claude-opus-4-8", max_cost: nil, effort_rejected: false,
              compacting: true, summarizer: "ollama", **profile)
    described_class.new(provider:, model:, profile: Lain::CLI::RunProfile.from_options({ provider:, **profile }),
                        max_cost:, effort_rejected:, compacting:, summarizer:)
  end

  describe "#hosted" do
    it "says nothing for a plain anthropic chat" do
      expect(notices.hosted([])).to eq([])
    end

    it "names the sampling flags the model refuses" do
      expect(notices.hosted(%w[temperature seed]))
        .to contain_exactly(/claude-opus-4-8 takes no --temperature and --seed .*: not sent/)
    end

    it "says the base reaches only the ollama summarizer" do
      expect(notices(api_base: "http://h:11434").hosted([]))
        .to eq(["--api-base reaches the ollama summarizer only, not the anthropic chat"])
    end

    it "says the base reaches nothing when nothing compacts" do
      expect(notices(api_base: "http://h:11434", compacting: false).hosted([]).join)
        .to include("--api-base reaches nothing")
    end

    it "says an effort the model rejects is not sent" do
      expect(notices(effort: "max", effort_rejected: true).hosted([]))
        .to eq(["--effort max is ignored by claude-opus-4-8 and is not sent"])
    end
  end

  describe "#ollama" do
    it "follows the tier's own notices with the unpriced ceiling and the dropped effort" do
      said = notices(provider: "ollama", model: "qwen3:4b", max_cost: 1, effort: "low").ollama(["tier says"])

      expect(said).to match(["tier says", /--max-cost cannot bind.*qwen3:4b/,
                             "--effort low is ignored by the ollama chat and is not sent"])
    end
  end
end
