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

  # The chat-assembly seams (build_toolset/build_agent) moved off the Thor
  # class into LainCLI::Wiring, so they are exercised on a Wiring built with a
  # plain options hash and the Null chronicle -- the same records-nothing duct
  # a directly-constructed CLI instance used to get from #chronicle.
  def wiring(chronicle: Lain::CLI::Chronicle::Null.new, **options)
    LainCLI::Wiring.new(options:, chronicle:)
  end

  describe LainCLI::Backend, "#provider" do
    it "constructs a Provider::Ollama honoring --api-base" do
      provider = backend(provider: "ollama", api_base: "http://localhost:11434").provider
      expect(provider).to be_a(Lain::Provider::Ollama)
      expect(provider.instance_variable_get(:@config).ollama_api_base).to eq("http://localhost:11434")
    end

    it "constructs a Provider::AnthropicRaw for --provider anthropic" do
      # AnthropicRaw reads ANTHROPIC_API_KEY at construction too (offline, no
      # request); a placeholder is enough to build the object.
      provider = with_env("ANTHROPIC_API_KEY" => "sk-test") do
        backend(provider: "anthropic").provider
      end
      expect(provider).to be_a(Lain::Provider::AnthropicRaw)
    end

    it "fails loudly on an unknown provider, naming the valid set" do
      expect { backend(provider: "gemini").provider }
        .to raise_error(Lain::CLI::UnknownProvider, /unknown provider "gemini", expected one of.*anthropic.*ollama/m)
    end

    it "constructs a Provider::Bedrock for --provider bedrock" do
      # Bedrock is env-configured, same as Anthropic above: the Mantle client
      # reads AWS_BEARER_TOKEN_BEDROCK / AWS_REGION at construction (offline,
      # no request); stub them so the real client can be built without the
      # developer's shell leaking in or the run failing for a missing region.
      provider = with_env("AWS_BEARER_TOKEN_BEDROCK" => "tok", "AWS_REGION" => "us-east-1") do
        backend(provider: "bedrock").provider
      end
      expect(provider).to be_a(Lain::Provider::Bedrock)
    end
  end

  describe "provider-dependent --model default" do
    it "defaults to Ollama's model when --provider ollama and no --model" do
      agent = wiring
              .send(:build_agent, toolset:, channel:, session: Lain::Session.new,
                                  backend: backend(provider: "ollama", api_base: nil, model: nil, max_tokens: 4096))
      expect(agent.context.model).to eq(Lain::Provider::Ollama::DEFAULT_MODEL)
    end

    # session: is required on build_agent -- a defaulted fresh Session would
    # let a caller wire a recorder-bearing toolset to an agent whose manifest
    # can never see that recorder, with no error anywhere (T1 panel fix).
    it "requires session: on build_agent so memory cannot be silently mis-wired" do
      backend = LainCLI::Backend.new({ provider: "ollama" })
      expect { wiring.send(:build_agent, toolset:, channel:, backend:) }.to raise_error(ArgumentError, /session/)
    end

    it "honors an explicit --model over the provider default" do
      model = backend(provider: "ollama", model: "qwen3:8b", max_tokens: 4096).context.model
      expect(model).to eq("qwen3:8b")
    end

    it "defaults to Bedrock's model when --provider bedrock and no --model" do
      model = backend(provider: "bedrock", model: nil, max_tokens: 4096).context.model
      expect(model).to eq("anthropic.claude-opus-4-8")
    end

    it "the chat command's --provider flag defaults to anthropic" do
      expect(described_class.commands.fetch("chat").options.fetch(:provider).default).to eq("anthropic")
    end
  end

  describe "--help text" do
    it "lists bedrock alongside anthropic and ollama in the --provider description" do
      description = described_class.commands.fetch("chat").options.fetch(:provider).description
      expect(description).to match(/anthropic/).and match(/ollama/).and match(/bedrock/)
    end

    it "still scopes the --api-base description to ollama" do
      description = described_class.commands.fetch("chat").options.fetch(:api_base).description
      expect(description).to match(/ollama/i)
      expect(description).not_to match(/bedrock/i)
    end
  end

  # T1 AC6: the chat toolset closes the memory loop -- the model can read
  # back, through memory_read, what it wrote through the SAME toolset's
  # memory_write, because both tools share the one session Recorder.
  describe "the chat toolset" do
    let(:recorder) { Lain::Memory::Recorder.new }
    # The research subagent this toolset wires in builds its own provider
    # eagerly (AnthropicRaw validates ANTHROPIC_API_KEY at construction, unlike
    # the SDK client it replaced there -- see T17w), so building the toolset
    # at all needs a key present even though nothing here makes a request.
    let(:chat_toolset) do
      ask_human = Lain::Tools::AskHuman.new(parent: -> {})
      with_env("ANTHROPIC_API_KEY" => "sk-test") do
        wiring.send(:build_toolset, recorder, backend: backend(provider: "anthropic"),
                                              parent: -> {}, journal: Lain::Channel.new, ask_human:)
      end
    end

    it "contains a memory_read tool" do
      expect(chat_toolset.names).to include("memory_read")
    end

    it "reads back an id written through the same toolset's memory_write" do
      written = chat_toolset.fetch("memory_write")
                            .call({ "id" => "aspirin-dosing",
                                    "description" => "Aspirin dosing bounds for adults",
                                    "body" => "81mg to 325mg daily" })
      expect(written.ok?).to be(true)

      read = chat_toolset.fetch("memory_read").call({ "id" => "aspirin-dosing" })
      expect(read.ok?).to be(true)
      expect(read.content).to eq("81mg to 325mg daily")
    end
  end

  # T13: the session-record lifecycle lives in Lain::CLI::Chronicle (see its
  # spec); the exe only wires it. A directly-constructed CLI instance still
  # memoizes the Null chronicle (its #chronicle reader), and Wiring drives the
  # assembly seams over that same Null duck, so build_toolset/build_agent
  # record nothing and need no chronicle setup here.
  describe "the chronicle seam" do
    it "defaults a bare instance to the Null chronicle" do
      expect(cli.send(:chronicle)).to be_a(Lain::CLI::Chronicle::Null)
    end

    it "wires the chronicle's (empty, for Null) turn middleware into build_agent" do
      agent = wiring.send(:build_agent, toolset:, channel:, session: Lain::Session.new,
                                        backend: backend(provider: "ollama", model: nil, max_tokens: 4096))
      expect(agent.instance_variable_get(:@turn_middleware).to_a).to eq([])
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
