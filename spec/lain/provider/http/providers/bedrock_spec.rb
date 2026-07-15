# frozen_string_literal: true

RSpec.describe Lain::Provider::HTTP::Providers::Bedrock do
  def config(**overrides)
    Lain::Provider::HTTP::Configuration.new.tap do |c|
      c.bedrock_api_key = overrides.fetch(:bedrock_api_key, "tok")
      c.bedrock_region = overrides.fetch(:bedrock_region, "us-east-1")
      c.bedrock_api_base = overrides[:bedrock_api_base] if overrides.key?(:bedrock_api_base)
    end
  end

  # The backend registers itself on load, exactly as the vendored Anthropic
  # backend does; resolution through the shared registry is the seam AC1 names.
  describe "registration" do
    it "registers under the :bedrock slug" do
      expect(Lain::Provider::HTTP::Provider.resolve(:bedrock)).to eq(described_class)
    end
  end

  describe "#api_base" do
    it "derives the Mantle endpoint from the region" do
      provider = Lain::Provider::HTTP::Provider.resolve(:bedrock).new(config)

      expect(provider.api_base).to eq("https://bedrock-mantle.us-east-1.api.aws/anthropic")
    end

    it "prefers an explicit bedrock_api_base over the derived URL" do
      provider = described_class.new(config(bedrock_api_base: "https://gateway.internal/anthropic"))

      expect(provider.api_base).to eq("https://gateway.internal/anthropic")
    end
  end

  describe "#headers" do
    it "sends bearer auth and the anthropic-version, never x-api-key" do
      headers = described_class.new(config).headers

      expect(headers).to include("Authorization" => "Bearer tok", "anthropic-version" => "2023-06-01")
      expect(headers).not_to have_key("x-api-key")
    end
  end

  describe "secret redaction" do
    it "never echoes the bearer token through Configuration#inspect" do
      expect(config.inspect).not_to include("tok")
    end
  end

  describe "missing configuration" do
    it "fails loudly, naming every unset required key" do
      bare = Lain::Provider::HTTP::Configuration.new

      expect { described_class.new(bare) }.to raise_error(Lain::Provider::HTTP::ConfigurationError) do |error|
        expect(error.message).to include("bedrock_api_key", "bedrock_region")
      end
    end
  end
end
