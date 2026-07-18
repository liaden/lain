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

    it "omits format when extra is present but carries no structured_output key" do
      encoded = encoder.encode(request(extra: { temperature: 0 }))

      expect(encoded.key?(:format)).to be(false)
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
end
