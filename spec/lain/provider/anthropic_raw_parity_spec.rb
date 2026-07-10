# frozen_string_literal: true

require "lain/provider/anthropic_raw"

# AnthropicRaw against the SAME seven-gate group Mock passes -- a new backend
# cannot land half-working. The canned Responses are replayed through the REAL
# streaming parse (StreamAssembler + response builder) via AnthropicSSE, so this
# is not a stub of AnthropicRaw's own logic: every gate exercises the actual
# block reassembly, tool-input parsing, and stop-reason normalization.
RSpec.describe Lain::Provider::AnthropicRaw do
  include_examples "a Lain::Provider",
                   provider_factory: lambda { |responses|
                     described_class.new(transport: AnthropicSSE.queue_transport(responses))
                   }
end
