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
    it "resolves the researcher policy from the catalog: fresh, schema, read + web egress" do
      resolved = backend.spawn_policy(:researcher)

      # The researcher gained the tier-1 web tools (web_fetch/web_search): a
      # deliberate capability grant, not tree-mutating, so the role stays a
      # read-and-fetch researcher with no edit/write. The policy resolves through
      # Role::Catalog, so this set tracks the catalog rather than a parallel list.
      expect(resolved.prefix.label).to eq("fresh")
      expect(resolved.posture.label).to eq("schema")
      expect(resolved.only).to eq(%w[read_file list_files web_fetch web_search])
    end

    it "comes from Role::Catalog.fetch, not a parallel construction -- attenuates identically" do
      union = Lain::Toolset.new([Lain::Tools::ReadFile.new, Lain::Tools::ListFiles.new, Lain::Tools::EditFile.new,
                                 Lain::Tools::WebFetch.new, Lain::Tools::WebSearch.new])

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

  # A8: everything the live-wiring chunk built converges here. `lain chat`
  # compacts by DEFAULT -- eager summaries when the local tier answers, honest
  # elision when it does not -- so these pin the factories the exe's flags
  # resolve through, including the memoization that makes them RUN state rather
  # than per-call values (#context is deliberately the opposite: a fresh Context
  # at six call sites).
  describe "compaction wiring" do
    let(:journal) { RecordingChannel.new }
    let(:session) { instance_double(Lain::Session, plan_step_completed?: false) }
    let(:profile) { Lain::CacheProfile::ANTHROPIC }
    let(:toolset) { Lain::Toolset.new([]) }

    def compacting_backend(**overrides)
      backend_for(provider: "anthropic", model: "claude-opus-4-8", max_tokens: 64, **overrides)
    end

    def source_for(**overrides)
      compacting_backend(**overrides).pipeline_source(cache_profile: profile, journal:)
    end

    # Substantial String-content tool_results: the shape SummarySnapshot keys a
    # summary on, and big enough that a rewrite actually SHRINKS the history
    # (Source#shrinks? refuses one that would not).
    def history(size)
      (1..size).inject(Lain::Timeline.empty(store: Lain::Store.new)) do |line, index|
        body = "result number #{index}: #{"the quick brown fox jumped over the lazy dog. " * 20}"
        line.commit(role: "user",
                    content: [{ "type" => "tool_result", "tool_use_id" => "call-#{index}", "content" => body }])
      end
    end

    # One backend, one source, one turn -- the shape the live path takes.
    def decide(timeline, usage: nil, cache_profile: profile, **overrides)
      backend = compacting_backend(**overrides)
      backend.pipeline_source(cache_profile:, journal:)
             .context_for(base: backend.context, timeline:, usage:, session:)
    end

    def decisions = journal.events.grep(Lain::Compaction::Source::CompactionDecision)

    it "builds a live compaction Source when no compaction flags are given at all" do
      expect(source_for).to be_a(Lain::Compaction::Source)
    end

    it "builds the Null source under --no-compact" do
      expect(source_for(compact: false)).to be(Lain::Agent::PipelineSource::Null)
    end

    # AC2's second half: with compaction off, the turn's Context is the base
    # ITSELF, so the Request is byte-identical to one rendered with no source
    # wired at all -- not merely equivalent.
    it "renders byte-identically to an unwired Context under --no-compact" do
      backend = compacting_backend(compact: false)
      timeline = history(8)
      base = backend.context

      turn = backend.pipeline_source(cache_profile: profile, journal:)
                    .context_for(base:, timeline:, usage: nil, session:)

      expect(turn).to be(base)
      expect(Lain::Canonical.dump(turn.render(timeline:, toolset:).cache_payload))
        .to eq(Lain::Canonical.dump(base.render(timeline:, toolset:).cache_payload))
    end

    # The Observer is the PRODUCTION mount (summarizing.rb:38-45): it and the
    # Summarizing decorator are alternatives, never both against one Eager --
    # #fire consumes the digest before spawning, so whichever fires first spends
    # it and the other misses forever.
    it "wires the Summarizing::Observer over the one Eager the source reads" do
      backend = compacting_backend

      expect(backend.tool_observer).to be_a(Lain::Effect::Handler::Summarizing::Observer)
      expect(backend.tool_observer.instance_variable_get(:@eager)).to be(backend.eager)
      expect(backend.pipeline_source(cache_profile: profile, journal:)
                    .instance_variable_get(:@eager)).to be(backend.eager)
    end

    it "observes nothing under --no-compact -- no summary is ever read, so none is fired" do
      expect(compacting_backend(compact: false).tool_observer).to be_a(Lain::Agent::ToolRunner::Observer::Null)
    end

    # AC6. Cold's accumulated warmth and the Eager's fired summaries are run
    # state: a factory rebuilt per call resets both, silently, every turn.
    it "builds the source, the eager, and the observer once per run" do
      backend = compacting_backend

      expect(backend.pipeline_source(cache_profile: profile, journal:))
        .to be(backend.pipeline_source(cache_profile: profile, journal:))
      expect(backend.eager).to be(backend.eager)
      expect(backend.tool_observer).to be(backend.tool_observer)
    end

    # The other half of that memo, and the half that could hurt: a memoized
    # factory answers its FIRST caller's arguments forever. With one wiring
    # site that is a cache hit; a second, DIFFERING call would silently hand
    # back a Source bound to the first journal, and every compaction decision
    # would land in Channel::Null with nothing failing -- the precise
    # silent-degrade shape this chunk exists to end. So it is loud.
    describe "a second, differing call" do
      it "refuses one that would bind a different journal" do
        backend = compacting_backend
        backend.pipeline_source(cache_profile: profile, journal:)

        expect { backend.pipeline_source(cache_profile: profile) }
          .to raise_error(Lain::CLI::Backend::Rebound, /pipeline_source/)
      end

      it "refuses one that would bind a different cache profile" do
        backend = compacting_backend
        backend.pipeline_source(cache_profile: profile, journal:)

        expect { backend.pipeline_source(cache_profile: Lain::CacheProfile::NO_CACHING, journal:) }
          .to raise_error(Lain::CLI::Backend::Rebound, /cache profile/i)
      end

      # The guard is about the BINDING, not about what got built, so it holds
      # on the Null branch too -- where the arguments are ignored entirely and
      # a mis-wiring would otherwise be even harder to see.
      it "refuses one under --no-compact as well, where the arguments are unused" do
        backend = compacting_backend(compact: false)
        backend.pipeline_source(cache_profile: profile, journal:)

        expect { backend.pipeline_source(cache_profile: profile) }
          .to raise_error(Lain::CLI::Backend::Rebound)
      end

      it "names a Lain::Error, so the exe presents it cleanly rather than as a backtrace" do
        expect(Lain::CLI::Backend::Rebound).to be < Lain::Error
      end
    end

    # AC4. `--provider ollama` and `--provider bedrock` name models no
    # Anthropic-shaped window table can carry, so ContextWindow.default falls
    # back rather than raising -- an unsupported provider must still START.
    # Proven behaviorally: 7_500 used tokens is under 0.9 of every real entry
    # and over 0.9 of the 8_192 fallback, so only the fallback makes the signal
    # fire here.
    it "builds against the conservative fallback window for a model in no table, and chat starts" do
      backend = backend_for(provider: "ollama", model: "qwen3:4b", max_tokens: 64,
                            compact_keep: 1, compact_bytes: 10_000_000)
      source = backend.pipeline_source(cache_profile: Lain::CacheProfile::NO_CACHING, journal:)

      source.context_for(base: backend.context, timeline: history(6), usage: 7_500, session:)

      expect(decisions.last.signals).to eq([:approaching_window])
      expect(decisions.last.compacted).to be(true)
    end

    # A nil or blank --model is a WIRING bug, not an unsupported provider, and
    # ContextWindow says so loudly (context_window.rb:104-108) rather than
    # degrading to a fallback that would silently never fire.
    it "refuses a blank --model loudly rather than falling back" do
      expect { backend_for(provider: "ollama", model: "  ", max_tokens: 64).pipeline_source(cache_profile: profile) }
        .to raise_error(Lain::ContextWindow::UnknownModel, /wiring bug/)
    end

    # AC5.
    it "schedules against an overridden byte threshold" do
      decide(history(6), compact_bytes: 200, compact_keep: 1)

      expect(decisions.last.signals).to include(:token_threshold)
    end

    it "leaves the default threshold far above a short history, so a fresh chat does not compact" do
      decide(history(6), compact_keep: 1)

      expect(decisions.last.signals).to be_empty
      expect(decisions.last.compacted).to be(false)
    end

    # The decision lands on EVERY turn, deferring ones included: Agent#render_request
    # delegates to a collaborator that reports nothing back, so this record is the
    # only trace the choice was made -- and on a bench whose deliverable is
    # comparability, an unrecorded decision is a missing measurement.
    it "journals a decision even when it defers" do
      decide(history(3), compact_keep: 1)

      expect(decisions.size).to eq(1)
      expect(decisions.last.compacted).to be(false)
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
end
