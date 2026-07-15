# frozen_string_literal: true

# exe/lain is a script, not a lib file: it ends in `LainCLI.start(ARGV)`,
# guarded by `$PROGRAM_NAME == __FILE__` so this `load` defines the class
# WITHOUT parsing rspec's ARGV or touching the network. We test at the Thor
# class seam -- build_provider/build_context/build_agent -- never a subprocess.
load File.expand_path("../../exe/lain", __dir__)

RSpec.describe LainCLI do
  # Thor applies method_option defaults only during `.start`; constructing the
  # class directly does not, so each example passes the full options hash the
  # method under test reads. Thor wraps it with indifferent access.
  def cli(**options)
    described_class.new([], options)
  end

  let(:toolset) { Lain::Toolset.new }
  let(:channel) { Lain::Channel.new }

  # The provider/model choice lives in Backend, a plain object over the flags,
  # so it is exercised directly -- no Thor instance, no network.
  def backend(**options) = LainCLI::Backend.new(options)

  describe LainCLI::Backend, "#provider" do
    it "constructs a Provider::Ollama honoring --api-base" do
      provider = backend(provider: "ollama", api_base: "http://localhost:11434").provider
      expect(provider).to be_a(Lain::Provider::Ollama)
      expect(provider.instance_variable_get(:@config).ollama_api_base).to eq("http://localhost:11434")
    end

    it "constructs a Provider::Anthropic for --provider anthropic" do
      # Anthropic's SDK client reads ANTHROPIC_API_KEY at construction (offline,
      # no request); a placeholder is enough to build the object.
      provider = with_env("ANTHROPIC_API_KEY" => "sk-test") do
        backend(provider: "anthropic").provider
      end
      expect(provider).to be_a(Lain::Provider::Anthropic)
    end

    it "fails loudly on an unknown provider, naming the valid set" do
      expect { backend(provider: "gemini").provider }
        .to raise_error(Thor::Error, /unknown provider "gemini", expected one of.*anthropic.*ollama/m)
    end
  end

  describe "provider-dependent --model default" do
    it "defaults to Ollama's model when --provider ollama and no --model" do
      agent = cli(provider: "ollama", api_base: nil, model: nil, max_tokens: 4096)
              .send(:build_agent, toolset:, channel:)
      expect(agent.context.model).to eq(Lain::Provider::Ollama::DEFAULT_MODEL)
    end

    it "honors an explicit --model over the provider default" do
      model = backend(provider: "ollama", model: "qwen3:8b", max_tokens: 4096).context.model
      expect(model).to eq("qwen3:8b")
    end

    it "the chat command's --provider flag defaults to anthropic" do
      expect(described_class.commands.fetch("chat").options.fetch(:provider).default).to eq("anthropic")
    end
  end

  # AC2: --temperature 0 --seed 7 reach the Ollama wire payload's options, but
  # NOT the Request digest -- temperature is a sampler knob, not a prompt.
  describe "temperature and seed threading" do
    let(:store) { Lain::Store.new }
    let(:timeline) do
      Lain::Timeline.empty(store:)
                    .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
    end

    def render(**options)
      backend(**options).context.render(timeline:, toolset:)
    end

    it "carries options.temperature 0 and options.seed 7 into the encoded payload" do
      request = render(provider: "ollama", model: nil, max_tokens: 4096, temperature: 0, seed: 7)
      payload = Lain::Provider::Ollama.new.encode(request)
      expect(payload[:options]).to include(temperature: 0, seed: 7)
    end

    it "renders a Request whose cache_payload is identical to the flagless render" do
      tuned = render(provider: "ollama", model: nil, max_tokens: 4096, temperature: 0, seed: 7)
      plain = render(provider: "ollama", model: nil, max_tokens: 4096, temperature: nil, seed: nil)
      expect(tuned.cache_payload).to eq(plain.cache_payload)
      expect(tuned).to have_same_digest_as(plain)
    end

    it "omits absent sampler keys entirely (0 is present, nil is not)" do
      request = render(provider: "ollama", model: nil, max_tokens: 4096, temperature: 0, seed: nil)
      payload = Lain::Provider::Ollama.new.encode(request)
      expect(payload[:options]).to eq(temperature: 0)
    end
  end

  def with_env(vars)
    saved = vars.keys.to_h { |k| [k, ENV.fetch(k, :__unset__)] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| v == :__unset__ ? ENV.delete(k) : (ENV[k] = v) }
  end
end
