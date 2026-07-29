# frozen_string_literal: true

# Bedrock against the SAME seven-gate group Mock and Anthropic pass -- the
# Bedrock arm cannot land half-working. The canned Responses are replayed through
# the REAL streaming parse (Anthropic::StreamAssembler + response builder) via
# AnthropicSSE: Mantle speaks the plain Anthropic Messages API over SSE, so the
# same replay harness drives Bedrock's actual block reassembly, tool-input
# parsing, and stop-reason normalization.
RSpec.describe Lain::Provider::Bedrock do
  include_examples "a Lain::Provider",
                   provider_factory: lambda { |responses|
                     described_class.new(transport: AnthropicSSE.queue_transport(responses))
                   }
end
