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

    it "constructs a Provider::AnthropicRaw for --provider anthropic" do
      provider = with_env("ANTHROPIC_API_KEY" => "sk-test") do
        backend_for(provider: "anthropic").provider
      end
      expect(provider).to be_a(Lain::Provider::AnthropicRaw)
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

    # A missing key used to reach AnthropicRaw's own eager check and backtrace
    # as Provider::HTTP::ConfigurationError -- a plain StandardError the exe's
    # `rescue Lain::Error` does not catch. This refuses BEFORE construction, as
    # a named Lain error, so the exe's clean mapping applies here too.
    it "fails loudly on a missing ANTHROPIC_API_KEY with a named Lain error, not a raw backtrace class" do
      with_env("ANTHROPIC_API_KEY" => nil) do
        expect { backend_for(provider: "anthropic").provider }
          .to raise_error(Lain::CLI::Backend::MissingAPIKey, /ANTHROPIC_API_KEY.*--provider anthropic/m)
      end
    end

    it "raises a Lain::Error for a missing key too (so the exe's rescue presents it cleanly)" do
      expect(Lain::CLI::Backend::MissingAPIKey).to be < Lain::Error
    end
  end

  # T17w's convergence: "anthropic" always means {Provider::AnthropicRaw} for
  # chat now, whether or not journaling is on -- the spool no longer switches
  # provider CLASS, only whether the spool it's handed is Null (--no-journal,
  # bench's no-spool-at-all default) or a real tee (journaling on). Class
  # identity alone is now vacuous (every branch here builds AnthropicRaw), so
  # these pin the ACTUAL spool object reaching the built provider -- the same
  # ivar-inspection idiom the Ollama --api-base example above uses.
  describe "#provider spool threading" do
    it "still constructs AnthropicRaw with the default Null spool when none is given at all" do
      provider = with_env("ANTHROPIC_API_KEY" => "sk-test") { backend_for(provider: "anthropic").provider }
      expect(provider).to be_a(Lain::Provider::AnthropicRaw)
      expect(provider.instance_variable_get(:@retries).instance_variable_get(:@spool))
        .to be_a(Lain::Provider::Spool::Null)
    end

    it "constructs AnthropicRaw with the given Null spool -- --no-journal's answer" do
      spool = Lain::Provider::Spool::Null.new
      provider = with_env("ANTHROPIC_API_KEY" => "sk-test") do
        backend_for(provider: "anthropic").provider(spool:)
      end
      expect(provider).to be_a(Lain::Provider::AnthropicRaw)
      expect(provider.instance_variable_get(:@retries).instance_variable_get(:@spool)).to be(spool)
    end

    it "carries the SAME spool object into AnthropicRaw when journaling hands in a real one" do
      spool = Lain::Provider::ResponseWal.new("/tmp/lain-backend-spec-session.wal")
      provider = with_env("ANTHROPIC_API_KEY" => "sk-test") do
        backend_for(provider: "anthropic").provider(spool:)
      end
      expect(provider).to be_a(Lain::Provider::AnthropicRaw)
      expect(provider.instance_variable_get(:@retries).instance_variable_get(:@spool)).to be(spool)
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

  # CE-5: the RAW provider emits retry and stream_started events onto its
  # `channel:`. Chat's live TTY Channel must be that channel or the frontend
  # never sees a stream start; the headless/bench paths (no channel given)
  # keep the Null channel default, so nothing is emitted where nothing drains.
  describe "#provider channel threading" do
    it "threads the given live Channel into AnthropicRaw so stream_started reaches it" do
      channel = Lain::Channel.new
      provider = with_env("ANTHROPIC_API_KEY" => "sk-test") do
        backend_for(provider: "anthropic").provider(channel:)
      end
      expect(provider.instance_variable_get(:@channel)).to be(channel)
    end

    it "defaults to the Null channel when none is given (headless/bench stay quiet)" do
      provider = with_env("ANTHROPIC_API_KEY" => "sk-test") do
        backend_for(provider: "anthropic").provider
      end
      expect(provider.instance_variable_get(:@channel)).to be(Lain::Channel::Null.instance)
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

  # RES4: the exe's research subagent used to hand-assemble a SpawnPolicy
  # inline (exe/lain:293-297) instead of naming a catalog role, so the child's
  # capability set could drift from {Lain::Role::Catalog}'s own idea of what
  # "researcher" means. #spawn_policy resolves through the catalog instead --
  # the same "one seam decides" shape #provider and #context already give
  # --provider and --model.
  describe "#spawn_policy" do
    # SpawnPolicy's `prefix`/`posture` normalize to freshly-built strategy
    # objects (PrefixStrategy::Fresh.new, AttenuationPosture::Schema.new) with
    # no custom `==`, so two structurally-identical policies are NOT `==` by
    # Data's generated equality (it falls through to Object#==, i.e. identity)
    # -- comparing the policy "field-for-field" means comparing each field's
    # own value (a strategy's `#label`, and `only`), not `==` on the whole.
    it "matches today's inline research policy field-for-field: fresh, schema, read_file+list_files" do
      resolved = backend.spawn_policy(:researcher)

      expect(resolved.prefix.label).to eq("fresh")
      expect(resolved.posture.label).to eq("schema")
      expect(resolved.only).to eq(%w[read_file list_files])
    end

    it "comes from Role::Catalog.fetch, not a parallel construction -- attenuates identically" do
      union = Lain::Toolset.new([Lain::Tools::ReadFile.new, Lain::Tools::ListFiles.new, Lain::Tools::EditFile.new])

      resolved = backend.spawn_policy(:researcher)
      cataloged = Lain::Role::Catalog.fetch(:researcher).spawn_policy

      expect(resolved.attenuate(union).names).to eq(cataloged.attenuate(union).names)
    end

    it "fails loudly on an uncataloged role name, naming the catalog (Role::Catalog's own refusal)" do
      expect { backend.spawn_policy(:chef) }
        .to raise_error(Lain::Role::Catalog::Unknown, /chef.*researcher/m)
    end
  end

  # RES4's escalation trigger: Context#cache_marked always marks the LAST
  # system block, and CacheBreakpoints budgets exactly ONE system cache slot
  # (the T24 follow-up) -- Anthropic's cache_control cap is 4 breakpoints, so
  # a second system mark here is a live 400 risk, not a style nit. A role's
  # prelude is TWO segments (the shared bulk, then the role tail --
  # {Lain::Role#prelude_segments}); rendering them as two ordinary text
  # blocks -- neither pre-marked -- through Context must spend that ONE mark
  # on the tail and leave the bulk unmarked, not double it. This spec is the
  # guard: if it ever found two marked blocks, that is the recorded risk, and
  # spending it is the orchestrator's call, not this glue's.
  describe "a role prelude rendered through Context spends exactly one cache mark" do
    let(:store) { Lain::Store.new }
    let(:timeline) do
      Lain::Timeline.empty(store:)
                    .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
    end

    it "marks exactly one system block, not one per prelude segment" do
      role = Lain::Role::Catalog.fetch(:researcher)
      bulk, tail = role.prelude_segments(slots: backend.slots)
      context = Lain::Context.new(
        model: "probe", max_tokens: 64,
        system: [{ "type" => "text", "text" => bulk }, { "type" => "text", "text" => tail }]
      )

      request = context.render(timeline:, toolset: Lain::Toolset.new)
      marked = request.system.select { |block| block["cache"] }

      expect(marked.size).to eq(1)
      expect(marked.first["text"]).to eq(tail)
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
