# frozen_string_literal: true

require "lain/provider/http"

# Ported near-verbatim from ruby_llm 1.16.0 (2cf34b9),
# spec/ruby_llm/error_middleware_spec.rb. Only the namespace changed
# (RubyLLM:: -> Lain::Provider::HTTP::); `.parse_error`'s status-dispatch
# behavior (including the 400/429 context-length sniff) is unchanged even
# though its implementation was refactored away from a ten-branch `case`
# with an inline `rubocop:disable` -- these examples are exactly what
# proves the refactor preserved behavior.
RSpec.describe Lain::Provider::HTTP::ErrorMiddleware do
  describe ".parse_error" do
    let(:provider) { instance_double(Lain::Provider::HTTP::Provider, parse_error: "provider error") }

    it "maps 502 to ServiceUnavailableError" do
      response = Struct.new(:status, :body).new(502, '{"error":{"message":"down"}}')

      expect do
        described_class.parse_error(provider: provider, response: response)
      end.to raise_error(Lain::Provider::HTTP::ServiceUnavailableError)
    end

    it "maps 503 to ServiceUnavailableError" do
      response = Struct.new(:status, :body).new(503, '{"error":{"message":"down"}}')

      expect do
        described_class.parse_error(provider: provider, response: response)
      end.to raise_error(Lain::Provider::HTTP::ServiceUnavailableError)
    end

    it "maps 504 to ServiceUnavailableError" do
      response = Struct.new(:status, :body).new(504, '{"error":{"message":"timeout"}}')

      expect do
        described_class.parse_error(provider: provider, response: response)
      end.to raise_error(Lain::Provider::HTTP::ServiceUnavailableError)
    end

    it "maps context-length-like 429 errors to ContextLengthExceededError" do
      response = Struct.new(:status, :body).new(429, '{"error":{"message":"Request too large for model"}}')
      provider = instance_double(Lain::Provider::HTTP::Provider, parse_error: "Request too large for model")

      expect do
        described_class.parse_error(provider: provider, response: response)
      end.to raise_error(Lain::Provider::HTTP::ContextLengthExceededError)
    end

    it "keeps regular 429 errors as RateLimitError" do
      response = Struct.new(:status, :body).new(429, '{"error":{"message":"Rate limit exceeded"}}')
      provider = instance_double(Lain::Provider::HTTP::Provider, parse_error: "Rate limit exceeded")

      expect do
        described_class.parse_error(provider: provider, response: response)
      end.to raise_error(Lain::Provider::HTTP::RateLimitError)
    end

    it "maps context-length-like 400 errors to ContextLengthExceededError" do
      msg = "This model's maximum context length is 8192 tokens."
      response = Struct.new(:status, :body).new(400, %({"error":{"message":"#{msg}"}}))
      provider = instance_double(Lain::Provider::HTTP::Provider, parse_error: msg)

      expect do
        described_class.parse_error(provider: provider, response: response)
      end.to raise_error(Lain::Provider::HTTP::ContextLengthExceededError)
    end

    it "maps Anthropic's 'prompt is too long' 400 error to ContextLengthExceededError" do
      msg = "prompt is too long: 209025 tokens > 200000 maximum"
      response = Struct.new(:status, :body).new(400, %({"error":{"message":"#{msg}"}}))
      provider = instance_double(Lain::Provider::HTTP::Provider, parse_error: msg)

      expect do
        described_class.parse_error(provider: provider, response: response)
      end.to raise_error(Lain::Provider::HTTP::ContextLengthExceededError)
    end

    it "keeps regular 400 errors as BadRequestError" do
      response = Struct.new(:status, :body).new(400, '{"error":{"message":"Invalid model specified"}}')
      provider = instance_double(Lain::Provider::HTTP::Provider, parse_error: "Invalid model specified")

      expect do
        described_class.parse_error(provider: provider, response: response)
      end.to raise_error(Lain::Provider::HTTP::BadRequestError)
    end
  end
end
