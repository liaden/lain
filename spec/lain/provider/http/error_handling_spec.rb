# frozen_string_literal: true

# Adapted, not ported, from ruby_llm 1.16.0 (2cf34b9),
# spec/ruby_llm/error_handling_spec.rb. Upstream's 17-line version drives the
# whole thing through `RubyLLM.chat(model: "gpt-4.1-nano").ask("Hello")` --
# `Chat#ask` owns a loop and a default-model lookup through the Models
# registry, neither of which this branch vendors (Provider#complete is a
# single round trip; see provider.rb's header). "Near-verbatim" is not
# reachable here without vendoring machinery the porting brief explicitly
# excludes, so this drives the same real seam -- an unauthorized response
# reaching {Lain::Provider::HTTP::Provider#complete} -- one layer down, at
# {Lain::Provider::HTTP::Providers::Anthropic#complete}, stubbed with
# WebMock (already required globally by spec_helper.rb, not the VCR/:vcr
# machinery this branch is told not to add).
RSpec.describe Lain::Provider::HTTP::Error do
  it "handles an invalid API key gracefully" do
    stub_request(:post, "https://api.anthropic.com/v1/messages")
      .to_return(
        status: 401,
        headers: { "Content-Type" => "application/json" },
        body: { error: { type: "authentication_error", message: "invalid x-api-key" } }.to_json
      )

    config = Lain::Provider::HTTP::Configuration.new
    config.anthropic_api_key = "sk-ant-invalid"
    provider = Lain::Provider::HTTP::Providers::Anthropic.new(config)
    model = Struct.new(:id, :max_tokens).new("claude-haiku-4-5", 1024)
    messages = [Lain::Provider::HTTP::Message.new(role: :user, content: "Hello")]

    expect do
      provider.complete(messages, tools: {}, temperature: nil, model:)
    end.to raise_error(Lain::Provider::HTTP::UnauthorizedError)
  end
end
