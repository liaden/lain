# frozen_string_literal: true

RSpec.describe Lain::CLI::Backend::Thinking do
  def show_transport(body)
    Class.new do
      define_method(:model_details) { |_model| Struct.new(:body).new(body) }
    end.new
  end

  def provider_showing(thinking)
    body = { "capabilities" => %w[completion thinking], "thinking" => thinking }.compact
    Lain::Provider::Ollama.new(transport: show_transport(body))
  end

  let(:model) { "glm-5.3" }
  let(:accepting) { provider_showing("values" => %w[low high max], "default" => "max") }

  def thinking(level, provider: accepting)
    described_class.new(level:, backend: Struct.new(:provider, :model).new(provider, model))
  end

  it "sends a configured level the model lists, as the think field of the encoded body" do
    encoder = Class.new { include Lain::Provider::Ollama::Encoding }.new
    request = Lain::Request.new(model:, messages: [{ role: "user", content: "hi" }], max_tokens: 64, stream: false,
                                extra: thinking("low").extra)

    expect(encoder.encode(request)).to include(think: "low")
  end

  it "sends nothing when no level is configured, and does not ask the server" do
    asked = Class.new { define_method(:thinking_levels) { |_| raise "probed" } }.new

    expect(thinking(nil, provider: asked).extra).to eq({})
  end

  it "refuses a level the model does not list, naming the ones it does" do
    expect { thinking("medium").extra }
      .to raise_error(Lain::CLI::Backend::Thinking::Invalid, /"medium".*low, high, max/)
  end

  it "refuses a configured level when the server could not say which it accepts, naming the missing metadata" do
    unanswered = provider_showing(nil)

    expect { thinking("low", provider: unanswered).extra }
      .to raise_error(Lain::CLI::Backend::Thinking::Invalid, /no thinking metadata.*glm-5.3/)
  end

  describe "a cloud /api/show that errors" do
    let(:failing) do
      Class.new { define_method(:model_details) { |_model| raise Faraday::ConnectionFailed, "down" } }.new
    end
    let(:cloud) { Lain::Provider::Ollama.cloud(api_key: "sk-test", transport: failing) }

    it "launches as before when no level is configured" do
      expect([thinking(nil, provider: cloud).extra, cloud.trained_context_tokens(model)]).to eq([{}, nil])
    end

    it "refuses a configured level at launch" do
      expect { thinking("low", provider: cloud).extra }
        .to raise_error(Lain::CLI::Backend::Thinking::Invalid, /no thinking metadata/)
    end
  end

  it "reads the accepted levels through the production Ollama provider, once per model" do
    asked = 0
    transport = Class.new do
      define_method(:model_details) do |_model|
        asked += 1
        Struct.new(:body).new({ "thinking" => { "values" => %w[low high] } })
      end
    end.new
    provider = Lain::Provider::Ollama.new(transport:)

    2.times { provider.thinking_levels(model) }

    expect([provider.thinking_levels(model), asked]).to eq([%w[low high], 1])
  end

  it "asks /api/show once per model for capabilities, levels, identity and the trained maximum together" do
    shown = 0
    body = { "capabilities" => %w[thinking], "thinking" => { "values" => %w[low] },
             "details" => { "quantization_level" => "Q4" },
             "model_info" => { "general.architecture" => "glm", "glm.context_length" => 1_000_000 } }
    transport = Class.new do
      define_method(:model_details) do |_model|
        shown += 1
        Struct.new(:body).new(body)
      end
      define_method(:tags) { Struct.new(:body).new({ "models" => [] }) }
    end.new
    provider = Lain::Provider::Ollama.cloud(api_key: "sk-test", transport:)

    provider.model_capabilities(model)
    provider.thinking_levels(model)
    provider.trained_context_tokens(model)
    provider.model_identity(model)

    expect(shown).to eq(1)
  end
end
