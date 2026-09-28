# frozen_string_literal: true

# Two layers used to place cache_control independently -- this module's
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
  # that claim :strict_tools emit it, and one that does not -- a validator
  # rejecting it as an extra input -- gets it masked by the same shared encoder.
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

  # Structured-answer format, expressed neutrally on Request#extra (the
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

    # An Oracle::Model builds the marker from its answer SCHEMA and has no
    # tool to name, because an oracle sends no tools. A half-built marker must
    # therefore be treated the same as an absent one -- the mirror of
    # Ollama::Encoding#structured_format, which already omits `format` when the
    # marker carries no "schema". Without this, `tool_choice: {type: "tool",
    # name: nil}` reaches the wire and the API 400s on it.
    it "omits tool_choice, rather than forcing a nil name, when the marker names no tool" do
      encoded = encoder.encode(request(extra: { "structured_output" => { "schema" => { "type" => "object" } } }))

      expect(encoded).not_to have_key(:tool_choice)
    end

    # Review escalation trigger: extra can ALREADY carry a raw tool_choice
    # (the pre-existing forwarding path exercised above by "forwards
    # provider-specific params from #extra as symbol keys"). If a
    # structured_output marker arrives alongside it, the generic extra merge
    # running last would silently let the raw tool_choice win over the forced
    # one -- a silent clobber, not a reconciliation. Fails loudly instead,
    # matching the cache-breakpoint-cap precedent in this same file.
    it "raises when extra carries both a raw tool_choice and a structured_output marker" do
      tool = { name: "answer", description: "d", input_schema: { type: :object, properties: {}, required: [] } }
      req = request(tools: [tool],
                    extra: { "tool_choice" => { "type" => "any" }, "structured_output" => { "tool" => "answer" } })

      expect { encoder.encode(req) }
        .to raise_error(Lain::Error, /tool_choice/)
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
        .to raise_error(Lain::Error, /5 cache breakpoints/)
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
        .to raise_error(Lain::Error, /5 cache breakpoints/)
    end
  end

  # The neutral image block wears Anthropic's own shape, so this encoder has
  # nothing to translate -- and that is the claim, not an absence of one. The
  # other half is the refusal: the ADDRESS is not a wire shape anywhere, and
  # Anthropic answers a `source.type` it does not know with a 400 that names
  # neither the picture nor what failed to resolve it.
  describe "images" do
    let(:png) { (+"\x89PNG\r\n\x1a\n\x00\xff\x80pixels").force_encoding(Encoding::BINARY) }
    let(:reference) { Lain::Attachment::Reference.new(digest: "blake3:#{"9f" * 32}", media_type: "image/png") }
    let(:image) { reference.inline(png) }

    it "passes an inline picture to the wire unchanged, source and all" do
      encoded = encoder.encode(request(messages: [{ role: "user", content: [image] }]))

      expect(encoded[:messages].first["content"]).to eq([image])
    end

    # Ollama's `images` array is that encoder's business and must not appear
    # here, and the neutral block must not have grown a field for it: what
    # arrives on this wire is `source.data` and nothing else.
    it "sends the payload on the block's own source, with no images array anywhere" do
      encoded = encoder.encode(request(messages: [{ role: "user", content: [image] }]))

      expect(encoded[:messages].first["content"].first["source"]["data"]).to eq([png].pack("m0"))
      expect(encoded[:messages].first).not_to have_key(:images)
      expect(encoded[:messages].first).not_to have_key("images")
    end

    it "passes one nested inside a tool_result unchanged too" do
      result = { "type" => "tool_result", "tool_use_id" => "call_1",
                 "content" => [{ "type" => "text", "text" => "the page" }, image] }
      encoded = encoder.encode(request(messages: [{ role: "user", content: [result] }]))

      expect(encoded[:messages].first["content"].first["content"].last).to eq(image)
    end

    it "translates a neutral cache marker on a picture as it does on any block" do
      marked = image.merge("cache" => true)
      encoded = encoder.encode(request(messages: [{ role: "user", content: [marked] }]))

      expect(encoded[:messages].first["content"].first).to include("cache_control" => { "type" => "ephemeral" })
      expect(encoded[:messages].first["content"].first).not_to have_key("cache")
    end

    it "refuses an address nobody resolved, naming it" do
      expect { encoder.encode(request(messages: [{ role: "user", content: [reference.block] }])) }
        .to raise_error(Lain::Attachment::Reference::Unresolved, /#{reference.digest}/)
    end

    it "refuses one hidden inside a tool_result, which #translate_block never descends into" do
      result = { "type" => "tool_result", "tool_use_id" => "call_1", "content" => [reference.block] }

      expect { encoder.encode(request(messages: [{ role: "user", content: [result] }])) }
        .to raise_error(Lain::Attachment::Reference::Unresolved)
    end
  end
end
