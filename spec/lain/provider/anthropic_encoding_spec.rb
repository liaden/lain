# frozen_string_literal: true

# CE-1: two layers used to place cache_control independently -- this module's
# own with_stride_breakpoint, and Context::CacheBreakpoints -- with no shared
# budget, so a long enough session exceeded Anthropic's 4-cache_control cap
# and 400d. Context::CacheBreakpoints now owns the whole budget; this module
# is pure translation of the neutral "cache" marker it already placed.
RSpec.describe Lain::Provider::AnthropicEncoding do
  # The encoder consults the includer's #supports? for capability-gated wire
  # fields, so the bare host supplies that duck (real includers are Providers).
  def encoder_supporting(*capabilities)
    Class.new do
      include Lain::Provider::AnthropicEncoding

      define_method(:supports?) { |capability| capabilities.include?(capability) }
    end.new
  end

  let(:encoder) { encoder_supporting(:strict_tools) }

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
    encoded = encoder.encode(request(messages: [{ role: "user", content: }]))

    emitted = encoded[:messages].first["content"]
    expect(emitted[0]).not_to have_key("cache_control")
    expect(emitted[1]).to include("cache_control" => { "type" => "ephemeral" })
  end

  it "has no stride placement left of its own to place breakpoints" do
    expect(described_class.private_instance_methods).not_to include(:with_stride_breakpoint)
    expect(described_class.constants).not_to include(:CACHE_STRIDE)
  end

  # The tools' `strict` field is capability-gated: Anthropic-shaped backends
  # that claim :strict_tools emit it, and Bedrock's Mantle -- whose validator
  # rejects it as an extra input -- gets it masked by the same shared encoder.
  describe "the strict mask" do
    def request_with_tool
      tool = { name: "t", description: "d", strict: true,
               input_schema: { type: :object, properties: {}, required: [] } }
      request(tools: [tool])
    end

    it "emits strict when the includer claims :strict_tools" do
      encoded = encoder_supporting(:strict_tools).encode(request_with_tool)
      expect(encoded[:tools].first).to include("strict" => true)
    end

    it "masks strict when the includer does not" do
      encoded = encoder_supporting.encode(request_with_tool)
      expect(encoded[:tools].first).not_to have_key("strict")
    end
  end

  # T1: structured-answer format, expressed neutrally on Request#extra (the
  # same escape hatch temperature/tool_choice-forwarding already uses) rather
  # than a new Request field -- extra is already excluded from
  # Request#cache_payload, so this never touches cache identity.
  describe "structured-answer format" do
    def request_with_structured_tool
      tool = { name: "answer", description: "d", input_schema: { type: :object, properties: {}, required: [] } }
      request(tools: [tool], extra: { "structured_output" => { "tool" => "answer" } })
    end

    it "forces tool_choice naming the structured-answer tool" do
      encoded = encoder.encode(request_with_structured_tool)

      expect(encoded[:tool_choice]).to eq(type: "tool", name: "answer")
    end

    it "does not leak the neutral structured_output marker itself onto the wire" do
      encoded = encoder.encode(request_with_structured_tool)

      expect(encoded).not_to have_key(:structured_output)
    end

    # THE CRITICAL AC: no structured format means no tool_choice, and every
    # other field is exactly what today's plain encode already produces.
    it "encodes byte-identically to today when no structured format is present" do
      encoded = encoder.encode(request)

      expect(encoded).not_to have_key(:tool_choice)
      expect(encoded).to eq(model: "m", max_tokens: 64, messages: [{ "role" => "user", "content" => "hi" }])
    end

    # Review escalation trigger: extra can ALREADY carry a raw tool_choice
    # (the pre-existing forwarding path exercised above by "forwards
    # provider-specific params from #extra as symbol keys"). If a
    # structured_output marker arrives alongside it, the generic extra merge
    # running last would silently let the raw tool_choice win over the forced
    # one -- a silent clobber, not a reconciliation. Fails loudly instead,
    # matching the TooManyCacheMarkers precedent in this same file.
    it "raises when extra carries both a raw tool_choice and a structured_output marker" do
      tool = { name: "answer", description: "d", input_schema: { type: :object, properties: {}, required: [] } }
      req = request(tools: [tool],
                    extra: { "tool_choice" => { "type" => "any" }, "structured_output" => { "tool" => "answer" } })

      expect { encoder.encode(req) }
        .to raise_error(Lain::Provider::AnthropicEncoding::ConflictingToolChoice, /tool_choice/)
    end
  end

  # Anthropic accepts at most four cache_control breakpoints; the encoder is
  # the anti-corruption layer, so it refuses a fifth at encode time (a clear,
  # named error) rather than letting the wire 400.
  describe "the cache-breakpoint budget" do
    def request_with_markers(count)
      content = Array.new(count) { |i| { "type" => "text", "text" => "b#{i}", "cache" => true } }
      request(messages: [{ role: "user", content: }])
    end

    it "encodes four markers without complaint" do
      expect { encoder.encode(request_with_markers(4)) }.not_to raise_error
    end

    it "refuses five markers with a named error" do
      expect { encoder.encode(request_with_markers(5)) }
        .to raise_error(Lain::Provider::AnthropicEncoding::TooManyCacheMarkers, /5 cache breakpoints/)
    end

    # The count spans all three prefix regions, not just messages: markers on
    # tools and system count against the same budget.
    it "counts markers across tools, system, and messages together" do
      tool = { "name" => "t", "description" => "d", "input_schema" => { "type" => "object" }, "cache" => true }
      system = [{ "type" => "text", "text" => "sys", "cache" => true }]
      messages = [{ role: "user", content: [
        { "type" => "text", "text" => "a", "cache" => true },
        { "type" => "text", "text" => "b", "cache" => true },
        { "type" => "text", "text" => "c", "cache" => true }
      ] }]

      expect { encoder.encode(request(tools: [tool], system:, messages:)) }
        .to raise_error(Lain::Provider::AnthropicEncoding::TooManyCacheMarkers, /5 cache breakpoints/)
    end
  end
end
