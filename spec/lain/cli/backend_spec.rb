# frozen_string_literal: true

require "tmpdir"

# Backend is the plain object the CLI's chat and bench-record paths BOTH resolve
# their provider and context through, extracted out of exe/lain so the
# provider/model/sampler resolution is unit-testable without a Thor instance and
# so a single seam decides what `--provider` means for every command. Errors
# here are Lain's, not Thor's: the exe layer maps {Lain::CLI::UnknownProvider} to
# a Thor::Error, but below the frontend an unknown provider is a plain Lain
# error (CLAUDE.md output/error discipline -- thor never crosses into lib/).
RSpec.describe Lain::CLI::Backend do
  subject(:backend) { described_class.new(options, root: Dir.pwd) }

  let(:options) { {} }

  # A Backend on `--provider ollama` asks its server which window it is
  # SERVING before it builds the run's book ({Backend#context_window}), so
  # every ollama example here now makes one GET. The default answer is "nothing
  # resident", which is both the ordinary state of a fresh box and the answer
  # that leaves {ContextWindow::CONSERVATIVE_FALLBACK} in charge -- so an
  # example that is not about the window measures exactly what it did before.
  # An example that IS about it declares its own stub, which WebMock prefers
  # (the most recently registered match wins).
  before do
    stub_request(:get, %r{/api/ps})
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: JSON.generate("models" => []))
  end

  # `root:` is the Backend's own required keyword, not one of the flags, so it
  # is peeled off the options bag here -- a spec that passed it inside the bag
  # would be exercising an unread Hash key.
  def backend_for(root: Dir.pwd, **options) = described_class.new(options, root:)

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

    # Bedrock reused ANTHROPIC, so removing it is the moment that profile could
    # silently lose its last hosted reader: the surviving arm has to still report
    # the real numbers a compaction scheduler prices a cache read with.
    it "reports the Anthropic cache profile for --provider anthropic" do
      provider = with_env("ANTHROPIC_API_KEY" => "sk-test") { backend_for(provider: "anthropic").provider }

      expect(provider.cache_profile).to equal(Lain::CacheProfile::ANTHROPIC)
    end

    # Bedrock is gone, and a name that was once valid is the one an operator is
    # likeliest to still have in a script or an `.envrc`: the refusal has to say
    # what to type instead, not merely that the name is unknown.
    it "refuses --provider bedrock, naming the providers that are supported" do
      expect { backend_for(provider: "bedrock").provider }
        .to raise_error(Lain::CLI::UnknownProvider,
                        /unknown provider "bedrock", expected one of.*anthropic.*ollama.*ollama-cloud/m)
    end

    it "does not offer bedrock among the providers --provider selects between" do
      expect(Lain::CLI::Backend::PROVIDERS).not_to include("bedrock")
    end

    # The whole point of the extraction: an unknown name is a Lain error,
    # NOT Thor::Error -- the exe maps it. chat and record both resolve through
    # this one method, so they reject an unknown provider identically.
    it "fails loudly on an unknown provider with a named Lain error, not Thor::Error" do
      expect { backend_for(provider: "gemini").provider }
        .to raise_error(Lain::CLI::UnknownProvider, /unknown provider "gemini", expected one of.*anthropic.*ollama/m)
    end

    it "raises a Lain::Error (so the exe's Lain::Error rescue presents it cleanly)" do
      expect(Lain::CLI::UnknownProvider).to be < Lain::Error
    end

    # A missing key used to reach Anthropic's own eager check and backtrace
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

    # The refusal must name the flag that SELECTED this arm. Pre-existing, and
    # made reachable at launch rather than at the first compaction by the
    # pre-flight's new summarizer enumeration -- so an operator who typed
    # `--summarizer-provider anthropic` was told to change `--provider`.
    it "names --summarizer-provider when that is the flag that asked for anthropic" do
      with_env("ANTHROPIC_API_KEY" => "") do
        expect { backend_for(provider: "ollama", summarizer_provider: "anthropic").summarizer_provider }
          .to raise_error(Lain::CLI::Backend::MissingAPIKey, /--summarizer-provider anthropic needs it/)
      end
    end

    it "still names --provider when that is the flag that asked" do
      with_env("ANTHROPIC_API_KEY" => "") do
        expect { backend_for(provider: "anthropic").provider }
          .to raise_error(Lain::CLI::Backend::MissingAPIKey, /--provider anthropic needs it/)
      end
    end
  end

  # The arm is selected by a PROVIDER NAME rather than by a boolean `--cloud`,
  # and that is what makes it reachable from `lain bench arms` / `lain bench
  # record`: both build their Backend from the model flag band, whose profile
  # carries `provider` and has no field a boolean could ride in on. These
  # examples drive the same seam that band does.
  describe "the ollama-cloud arm" do
    def with_key(value = "sk-ollama-test", &) = with_env("OLLAMA_API_KEY" => value, &)

    it "is a name --provider accepts" do
      expect(Lain::CLI::Backend::PROVIDERS).to include("ollama-cloud")
    end

    it "builds a provider resolving the cloud endpoint" do
      provider = with_key { backend_for(provider: "ollama-cloud").provider }
      expect(provider).to be_a(Lain::Provider::Ollama)
      expect(provider.send(:resolved_endpoint)).to eq("https://ollama.com")
    end

    # Same claim the anthropic and ollama arms already carry: a round trip that
    # queues for capacity has to reach the run's record.
    it "hands the cloud provider the run's journal" do
      provider = with_key { backend_for(provider: "ollama-cloud").provider }
      expect(provider.send(:wait_journal)).to be_a(Lain::CLI::Backend::Summarizer::RunJournal)
    end

    it "leaves the local arm resolving loopback" do
      expect(backend_for(provider: "ollama").provider.send(:resolved_endpoint)).to eq("http://localhost:11434")
    end

    # BEFORE the chronicle opens, with `--api-base` and `--num-ctx`: the one
    # path every command takes, so the refusal cannot depend on which
    # collaborator a given run happens to build.
    it "refuses a missing OLLAMA_API_KEY at construction, not at the first turn" do
      with_env("OLLAMA_API_KEY" => nil) do
        expect { backend_for(provider: "ollama-cloud") }
          .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey,
                          %r{OLLAMA_API_KEY is not set.*settings/keys}m)
      end
    end

    it "refuses a plaintext --api-base at construction, naming the key as the reason" do
      with_key do
        expect { backend_for(provider: "ollama-cloud", api_base: "http://ollama.example") }
          .to raise_error(Lain::CLI::Backend::PlaintextEndpoint, /OLLAMA_API_KEY/)
      end
    end

    it "names an api base with no host precisely, without claiming a scheme is required" do
      expect { backend_for(provider: "ollama", api_base: "http://") }
        .to raise_error(Lain::CLI::Backend::InvalidEndpoint) { |error|
          expect(error.message).to include("has no host")
          expect(error.message).not_to include("scheme is required")
        }
    end

    it "still refuses a malformed --api-base as a flag error rather than a cloud one" do
      with_key do
        expect { backend_for(provider: "ollama-cloud", api_base: "localhost:11434") }
          .to raise_error(Lain::CLI::Backend::InvalidEndpoint)
      end
    end

    it "refuses nothing about the cloud for a local run with a plaintext base" do
      with_env("OLLAMA_API_KEY" => nil) do
        expect { backend_for(provider: "ollama", api_base: "http://localhost:11434") }.not_to raise_error
      end
    end

    describe "the default model" do
      it "defaults a cloud run to a cloud model" do
        expect(with_key { backend_for(provider: "ollama-cloud").model })
          .to eq(Lain::CLI::Backend::OllamaTier::CLOUD_DEFAULT_MODEL)
      end

      it "leaves a local run on qwen3:4b" do
        expect(backend_for(provider: "ollama").model).to eq("qwen3:4b")
      end

      # The summarizer tier is LOCAL by default and must stay local when the
      # chat is on the cloud -- the names differ, so it resolves the local
      # arm's own default rather than inheriting the chat's cloud model.
      it "keeps the summarizer tier on the local default when the chat is on the cloud" do
        expect(with_key { backend_for(provider: "ollama-cloud").summarizer_model }).to eq("qwen3:4b")
      end

      # #model is read per turn by #context, WindowBook and
      # Compaction::Source#window_for. It must not be able to raise about a
      # credential, so it must not build a tier at all.
      it "answers #model on a cloud backend built while a key existed, after the key is gone" do
        backend = with_key { backend_for(provider: "ollama-cloud") }
        expect(with_env("OLLAMA_API_KEY" => nil) { backend.model }).to eq("gpt-oss:20b-cloud")
      end
    end

    # BLOCKER 1. `--api-base` is ONE flag and there are TWO tiers that can be
    # ollama. Handing the chat's base to a tier built for the summarizer's name
    # sent OLLAMA_API_KEY, as a bearer token, to a host the operator chose for
    # the other arm -- silently, because every value involved was valid alone.
    # THE WHOLE RULE, as a table, because the first version of it was wrong in a
    # direction no single example would have caught: it closed the leak and
    # silently moved a LOCAL summarizer off the host `--api-base` named, which
    # is a regression on the path this card promised not to touch. Every row is
    # here so that changing the rule cannot quietly change one of them --
    # DEFAULT_SUMMARIZER_PROVIDER is "ollama", so most operators are in the
    # anthropic row without ever typing `--summarizer-provider`.
    describe "which arm --api-base reaches" do
      internal = "http://my-ollama.internal:11434"
      # The cloud row needs its own, because an http base on a cloud CHAT arm is
      # refused at construction and no summarizer is ever reached -- which is
      # itself the plaintext rule doing its job, not a gap in this table.
      secure = "https://my-ollama.internal"

      # chat provider => [the --api-base, where the DEFAULT summarizer resolves, why]
      [
        # The base is the chat's own, and the summarizer shares the arm.
        ["ollama", internal, internal, "one ollama arm, and it is the chat's"],
        # NO --summarizer-provider is typed in either of these two: the default
        # is "ollama", so the summarizer is the only ollama-shaped arm there is
        # and the flag is plainly for it. This is the row the first rule broke.
        ["anthropic", internal, internal, "the only ollama arm there is"],
        [nil, internal, internal, "a hand-built Backend naming no chat provider"],
        # --provider names an ollama arm, so the base is THAT arm's. Nothing is
        # lost: the chat provider receives it, as the example below this pins.
        ["ollama-cloud", secure, "http://localhost:11434", "the base belongs to the cloud arm"]
      ].each do |chat_provider, base, expected, why|
        it "resolves the default summarizer at #{expected} for --provider #{chat_provider.inspect} (#{why})" do
          backend = with_key { backend_for(provider: chat_provider, api_base: base, max_tokens: 64) }
          expect(with_key { backend.summarizer_provider }.send(:resolved_endpoint)).to eq(expected)
        end
      end

      # The row above, from the other side: the base the cloud CHAT arm claimed
      # is a base it actually uses. "Not the summarizer's" would be a hollow
      # claim if it turned out to be nobody's.
      it "gives the cloud chat arm the base its summarizer was denied" do
        backend = with_key { backend_for(provider: "ollama-cloud", api_base: secure, max_tokens: 64) }
        expect(with_key { backend.provider }.send(:resolved_endpoint)).to eq(secure)
      end

      # The leak row, which needs an explicit --summarizer-provider to reach.
      it "does not reach a cloud summarizer beside a chat that named a different ollama arm" do
        backend = with_key do
          backend_for(provider: "ollama", api_base: "https://internal.example",
                      summarizer_provider: "ollama-cloud")
        end
        expect(with_key { backend.summarizer_provider }.send(:resolved_endpoint)).to eq("https://ollama.com")
      end

      it "never lets the bearer header and that host meet" do
        backend = with_key do
          backend_for(provider: "ollama", api_base: "https://internal.example",
                      summarizer_provider: "ollama-cloud")
        end
        provider = with_key { backend.summarizer_provider }
        headers = provider.instance_variable_get(:@transport).headers
        expect(headers["Authorization"]).to include("sk-ollama-test")
        expect(provider.send(:resolved_endpoint)).not_to include("internal.example")
      end

      # The chat arm always keeps it, on every row above.
      it "still reaches the chat arm itself" do
        backend = backend_for(provider: "ollama", api_base: "http://127.0.0.1:11500")
        expect(backend.provider.send(:resolved_endpoint)).to eq("http://127.0.0.1:11500")
      end

      it "still reaches the chat arm when the chat IS the cloud one" do
        backend = with_key { backend_for(provider: "ollama-cloud", api_base: "https://ollama.example") }
        expect(with_key { backend.provider }.send(:resolved_endpoint)).to eq("https://ollama.example")
      end

      # THE ROW THAT LOOKS LIKE THE LEAK AND IS NOT, kept explicit because a
      # future reader will otherwise rediscover the alarm and "fix" it.
      # `--provider anthropic --api-base X --summarizer-provider ollama-cloud`
      # sends the bearer token to X -- and should: there is exactly ONE
      # ollama-shaped arm, so X can only ever have been meant for it (a proxy
      # in front of ollama.com is the real case). What made the actual leak a
      # leak was that `--provider ollama` named a DIFFERENT arm which obviously
      # owned the flag. The guard here is the plaintext rule, not ownership.
      it "lets an explicit cloud summarizer use the base when it is the only ollama arm" do
        backend = with_key do
          backend_for(provider: "anthropic", api_base: "https://my-ollama.internal",
                      summarizer_provider: "ollama-cloud")
        end
        expect(with_key { backend.summarizer_provider }.send(:resolved_endpoint)).to eq("https://my-ollama.internal")
      end

      # And that guard fires on the reachable path, naming the flag the
      # operator actually typed -- which is what the flag being a FIELD buys.
      it "refuses a plaintext base for that same arm, naming --summarizer-provider" do
        with_key do
          expect do
            backend_for(provider: "anthropic", api_base: "http://my-ollama.internal:11434",
                        summarizer_provider: "ollama-cloud")
          end
            .to raise_error(Lain::CLI::Backend::PlaintextEndpoint, /--summarizer-provider ollama-cloud/)
        end
      end
    end

    # The summarizer flags are construction-time refusals whatever --no-compact
    # says -- `summarizer_max_tokens` already is -- so `lain up` cannot open a
    # pane that dies at the first compaction.
    describe "the summarizer arm's own refusals" do
      it "refuses a cloud summarizer with no key, at construction" do
        with_env("OLLAMA_API_KEY" => nil) do
          expect { backend_for(provider: "ollama", summarizer_provider: "ollama-cloud") }
            .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, /OLLAMA_API_KEY/)
        end
      end

      it "refuses it under --no-compact too, matching --summarizer-max-tokens' own posture" do
        with_env("OLLAMA_API_KEY" => nil) do
          expect { backend_for(provider: "ollama", summarizer_provider: "ollama-cloud", compact: false) }
            .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey)
        end
      end

      it "builds a cloud summarizer when the key is there" do
        backend = with_key { backend_for(provider: "ollama", summarizer_provider: "ollama-cloud") }
        expect(with_key { backend.summarizer_provider }.send(:resolved_endpoint)).to eq("https://ollama.com")
      end
    end
  end

  # THE CONVERGENCE: "anthropic" always means {Provider::Anthropic} for
  # chat now, whether or not journaling is on -- the spool no longer switches
  # provider CLASS, only whether the spool it's handed is Null (--no-journal,
  # bench's no-spool-at-all default) or a real tee (journaling on). Class
  # identity alone is now vacuous (every branch here builds Anthropic), so
  # these pin the ACTUAL spool object reaching the built provider -- the same
  # ivar-inspection idiom the Ollama --api-base example above uses.
  describe "#provider spool threading" do
    it "still constructs Anthropic with the default Null spool when none is given at all" do
      provider = with_env("ANTHROPIC_API_KEY" => "sk-test") { backend_for(provider: "anthropic").provider }
      expect(provider).to be_a(Lain::Provider::Anthropic)
      expect(provider.instance_variable_get(:@retries).instance_variable_get(:@spool))
        .to be_a(Lain::Provider::Spool::Null)
    end

    it "constructs Anthropic with the given Null spool -- --no-journal's answer" do
      spool = Lain::Provider::Spool::Null.new
      provider = with_env("ANTHROPIC_API_KEY" => "sk-test") do
        backend_for(provider: "anthropic").provider(spool:)
      end
      expect(provider).to be_a(Lain::Provider::Anthropic)
      expect(provider.instance_variable_get(:@retries).instance_variable_get(:@spool)).to be(spool)
    end

    it "carries the SAME spool object into Anthropic when journaling hands in a real one" do
      spool = Lain::Provider::ResponseWal.new("/tmp/lain-backend-spec-session.wal")
      provider = with_env("ANTHROPIC_API_KEY" => "sk-test") do
        backend_for(provider: "anthropic").provider(spool:)
      end
      expect(provider).to be_a(Lain::Provider::Anthropic)
      expect(provider.instance_variable_get(:@retries).instance_variable_get(:@spool)).to be(spool)
    end

    # This was INVERTED. Ollama used to be listed here as a provider whose
    # constructor took no spool, and "not_to raise_error" was the whole
    # assertion -- which is also what a silently DISCARDED spool looks like.
    # Now the ollama arm is metered and must actually receive it, so the
    # assertion is on the object, not on the absence of an exception.
    it "carries the SAME spool object into the ollama arm, which is now metered" do
      spool = Lain::Provider::ResponseWal.new("/tmp/lain-backend-spec-session.wal")
      provider = backend_for(provider: "ollama").provider(spool:)

      expect(provider).to be_a(Lain::Provider::Ollama)
      expect(provider.instance_variable_get(:@retries).instance_variable_get(:@spool)).to be(spool)
    end
  end

  # The RAW provider emits retry and stream_started events onto its
  # `channel:`. Chat's live TTY Channel must be that channel or the frontend
  # never sees a stream start; the headless/bench paths (no channel given)
  # keep the Null channel default, so nothing is emitted where nothing drains.
  describe "#provider channel threading" do
    it "threads the given live Channel into Anthropic so stream_started reaches it" do
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

    # The unwired-in-production check, and the assertion the other two in this
    # group cannot make: those read an ivar, which stays green whether or not
    # the keyword was ever threaded HERE. It drives the production chain -- Backend
    # -> Provider::Ollama -> #build_config's retry_block -> faraday-retry ->
    # the run's channel -- because a keyword accepted with a safe default and
    # never wired ships nothing, greenly. Ollama used to be the one arm whose
    # retries reached no Journal at all; the QA run's >400s silent hang is what
    # that cost.
    it "threads the live channel into ollama, so a retried ollama request is journaled" do
      stub_request(:post, "http://localhost:11434/api/chat")
        .to_raise(Faraday::ConnectionFailed).then
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate("model" => "qwen3:4b", "done" => true, "done_reason" => "stop",
                                       "message" => { "role" => "assistant", "content" => "pong" }))
      channel = RecordingChannel.new
      # The SHIPPED retry envelope, sleeps included (~0.1s for the one retry):
      # this example is about the wiring Backend performs, and shaping the
      # envelope would mean handing in a config, which is exactly the bypass
      # that would stop it proving anything.
      provider = backend_for(provider: "ollama").provider(channel:)

      response = provider.complete(Lain::Request.new(model: "qwen3:4b", max_tokens: 64, stream: false,
                                                     messages: [{ role: "user", content: "hi" }]))

      expect(response.text).to eq("pong")
      expect(channel.events.grep(Lain::Telemetry::ProviderRetry).map(&:attempt)).to eq([1])
    end
  end

  # The ONE denominator this run divides by. The POC published 86.4%
  # occupancy at 2.7% of the real capacity -- the numerator was exact and only
  # the window was wrong -- because every reader defaulted to
  # {ContextWindow.default}'s 8,192 conservative fallback for an ollama model
  # id no Anthropic-shaped table carries. The book is built HERE, once, out of
  # the window {Provider#context_window_tokens} says the server is
  # actually serving, and the status feed, the compaction source and the Agent
  # all read this one instance -- so `state.json`, the journal and the REPL
  # prompt cannot tell a human three different stories.
  #
  # {Backend::WindowBook} does the resolving and is exercised HERE rather than
  # in a file of its own, as {Backend::Ceiling} and {Backend::Summarizer} are:
  # what it resolves is three of Backend's own flags against Backend's own
  # provider, so every example below would have to build a Backend anyway, and
  # the memoization these readers depend on is Backend's.
  describe "#context_window" do
    let(:model) { "qwen3-coder:30b" }

    def ps_entry(name, context_length)
      { "name" => name, "model" => name, "size" => 18_000_000_000,
        "digest" => "abc123", "context_length" => context_length }
    end

    def serving(*entries)
      stub_request(:get, "http://localhost:11434/api/ps")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate("models" => entries))
    end

    def ollama_backend(**overrides) = backend_for(provider: "ollama", model:, max_tokens: 64, **overrides)

    # Measured with the POC's own numerator. 7,079 tokens is 86.4% of 8,192 and
    # 21.6% of the window actually being served -- the whole defect, as one
    # number.
    it "measures a turn against the window the server says it is serving" do
      serving(ps_entry(model, 32_768))

      expect(ollama_backend.context_window.occupancy(7_079, model:).ratio).to eq(7_079.fdiv(32_768))
    end

    # nil is the ORDINARY answer here (nothing resident yet, or no server
    # at all), so the fallback has to stand rather than degrade further.
    it "keeps the conservative fallback when the provider reports no window" do
      serving

      expect(ollama_backend.context_window.occupancy(7_079, model:).ratio)
        .to eq(7_079.fdiv(Lain::ContextWindow::CONSERVATIVE_FALLBACK))
    end

    # The served window is the run's MODEL's, and every other name falls back to
    # what that model's own book says rather than inheriting a window measured
    # for a different runner.
    it "leaves every other model on the shipped table" do
      serving(ps_entry(model, 32_768))
      book = ollama_backend.context_window

      expect(book.window_tokens("claude-opus-4-8")).to eq(1_000_000)
      expect(book.window_tokens("some-other-local:7b")).to eq(Lain::ContextWindow::CONSERVATIVE_FALLBACK)
    end

    # The SUBSTRING trap, which a merged-key book fails silently and 4-8x in the
    # forbidden direction. `ContextWindow#matched` falls back to
    # `name.include?(token)` over every key, so a served window merged into the
    # table becomes a prefix rule for every LATER model name -- and untagged
    # ollama names that are prefixes of tagged ones are the ordinary case, not a
    # contrived one: ollama prints the resident runner as `qwen3:latest` and
    # `Ollama#runs?` matches the untagged `qwen3` an operator typed. A
    # mid-session `/model qwen3-coder:30b` then measured 32,768 against a real
    # 8,192. Exact identity is the only rule a served window can carry, because
    # the server answered about one runner.
    it "never lends the run's served window to a model that merely contains its name" do
      serving(ps_entry("qwen3:latest", 32_768))
      book = backend_for(provider: "ollama", model: "qwen3", max_tokens: 64).context_window

      expect(book.window_tokens("qwen3")).to eq(32_768)
      expect(book.window_tokens("qwen3-coder:30b")).to eq(Lain::ContextWindow::CONSERVATIVE_FALLBACK)
      expect(book.window_tokens("qwen3:4b")).to eq(Lain::ContextWindow::CONSERVATIVE_FALLBACK)
      expect(book.window_tokens("qwen3-tiny:0.5b")).to eq(Lain::ContextWindow::CONSERVATIVE_FALLBACK)
    end

    # The other half of that rule, and the asymmetry it has to avoid: the book is
    # GRANTED through `Ollama#runs?`, which matches an untagged `--model qwen3`
    # against the `qwen3:latest` a server prints back -- so a window can exist
    # BECAUSE of a name a narrower spending rule then refuses to answer for.
    # That splits the two surfaces by one tag, because Agent#occupancy divides
    # using the operator's string while StatusFeed divides using the model the
    # response echoed. One set grants and spends.
    it "spends the window by the same names Ollama#runs? granted it by" do
      serving(ps_entry("qwen3:latest", 32_768))
      book = backend_for(provider: "ollama", model: "qwen3", max_tokens: 64).context_window

      expect(book.window_tokens("qwen3")).to eq(32_768)
      expect(book.window_tokens("qwen3:latest")).to eq(32_768)
    end

    # A blank `--model` is a WIRING bug and ContextWindow is loud about one.
    # `--num-ctx` resolves a window with NO server involved, so a blank model
    # otherwise reached the book with a real number beside it and the loudness
    # was swallowed -- the one path on which a served book must refuse to answer
    # for its own model.
    it "still refuses a blank --model loudly, even when --num-ctx resolved a window alone" do
      serving
      book = backend_for(provider: "ollama", model: "  ", max_tokens: 64, num_ctx: 16_384).context_window

      expect { book.window_tokens("  ") }.to raise_error(Lain::ContextWindow::UnknownModel, /wiring bug/)
    end

    # One book, one probe: the three readers must divide by the same number,
    # and asking three times could answer three different ones across a reload.
    it "answers the same book to every reader, off a single probe" do
      serving(ps_entry(model, 32_768))
      backend = ollama_backend

      expect(backend.context_window).to be(backend.context_window)
      expect(a_request(:get, "http://localhost:11434/api/ps")).to have_been_made.once
    end

    # {Provider#context_window_tokens}'s docstring makes this constraint the
    # CALLER's, and sending `num_ctx` on the request made it live: a runner left
    # at 32,768 by `ollama run` or by a sibling session answers 32,768 while the
    # very next request -- carrying --num-ctx -- reloads it at the smaller size.
    describe "--num-ctx" do
      it "outranks a larger served window" do
        serving(ps_entry(model, 32_768))

        expect(ollama_backend(num_ctx: 16_384).context_window.window_tokens(model)).to eq(16_384)
      end

      # The forbidden direction, refused: answering the LARGER of the two
      # over-estimates the window, and an over-estimate means
      # `approaching_window` never fires at all -- worse than the crash the
      # conservative fallback replaces.
      it "never lifts the window above what the server reports" do
        serving(ps_entry(model, 32_768))

        expect(ollama_backend(num_ctx: 65_536).context_window.window_tokens(model)).to eq(32_768)
      end

      # THE SECOND HALF of this CHANGED deliberately. The number stands --
      # discarding a plausible `--num-ctx` would over-report 4x on the ordinary
      # `--num-ctx 32768` case -- but nobody measured it, so it is a guess and
      # not the tier whose docstring says "the server said so". Measured before
      # the split: `--num-ctx 999999` journaled `provenance="probed"` while
      # ollama served 262,144.
      it "stands alone when the provider reports nothing, as a guess" do
        serving
        resolution = ollama_backend(num_ctx: 16_384).context_window.resolve(model)

        expect(resolution.window_tokens).to eq(16_384)
        expect(resolution.provenance).to eq(Lain::ContextWindow::GUESSED)
        expect(resolution).not_to be_authoritative
      end

      # `0` is TRUTHY, so nothing downstream fell back for it: it was sent
      # verbatim as the request's `num_ctx` AND adopted as the run's
      # denominator, where it killed the chat mid-turn with `ArgumentError:
      # window_tokens must be a positive Integer, got 0` out of
      # Compaction::Need. `--num-ctx` is `type: :numeric` with no range check
      # and EnvDefaults.numeric only rejects non-numbers, so `LAIN_NUM_CTX=0`
      # in an .envrc was that crash for every session in the directory.
      #
      # Refused, never filtered: a silently-ignored `--num-ctx 0` would be the
      # other half of the same failure, and the operator would never learn the
      # flag did nothing.
      it "refuses a zero at CONSTRUCTION, in the flag's own name" do
        expect { ollama_backend(num_ctx: 0) }
          .to raise_error(Lain::CLI::Backend::InvalidCeiling, /--num-ctx must be positive, got 0/)
      end

      it "refuses a negative the same way" do
        expect { ollama_backend(num_ctx: -1) }
          .to raise_error(Lain::CLI::Backend::InvalidCeiling, /--num-ctx must be positive/)
      end

      # Construction is the one path every command takes, so the refusal cannot
      # depend on which collaborator a given run happens to build -- `bench
      # record` never asks for a window book at all and still sends the flag.
      it "refuses before anything asks for a window or a payload" do
        expect { ollama_backend(num_ctx: 0) }.to raise_error(Lain::CLI::Backend::InvalidCeiling)
        expect(a_request(:get, %r{/api/ps})).not_to have_been_made
      end

      # UNSET is a real answer -- "serve the model's own" -- and must not trip
      # the ceiling {Ceiling} refuses for an omitted `--max-tokens`.
      it "accepts being unset, which is not the omission a ceiling refuses" do
        serving(ps_entry(model, 32_768))

        expect(ollama_backend.context_window.window_tokens(model)).to eq(32_768)
      end

      it "is a Lain::Error, so the exe presents it cleanly rather than as a backtrace" do
        expect(Lain::CLI::Backend::InvalidCeiling).to be < Lain::Error
      end

      # An operator's `--num-ctx` is a REQUEST, and there is exactly one
      # number it can be checked against before a runner exists: the maximum
      # the weights were trained for. `--num-ctx 999999` on a model trained to
      # 262,144 was accepted, sent, and journaled as the run's whole window
      # while ollama quietly served 262,144.
      #
      # The trained figure arrives through {Provider#trained_context_tokens},
      # which is a separate accessor for a reason spelled out at both ends: it
      # is a ceiling for refusing a flag and never a denominator. If it ever
      # becomes the second, the 8x under-report this area exists to prevent is
      # back one layer up.
      describe "above what the model can ever serve" do
        def trained(context_length)
          stub_request(:post, "http://localhost:11434/api/show")
            .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                       body: JSON.generate("model_info" => {
                                             "general.architecture" => "qwen3moe",
                                             "qwen3moe.context_length" => context_length
                                           }))
        end

        it "is a Lain::Error, so the exe presents it cleanly rather than as a backtrace" do
          expect(Lain::CLI::Backend::UnservableWindow).to be < Lain::Error
        end

        # Construction is the one path every command takes, `lain up`'s
        # pre-flight among them, and the trained maximum is a fact only a
        # running server has -- so this question cannot be asked here at all.
        it "opens no socket at construction" do
          show = trained(262_144)

          ollama_backend(num_ctx: 32_768)

          expect(show).not_to have_been_requested
        end

        it "refuses at the first window resolution, naming the flag, the value and the maximum" do
          trained(262_144)
          backend = ollama_backend(num_ctx: 999_999)

          expect { backend.context_window }
            .to raise_error(Lain::CLI::Backend::UnservableWindow,
                            "--num-ctx 999999 is above the model's trained maximum of 262144; " \
                            "no runner can serve a window larger than the weights were trained for")
        end

        # A refusal deferred to a reader is a refusal a reader can make TWICE:
        # the window book re-resolves at the top of every turn. The refusal
        # repeats, the round trip must not.
        it "asks the server once however many times the window is re-resolved" do
          show = trained(262_144)
          backend = ollama_backend(num_ctx: 999_999)

          2.times do
            expect { backend.context_window }.to raise_error(Lain::CLI::Backend::UnservableWindow)
          end

          expect(show).to have_been_requested.once
        end

        # The path every real run takes, and the one nothing covered: a REFUSED
        # window re-probing is loud, an ACCEPTED one re-probing is not.
        # {Middleware::ResolveWindow}'s re-resolution is the driver here, as it
        # is in a turn.
        it "asks the server once on the accept path too" do
          show = trained(262_144)
          window = ollama_backend(num_ctx: 32_768).context_window

          2.times { window.reresolve }

          expect(show).to have_been_requested.once
        end

        # The window book is resolved before the first turn is rendered, so a
        # refused launch still never reaches a chat -- and it must not have
        # opened one on the way to deciding.
        it "starts no chat" do
          trained(262_144)
          backend = ollama_backend(num_ctx: 999_999)

          expect { backend.context_window }.to raise_error(Lain::CLI::Backend::UnservableWindow)
          expect(a_request(:post, "http://localhost:11434/api/chat")).not_to have_been_made
        end

        # The boundary, both sides. Equal is servable -- it is exactly what the
        # weights allow -- and an off-by-one here would refuse the very flag an
        # operator reads off `/api/show` and types in.
        it "accepts a value at the trained maximum" do
          trained(262_144)

          expect { ollama_backend(num_ctx: 262_144).context_window }.not_to raise_error
        end

        it "accepts a value below it" do
          trained(262_144)

          expect { ollama_backend(num_ctx: 32_768).context_window }.not_to raise_error
        end

        # Degrade, do not refuse. Only ollama publishes a trained maximum;
        # {Provider}'s base answers nil, and a provider that cannot say must
        # not block a launch -- so the refusal fires only where a ceiling is
        # known AND exceeded.
        it "does not block a launch on a provider that publishes no trained maximum" do
          expect do
            with_env("ANTHROPIC_API_KEY" => "sk-test") do
              backend_for(provider: "anthropic", model: "claude-opus-4-5", max_tokens: 64,
                          num_ctx: 999_999).context_window
            end
          end.not_to raise_error
        end

        # An ollama that is not running is the ordinary state of this arm, and
        # a launch that cannot be validated is not a launch that is wrong.
        it "does not block a launch when the server cannot answer" do
          stub_request(:post, "http://localhost:11434/api/show").to_raise(Faraday::ConnectionFailed)

          expect { ollama_backend(num_ctx: 999_999).context_window }.not_to raise_error
        end

        # A flag nobody set has nothing to check, and checking it anyway would
        # buy every `lain up` a round trip for a question it is not asking.
        it "asks no ceiling at all when --num-ctx is unset" do
          serving(ps_entry(model, 32_768))

          ollama_backend.context_window

          expect(a_request(:post, "http://localhost:11434/api/show")).not_to have_been_made
        end

        # The construction ORDER, which the ceiling's fix round made
        # user-visible and which nothing pinned: `--api-base` is validated
        # before `--num-ctx`, because a base URL a probe will talk to has to be
        # a usable one before a window is judged against it. Asserted through a
        # run that gets BOTH flags wrong, since that is the only case in which
        # the order is observable -- swap the two lines in `#initialize` and
        # this reads InvalidCeiling instead.
        it "refuses a bad --api-base before it asks that base for a ceiling" do
          expect { ollama_backend(api_base: "localhost:11434", num_ctx: 0) }
            .to raise_error(Lain::CLI::Backend::InvalidEndpoint, /--api-base "localhost:11434"/)
        end

        # `--num-ctx 0` is refused by {Ceiling} for being non-positive, and that
        # refusal has to come first: a zero is a flag mistake whatever the model
        # was trained to, and reordering would make the message depend on
        # whether a server happened to be up.
        it "still refuses a non-positive value in Ceiling's name, not this one" do
          trained(262_144)

          expect { ollama_backend(num_ctx: 0) }
            .to raise_error(Lain::CLI::Backend::InvalidCeiling, /--num-ctx must be positive/)
        end
      end
    end

    # Unlike an unknown --provider or a missing key (both below), a bad
    # `--api-base` is not a question #provider can defer -- Endpoint checks it
    # at CONSTRUCTION, same as --num-ctx above, because `localhost:11434` (the
    # scheme-less typo) is a VALID URI and used to sail past a URI.parse guard
    # straight into a bare Faraday NoMethodError on the first turn.
    describe "--api-base" do
      it "refuses a scheme-less base at CONSTRUCTION, in the flag's own name" do
        expect { ollama_backend(api_base: "localhost:11434") }
          .to raise_error(Lain::CLI::Backend::InvalidEndpoint, /--api-base "localhost:11434"/)
      end

      it "refuses a value that does not parse as a URI at all" do
        expect { ollama_backend(api_base: "not a url") }
          .to raise_error(Lain::CLI::Backend::InvalidEndpoint, /--api-base "not a url"/)
      end

      it "refuses before anything asks for a window or a payload" do
        expect { ollama_backend(api_base: "not a url") }.to raise_error(Lain::CLI::Backend::InvalidEndpoint)
        expect(a_request(:get, %r{/api/ps})).not_to have_been_made
      end

      # UNSET is a real answer -- "ollama's own default" -- and must not trip
      # the refusal a value with no usable scheme gets.
      it "accepts being unset" do
        serving(ps_entry(model, 32_768))

        expect(ollama_backend.context_window.window_tokens(model)).to eq(32_768)
      end

      it "is a Lain::Error, so the exe presents it cleanly rather than as a backtrace" do
        expect(Lain::CLI::Backend::InvalidEndpoint).to be < Lain::Error
      end
    end

    # A provider with no endpoint that reports a served window answers nil from
    # {Provider#context_window_tokens} without asking anything, so the book is
    # the shipped one and no probe is paid for.
    it "leaves a provider that cannot report a served window on the shipped book" do
      book = with_env("ANTHROPIC_API_KEY" => "sk-test") do
        backend_for(provider: "anthropic", model: "claude-opus-4-8", max_tokens: 64).context_window
      end

      expect(book.window_tokens("claude-opus-4-8")).to eq(1_000_000)
      expect(book.window_tokens("qwen3:4b")).to eq(Lain::ContextWindow::CONSERVATIVE_FALLBACK)
    end

    # A denominator lookup is not where a bad `--provider` or a missing key is
    # discovered. Both refusals belong to #provider's real callers, and raising
    # here would move them ahead of the chronicle open -- which is precisely
    # the ordering ChatLaunch keeps so a refusal never orphans a fresh journal.
    it "does not turn an unknown --provider into a refusal of its own" do
      backend = backend_for(provider: "gemini", model: "x", max_tokens: 64)

      expect(backend.context_window.window_tokens("x")).to eq(Lain::ContextWindow::CONSERVATIVE_FALLBACK)
      expect { backend.provider }.to raise_error(Lain::CLI::UnknownProvider)
    end

    # The same deferral with NO `--model` and a `--num-ctx` set, which is the
    # combination that reaches it: `#model` defaults THROUGH `#provider_name`,
    # so it raises `UnknownProvider` too, and a `--num-ctx` alone resolves a
    # window -- so the model name is asked for on the answering path, outside
    # any rescue, unless it is resolved once inside one. Both examples above
    # pin the provider message and neither could reach this.
    it "does not raise for a model resolved through an unknown --provider either" do
      backend = backend_for(provider: "gemini", max_tokens: 64, num_ctx: 16_384)

      expect(backend.context_window.window_tokens("x")).to eq(Lain::ContextWindow::CONSERVATIVE_FALLBACK)
      expect { backend.model }.to raise_error(Lain::CLI::UnknownProvider)
    end

    # This example was UPDATED deliberately: `--api-base "not a url"` used to be
    # a THIRD deferral -- a denominator lookup left `#provider` to raise
    # URI::InvalidURIError on its own request -- but that meant construction
    # SUCCEEDED for a base that could never serve a chat, and the same
    # scheme-less typo (`localhost:11434`) parsed as a valid URI and reached a
    # bare Faraday NoMethodError on the first real turn instead of ever
    # raising here at all. Unlike the two deferrals above, a bad `--api-base`
    # is now refused at CONSTRUCTION (see the "--api-base" examples above,
    # which is where {Backend::Endpoint} is actually exercised) -- there is no
    # backend left standing for #context_window or #provider to be asked
    # about one.
    it "refuses an unusable --api-base at construction, not as a deferred #provider failure" do
      expect { backend_for(provider: "ollama", model:, max_tokens: 64, api_base: "not a url") }
        .to raise_error(Lain::CLI::Backend::InvalidEndpoint, /--api-base "not a url"/)
    end

    it "does not turn a missing ANTHROPIC_API_KEY into a refusal of its own" do
      backend = with_env("ANTHROPIC_API_KEY" => "") do
        backend_for(provider: "anthropic", model: "claude-opus-4-8", max_tokens: 64).tap(&:context_window)
      end

      expect(backend.context_window.window_tokens("claude-opus-4-8")).to eq(1_000_000)
    end
  end

  describe "#context" do
    it "defaults the model to the selected provider's own default" do
      expect(backend_for(provider: "ollama", model: nil, max_tokens: 1024).context.model)
        .to eq(Lain::Provider::Ollama::DEFAULT_MODEL)
    end

    it "defaults to Anthropic's model when --provider anthropic and no --model" do
      expect(backend_for(provider: "anthropic", model: nil, max_tokens: 1024).context.model)
        .to eq(Lain::Provider::Anthropic::DEFAULT_MODEL)
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

    # `--max-tokens` has no default HERE (unlike --model, resolved above from the
    # provider) -- every command declaring the flag gives Thor one, so a nil means
    # a caller built this Backend and left the ceiling out. Backend is the single
    # authority on it now that Bench's own constants are flag declarations only,
    # so this is where it has to be caught: Context answers a nil with
    # `TypeError: can't convert nil into Integer`, which is not a Lain::Error, so
    # Boundary#render passes it through as a backtrace naming Context -- a class
    # no operator has heard of. Same wound MissingAPIKey and InvalidCeiling were
    # both written for; same error class as --summarizer-max-tokens'.
    it "refuses a missing ceiling as a Lain::Error naming the flag, never a TypeError from Context" do
      expect { backend_for(provider: "ollama").context }
        .to raise_error(Lain::CLI::Backend::InvalidCeiling, /--max-tokens is not set/)
    end

    it "refuses an explicit nil ceiling the same way an absent key is refused" do
      expect { backend_for(provider: "ollama", max_tokens: nil).context }
        .to raise_error(Lain::CLI::Backend::InvalidCeiling, /--max-tokens/)
    end

    # The two ceiling flags are two different mistakes to make, and one Ceiling
    # object now answers for both -- so the refusal has to name the one that was
    # actually wrong, or it sends the operator to the other flag.
    it "names --max-tokens, never the summarizer's flag, when the chat tier's is missing" do
      expect { backend_for(provider: "ollama").context }
        .to raise_error(Lain::CLI::Backend::InvalidCeiling) do |error|
          expect(error.message).not_to include("summarizer")
        end
    end
  end

  # The object both ceiling flags now go through. Exercised here rather than in a
  # file of its own, as Backend::Summarizer and Backend::SpanSummarizer are: the
  # flag NAME is the field that makes it worth extracting, and the two callers
  # above and below are what prove each flag keeps its own voice.
  describe Lain::CLI::Backend::Ceiling do
    def ceiling(value) = described_class.new(flag: "--flag", value:)

    it "answers the parsed ceiling for a positive value" do
      expect(ceiling(64).tokens).to eq(64)
      expect(ceiling("64").tokens).to eq(64)
    end

    it "refuses an unset ceiling, naming its own flag" do
      expect { ceiling(nil).tokens }
        .to raise_error(Lain::CLI::Backend::InvalidCeiling, /--flag is not set/)
    end

    # 0 is TRUTHY, so no `||` downstream falls back for it and Request#max_tokens
    # only does `Integer()` -- the provider is what 400s, three layers away.
    it "refuses zero and negative ceilings, quoting the value" do
      expect { ceiling(0).tokens }.to raise_error(Lain::CLI::Backend::InvalidCeiling, /--flag must be positive, got 0/)
      expect { ceiling(-1).tokens }.to raise_error(Lain::CLI::Backend::InvalidCeiling, /got -1/)
    end

    # Unchanged from the inline `Integer(knob(...))` this replaced: a non-numeric
    # ceiling is a parser or programmer bug, and stays a loud ArgumentError rather
    # than being dressed up as an operator's flag mistake.
    it "leaves an unparseable ceiling as the ArgumentError it always was" do
      expect { ceiling("wide").tokens }.to raise_error(ArgumentError)
    end
  end

  # The exe's research subagent used to hand-assemble a SpawnPolicy
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
    # A smoke check only: WHICH tools the researcher holds is pinned at the seam
    # that renders them (role_prelude_wiring_spec's "keeps the researcher
    # tree-read-only"), and the next example proves this method is that
    # catalog's delegate rather than a parallel construction. Re-listing the
    # only-set here just gave the catalog a second place to drift from.
    it "resolves the researcher policy from the catalog: fresh prefix, schema posture" do
      resolved = backend.spawn_policy(:researcher)

      expect([resolved.prefix.label, resolved.posture.label]).to eq(%w[fresh schema])
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

  # An escalation trigger: Context#cache_marked always marks the LAST
  # system block, and CacheBreakpoints budgets exactly ONE system cache slot --
  # Anthropic's cache_control cap is 4 breakpoints, so a second system mark here
  # is a live 400 risk, not a style nit. A role's
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

  # The slots are HALF a pair. This object is the one owner of both halves
  # now -- before, it owned the slots while Wiring separately owned the catalog,
  # and the two travelled onward as two keywords. One library, one read, one
  # owner; #slots is the library's, so the bench path's reader is unchanged.
  describe "#library" do
    it "exposes the session's ONE Skill::Library, memoized" do
      expect(backend.library).to be_a(Lain::Skill::Library)
      expect(backend.library).to be(backend.library)
    end

    it "answers #slots out of that library, so there is only one read of the tree" do
      expect(backend.slots).to be(backend.library.slots)
    end

    # Why the library cannot live in Wiring: the system prompt is rendered HERE,
    # from the slots half, at a point above every other reader.
    #
    # Asserted as the CHAIN (#context -> #slots -> library.slots) and not as `eq`
    # against a second render, because the two are not the same claim and the
    # weaker one is worthless here: the tree does not change between two reads,
    # so `eq` holds just as well when #context does its OWN Prompt::Slots.load --
    # which is precisely the bug this example's name denies. The review panel caught
    # that; the example survived the mutation it is named for.
    #
    # The reader is stubbed rather than the Slots instance because a Slots is
    # frozen and rspec-mocks refuses to proxy a frozen object. The last link of
    # the chain is pinned by the example above.
    it "renders the system prompt from the library's slots" do
      wired = backend_for(provider: "ollama", max_tokens: 1024)
      allow(wired).to receive(:slots).and_return(instance_double(Lain::Prompt::Slots, render: "SENTINEL-T40"))

      expect(wired.context.system).to eq("SENTINEL-T40")
    end
  end

  # `lain chat --root PATH` resolves a Project, and the library is the last
  # collaborator that was not handed its root: the load defaulted to the
  # working directory, so a chat launched from anywhere but the project's own
  # directory read somebody else's `.lain/slots` -- or, far more often, nobody's,
  # and rendered the shipped default while the operator's override sat unread.
  # The keyword is REQUIRED for that reason; these two pin what it buys.
  #
  # Tagged `:seam`, and they are this file's only two: a real {Lain::Skill::Library}
  # reads a real `.lain/slots` off a real disk and a real {Lain::Prompt::Slots}
  # renders it, with no double anywhere between the Backend and the bytes. That
  # is what makes them worth having -- and what makes them the examples a
  # `--tag '~seam'` inner loop should skip.
  describe "the root its .lain/ overrides are read from", :seam do
    # Two directories, and the second one is the whole claim: a project's
    # override has to reach the prompt from a working directory that is NOT it.
    def from_elsewhere(slot_name, body)
      Dir.mktmpdir("lain-rooted-project") do |project|
        Dir.mkdir(File.join(project, ".lain"))
        Dir.mkdir(File.join(project, ".lain", "slots"))
        File.write(File.join(project, ".lain", "slots", slot_name), body)
        Dir.mktmpdir("lain-elsewhere") { |elsewhere| Dir.chdir(elsewhere) { yield project } }
      end
    end

    it "carries a project's system slot into the system prompt from another directory" do
      rendered = from_elsewhere("system.md", "SENTINEL-ROOTED-SLOT") do |project|
        backend_for(provider: "ollama", max_tokens: 1024, root: project).context.system
      end

      expect(rendered).to include("SENTINEL-ROOTED-SLOT")
    end

    # The refusal half. A slot file nobody reads cannot refuse, so the typo's
    # loud failure is itself evidence the right tree was opened -- and it is the
    # failure an operator meets first when they misname the file they just wrote.
    it "refuses a slot filename no slot name matches, naming the file" do
      expect do
        from_elsewhere("sistem.md", "a typo for system.md") do |project|
          backend_for(provider: "ollama", max_tokens: 1024, root: project).slots
        end
      end.to raise_error(Lain::Prompt::UnknownSlot, /sistem\.md/)
    end
  end

  # Everything the live-wiring chunk built converges here. `lain chat`
  # compacts by DEFAULT -- eager summaries when the local tier answers, honest
  # elision when it does not -- so these pin the factories the exe's flags
  # resolve through, including the memoization that makes them RUN state rather
  # than per-call values (#context is deliberately the opposite: a fresh Context
  # at six call sites).
  describe "compaction wiring" do
    let(:journal) { RecordingChannel.new }
    # `pinned?` too: the per-turn path asks the Session which turns compaction
    # may not elide, and a verifying double answers only what it declares --
    # as it does the cuts a committed compaction holds, and the count its plan
    # step signal latches on.
    let(:session) do
      instance_double(Lain::Session, plan_step_completed?: false, pinned?: false, plan_step_completions: 0,
                                     compaction_cuts: [], record_compaction_cut: nil)
    end
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

    # The other half: with compaction off, the turn's Context is the base
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

    # The observer fires into the SAME Eager the pipeline source snapshots, or
    # every summary it fires is one no compaction can ever read.
    it "wires the SummaryObserver over the one Eager the source reads" do
      backend = compacting_backend

      expect(backend.tool_observer).to be_a(Lain::Compaction::SummaryObserver)
      expect(backend.tool_observer.eager).to be(backend.eager)
      expect(backend.pipeline_source(cache_profile: profile, journal:)
                    .eager).to be(backend.eager)
    end

    it "observes nothing under --no-compact -- no summary is ever read, so none is fired" do
      expect(compacting_backend(compact: false).tool_observer).to be_a(Lain::Agent::ToolRunner::Observer::Null)
    end

    # Cold's accumulated warmth and the Eager's fired summaries are run
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

    # `--provider ollama` names models no Anthropic-shaped window table can
    # carry, so ContextWindow.default falls back rather than raising -- an
    # unsupported provider must still START.
    # 7_500 used tokens is under 0.9 of every real entry and over 0.9 of the
    # 8_192 fallback, so this turn DOES cross the trigger ratio -- and the
    # trigger is withheld anyway, because a fallback is a guess and a guess may
    # not authorise an irreversible rewrite. That is the whole finding: the QA run
    # compacted three times at 75-78% of a real 32_768 window.
    #
    # The denominator and the provenance are both asserted rather than inferred
    # from the absent signal, because empty signals alone would also be
    # satisfied by any window >= 8_334.
    #
    # The provider-reported window made the fallback the SECOND answer rather
    # than the only one, so the silent server is now stated rather than assumed:
    # /api/ps answers with nothing resident, which is exactly when the
    # conservative fallback is still what a run measures against.
    it "builds against the conservative fallback window for a model in no table, and chat starts" do
      stub_request(:get, "http://localhost:11434/api/ps")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate("models" => []))
      backend = backend_for(provider: "ollama", model: "qwen3:4b", max_tokens: 64,
                            compact_keep: 1, compact_bytes: 10_000_000)
      source = backend.pipeline_source(cache_profile: Lain::CacheProfile::NO_CACHING, journal:)

      source.context_for(base: backend.context, timeline: history(6), usage: 7_500, session:)

      expect(decisions.last.signals).to eq([])
      expect(decisions.last.compacted).to be(false)
      expect(decisions.last.window_tokens).to eq(Lain::ContextWindow::CONSERVATIVE_FALLBACK)
      expect(decisions.last.provenance).to eq(Lain::ContextWindow::GUESSED)
    end

    # The same 7,500 tokens, against a server that says it is serving 32,768:
    # 22.9% full, so nothing fires. The signal is what MOVED, which is the
    # whole card -- the numerator never changed.
    it "measures the same turn against a served window, and does not fire" do
      stub_request(:get, "http://localhost:11434/api/ps")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate("models" => [{ "name" => "qwen3:4b", "model" => "qwen3:4b",
                                                      "context_length" => 32_768 }]))
      backend = backend_for(provider: "ollama", model: "qwen3:4b", max_tokens: 64,
                            compact_keep: 1, compact_bytes: 10_000_000)
      source = backend.pipeline_source(cache_profile: Lain::CacheProfile::NO_CACHING, journal:)

      source.context_for(base: backend.context, timeline: history(6), usage: 7_500, session:)

      expect(decisions.last.signals).to be_empty
      expect(decisions.last.window_tokens).to eq(32_768)
      expect(decisions.last.used_tokens).to eq(7_500)
    end

    # A nil or blank --model is a WIRING bug, not an unsupported provider, and
    # ContextWindow says so loudly (context_window.rb:104-108) rather than
    # degrading to a fallback that would silently never fire.
    #
    # The lookup moved off construction and onto the render, so the raise
    # lands on the first TURN rather than at startup -- later, but no quieter,
    # which is the ruling. The Source is built here without incident; the turn
    # is what refuses.
    it "refuses a blank --model loudly on the first turn rather than falling back" do
      stub_request(:get, "http://localhost:11434/api/ps")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate("models" => []))
      backend = backend_for(provider: "ollama", model: "  ", max_tokens: 64)
      source = backend.pipeline_source(cache_profile: profile, journal:)

      expect { source.context_for(base: backend.context, timeline: history(2), usage: nil, session:) }
        .to raise_error(Lain::ContextWindow::UnknownModel, /wiring bug/)
    end

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

    # `--compact-strategy` is DECLARED by exe/lain and RESOLVED by
    # CLI::CompactionStrategy; this is the seam that reads it. Without this call
    # site the flag ships parsed and consumed by nobody -- the "unwired in
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

    # `--compact-fallback` is an arm of the experiment, not a member of the run
    # profile: a resumed chat defaults its BACKEND to what the header recorded,
    # and a fallback is not a backend.
    describe "--compact-fallback" do
      def fallback_of(backend)
        backend.pipeline_source(cache_profile: profile, journal:).instance_variable_get(:@fallback)
      end

      it "wires the handoff fallback by default, with no flag given" do
        expect(fallback_of(compacting_backend)).to be_a(Lain::Compaction::Source::Fallback)
      end

      it "wires the Null fallback under none, so a refusal stands" do
        expect(fallback_of(compacting_backend(compact_fallback: "none")))
          .to be(Lain::Compaction::Source::Fallback::None)
      end

      # At CONSTRUCTION, on the summarizer flags' own rule: a typo that
      # resolved silently to "none" would show up only as an ask that died
      # where it should have been kept.
      it "refuses an unknown arm as a Lain::Error, naming the flag and the valid set" do
        expect { compacting_backend(compact_fallback: "vibes") }
          .to raise_error(Lain::CLI::Backend::UnknownFallback, /--compact-fallback.*handoff, none/m)
      end

      it "records the arm in the session header's compaction section" do
        expect(compacting_backend.compaction_header).to eq("compact_fallback" => "handoff")
        expect(compacting_backend(compact_fallback: "none").compaction_header)
          .to eq("compact_fallback" => "none")
      end

      # `--compact-strategy` is the OTHER comparability axis on the same
      # header -- `bench variance` groups recordings by it, so its name has to
      # travel onto the record, and its absence has to stay tellable from
      # "summarizing" rather than collapsing into it.
      it "also records a named --compact-strategy, verbatim, beside the fallback" do
        expect(compacting_backend(compact_strategy: "elide").compaction_header)
          .to eq("compact_fallback" => "handoff", "compact_strategy" => "elide")
      end

      it "writes no compact_strategy key when the flag is unset" do
        expect(compacting_backend.compaction_header).not_to have_key("compact_strategy")
        expect(compacting_backend(compact_fallback: "none").compaction_header).not_to have_key("compact_strategy")
      end

      # Built on FIRST USE. A chat that never hands off must not open a second
      # provider for a tier nothing asks. `no_args` is the signature: the
      # handoff tier waits for capacity, where the eager tier alone asks with
      # `queue: false` and is built eagerly as it always was.
      it "builds no handoff tier until one is asked for" do
        backend = compacting_backend(provider: "ollama", model: "qwen3:4b")
        allow(backend).to receive(:summarizer_provider).and_call_original

        fallback_of(backend)

        expect(backend).not_to have_received(:summarizer_provider).with(no_args)
      end

      it "builds the handoff tier over a RECORDED oracle, so a failure leaves oracle_failed" do
        backend = compacting_backend(provider: "ollama", model: "qwen3:4b")

        expect(backend.send(:handoff_oracle)).to be_a(Lain::Oracle::Recorded::Journaling)
      end

      # The question is sized to the window the SUMMARIZER answers in, which is
      # not the chat's: they are different models by default, and sizing a
      # local summarizer's input to a 1M-token Anthropic window would write an
      # input it cannot read.
      describe "the window the question is sized to" do
        it "resolves the summarizer's model, not the chat's" do
          backend = compacting_backend(summarizer_provider: "ollama", summarizer_model: "qwen3:4b")
          allow(backend.context_window).to receive(:resolve).and_call_original

          backend.send(:handoff_window)

          expect(backend.context_window).to have_received(:resolve).with("qwen3:4b")
        end

        # A book that cannot identify the model degrades to the conservative
        # window rather than guessing large, which is the whole reason the
        # budget stopped being a constant.
        it "falls back to the conservative window for a model nothing identifies" do
          backend = compacting_backend(summarizer_provider: "ollama", summarizer_model: "a-model-nobody-lists")

          expect(backend.send(:handoff_window)).to eq(Lain::ContextWindow::CONSERVATIVE_FALLBACK)
        end
      end
    end

    # The sink already reaches {SpanSummarizer}; what it did not reach is the
    # Source, which is the object that discovers a warranted compaction with
    # nothing to drop and could not say so. A hand-built Source proves nothing
    # about that wire, so this drives {CLI::CompactionMount} -- the one caller
    # that mints the run's diagnostics sink -- and reads the attribution off
    # the event a frontend would render.
    describe "an operator's report from a full, uncompactable context" do
      let(:surface) { RecordingChannel.new }

      def mounted(backend)
        Lain::CLI::CompactionMount.new(
          backend:, provider: Lain::Provider::Mock.new, channel: surface,
          chronicle: Lain::CLI::Chronicle.new(journal:, journal_path: "backend-spec-compaction.ndjson")
        ).instrumentation.pipeline_source
      end

      def reported = surface.events.grep(Lain::Telemetry::ToolOutput)

      # A REAL occupancy, not a one-byte threshold. The first draft of this
      # example lowered --compact-bytes so that `:token_threshold` fired over a
      # two-byte empty head, which exercised the wire and hid the fact that the
      # report fired on warrants that say nothing about a full window. The
      # fixture has to be the condition the report claims to be about: two
      # turns under the default keep_last of 20 leaves the head empty, and
      # 950,000 of this model's PUBLISHED 1,000,000-token window is over the
      # 0.9 ratio, so `:approaching_window` fires and survives #need_for.
      it "carries the report on the run's own channel, attributed to compaction" do
        backend = compacting_backend

        mounted(backend).context_for(base: backend.context, timeline: history(2), usage: 950_000, session:)

        expect(reported.map(&:tool_use_id)).to eq(["lain:compaction"])
        expect(reported.first.bytes).to include("compaction is warranted (approaching_window)")
      end

      # The same construction, one turn that is merely busy rather than full.
      # Without this the example above passes against a Source wired to report
      # on any signal at all, which is what it did.
      it "says nothing through that channel when the window is nowhere near full" do
        backend = compacting_backend

        mounted(backend).context_for(base: backend.context, timeline: history(2), usage: 10, session:)

        expect(reported).to be_empty
      end
    end
  end

  # {Backend#chat_name?} compares the RAW `--provider` value rather than
  # going through {Backend#provider_name}, and that is the one place in this
  # class that reads a provider flag outside the validated seam. The reason is
  # testable rather than merely argued, so it is tested: with no chat provider in
  # the hash there is nothing for the summarizer tier to be the SAME as, so it
  # answers its own tier's default instead of refusing about a flag it does not
  # read. Routing the comparison through `provider_name` -- the alternative --
  # leaves the rest of the suite green, so without these two examples the choice
  # is defended by prose alone.
  describe "#summarizer_model with no chat provider in the option hash" do
    it "resolves the summarizer tier without raising about --provider" do
      backend = backend_for(summarizer_provider: "ollama", model: "qwen3-coder:30b")

      expect { backend.summarizer_model }.not_to raise_error
      expect(backend.summarizer_model).to eq(Lain::Provider::Ollama::DEFAULT_MODEL)
    end

    # The other half, and why the first is not a hole: the missing flag is still
    # refused loudly by the tier that actually reads it.
    it "still refuses the chat tier itself, so the missing flag is not silently forgiven" do
      backend = backend_for(summarizer_provider: "ollama", model: "qwen3-coder:30b")

      expect { backend.provider }.to raise_error(Lain::CLI::UnknownProvider, /unknown provider nil/)
    end
  end

  # The eager summarizer is a SELECTABLE tier now, not a hardcoded local
  # one, and its spend lands on the record. Before this, #summary_oracle built a
  # bare Oracle::Model over Ollama and wrapped nothing, so eager summary Q&A
  # produced no Telemetry::OracleAnswer at all on the live chat path -- pointing
  # it at a paid model would have spent tokens with no trace of the spend.
  #
  # The default PROVIDER is unchanged (local Ollama), resolved through the SAME
  # validated PROVIDERS set the chat tier uses, so `--summarizer-provider` cannot
  # mean something `--provider` does not. The default MODEL is no longer fixed to
  # that provider's own: when both tiers name one provider it follows the chat's
  # `--model`, so the examples below that pin an Ollama chat read through the
  # inheritance branch and say so.
  describe "#summary_oracle" do
    let(:journal) { RecordingChannel.new }

    def summarizer_for(**overrides) = backend_for(provider: "ollama", max_tokens: 64, **overrides)

    # The journaling wrap is OUTERMOST (a router slots above it), so the live
    # tier that actually pays is one layer in.
    # The nesting the run is wired in: RoutedSummarizer(Journaling(Model)).
    def journaling_of(backend) = backend.send(:summary_oracle).instance_variable_get(:@inner)
    def tier_of(backend) = journaling_of(backend).instance_variable_get(:@inner)

    # The provider the tier will actually ASK, one decorator further in. It is
    # wrapped in {Lain::Provider::Journaled} so the round trip an oracle spends
    # reaches the Journal at all; WHICH arm answers is what these examples pin,
    # and that is the wrapped one.
    def provider_of(tier) = tier.instance_variable_get(:@provider).inner

    # A local reply the summarizer schema accepts, priced with a REAL usage so
    # the journaled cost is a genuine count rather than the zero identity.
    def answering_provider
      reply = Lain::Response.new(content: [{ "type" => "text", "text" => %({"summary":"it listed three files"}) }],
                                 stop_reason: :end_turn,
                                 usage: Lain::Usage.new(input_tokens: 12, output_tokens: 7))
      Lain::Provider::Mock.new(responses: [reply])
    end

    def answers = journal.events.grep(Lain::Telemetry::OracleAnswer)

    # The MODEL here arrives by inheritance, not by the tier's own default: an
    # ollama chat with `--model` unset resolves to Ollama's default, and the
    # summarizer shares its provider, so the two are the same string by two
    # different routes. What this example uniquely pins is the PROVIDER; the
    # tier's own default model is pinned by the cross-provider example below,
    # where nothing can be inherited.
    it "defaults to today's local tier -- Provider::Ollama, at the model the chat resolved" do
      tier = tier_of(summarizer_for)

      expect(provider_of(tier)).to be_a(Lain::Provider::Ollama)
      expect(tier.model).to eq(Lain::Provider::Ollama::DEFAULT_MODEL)
    end

    # The router goes ABOVE the journaling wrap, not below it. Below, a
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

    # Open decision 4, wired. The eager tier and the span summarizer call the
    # SAME `#summarizer_provider`, so the only thing that can tell them apart is
    # what each asks for -- and they need opposite answers. {Oracle::Eager}
    # promises the turn never waits on a summary (`oracle/eager.rb:45-47`), so a
    # busy endpoint must skip it; {Backend::SpanSummarizer} answers on the render
    # path, where the summary is worth waiting for.
    describe "willingness to queue for provider capacity" do
      def queue_flags_asked_of(backend)
        asked = []
        allow(backend).to receive(:summarizer_provider).and_wrap_original do |original, **kwargs|
          asked << kwargs.fetch(:queue, :not_passed)
          original.call(**kwargs)
        end
        yield backend
        asked
      end

      it "builds the eager tier's provider unwilling to queue" do
        backend = summarizer_for

        expect(queue_flags_asked_of(backend) { |b| tier_of(b) }).to eq([false])
      end

      it "leaves the span summarizer's provider willing to wait" do
        backend = summarizer_for
        span = Lain::CLI::Backend::SpanSummarizer.new(backend:, name: "summarize", sink: Lain::Sink::Null.new)

        flags = queue_flags_asked_of(backend) do
          span.send(:tier, Lain::Oracle::Summarize.definition)
        end

        expect(flags).to eq([:not_passed])
      end

      # The keyword has to reach the constructed provider, not merely be
      # accepted: a `#summarizer_provider` that swallowed it would satisfy the
      # two examples above and gate the eager oracle anyway.
      it "carries the flag into the provider it builds" do
        backend = summarizer_for
        impatient = backend.summarizer_provider(queue: false)

        expect(impatient.instance_variable_get(:@queue)).to be(false)
        expect(backend.summarizer_provider.instance_variable_get(:@queue)).to be(true)
      end
    end

    # The point of the flag: compressing a tool result is a different job from
    # answering the conversation, so it gets its own tier. A local chat can buy
    # a better summarizer, and a frontier chat can keep summarizing for free.
    it "points the summarizer at a paid provider while the chat model stays local" do
      backend = summarizer_for(summarizer_provider: "anthropic")
      chat, summary = with_env("ANTHROPIC_API_KEY" => "sk-test") { [backend.provider, tier_of(backend)] }

      expect(chat).to be_a(Lain::Provider::Ollama)
      expect(provider_of(summary)).to be_a(Lain::Provider::Anthropic)
      expect(summary.model).to eq(Lain::Provider::Anthropic::DEFAULT_MODEL)
    end

    # The other side of that flag, and the case the GPU pays for: one local
    # provider serving both tiers holds ONE resident model, so a summarizer left
    # at the provider's default evicts the chat model on every compaction and
    # the next turn reloads it -- 84.0s against 7.5s, measured. Same provider
    # means the chat's model is already loaded, which makes it the right default.
    it "inherits the chat's --model when both tiers name the same provider" do
      expect(tier_of(summarizer_for(model: "qwen3-coder:30b")).model).to eq("qwen3-coder:30b")
    end

    it "honors an explicit --summarizer-model over the tier provider's default" do
      expect(tier_of(summarizer_for(summarizer_model: "qwen3:8b")).model).to eq("qwen3:8b")
    end

    it "honors an explicit --summarizer-model over the chat's own model" do
      expect(tier_of(summarizer_for(model: "qwen3-coder:30b", summarizer_model: "gemma3:12b")).model)
        .to eq("gemma3:12b")
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
    # {Lain::Compaction.validate_keep_last} already uses for keep_last.
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
      oracle = backend.eager.oracle
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
      expect(payload[:options].except(:num_predict)).to eq(temperature: 0, seed: 7, num_batch: 2048)
    end

    it "renders a Request whose cache_payload is identical to the flagless render" do
      tuned = render(provider: "ollama", model: nil, temperature: 0, seed: 7)
      plain = render(provider: "ollama", model: nil, temperature: nil, seed: nil)
      expect(tuned.cache_payload).to eq(plain.cache_payload)
      expect(tuned).to have_same_digest_as(plain)
    end

    it "omits absent sampler keys entirely (0 is present, nil is not), but always carries num_batch" do
      request = render(provider: "ollama", model: nil, temperature: 0, seed: nil)
      payload = Lain::Provider::Ollama.new.encode(request)
      expect(payload[:options]).to eq(num_predict: 1024, temperature: 0, num_batch: 2048)
    end
  end

  # The two throughput knobs no longer reach the wire the same way. `num_ctx`
  # still follows temperature and seed through #sampler_extra -- an UNSET flag
  # adds nothing to the options hash, which is what the third example pins.
  # `num_batch` is the opposite case: ollama's own server default (512) costs
  # 1.31x prefill against llama.cpp's actual default (2048, measured -- see
  # {Provider::Ollama::Encoding::SAMPLER_KEYS}), so #sampler_extra sends
  # {Lain::CLI::Backend::DEFAULT_NUM_BATCH} whether or not a flag set it, on
  # every ollama chat. The hash is still no longer evidence of a flag having
  # been TYPED: the encoder seeds it with the generation cap regardless, and
  # now num_batch rides along unasked too.
  describe "num_batch and num_ctx threading" do
    let(:store) { Lain::Store.new }
    let(:timeline) do
      Lain::Timeline.empty(store:)
                    .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
    end

    def payload_for(**options)
      request = backend_for(max_tokens: 1024, provider: "ollama", model: nil, **options)
                .context.render(timeline:, toolset: Lain::Toolset.new)
      Lain::Provider::Ollama.new.encode(request)
    end

    it "carries an operator-set batch size into the encoded request options" do
      expect(payload_for(num_batch: 2048)[:options]).to eq(num_predict: 1024, num_batch: 2048)
    end

    it "carries an operator-set context length into the encoded request options, alongside the num_batch default" do
      expect(payload_for(num_ctx: 8192)[:options]).to eq(num_predict: 1024, num_batch: 2048, num_ctx: 8192)
    end

    it "defaults num_batch to 2048 when no sampler flag was given, and adds no other sampler key" do
      expect(payload_for[:options]).to eq(num_predict: 1024, num_batch: 2048)
    end

    # The same claim from argv: the exe's flag band leaves num_ctx nil when
    # neither a flag nor LAIN_NUM_CTX says anything, and the launch's profile
    # carries that absence into the Backend -- but num_batch still defaults,
    # because that default is #sampler_extra's own, not the profile's.
    it "sends the num_batch default and no other sampler knob for a flagless chat through the exe's profile band" do
      load File.expand_path("../../../exe/lain", __dir__) unless defined?(LainCLI)
      options = Thor::Options.new(LainCLI.commands.fetch("chat").options).parse([])
      profile = with_env("LAIN_PROVIDER" => "ollama", "LAIN_NUM_BATCH" => nil, "LAIN_NUM_CTX" => nil) do
        LainCLI::ModelFlags.profile(options)
      end
      request = Lain::CLI::ChatLaunch.new(options, profile:).backend
                                     .context.render(timeline:, toolset: Lain::Toolset.new)

      expect(Lain::Provider::Ollama.new.encode(request)[:options].except(:num_predict)).to eq(num_batch: 2048)
    end

    # A sampler knob is not a prompt: the same cache-identity claim temperature
    # and seed already carry, restated for the two keys that are new here.
    it "renders a Request whose cache_payload is identical to the flagless render" do
      tuned = backend_for(max_tokens: 1024, provider: "ollama", model: nil, num_batch: 2048, num_ctx: 8192)
              .context.render(timeline:, toolset: Lain::Toolset.new)
      plain = backend_for(max_tokens: 1024, provider: "ollama", model: nil)
              .context.render(timeline:, toolset: Lain::Toolset.new)

      expect(tuned.cache_payload).to eq(plain.cache_payload)
      expect(tuned).to have_same_digest_as(plain)
    end

    # `seed` and the two runner knobs are ollama's, and the Anthropic encoder
    # forwards every `extra` key it does not recognise straight onto the wire --
    # so an `.envrc` exporting LAIN_SEED or LAIN_NUM_BATCH put a field on every
    # hosted request that the API does not define.
    it "keeps seed and both runner knobs off an Anthropic chat's wire body, and temperature on it" do
      request = backend_for(max_tokens: 1024, provider: "anthropic", model: nil, temperature: 0.2, seed: 7,
                            num_batch: 2048, num_ctx: 8192)
                .context.render(timeline:, toolset: Lain::Toolset.new)
      body = Lain::Provider::Anthropic.new(api_key: "test").encode(request)

      expect(request.extra).to eq("temperature" => 0.2)
      expect(body.keys.map(&:to_s)).not_to include("seed", "num_batch", "num_ctx")
    end
  end

  # A secondary model request -- a summary, a span collapse, a secret-read
  # judgement -- is not a turn, but on ONE ollama runner it is still a request
  # that runner answers. Sent without the chat's `num_batch`, it no longer
  # matches the loaded runner, so the server reloads the model for the summary
  # and again for the next turn: 29.4s of oracle wall against 1.6s, measured.
  #
  # So the chat's runner knobs follow a tier onto the wire in exactly the case
  # where the tier IS the chat's runner -- same arm, same endpoint, same model
  # -- and never the chat's temperature or seed, which would move the answer
  # rather than keep the runner.
  describe "sampler options on a secondary tier" do
    let(:journal) { RecordingChannel.new }

    def summary_reply
      Lain::Response.new(content: [{ "type" => "text", "text" => %({"summary":"three files"}) }],
                         stop_reason: :end_turn, usage: Lain::Usage.new(input_tokens: 12, output_tokens: 7))
    end

    # Ollama's own capability set, so the request carries the structured-output
    # marker a real local tier would -- the options have to ride beside it.
    def answering_provider
      Lain::Provider::Mock.new(responses: [summary_reply], capabilities: Lain::Provider::Ollama::CAPABILITIES)
    end

    # The eager summarizer the run actually builds, asked once over a provider
    # the example can read the request back off.
    def summarize_through(backend, provider)
      allow(backend).to receive(:summarizer_provider).and_return(provider)
      backend.pipeline_source(cache_profile: Lain::CacheProfile::NO_CACHING, journal:)
      Sync { backend.send(:summary_oracle).ask(source: "a tool result").await }
    end

    def ollama_options(request) = Lain::Provider::Ollama.new.encode(request)[:options]

    it "asks the summarizer with the chat's batch size, and journals the request saying so" do
      provider = answering_provider
      summarize_through(backend_for(provider: "ollama", max_tokens: 64, num_batch: 2048), provider)

      expect(ollama_options(provider.last_request).except(:num_predict)).to eq(num_batch: 2048)
      expect(journal.events.grep(Lain::Telemetry::RequestSent).last.extra).to include("num_batch" => 2048)
    end

    # The summarizer is pinned to the chat's own model, so only the ARM differs
    # and the provider half of the rule is what keeps the options off.
    it "never hands an Anthropic summarizer the chat's ollama options" do
      transport = AnthropicSSE.queue_transport([summary_reply])
      hosted = Lain::Provider::Anthropic.new(transport:, api_key: "test")
      backend = backend_for(provider: "ollama", model: "qwen3:4b", max_tokens: 64, seed: 7, num_batch: 2048,
                            summarizer_provider: "anthropic", summarizer_model: "qwen3:4b")

      summarize_through(backend, hosted)

      expect(JSON.generate(transport.calls.last)).not_to include("num_batch")
    end

    # The summarizer shares the chat's own default model and endpoint here, so
    # it shares its runner too -- the num_batch default follows for the same
    # reason a typed one would: a mismatched batch size reloads this runner.
    it "sends the num_batch default and no other sampler key on a flagless run" do
      provider = answering_provider
      summarize_through(backend_for(provider: "ollama", max_tokens: 64), provider)

      expect(ollama_options(provider.last_request).except(:num_predict)).to eq(num_batch: 2048)
    end

    it "carries the batch size and never the temperature or seed to a summarizer on the chat's own model" do
      provider = answering_provider
      summarize_through(backend_for(provider: "ollama", model: "qwen3-coder:30b", max_tokens: 64,
                                    temperature: 0.2, seed: 7, num_batch: 2048), provider)

      expect(ollama_options(provider.last_request).except(:num_predict)).to eq(num_batch: 2048)
    end

    it "carries none of them to a summarizer pinned to a different model" do
      provider = answering_provider
      summarize_through(backend_for(provider: "ollama", model: "qwen3-coder:30b", max_tokens: 64, temperature: 0.2,
                                    num_batch: 2048, num_ctx: 32_768, summarizer_model: "qwen3:4b"), provider)

      expect(ollama_options(provider.last_request).keys).to eq([:num_predict])
    end

    # The value {Lain::Oracle::SecretRead.tier} is handed: a local ollama arm on
    # loopback, at its own model. Asked of the Backend because the rule is the
    # Backend's, not the wiring's.
    describe "#tier_options" do
      let(:local_judge) { { provider: "ollama", model: "qwen3:4b" } }

      it "answers nothing for a tier on a different model than a qwen3-coder chat" do
        backend = backend_for(provider: "ollama", model: "qwen3-coder:30b", temperature: 0.2, num_batch: 2048)

        expect(backend.tier_options(**local_judge)).to eq({})
      end

      it "answers the runner knobs alone for a tier on the chat's model and endpoint" do
        backend = backend_for(provider: "ollama", model: "qwen3:4b", temperature: 0.2, seed: 7,
                              num_batch: 2048, num_ctx: 32_768)

        expect(backend.tier_options(**local_judge)).to eq("num_batch" => 2048, "num_ctx" => 32_768)
      end

      # A missing base IS the arm's default, and a trailing slash names the
      # same base -- so the judge's own loopback server spelled out still
      # shares the chat's runner.
      it "answers the runner knobs for a chat whose base spells out the arm's default" do
        backend = backend_for(provider: "ollama", model: "qwen3:4b", api_base: "http://localhost:11434/",
                              num_batch: 2048)

        expect(backend.tier_options(**local_judge)).to eq("num_batch" => 2048)
      end

      # `localhost` may resolve to ::1, where a different listener can sit, so
      # the spelling cannot prove it is the same server.
      it "does not equate localhost with 127.0.0.1" do
        backend = backend_for(provider: "ollama", model: "qwen3:4b", api_base: "http://127.0.0.1:11434",
                              num_batch: 2048)

        expect(backend.tier_options(**local_judge)).to eq({})
      end

      it "answers nothing when the chat's runner lives at another endpoint" do
        backend = backend_for(provider: "ollama", model: "qwen3:4b", api_base: "http://gpu-box:11434",
                              num_batch: 2048)

        expect(backend.tier_options(**local_judge)).to eq({})
      end

      it "answers nothing when the chat is on another arm with a same-named model" do
        backend = with_env("OLLAMA_API_KEY" => "sk-test") do
          backend_for(provider: "ollama-cloud", model: "qwen3:4b", num_batch: 2048)
        end

        expect(backend.tier_options(**local_judge)).to eq({})
      end

      it "answers nothing for an Anthropic chat" do
        backend = backend_for(provider: "anthropic", model: "qwen3:4b", num_batch: 2048)

        expect(backend.tier_options(provider: "anthropic", model: "qwen3:4b")).to eq({})
      end
    end
  end
end
