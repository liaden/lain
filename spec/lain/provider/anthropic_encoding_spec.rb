# frozen_string_literal: true

require "lain/provider/anthropic_encoding"
require "lain/request"

# CE-1: two layers used to place cache_control independently -- this module's
# own with_stride_breakpoint, and Context::CacheBreakpoints -- with no shared
# budget, so a long enough session exceeded Anthropic's 4-cache_control cap
# and 400d. Context::CacheBreakpoints now owns the whole budget; this module
# is pure translation of the neutral "cache" marker it already placed.
RSpec.describe Lain::Provider::AnthropicEncoding do
  let(:encoder) { Class.new { include Lain::Provider::AnthropicEncoding }.new }

  def request(**overrides)
    Lain::Request.new(model: "m", max_tokens: 64, messages: [{ role: "user", content: "hi" }], **overrides)
  end

  it "adds no cache_control of its own, even over many blocks that carry no neutral marker" do
    blocks = Array.new(40) { |i| { "type" => "text", "text" => "b#{i}" } }
    encoded = encoder.encode(request(messages: [{ role: "user", content: blocks }]))

    emitted = encoded[:messages].first["content"]
    expect(emitted.any? { |block| block.key?("cache_control") }).to be(false)
  end

  it "still translates a neutral marker into cache_control wherever the Context layer placed it" do
    content = [{ "type" => "text", "text" => "a" }, { "type" => "text", "text" => "b", "cache" => true }]
    encoded = encoder.encode(request(messages: [{ role: "user", content: content }]))

    emitted = encoded[:messages].first["content"]
    expect(emitted[0]).not_to have_key("cache_control")
    expect(emitted[1]).to include("cache_control" => { "type" => "ephemeral" })
  end

  it "has no stride placement left of its own to place breakpoints" do
    expect(described_class.private_instance_methods).not_to include(:with_stride_breakpoint)
    expect(described_class.constants).not_to include(:CACHE_STRIDE)
  end
end
