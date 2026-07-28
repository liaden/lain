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
    # `pinned?` too: the per-turn path asks the Session which turns compaction
    # may not elide (B2), and a verifying double answers only what it declares.
    let(:session) { instance_double(Lain::Session, plan_step_completed?: false, pinned?: false) }
    let(:profile) { Lain::CacheProfile::ANTHROPIC }
    let(:toolset) { Lain::Toolset.new([]) }

    def compacting_backend(**overrides)
      backend_for(provider: "anthropic", model: "claude-opus-4-8", max_tokens: 64, **overrides)
    end

    def source_for(**overrides)
      compacting_backend(**overrides).pipeline_source(cache_profile: profile, journal:)
    end

    # A WELL-FORMED conversation -- alternating from `user` -- and substantial
    # enough that a rewrite actually SHRINKS it (Source#shrinks? refuses one
    # that would not).
    #
    # It used to be a run of `user` turns each carrying an orphan
    # `tool_result`, which the Messages API would reject outright. That was
    # invisible while compaction was a render-time projection and is not now:
    # {Compaction::Derivation} validates the chain it derives through
    # {Context::Conversation} and REFUSES an invalid one, so an ill-formed
    # fixture measures a compaction that never happens (`compacted: false`,
    # nothing raised). Tool blocks moved out with the orphans: the tier that
    # keys on them is exercised in `spec/lain/compaction/source_spec.rb`, and
    # what this file is about is which flags reach which collaborator.
    def history(size)
      (1..size).inject(Lain::Timeline.empty(store: Lain::Store.new)) do |line, index|
        body = "result number #{index}: #{"the quick brown fox jumped over the lazy dog. " * 20}"
        line.commit(role: index.odd? ? "user" : "assistant", content: [{ "type" => "text", "text" => body }])
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
    #
    # C1 moved the lookup off construction and onto the render, so the raise
    # lands on the first TURN rather than at startup -- later, but no quieter,
    # which is the ruling. The Source is built here without incident; the turn
    # is what refuses.
    it "refuses a blank --model loudly on the first turn rather than falling back" do
      backend = backend_for(provider: "ollama", model: "  ", max_tokens: 64)
      source = backend.pipeline_source(cache_profile: profile, journal:)

      expect { source.context_for(base: backend.context, timeline: history(2), usage: nil, session:) }
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

    # T9. `--compact-strategy` is DECLARED by exe/lain and RESOLVED by
    # CLI::CompactionStrategy; this is the seam that reads it. Without this call
    # site the flag ships parsed and consumed by nobody -- F7's "unwired in
    # production" pattern, and the exact direction `chat_flags_spec.rb` cannot
    # see (it fails on read-but-undeclared, never on declared-but-unread).
    describe "--compact-strategy" do
      def strategy_of(backend)
        source_for_backend(backend).instance_variable_get(:@derived).instance_variable_get(:@strategy)
      end

      def source_for_backend(backend) = backend.pipeline_source(cache_profile: profile, journal:)

      it "resolves the named strategy and injects it into the Source" do
        expect(strategy_of(compacting_backend(compact_strategy: "elide")))
          .to be_a(Lain::Compaction::Strategy::Elide)
      end

      it "builds the summarizing strategy over a RECORDED oracle, never a bare model tier" do
        strategy = strategy_of(compacting_backend(compact_strategy: "summarizing", provider: "ollama"))

        expect(strategy).to be_a(Lain::Compaction::Strategy::Summarizing)
        expect(strategy.instance_variable_get(:@oracle)).to be_a(Lain::Oracle::Recorded::Journaling)
      end

      it "refuses an unknown name as a Lain::Error, naming the flag and the valid set" do
        expect { source_for_backend(compacting_backend(compact_strategy: "vibes")) }
          .to raise_error(Lain::CLI::CompactionStrategy::Unknown, /--compact-strategy.*summarizing/m)
      end

      # An UNSET flag is deliberately not CompactionStrategy::DEFAULT: the
      # un-flagged run keeps the eager tier it already fires and snapshots, and
      # naming a strategy is what opts into the seam. See {SpanSummarizer}.
      it "leaves the un-flagged run on its own eager tier rather than resolving a default" do
        expect(strategy_of(compacting_backend)).to be_nil
      end

      # The tier a down summarizer reports through. With the Null sink "the
      # summarizer is unreachable" and "compaction is off" are the same silence.
      it "threads the run's sink into the strategy" do
        sink = Lain::Sink::Null.new
        backend = compacting_backend(compact_strategy: "summarizing", provider: "ollama")
        strategy = backend.pipeline_source(cache_profile: profile, journal:, sink:)
                          .instance_variable_get(:@derived).instance_variable_get(:@strategy)

        expect(strategy.instance_variable_get(:@sink)).to be(sink)
      end

      # Resolved ONCE, with the memoized Source. #pipeline_source raises Rebound
      # on a differing second call and a model-backed strategy holds a memo, so
      # a strategy fetched per turn would be a second, disconnected one.
      it "resolves the strategy once for the run" do
        backend = compacting_backend(compact_strategy: "elide")

        expect(strategy_of(backend)).to be(strategy_of(backend))
      end
    end
  end

  # A1. The eager summarizer is a SELECTABLE tier now, not a hardcoded local
  # one, and its spend lands on the record. Before this, #summary_oracle built a
  # bare Oracle::Model over Ollama and wrapped nothing, so eager summary Q&A
  # produced no Telemetry::OracleAnswer at all on the live chat path -- pointing
  # it at a paid model would have spent tokens with no trace of the spend.
  #
  # The default is unchanged (local Ollama, its own default model): what changed
  # is that the choice is a flag resolved through the SAME validated PROVIDERS
  # set the chat tier uses, so `--summarizer-provider` cannot mean something
  # `--provider` does not.
  describe "#summary_oracle" do
    let(:journal) { RecordingChannel.new }

    def summarizer_for(**overrides) = backend_for(provider: "ollama", max_tokens: 64, **overrides)

    # The journaling wrap is OUTERMOST (A3 slots a router above it), so the live
    # tier that actually pays is one layer in.
    # The nesting the run is wired in: RoutedSummarizer(Journaling(Model)).
    def journaling_of(backend) = backend.send(:summary_oracle).instance_variable_get(:@inner)
    def tier_of(backend) = journaling_of(backend).instance_variable_get(:@inner)

    # A local reply the summarizer schema accepts, priced with a REAL usage so
    # the journaled cost is a genuine count rather than the zero identity.
    def answering_provider
      reply = Lain::Response.new(content: [{ "type" => "text", "text" => %({"summary":"it listed three files"}) }],
                                 stop_reason: :end_turn,
                                 usage: Lain::Usage.new(input_tokens: 12, output_tokens: 7))
      Lain::Provider::Mock.new(responses: [reply])
    end

    def answers = journal.events.grep(Lain::Telemetry::OracleAnswer)

    it "defaults to today's local tier -- Provider::Ollama at its own default model" do
      tier = tier_of(summarizer_for)

      expect(tier.instance_variable_get(:@provider)).to be_a(Lain::Provider::Ollama)
      expect(tier.model).to eq(Lain::Provider::Ollama::DEFAULT_MODEL)
    end

    # A3: the router goes ABOVE the journaling wrap, not below it. Below, a
    # custom answer would be journaled as an oracle call some model was billed
    # for; above, it never reaches the record at all and a fallthrough is
    # journaled exactly once. The order is forced besides -- Recorded::Journaling
    # defines neither #model nor #usage, so the other nesting raises.
    it "wraps the journaled live tier in the routed summarizer, outermost" do
      expect(summarizer_for.send(:summary_oracle)).to be_a(Lain::Oracle::RoutedSummarizer)
      expect(journaling_of(summarizer_for)).to be_a(Lain::Oracle::Recorded::Journaling)
      expect(tier_of(summarizer_for)).to be_a(Lain::Oracle::Model)
    end

    # The project's own `.lain/summarizers.rb`, loaded once per oracle build.
    # Lain's own tree declares none, so the catalog is empty and every result
    # falls through -- which is exactly what the journaling examples below rely
    # on.
    it "routes through the project's declared summarizer catalog" do
      catalog = summarizer_for.send(:summary_oracle).instance_variable_get(:@catalog)

      expect(catalog).to be_a(Lain::Summarizer::Catalog)
      expect(catalog).to be_empty
    end

    # The point of the flag: compressing a tool result is a different job from
    # answering the conversation, so it gets its own tier. A local chat can buy
    # a better summarizer, and a frontier chat can keep summarizing for free.
    it "points the summarizer at a paid provider while the chat model stays local" do
      backend = summarizer_for(summarizer_provider: "anthropic")
      chat, summary = with_env("ANTHROPIC_API_KEY" => "sk-test") { [backend.provider, tier_of(backend)] }

      expect(chat).to be_a(Lain::Provider::Ollama)
      expect(summary.instance_variable_get(:@provider)).to be_a(Lain::Provider::AnthropicRaw)
      expect(summary.model).to eq(Lain::Provider::AnthropicRaw::DEFAULT_MODEL)
    end

    it "honors an explicit --summarizer-model over the tier provider's default" do
      expect(tier_of(summarizer_for(summarizer_model: "qwen3:8b")).model).to eq("qwen3:8b")
    end

    # Resolved through Backend#provider's own PROVIDERS set, not a second copy,
    # so the two flags cannot drift about what a provider name means. The
    # refusal names WHICH flag was wrong -- "provider" and "summarizer provider"
    # are different mistakes to make.
    it "refuses an unknown summarizer provider by name, naming the valid set" do
      expect { tier_of(summarizer_for(summarizer_provider: "notreal")) }
        .to raise_error(Lain::CLI::UnknownProvider,
                        /unknown summarizer provider "notreal", expected one of.*anthropic.*ollama/m)
    end

    it "still names the chat flag when --provider is the wrong one" do
      expect { summarizer_for(provider: "gemini").provider }
        .to raise_error(Lain::CLI::UnknownProvider, /unknown provider "gemini"/)
    end

    it "defaults the token ceiling to Oracle::Model::DEFAULT_MAX_TOKENS" do
      expect(tier_of(summarizer_for).instance_variable_get(:@max_tokens))
        .to eq(Lain::Oracle::Model::DEFAULT_MAX_TOKENS)
    end

    it "honors --summarizer-max-tokens" do
      expect(tier_of(summarizer_for(summarizer_max_tokens: 256)).instance_variable_get(:@max_tokens)).to eq(256)
    end

    # 0 is TRUTHY in Ruby, so #knob's `||` never falls back for it: a zero or
    # negative ceiling reaches Request#max_tokens, which only does Integer()
    # with no range check, and the provider 400s. Oracle::Eager's task boundary
    # then swallows that BY DESIGN, so the only symptom a user ever sees is
    # "compaction quietly stopped summarizing" -- exactly the silent failure
    # this card exists to end. Refused at the seam, the shape
    # {Compaction::Head#validated} already uses for keep_last.
    it "refuses a non-positive summarizer ceiling rather than 400ing silently later" do
      expect { summarizer_for(summarizer_max_tokens: 0) }
        .to raise_error(Lain::CLI::Backend::InvalidCeiling, /--summarizer-max-tokens must be positive, got 0/)
      expect { summarizer_for(summarizer_max_tokens: -1) }
        .to raise_error(Lain::CLI::Backend::InvalidCeiling, /got -1/)
    end

    # Named Lain error, not Head's bare ArgumentError: a bad flag is user error
    # and the exe's `rescue Lain::Error` is what turns it into a clean
    # Thor::Error instead of a backtrace -- {MissingAPIKey}'s own reasoning.
    it "raises a Lain::Error for a bad ceiling (so the exe presents it cleanly)" do
      expect(Lain::CLI::Backend::InvalidCeiling).to be < Lain::Error
    end

    # `--provider` refuses on EVERY run, because #provider always runs. The
    # summarizer flags did not: under --no-compact #tool_observer answers the
    # Null, #summary_oracle is never built, and #validated never ran -- so a
    # typo was accepted in exactly one configuration. An asymmetry a user hits
    # in only one mode is one they misread, so both flags are refused at
    # CONSTRUCTION, which is the one path every command takes.
    describe "under --no-compact, where no summarizer tier is ever built" do
      it "still refuses a typo'd --summarizer-provider" do
        expect { summarizer_for(compact: false, summarizer_provider: "notreal") }
          .to raise_error(Lain::CLI::UnknownProvider, /unknown summarizer provider "notreal"/)
      end

      it "still refuses a non-positive --summarizer-max-tokens" do
        expect { summarizer_for(compact: false, summarizer_max_tokens: 0) }
          .to raise_error(Lain::CLI::Backend::InvalidCeiling)
      end

      it "builds normally when both flags are well-formed" do
        expect(summarizer_for(compact: false).tool_observer).to be_a(Lain::Agent::ToolRunner::Observer::Null)
      end
    end

    # The bug this card fixes: a summarizer call is a model call, and a model
    # call that does not reach the Journal is spend the bench cannot see.
    it "journals a Telemetry::OracleAnswer carrying the model and a non-empty usage" do
      backend = summarizer_for
      allow(backend).to receive(:summarizer_provider).and_return(answering_provider)
      backend.pipeline_source(cache_profile: Lain::CacheProfile::NO_CACHING, journal:)

      Sync { backend.send(:summary_oracle).ask(source: "a tool result").await }

      expect(answers.last.oracle_digest).to eq(Lain::Oracle::Summarize.definition.digest)
      expect(answers.last.model).to eq(Lain::Provider::Ollama::DEFAULT_MODEL)
      expect(answers.last.usage).not_to be_empty
      expect(answers.last.usage).to include("input_tokens" => 12, "output_tokens" => 7)
      expect(answers.last.question).to include("a tool result")
    end

    # Nothing orders #tool_observer (which builds the one Eager, and with it the
    # oracle) against #pipeline_source (which binds the run's journal):
    # CompactionMount happens to reach the journal first only because a Hash
    # literal evaluates left to right. A wrap that captured its destination at
    # construction would hold Channel::Null for the whole run and journal
    # nothing, with nothing raising -- so the destination is resolved per EVENT.
    it "records a summary fired through an Eager built BEFORE the journal was bound" do
      backend = summarizer_for
      allow(backend).to receive(:summarizer_provider).and_return(answering_provider)
      oracle = backend.eager.instance_variable_get(:@oracle)
      backend.pipeline_source(cache_profile: Lain::CacheProfile::NO_CACHING, journal:)

      Sync { oracle.ask(source: "a tool result").await }

      expect(answers.size).to eq(1)
    end

    # And with no journal bound at all -- a bench path that never calls
    # #pipeline_source -- the wrap still answers, into the Null channel.
    it "answers with no journal bound at all, sending the record nowhere" do
      backend = summarizer_for
      allow(backend).to receive(:summarizer_provider).and_return(answering_provider)

      answer = Sync { backend.send(:summary_oracle).ask(source: "a tool result").await }

      expect(answer.summary).to eq("it listed three files")
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
