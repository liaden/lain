# frozen_string_literal: true

require "lain/provider/anthropic_raw"
require "lain/provider/anthropic"

# Two recorded layers, each proving something the unit specs cannot.
#
#   :vcr   replays a committed cassette through the REAL Faraday/SSE stack,
#          proving the parse against a full recorded body -- free, offline.
#   :live  one call each against the API, asserting AnthropicRaw and the SDK
#          oracle agree. Real money, opt-in (LAIN_LIVE=1), skipped otherwise.
RSpec.describe Lain::Provider::AnthropicRaw do
  def prompt
    Lain::Request.new(model: "claude-opus-4-8", max_tokens: 64,
                      system: "You are a terse assistant.",
                      messages: [{ role: "user", content: "Read the README." }])
  end

  describe "parsing a recorded streaming completion", :vcr do
    # A synthetic, committed cassette (never real content). It carries a thinking
    # block with a signature, text, a tool_use, and usage with null cache fields.
    it "retains every block, the thinking signature, and maps null cache usage to zero",
       vcr: { cassette_name: "anthropic_raw_streaming_tool_use" } do
      response = described_class.new(api_key: "test").complete(prompt)

      expect(response.content.map { |block| block["type"] }).to eq(%w[thinking text tool_use])
      expect(response.blocks_of_type("thinking").first["signature"]).to eq("sig-ZZZ")
      expect(response.tool_uses.first["input"]).to eq("path" => "README.md")
      expect(response.stop_reason).to eq(:tool_use)

      expect(response.usage.input_tokens).to eq(12)
      expect(response.usage.output_tokens).to eq(30)
      expect(response.usage.cache_creation_input_tokens).to eq(0)
      expect(response.usage.cache_read_input_tokens).to eq(0)
    end
  end

  # Real money on every run; only with LAIN_LIVE=1 and a key (see tags.rb). This
  # is the branch's ultimate proof: the forked transport and the SDK oracle
  # produce the same Lain::Response for one identical Request.
  describe "live differential against the SDK oracle", :live do
    it "yields the same content shape and stop_reason from both providers" do
      forked = described_class.new
      oracle = Lain::Provider::Anthropic.new

      raw = forked.complete(prompt)
      ref = oracle.complete(prompt)

      expect(raw.content.map { |block| block["type"] }).to eq(ref.content.map { |block| block["type"] })
      expect(raw.stop_reason).to eq(ref.stop_reason)
      expect(raw.tool_uses.map { |block| block["name"] }).to eq(ref.tool_uses.map { |block| block["name"] })
    end
  end
end
