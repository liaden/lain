# frozen_string_literal: true

# Backend is the plain object the CLI's chat and bench-record paths BOTH resolve
# their provider and context through, extracted out of exe/lain so the
# provider/model/sampler resolution is unit-testable without a Thor instance and
# so a single seam decides what `--provider` means for every command. Errors
# here are Lain's, not Thor's: the exe layer maps {Lain::CLI::UnknownProvider} to
# a Thor::Error, but below the frontend an unknown provider is a plain Lain
# error (CLAUDE.md output/error discipline -- thor never crosses into lib/).
RSpec.describe Lain::CLI::Backend do
  subject(:backend) { described_class.new(options) }

  let(:options) { {} }

  def backend_for(**options) = described_class.new(options)

  describe "#provider" do
    it "constructs a Provider::Ollama honoring --api-base" do
      provider = backend_for(provider: "ollama", api_base: "http://localhost:11434").provider
      expect(provider).to be_a(Lain::Provider::Ollama)
      expect(provider.instance_variable_get(:@config).ollama_api_base).to eq("http://localhost:11434")
    end

    it "constructs a Provider::Anthropic for --provider anthropic" do
      provider = with_env("ANTHROPIC_API_KEY" => "sk-test") do
        backend_for(provider: "anthropic").provider
      end
      expect(provider).to be_a(Lain::Provider::Anthropic)
    end

    it "constructs a Provider::Bedrock for --provider bedrock" do
      provider = with_env("AWS_BEARER_TOKEN_BEDROCK" => "tok", "AWS_REGION" => "us-east-1") do
        backend_for(provider: "bedrock").provider
      end
      expect(provider).to be_a(Lain::Provider::Bedrock)
    end

    # The whole point of the extraction (AC2): an unknown name is a Lain error,
    # NOT Thor::Error -- the exe maps it. chat and record both resolve through
    # this one method, so they reject an unknown provider identically.
    it "fails loudly on an unknown provider with a named Lain error, not Thor::Error" do
      expect { backend_for(provider: "gemini").provider }
        .to raise_error(Lain::CLI::UnknownProvider, /unknown provider "gemini", expected one of.*anthropic.*ollama/m)
    end

    it "raises a Lain::Error (so the exe's Lain::Error rescue presents it cleanly)" do
      expect(Lain::CLI::UnknownProvider).to be < Lain::Error
    end
  end

  # T17's wiring obligation: the chronicle's response spool (real only when
  # journaling is on) threads into whichever backend can actually tee raw
  # bytes to it -- AnthropicRaw today. No caller here passes spool: at all
  # except the new examples, so the FIRST two tests above (bare #provider)
  # already prove the untouched default keeps returning the plain SDK client.
  describe "#provider spool threading" do
    it "still constructs the plain SDK client when no spool is given at all" do
      provider = with_env("ANTHROPIC_API_KEY" => "sk-test") { backend_for(provider: "anthropic").provider }
      expect(provider).to be_a(Lain::Provider::Anthropic)
    end

    it "constructs the plain SDK client when handed the Null spool -- --no-journal's answer" do
      provider = with_env("ANTHROPIC_API_KEY" => "sk-test") do
        backend_for(provider: "anthropic").provider(spool: Lain::Provider::Spool::Null.new)
      end
      expect(provider).to be_a(Lain::Provider::Anthropic)
    end

    it "switches to AnthropicRaw, carrying the spool, when journaling hands in a real one" do
      spool = Lain::Provider::ResponseWal.new("/tmp/lain-backend-spec-session.wal")
      provider = with_env("ANTHROPIC_API_KEY" => "sk-test") do
        backend_for(provider: "anthropic").provider(spool:)
      end
      expect(provider).to be_a(Lain::Provider::AnthropicRaw)
    end

    it "never hands ollama or bedrock the spool keyword -- their constructors don't accept it" do
      spool = Lain::Provider::ResponseWal.new("/tmp/lain-backend-spec-session.wal")

      expect { backend_for(provider: "ollama").provider(spool:) }.not_to raise_error
      expect do
        with_env("AWS_BEARER_TOKEN_BEDROCK" => "tok", "AWS_REGION" => "us-east-1") do
          backend_for(provider: "bedrock").provider(spool:)
        end
      end.not_to raise_error
    end
  end

  describe "#context" do
    it "defaults the model to the selected provider's own default" do
      expect(backend_for(provider: "ollama", model: nil, max_tokens: 1024).context.model)
        .to eq(Lain::Provider::Ollama::DEFAULT_MODEL)
    end

    it "defaults to Bedrock's model when --provider bedrock and no --model" do
      expect(backend_for(provider: "bedrock", model: nil, max_tokens: 1024).context.model)
        .to eq(Lain::Provider::Bedrock::DEFAULT_MODEL)
    end

    it "honors an explicit --model over the provider default" do
      expect(backend_for(provider: "ollama", model: "qwen3:8b", max_tokens: 1024).context.model).to eq("qwen3:8b")
    end

    it "renders the prompt slots into the system prompt by default" do
      expect(backend_for(provider: "ollama", max_tokens: 1024).context.system)
        .to eq(Lain::Prompt::Slots.load.render)
    end

    it "honors an explicit system override without touching the slots" do
      expect(backend_for(provider: "ollama", max_tokens: 1024).context(system_override: "BE TERSE").system)
        .to eq("BE TERSE")
    end
  end

  # The loaded Slots are exposed (not just the rendered String) so the bench
  # record path can emit ONE Telemetry::SlotFills built from the exact slots
  # #context rendered, without a second disk read.
  describe "#slots" do
    it "exposes the loaded Prompt::Slots" do
      expect(backend.slots).to be_a(Lain::Prompt::Slots)
    end

    it "loads the slots once and memoizes them" do
      expect(backend.slots).to be(backend.slots)
    end
  end

  # AC: --temperature 0 --seed 7 reach the sampler extra (Request#extra), but
  # NOT the Request digest -- a sampler knob is not a prompt.
  describe "temperature and seed threading" do
    let(:store) { Lain::Store.new }
    let(:timeline) do
      Lain::Timeline.empty(store:)
                    .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
    end

    def render(**options)
      backend_for(max_tokens: 1024, **options).context.render(timeline:, toolset: Lain::Toolset.new)
    end

    it "carries options.temperature 0 and options.seed 7 into the encoded Ollama payload" do
      request = render(provider: "ollama", model: nil, temperature: 0, seed: 7)
      payload = Lain::Provider::Ollama.new.encode(request)
      expect(payload[:options]).to include(temperature: 0, seed: 7)
    end

    it "renders a Request whose cache_payload is identical to the flagless render" do
      tuned = render(provider: "ollama", model: nil, temperature: 0, seed: 7)
      plain = render(provider: "ollama", model: nil, temperature: nil, seed: nil)
      expect(tuned.cache_payload).to eq(plain.cache_payload)
      expect(tuned).to have_same_digest_as(plain)
    end

    it "omits absent sampler keys entirely (0 is present, nil is not)" do
      request = render(provider: "ollama", model: nil, temperature: 0, seed: nil)
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
