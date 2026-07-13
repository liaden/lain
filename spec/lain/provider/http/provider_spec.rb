# frozen_string_literal: true

# Trimmed from ruby_llm 1.16.0 (2cf34b9), spec/ruby_llm/provider_spec.rb.
# Upstream is a lookup table over all thirteen providers' `api_base` and
# config options; this branch vendors Anthropic only, so the table keeps its
# *shape* (a Hash keyed by slug, one row per provider) with a single row.
# Adding openai/gemini/bedrock later is one new row in `api_base_cases` and
# one new `when` in `config_for`, not a rewrite. The generic `.register` /
# `.configured?` / "provider configuration schema" examples are unchanged
# apart from namespace, since they exercise the base `Provider`/
# `Configuration` seam directly and never touch a specific provider.
RSpec.describe Lain::Provider::HTTP::Provider do
  def api_base_cases
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

  describe ".register" do
    it "registers provider configuration options on Configuration" do
      provider_key = :test_provider_spec
      option_keys = %i[test_provider_api_key test_provider_api_base]

      provider_class = Class.new(described_class) do
        class << self
          def configuration_options
            %i[test_provider_api_key test_provider_api_base]
          end

          def configuration_requirements
            %i[test_provider_api_key]
          end
        end
      end

      original_providers = described_class.providers.dup

      begin
        described_class.register(provider_key, provider_class)

        config = Lain::Provider::HTTP::Configuration.new
        option_keys.each do |key|
          expect(config).to respond_to(key)
          expect(config).to respond_to("#{key}=")
        end
      ensure
        described_class.providers.replace(original_providers)
        deregister_options(option_keys)
      end
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
      described_class.providers.each_value do |provider_class|
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
    it "covers every registered provider" do
      expect(api_base_cases.keys).to match_array(described_class.providers.keys)
    end

    it "registers an API base option for every provider" do
      expected_options = api_base_cases.values.map { |data| data[:key] }

      expect(Lain::Provider::HTTP::Configuration.options).to include(*expected_options)
    end

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

  # `.register`'s and `.configured?`'s throwaway provider classes leave
  # options registered on the shared `Configuration` class; RSpec examples
  # run in random order (spec/support/rspec_configuration.rb), so a leaked
  # option would otherwise leak into whichever example runs next.
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
