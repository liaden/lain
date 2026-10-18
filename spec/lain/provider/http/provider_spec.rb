# frozen_string_literal: true

# Trimmed from ruby_llm 1.16.0 (2cf34b9), spec/ruby_llm/provider_spec.rb.
# Upstream is a lookup table over all thirteen providers' `api_base` and
# config options; this branch vendors Anthropic only, so the table keeps its
# *shape* (a Hash keyed by slug, one row per provider) with a single row.
# Adding openai/gemini/bedrock later is one new row in `api_base_cases` and
# one more line in `config_for`, not a rewrite. The generic
# `.configured?` / "provider configuration schema" examples are unchanged
# apart from namespace, since they exercise the base `Provider`/
# `Configuration` seam directly; only the requirements-subset and api_base
# examples read the Anthropic table.
RSpec.describe Lain::Provider::HTTP::Provider do
  let(:api_base_cases) do
    {
      anthropic: {
        provider: Lain::Provider::HTTP::Providers::Anthropic,
        key: :anthropic_api_base,
        custom: "https://anthropic-proxy.example.com",
        default: "https://api.anthropic.com"
      }
    }
  end

  def config_for(slug)
    Lain::Provider::HTTP::Configuration.new.tap do |config|
      config.anthropic_api_key = "anthropic-key" if slug == :anthropic
    end
  end

  describe ".configured?" do
    it "treats blank required configuration as missing" do
      provider_class = Class.new(described_class) do
        class << self
          def configuration_options
            %i[blank_test_api_key]
          end

          def configuration_requirements
            %i[blank_test_api_key]
          end
        end
      end

      Lain::Provider::HTTP::Configuration.register_provider_options(provider_class.configuration_options)
      config = Lain::Provider::HTTP::Configuration.new
      config.blank_test_api_key = ""

      expect(provider_class.configured?(config)).to be(false)
    ensure
      deregister_options(%i[blank_test_api_key])
    end
  end

  describe "provider configuration schema" do
    it "keeps requirements as a subset of declared configuration options" do
      api_base_cases.each_value do |data|
        provider_class = data[:provider]
        missing = provider_class.configuration_requirements - provider_class.configuration_options
        expect(missing).to be_empty, "#{provider_class.name} is missing options for requirements: #{missing.inspect}"
      end
    end

    it "exposes aggregated provider options through Configuration" do
      expect(Lain::Provider::HTTP::Configuration.options).to include(:anthropic_api_base, :anthropic_api_key)
      expect(Lain::Provider::HTTP::Configuration.options).to include(:request_timeout, :max_retries)
    end
  end

  context "with API base configuration" do
    it "uses the configured API base for every provider" do
      api_base_cases.each do |slug, data|
        config = config_for(slug)
        config.public_send("#{data[:key]}=", data[:custom])

        expect(data[:provider].new(config).api_base).to eq(data[:custom])
      end
    end

    it "keeps existing defaults for providers with built-in endpoints" do
      api_base_cases.select { |_slug, data| data[:default] }.each do |slug, data|
        expect(data[:provider].new(config_for(slug)).api_base).to eq(data[:default])
      end
    end
  end

  private

  # `.configured?`'s throwaway provider class leaves an option registered on
  # the shared `Configuration` class; RSpec examples run in random order
  # (spec/support/rspec_configuration.rb), so a leaked option would otherwise
  # leak into whichever example runs next.
  def deregister_options(option_keys)
    option_keys.each do |key|
      Lain::Provider::HTTP::Configuration.send(:option_keys).delete(key)
      Lain::Provider::HTTP::Configuration.send(:defaults).delete(key)
      Lain::Provider::HTTP::Configuration.class_eval do
        remove_method key if method_defined?(key)
        remove_method :"#{key}=" if method_defined?(:"#{key}=")
      end
    end
  end
end
