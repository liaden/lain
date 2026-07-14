# frozen_string_literal: true

# Provider::Ollama against the SAME seven-gate group Mock and AnthropicRaw pass
# -- a new backend cannot land half-working. The canned Responses are replayed
# through the REAL Ollama decode (OllamaWire serializes them into `/api/chat`
# bodies), so every gate exercises the actual content reassembly, tool-call
# handling, and stop_reason normalization rather than a stub of the provider's
# own logic.
RSpec.describe Lain::Provider::Ollama do
  include_examples "a Lain::Provider",
                   provider_factory: lambda { |responses|
                     described_class.new(transport: OllamaWire.queue_transport(responses))
                   }
end
