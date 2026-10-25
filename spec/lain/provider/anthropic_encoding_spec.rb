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

  # A recap's marker is provenance for readers inside lain, like the workspace marker, and never a
  # wire field.
  describe "the recap marker" do
    let(:derived) { RecapChain.messages }
    let(:rendered) { request(messages: derived) }

    it "is on no block of the body, while the rendered request's recap blocks still carry it" do
      encoded = encoder.encode(rendered)

      expect(RecapChain.keys_anywhere(encoded)).not_to include(Lain::Compaction::Recap::MARKER)
      expect(encoded[:messages].first["content"].first["text"]).to eq(Lain::Compaction::Recap::PREAMBLE)
      expect(rendered.messages.first["content"]).to all(include(Lain::Compaction::Recap::MARKER => true))
    end

    it "still translates a cache marker the context placed on a recap block" do
      cached = derived.first.merge("content" => [*derived.first["content"][0...-1],
                                                 derived.first["content"].last.merge("cache" => true)])
      emitted = encoder.encode(request(messages: [cached, *derived.drop(1)]))[:messages].first["content"].last

      expect(emitted).to eq("type" => "text", "text" => Lain::Compaction::Recap::CLOSING,
                            "cache_control" => { "type" => "ephemeral" })
    end
  end

  describe "effort" do
    it "rides output_config" do
      expect(encoder.encode(request(effort: "low"))[:output_config]).to eq(effort: "low")
    end

    it "sends no output_config without an effort" do
      expect(encoder.encode(request)).not_to have_key(:output_config)
    end

    it "refuses a raw output_config that is not a Hash when an effort must join it" do
      expect { encoder.encode(request(effort: "low", extra: { "output_config" => "json" })) }
        .to raise_error(Lain::Error, /output_config.*Hash/)
    end

    it "keeps an output_config in extra alongside the effort" do
      encoded = encoder.encode(request(effort: "low", extra: { "output_config" => { "format" => "x" } }))

      expect(encoded[:output_config]).to eq(format: "x", effort: "low")
    end
  end

  describe "parameters a model rejects" do
    def encode_for(model, **overrides) = encoder.encode(request(model:, **overrides))

    def expect_refused(model, pattern, **overrides)
      expect { encode_for(model, **overrides) }.to raise_error(described_class::Rejected, pattern)
    end

    def sampling_keys = %w[temperature top_p top_k]
    def efforts = %w[low medium high xhigh max]
    def efforts_to_max = %w[low medium high max]

    # Under anthropic-version 2023-06-01 these 400 even at the default value.
    %w[claude-fable-5 claude-fable-5-1 claude-mythos-5-1 claude-opus-5-5 claude-opus-5 claude-opus-4-8
       claude-opus-4-7 claude-sonnet-5].each do |model|
      it "refuses temperature, top_p and top_k at their defaults on #{model}" do
        sampling_keys.each { |key| expect_refused(model, /#{model}.*#{key}/, extra: { key => 1 }) }
      end
    end

    %w[claude-sonnet-5-5 claude-haiku-5-5].each do |model|
      it "refuses a temperature other than 1 on #{model}" do
        expect_refused(model, /#{model}.*temperature/, extra: { "temperature" => 0.2 })
      end

      it "refuses any top_p or top_k on #{model}" do
        expect_refused(model, /top_p/, extra: { "top_p" => 1 })
        expect_refused(model, /top_k/, extra: { "top_k" => 1 })
      end

      it "accepts temperature 1 on #{model}" do
        expect(encode_for(model, extra: { "temperature" => 1 })[:temperature]).to eq(1)
      end
    end

    %w[claude-opus-4-6 claude-sonnet-4-6 claude-haiku-4-5 claude-3-5-sonnet-20241022].each do |model|
      it "forwards temperature, top_p and top_k on #{model}" do
        encoded = encode_for(model, extra: { "temperature" => 0.2, "top_p" => 0.9, "top_k" => 5 })

        expect(encoded).to include(temperature: 0.2, top_p: 0.9, top_k: 5)
      end
    end

    it "refuses a sampling key spelled as a symbol" do
      expect_refused("claude-opus-4-8", /temperature/, extra: { temperature: 0.2 })
    end

    it "matches a bedrock-style or dated id by containment" do
      expect_refused("us.anthropic.claude-opus-5-5-v1:0", /temperature/, extra: { "temperature" => 1 })
      expect_refused("claude-opus-4-8-20260101", /temperature/, extra: { "temperature" => 1 })
    end

    it "keeps claude-sonnet-5-5 on its own row, not claude-sonnet-5's" do
      expect(encode_for("claude-sonnet-5-5", extra: { "temperature" => 1 })[:temperature]).to eq(1)
    end

    %w[claude-opus-4-6 claude-haiku-4-5 m].each do |model|
      it "refuses seed on #{model}, which is no Anthropic parameter" do
        expect_refused(model, /seed.*not an Anthropic parameter/, extra: { "seed" => 1 })
      end
    end

    describe "forced tool_choice" do
      let(:forced) { { "tool_choice" => { "type" => "tool", "name" => "x" } } }

      %w[claude-opus-5-5 claude-sonnet-5-5 claude-fable-5-1 claude-mythos-5-1].each do |model|
        it "refuses it on #{model}, naming the model and the alternative" do
          expect_refused(model, /#{model}.*auto.*strict tool.*structured answer/, extra: forced)
        end
      end

      it "refuses the structured-answer tool_choice on a model that rejects forcing" do
        expect_refused("claude-sonnet-5-5", /claude-sonnet-5-5/,
                       extra: { "structured_output" => { "tool" => "answer" } })
      end

      it "refuses it on a bedrock-prefixed id by containment" do
        expect_refused("us.anthropic.claude-fable-5-1-v1:0", /claude-fable-5-1/, extra: forced)
      end

      it "still encodes it for claude-opus-4-8 and claude-opus-5" do
        %w[claude-opus-4-8 claude-opus-5].each do |model|
          expect(encode_for(model, extra: forced)[:tool_choice]).to eq("type" => "tool", "name" => "x")
        end
      end

      it "allows tool_choice auto on claude-opus-5-5" do
        encoded = encode_for("claude-opus-5-5", extra: { "tool_choice" => { "type" => "auto" } })

        expect(encoded[:tool_choice]).to eq("type" => "auto")
      end
    end

    describe "disabled thinking" do
      let(:disabled) { { "type" => "disabled" } }

      %w[claude-opus-5-5 claude-sonnet-5-5 claude-fable-5 claude-fable-5-1 claude-mythos-5-1].each do |model|
        it "is refused on #{model} at every effort" do
          expect_refused(model, /#{model}/, reasoning: disabled)
          expect_refused(model, /#{model}/, reasoning: disabled, effort: "low")
        end
      end

      it "suggests between_tools for claude-sonnet-5-5" do
        expect_refused("claude-sonnet-5-5", /between_tools/, reasoning: disabled)
      end

      %w[claude-opus-5 claude-haiku-5-5].each do |model|
        it "is refused on #{model} at xhigh and max only" do
          expect_refused(model, /#{model}.*xhigh/, reasoning: disabled, effort: "xhigh")
          expect_refused(model, /max/, reasoning: disabled, effort: "max")
          expect(encode_for(model, reasoning: disabled, effort: "high")[:thinking]).to eq(disabled)
          expect(encode_for(model, reasoning: disabled)[:thinking]).to eq(disabled)
        end
      end

      it "is allowed on claude-opus-4-8 and by containment refused on a bedrock claude-opus-5-5" do
        expect(encode_for("claude-opus-4-8", reasoning: disabled)[:thinking]).to eq(disabled)
        expect_refused("anthropic.claude-opus-5-5-v1:0", /claude-opus-5-5/, reasoning: disabled)
      end
    end

    describe "effort" do
      %w[claude-haiku-4-5 claude-sonnet-4-5 claude-opus-4-1 claude-opus-4 claude-sonnet-4 claude-3-haiku-20240307
         claude-opus-4-20250514].each do |model|
        it "is refused whole on #{model}" do
          expect_refused(model, /#{model}.*effort/, effort: "low")
        end
      end

      %w[claude-opus-4-0 claude-sonnet-4-0].each do |model|
        it "refuses effort on the #{model} alias" do
          expect_refused(model, /effort/, effort: "low")
        end
      end

      it "gives claude-opus-4-5 low, medium and high only" do
        %w[low medium high].each do |e|
          expect(encode_for("claude-opus-4-5", effort: e)[:output_config]).to eq(effort: e)
        end
        expect_refused("claude-opus-4-5", /xhigh/, effort: "xhigh")
        expect_refused("claude-opus-4-5", /max/, effort: "max")
      end

      %w[claude-opus-4-6 claude-sonnet-4-6].each do |model|
        it "gives #{model} low through max but not xhigh" do
          efforts_to_max.each { |e| expect(encode_for(model, effort: e)[:output_config]).to eq(effort: e) }
          expect_refused(model, /#{model}.*xhigh/, effort: "xhigh")
        end
      end

      %w[claude-opus-4-7 claude-opus-4-8 claude-opus-5 claude-opus-5-5 claude-sonnet-5 claude-sonnet-5-5
         claude-haiku-5-5 claude-fable-5 claude-fable-5-1 claude-mythos-5-1].each do |model|
        it "gives #{model} all 5 levels" do
          efforts.each do |e|
            expect(encode_for(model, effort: e)[:output_config]).to eq(effort: e)
          end
        end
      end

      it "matches a bedrock-style id by containment" do
        expect_refused("us.anthropic.claude-opus-4-5-v1:0", /max/, effort: "max")
      end

      it "matches dated, vertex and bedrock ids at a version boundary" do
        %w[claude-opus-4-5-20251101 claude-opus-4-5@20251101 anthropic.claude-opus-4-5 claude-haiku-4-5-latest]
          .each { |id| expect_refused(id, /effort/, effort: "max") }
      end

      it "does not let a short row swallow a later version" do
        %w[claude-opus-4-9 claude-opus-4-10 claude-sonnet-4-10 claude-haiku-4-50 claude-opus-6 claude-fable-5-2]
          .each { |id| expect(encode_for(id, effort: "max")[:output_config]).to eq(effort: "max") }
      end

      it "gives an id that has no row no sampling or thinking rule either" do
        expect(encode_for("claude-fable-5-2", extra: { "temperature" => 0.2 }, reasoning: { "type" => "disabled" }))
          .to include(temperature: 0.2)
      end
    end
  end
end
