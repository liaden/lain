# frozen_string_literal: true

require "pp"

# Converted from the T1 review's probes-T1/probe_redaction.rb: the redacting
# `#inspect`/`instance_variables` pair on the shared vendored Configuration is
# a security seam, so its regression guard lives here, where the behavior
# lives, not in any one provider's spec.
RSpec.describe Lain::Provider::HTTP::Configuration do
  let(:secret) { "SUPERSECRET-TOKEN" }

  def pretty(config)
    StringIO.new.tap { |io| PP.pp(config, io) }.string
  end

  # Synthetic options registered through the same seam providers use
  # (register_provider_options), removed again so nothing leaks into other
  # randomly-ordered examples -- same hygiene as provider_spec's `.register`.
  def with_options(*keys)
    described_class.register_provider_options(keys)
    yield
  ensure
    deregister_options(keys)
  end

  def deregister_options(option_keys)
    option_keys.each do |key|
      described_class.send(:option_keys).delete(key)
      described_class.send(:defaults).delete(key)
      described_class.class_eval do
        remove_method key if method_defined?(key)
        remove_method :"#{key}=" if method_defined?(:"#{key}=")
      end
    end
  end

  describe "secret redaction" do
    %i[probe_account_id probe_api_key probe_client_secret probe_session_token].each do |key|
      it "redacts #{key} through both #inspect and pp" do
        with_options(key) do
          config = described_class.new
          config.public_send("#{key}=", secret)

          expect(config.inspect).not_to include(secret)
          expect(pretty(config)).not_to include(secret)
        end
      end
    end

    it "redacts a real provider secret (the bearer token) through both paths" do
      config = described_class.new
      config.bedrock_api_key = secret

      expect(config.inspect).not_to include(secret)
      expect(pretty(config)).not_to include(secret)
    end
  end

  describe "suffix anchoring" do
    # The suffixes are secret-shaped only at END of name: a mid-name occurrence
    # (`_key_` in probe_api_key_source) is an ordinary option and must render,
    # or a redaction refactor could silently hide legitimate config from every
    # failure message that ever prints one.
    it "does not swallow an option with a secret suffix mid-name" do
      with_options(:probe_api_key_source) do
        config = described_class.new
        config.probe_api_key_source = "instance-profile"

        expect(config.inspect).to include("probe_api_key_source=\"instance-profile\"")
        expect(pretty(config)).to include("probe_api_key_source")
      end
    end

    it "keeps _token symmetric with the other suffixes -- mid-name renders" do
      with_options(:probe_token_refresh_margin) do
        config = described_class.new
        config.probe_token_refresh_margin = "30s"

        expect(config.inspect).to include("probe_token_refresh_margin=\"30s\"")
      end
    end
  end

  describe "non-secret rendering" do
    it "still renders ordinary options through #inspect" do
      expect(described_class.new.inspect).to include("@request_timeout=300", "@max_retries=3")
    end

    it "still renders ordinary options through pp" do
      expect(pretty(described_class.new)).to include("request_timeout")
    end
  end
end
