# frozen_string_literal: true

RSpec.describe Lain::Config::Review do
  describe ".from" do
    it "refuses a blank model" do
      expect { described_class.from({ "model" => "  " }, path: "config.rb:1") }
        .to raise_error(Lain::Config::Refusal, /model must be a non-blank string/)
    end

    it "strips the model and freezes it" do
      model = described_class.from({ "model" => " claude-sonnet-5-5 " }, path: nil).model

      expect([model, model.frozen?]).to eq(["claude-sonnet-5-5", true])
    end
  end

  describe "#choose" do
    it "falls back to the author when no model is configured" do
      choice = described_class.empty.choose(author: "glm-5.3")

      expect([choice.model, choice.author]).to eq(%w[glm-5.3 glm-5.3])
    end

    it "keeps the configured model when it equals the author's" do
      choice = described_class.new(model: "glm-5.3").choose(author: "glm-5.3")

      expect([choice.model, choice.author]).to eq(%w[glm-5.3 glm-5.3])
    end
  end
end
