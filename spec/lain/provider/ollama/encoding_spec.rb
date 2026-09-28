# frozen_string_literal: true

# Structured-answer format, expressed neutrally on Request#extra so the
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

  # Left to its default, ollama cuts a prompt that does not fit its context and
  # evaluates the remainder: from the front when the last message alone
  # overflows, and by dropping whole older messages otherwise -- the system
  # prompt and every tool schema among them, with nothing in the reply to say
  # so. Asked not to, 0.32.12 refuses the request with HTTP 400 naming the exact
  # prompt count and the context size, on both the streaming and the
  # non-streaming path.
  describe "truncation" do
    it "asks ollama to refuse a prompt that does not fit rather than cut it" do
      expect(encoder.encode(request)).to include(truncate: false)
    end

    it "asks it on every request, whatever else the request carries" do
      encoded = encoder.encode(request(stream: true, extra: { "num_ctx" => 8192, "think" => true }))

      expect(encoded).to include(truncate: false, think: true, options: { num_predict: 64, num_ctx: 8192 })
    end
  end

  describe "structured-answer format" do
    let(:schema) do
      { "type" => "object", "properties" => { "answer" => { "type" => "string" } }, "required" => ["answer"] }
    end

    it "includes a format field equal to the schema when the Request carries one" do
      encoded = encoder.encode(request(extra: { "structured_output" => { "schema" => schema, "tool" => "answer" } }))

      expect(encoded[:format]).to eq(schema)
    end

    # THE CRITICAL AC: no structured format means no `format` key, and the
    # marker's absence adds nothing else either -- what is sent is the plain
    # payload, whole, down to the generation cap every Request declares.
    it "encodes to the plain payload, with no format key, when no structured format is present" do
      encoded = encoder.encode(request)

      expect(encoded).to eq(model: "qwen3:4b", messages: [{ role: "user", content: "hi" }], stream: false,
                            truncate: false, options: { num_predict: 64 })
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

      expect(encoded[:options]).to eq(num_predict: 64, temperature: 0)
      expect(encoded.key?(:format)).to be(false)
    end

    # The case the example above was misread as covering: an extra key this
    # encoder claims nothing about reaches no wire field at all. `repeat_penalty`
    # is a real ollama option and still an unknown key HERE, which is the point:
    # the drop is of what this encoder claims nothing about, not of what ollama
    # would refuse. It reads `keep_alive` because that key is now claimed --
    # see the residency field below.
    it "drops an extra key that is neither a sampler key nor a structured_output marker" do
      encoded = encoder.encode(request(extra: { "repeat_penalty" => 1.1 }))

      expect(encoded).to eq(model: "qwen3:4b", messages: [{ role: "user", content: "hi" }], stream: false,
                            truncate: false, options: { num_predict: 64 })
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

    describe "alongside tools" do
      let(:tools) { [{ "name" => "echo", "description" => "echoes", "input_schema" => { "type" => "object" } }] }

      # Ollama answers this pair without an error and drops the tool call.
      it "refuses a format and tools in the same request" do
        marker = { "structured_output" => { "schema" => schema } }

        expect { encoder.encode(request(tools:, extra: marker)) }
          .to raise_error(Lain::Error, /structured_output format and tools/)
      end

      it "still sends tools when the marker carries no schema, since no format reaches the wire" do
        encoded = encoder.encode(request(tools:, extra: { "structured_output" => { "tool" => "answer" } }))

        expect(encoded.keys).to include(:tools)
        expect(encoded.key?(:format)).to be(false)
      end
    end
  end

  # The two throughput knobs. `num_batch` is the one with a measured cost
  # -- ollama passes llama-server `-b 512`, overriding llama.cpp's own 2048, and
  # there is no server-side setting to undo it, so the only place it can be
  # fixed is the request (docs/providers/ollama.md, "Serving performance").
  # `num_ctx` was already a SAMPLER_KEY with no caller putting it in extra.
  describe "the throughput sampler keys" do
    it "carries num_batch from Request#extra into options" do
      encoded = encoder.encode(request(extra: { "num_batch" => 2048 }))

      expect(encoded[:options]).to eq(num_predict: 64, num_batch: 2048)
    end

    it "carries num_ctx from Request#extra into options" do
      encoded = encoder.encode(request(extra: { "num_ctx" => 8192 }))

      expect(encoded[:options]).to eq(num_predict: 64, num_ctx: 8192)
    end

    # Both stay strictly opt-in: a request nobody tuned sends neither, and
    # defaulting either one here would be a wire change for callers who asked
    # for nothing. What such a request does carry is the generation cap below,
    # so the absence worth pinning is of the KNOBS, not of the `options` object
    # they used to be the only reason for.
    it "emits neither throughput knob for a request that tuned nothing" do
      encoded = encoder.encode(request)

      expect(encoded[:options].keys).to eq([:num_predict])
    end
  end

  # Residency: how long ollama keeps the runner loaded after answering, which
  # says nothing about the answer. Ollama keeps it a top-level sibling of
  # `stream`/`tools`, the way it keeps `think`, so it is deliberately NOT a
  # SAMPLER_KEY -- inside `options` it is a field ollama does not define.
  # What pinning is worth, and the probe behind the type rule below, are in
  # docs/providers/ollama.md, "Serving performance".
  describe "the residency field" do
    it "carries keep_alive from Request#extra as a top-level field, not into options" do
      encoded = encoder.encode(request(extra: { "keep_alive" => -1 }))

      expect(encoded[:keep_alive]).to eq(-1)
      expect(encoded[:options]).to eq(num_predict: 64)
    end

    # The TYPE is the payload here, not an implementation detail of it: 0.34.4
    # reads a String through Go's time.ParseDuration and a number as seconds,
    # so -1 and "-1" are a pin and an HTTP 400 respectively. This encoder is a
    # forwarder and must not convert either way -- {Lain::CLI::Backend} is the
    # one place that decides which type a flag becomes.
    it "forwards the value with its JSON type intact, converting neither way" do
      expect(JSON.generate(encoder.encode(request(extra: { "keep_alive" => -1 })))).to include(%("keep_alive":-1))
      expect(JSON.generate(encoder.encode(request(extra: { "keep_alive" => "5m" })))).to include(%("keep_alive":"5m"))
    end

    it "sends no keep_alive key at all for a request that asked for none" do
      expect(encoder.encode(request).key?(:keep_alive)).to be(false)
    end
  end

  # The generation cap, which is not a sampler knob and not opt-in: every
  # Request declares a max_tokens, and this arm was the one that never sent it.
  # Ollama spells the bound `num_predict` and keeps it inside `options`, so the
  # `options` object now rides every request -- a Thinking finetune left with no
  # ceiling deliberates until it decides to stop.
  describe "the generation cap" do
    it "carries the Request's max_tokens into options as num_predict" do
      encoded = encoder.encode(request(max_tokens: 4096))

      expect(encoded[:options]).to eq(num_predict: 4096)
    end

    it "does not displace a tuned sampler knob" do
      encoded = encoder.encode(request(max_tokens: 4096, extra: { "num_batch" => 2048 }))

      expect(encoded[:options]).to eq(num_predict: 4096, num_batch: 2048)
    end

    # The cap is not something a caller opts into, so there is no request shape
    # left that sends no `options` at all.
    it "sends an options object on a request that tuned nothing" do
      expect(encoder.encode(request)).to include(options: { num_predict: 64 })
    end
  end
end
