# frozen_string_literal: true

# BedrockRaw against the SAME seven-gate group Mock and AnthropicRaw pass -- the
# Bedrock arm cannot land half-working. The canned Responses are replayed through
# the REAL streaming parse (AnthropicRaw::StreamAssembler + response builder) via
# AnthropicSSE: Mantle speaks the plain Anthropic Messages API over SSE, so the
# same replay harness drives BedrockRaw's actual block reassembly, tool-input
# parsing, and stop-reason normalization.
RSpec.describe Lain::Provider::BedrockRaw do
  include_examples "a Lain::Provider",
                   provider_factory: lambda { |responses|
                     described_class.new(transport: AnthropicSSE.queue_transport(responses))
                   }
end
