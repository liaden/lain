# frozen_string_literal: true

require "lain/provider/anthropic"

# Hits the REAL Claude API. Skipped unless LAIN_INTEGRATION=1 and
# ANTHROPIC_API_KEY are both set (see spec_helper). Deliberately two examples
# and tiny max_tokens -- these cost money. Their job is to catch the things a
# stub cannot: that the live streaming API really does hand back a JSON String
# tool input, and that a real round trip lands as a neutral Response.
RSpec.describe Lain::Provider::Anthropic, :integration do
  subject(:provider) { described_class.new }

  it "completes a plain text round trip" do
    request = Lain::Request.new(
      model: "claude-opus-4-8", max_tokens: 16,
      messages: [{ role: "user", content: "Reply with exactly the word: pong" }]
    )

    response = provider.complete(request)

    expect(response).to be_a(Lain::Response)
    expect(response.stop_reason).to eq(:end_turn)
    expect(response.text).to match(/pong/i)
    expect(response.usage.input_tokens).to be > 0
    expect(response.usage.output_tokens).to be > 0
  end

  it "returns a parsed Hash input for a single-tool round trip (the streaming String trap, live)" do
    request = Lain::Request.new(
      model: "claude-opus-4-8", max_tokens: 256,
      tools: [{
        name: "get_weather",
        description: "Get the current weather for a city.",
        input_schema: { type: "object", properties: { city: { type: "string" } }, required: ["city"] }
      }],
      messages: [{ role: "user", content: "Use the get_weather tool to check the weather in Paris." }]
    )

    response = provider.complete(request)

    expect(response.stop_reason).to eq(:tool_use)
    input = response.tool_uses.first["input"]
    expect(input).to be_a(Hash)
    expect(input["city"]).to match(/paris/i)
  end
end
