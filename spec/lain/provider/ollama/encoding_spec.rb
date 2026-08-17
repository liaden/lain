# frozen_string_literal: true

# T1: structured-answer format, expressed neutrally on Request#extra so the
# Request shape itself never changes (extra is already excluded from
# Request#cache_payload -- see request.rb -- so this rides the same escape
# hatch temperature/seed/think already use, and never touches cache identity).
RSpec.describe Lain::Provider::Ollama::Encoding do
  def encoder
    Class.new { include Lain::Provider::Ollama::Encoding }.new
  end

  def request(**overrides)
    Lain::Request.new(model: "qwen3:4b", max_tokens: 64, stream: false,
                      messages: [{ role: "user", content: "hi" }], **overrides)
  end

  describe "structured-answer format" do
    let(:schema) do
      { "type" => "object", "properties" => { "answer" => { "type" => "string" } }, "required" => ["answer"] }
    end

    it "includes a format field equal to the schema when the Request carries one" do
      encoded = encoder.encode(request(extra: { "structured_output" => { "schema" => schema, "tool" => "answer" } }))

      expect(encoded[:format]).to eq(schema)
    end

    # THE CRITICAL AC: no structured format means no `format` key, and every
    # other field is exactly what today's plain encode already produces.
    it "encodes byte-identically to today when no structured format is present" do
      encoded = encoder.encode(request)

      expect(encoded).to eq(model: "qwen3:4b", messages: [{ role: "user", content: "hi" }], stream: false)
      expect(encoded.key?(:format)).to be(false)
    end

    # SAMPLER_KEYS are Strings, and so is every key Request#extra holds --
    # Canonical.normalize stringifies them on the way in, so the Symbol
    # `temperature:` this used to be written with reached the encoder as
    # "temperature" and rode the sampler path the example reads as avoiding.
    # Written as the String it becomes, and asserting where it lands, so the
    # setup means what it says.
    it "omits format when extra carries only sampler keys" do
      encoded = encoder.encode(request(extra: { "temperature" => 0 }))

      expect(encoded[:options]).to eq(temperature: 0)
      expect(encoded.key?(:format)).to be(false)
    end

    # The case the example above was misread as covering: an extra key this
    # encoder claims nothing about reaches no wire field at all.
    it "drops an extra key that is neither a sampler key nor a structured_output marker" do
      encoded = encoder.encode(request(extra: { "keep_alive" => "5m" }))

      expect(encoded).to eq(model: "qwen3:4b", messages: [{ role: "user", content: "hi" }], stream: false)
    end

    # Review SHOULD-FIX: a nil marker (key present, value nil) must no-op
    # rather than raise a raw NoMethodError -- mirrors AnthropicEncoding's
    # `return {} unless format` graceful-absence guard.
    it "does not raise, and omits format, when the structured_output marker itself is nil" do
      expect { encoder.encode(request(extra: { "structured_output" => nil })) }.not_to raise_error

      encoded = encoder.encode(request(extra: { "structured_output" => nil }))
      expect(encoded.key?(:format)).to be(false)
    end

    # Review SHOULD-FIX: a marker present but missing "schema" must be
    # treated the SAME as an absent marker -- omit the key entirely, never
    # emit a literal `format: nil` the real Ollama API would reject.
    it "omits format, rather than emitting null, when the marker carries no schema" do
      encoded = encoder.encode(request(extra: { "structured_output" => { "tool" => "answer" } }))

      expect(encoded.key?(:format)).to be(false)
    end
  end

  # T11: the two throughput knobs. `num_batch` is the one with a measured cost
  # -- ollama passes llama-server `-b 512`, overriding llama.cpp's own 2048, and
  # there is no server-side setting to undo it, so the only place it can be
  # fixed is the request (docs/providers/ollama.md, "Serving performance").
  # `num_ctx` was already a SAMPLER_KEY with no caller putting it in extra.
  describe "the throughput sampler keys" do
    it "carries num_batch from Request#extra into options" do
      encoded = encoder.encode(request(extra: { "num_batch" => 2048 }))

      expect(encoded[:options]).to eq(num_batch: 2048)
    end

    it "carries num_ctx from Request#extra into options" do
      encoded = encoder.encode(request(extra: { "num_ctx" => 8192 }))

      expect(encoded[:options]).to eq(num_ctx: 8192)
    end

    # Strictly opt-in, like every other sampler key: an encoder that defaulted
    # num_batch on would put an `options` key on every request that has none
    # today, which is the shape the guard below and Ollama's own spec pin.
    it "emits no options key at all when no sampler key is present" do
      encoded = encoder.encode(request)

      expect(encoded.key?(:options)).to be(false)
    end
  end
end
