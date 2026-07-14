# frozen_string_literal: true

# Lain::Provider::Mock is the reference implementation the shared parity group
# proves itself against: if a provider this trivial cannot pass all seven
# gates plus the Provider contract, the shared group itself is broken. Every
# other provider (Provider::Anthropic, and later Provider::AnthropicRaw on the
# `transport` branch) is judged against the SAME group.
RSpec.describe Lain::Provider::Mock do
  include_examples "a Lain::Provider",
                   provider_factory: ->(responses) { described_class.new(responses:) }
end
