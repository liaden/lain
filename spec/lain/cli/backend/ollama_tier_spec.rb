# frozen_string_literal: true

# The object that owns what `--provider ollama` and `--provider ollama-cloud`
# each MEAN: which deployment gets built, where the key comes from, which model
# a run defaults to, and the two refusals that have to fire before the
# chronicle opens.
#
# The refusals are examined HERE rather than only through Backend because this
# is where they are decided; backend_spec.rb pins that they are reached from the
# real launch path, which is the other half and a different question.
RSpec.describe Lain::CLI::Backend::OllamaTier do
  # Never inherited from the developer's own shell. This box has a live
  # OLLAMA_API_KEY (the chunk measured against one), so an example that
  # asserted a refusal without pinning the variable would pass on CI and fail
  # here -- or, worse, the reverse.
  def with_key(value = "sk-ollama-test", &) = with_env("OLLAMA_API_KEY" => value, &)

  # The four readers below are Admitted's private half -- the shape
  # ollama_spec.rb:89 already uses, for its reason: they are how the provider
  # answers ITSELF, not a public surface, and a spec that needed them public
  # would be asking for a door nothing else wants.
  def endpoint_of(provider) = provider.send(:resolved_endpoint)

  def cloud(**overrides) = described_class.new(name: described_class::CLOUD, **overrides)

  def local(**overrides) = described_class.new(name: described_class::LOCAL, **overrides)

  describe "the names it answers for" do
    it "answers for exactly the two ollama arms" do
      expect(described_class::NAMES).to eq(%w[ollama ollama-cloud])
    end

    # The two constants are what Backend's `case` arms and its PROVIDERS entry
    # key off, so a rename that only edited one of them would silently route a
    # cloud run at the local arm.
    it "names each arm the same way --provider spells it" do
      expect([described_class::LOCAL, described_class::CLOUD]).to eq(%w[ollama ollama-cloud])
      expect(Lain::CLI::Backend::PROVIDERS).to include(*described_class::NAMES)
    end
  end

  describe "#provider" do
    it "builds a loopback provider for the local arm" do
      provider = local.provider(channel: Lain::Channel::Null.instance, queue: true,
                                journal: Lain::Channel::Null.instance)
      expect(provider).to be_a(Lain::Provider::Ollama)
      expect(endpoint_of(provider)).to eq("http://localhost:11434")
    end

    it "honours --api-base on the local arm exactly as it always did" do
      provider = local(api_base: "http://127.0.0.1:11500")
                 .provider(channel: Lain::Channel::Null.instance, queue: true,
                           journal: Lain::Channel::Null.instance)
      expect(endpoint_of(provider)).to eq("http://127.0.0.1:11500")
    end

    it "builds a provider dialling ollama.com for the cloud arm" do
      provider = with_key do
        cloud.provider(channel: Lain::Channel::Null.instance, queue: true,
                       journal: Lain::Channel::Null.instance)
      end
      expect(endpoint_of(provider)).to eq("https://ollama.com")
    end

    # The whole point of the arm reaching the CLI: a cloud round trip that
    # queues for capacity has to land in the run's record like a local one.
    it "carries the journal it is handed onto the cloud provider" do
      journal = Lain::Channel.new
      provider = with_key do
        cloud.provider(channel: Lain::Channel::Null.instance, queue: true, journal:)
      end
      expect(provider.send(:wait_journal)).to be(journal)
    end

    it "carries the caller's willingness to wait onto the cloud provider" do
      provider = with_key do
        cloud.provider(channel: Lain::Channel::Null.instance, queue: false,
                       journal: Lain::Channel::Null.instance)
      end
      expect(provider.send(:queue_for_capacity?)).to be(false)
    end

    # Free-plan width, read by Deployment::Cloud from its own env key. Pinned
    # here because the CLI is the caller that must NOT quietly pass a width of
    # its own and reopen the metered-plan starvation the default exists for.
    it "leaves the cloud plan's width to the deployment's own default" do
      provider = with_env("LAIN_OLLAMA_CLOUD_CONCURRENCY" => nil) do
        with_key do
          cloud.provider(channel: Lain::Channel::Null.instance, queue: true,
                         journal: Lain::Channel::Null.instance)
        end
      end
      expect(provider.send(:admission_width)).to eq(1)
    end

    # The declared width is only worth declaring if Admission actually pins the
    # cloud endpoint's gate at it. The overlap that FOLLOWS from a width of one
    # is Admission's own behaviour and admission_spec.rb owns it; racing two
    # threads here would be testing that file's subject through this one.
    it "pins the cloud endpoint's gate at the plan's width" do
      Lain::Provider::Admission.reset!
      provider = with_env("LAIN_OLLAMA_CLOUD_CONCURRENCY" => nil, Lain::Provider::Admission::ENV_KEY => nil) do
        with_key do
          cloud.provider(channel: Lain::Channel::Null.instance, queue: true,
                         journal: Lain::Channel::Null.instance)
        end
      end
      gate = Lain::Provider::Admission.for(endpoint: endpoint_of(provider), width: provider.send(:admission_width))
      expect(gate.width).to eq(1)
    ensure
      Lain::Provider::Admission.reset!
    end

    it "sends an https --api-base through to the cloud provider" do
      provider = with_key do
        cloud(api_base: "https://ollama.example").provider(channel: Lain::Channel::Null.instance, queue: true,
                                                           journal: Lain::Channel::Null.instance)
      end
      expect(endpoint_of(provider)).to eq("https://ollama.example")
    end

    # T6 AC: the run's chronicle must reach the ollama provider, not a Null
    # spool. This is the line that decides whether the whole WAL is live or
    # dormant -- every OTHER spec in this card injects its own spool, so all of
    # them stay green if this forwarding is missing. Asserted on the spool
    # OBJECT reaching the tap, which is the only assertion a dropped keyword
    # cannot satisfy.
    describe "forwarding the run's spool" do
      def spool_of(provider) = provider.instance_variable_get(:@retries).instance_variable_get(:@spool)

      def built(tier, spool)
        tier.provider(channel: Lain::Channel::Null.instance, queue: true,
                      journal: Lain::Channel::Null.instance, spool:)
      end

      it "hands the local arm the very spool it was given" do
        spool = Lain::Provider::ResponseWal.new("/tmp/lain-ollama-tier-spec-session.wal")

        expect(spool_of(built(local, spool))).to be(spool)
      end

      it "hands the metered cloud arm the very spool it was given" do
        spool = Lain::Provider::ResponseWal.new("/tmp/lain-ollama-tier-spec-session.wal")

        expect(with_key { spool_of(built(cloud, spool)) }).to be(spool)
      end

      # Nil is the Null spool, not a crash and not a silently absent tap: bench
      # and --no-journal both arrive this way.
      it "falls back to the Null spool when the caller has no chronicle" do
        provider = local.provider(channel: Lain::Channel::Null.instance, queue: true,
                                  journal: Lain::Channel::Null.instance)

        expect(spool_of(provider)).to be_a(Lain::Provider::Spool::Null)
      end

      # Object identity above proves the keyword arrives. This proves the whole
      # path WORKS: a round trip completed through a tier-built provider leaves
      # a readable, complete frame in the file the run would salvage from.
      it "leaves a complete frame in the WAL file after a round trip", :webmock do
        Dir.mktmpdir("tier-wal") do |dir|
          path = File.join(dir, "session.wal")
          body = '{"message":{"role":"assistant","content":"hi"},"done":true,"done_reason":"stop"}'
          stub_request(:post, "http://localhost:11434/api/chat")
            .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body:)
          # stream: false is EXPLICIT -- Request defaults it to true
          # (`request.rb:21`), and the stubbed body here is a single JSON
          # object, i.e. the sync path this example means to drive.
          request = Lain::Request.new(model: "qwen3:4b", max_tokens: 16, stream: false,
                                      messages: [{ role: "user", content: "hi" }])

          built(local, Lain::Provider::ResponseWal.new(path)).complete(request)

          frames = Lain::Provider::ResponseWal.new(path).frames.to_a
          expect(frames.map(&:request_digest)).to eq([request.digest])
          expect(frames.fetch(0)).to be_complete
        end
      end
    end
  end

  describe "the key refusal" do
    it "refuses at CONSTRUCTION, before anything asks for a provider" do
      expect { with_env("OLLAMA_API_KEY" => nil) { cloud } }
        .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey)
    end

    it "names the variable and where a key comes from" do
      expect { with_env("OLLAMA_API_KEY" => nil) { cloud } }
        .to raise_error(%r{OLLAMA_API_KEY is not set.*ollama\.com/settings/keys}m)
    end

    # Delegated, not re-implemented: a key that is present but unusable has
    # three distinct diagnoses and they live on the deployment.
    it "refuses a whitespace-only key with the deployment's own diagnosis" do
      expect { with_key(" ") { cloud } }
        .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, /only whitespace/)
    end

    it "is a Lain::Error, so the exe maps it to a clean Thor::Error" do
      expect(Lain::Provider::Ollama::Deployment::MissingAPIKey.ancestors).to include(Lain::Error)
    end

    it "asks the environment for nothing at all on the local arm" do
      expect { with_env("OLLAMA_API_KEY" => nil) { local } }.not_to raise_error
    end
  end

  describe "the plaintext refusal" do
    it "refuses an http --api-base on the cloud arm, at construction" do
      expect { with_key { cloud(api_base: "http://ollama.example") } }
        .to raise_error(Lain::CLI::Backend::PlaintextEndpoint)
    end

    it "names the key as the reason https is required" do
      expect { with_key { cloud(api_base: "http://ollama.example") } }
        .to raise_error(/OLLAMA_API_KEY/)
    end

    it "names the flag the operator actually typed" do
      expect { with_key { cloud(api_base: "http://ollama.example") } }
        .to raise_error(%r{--api-base "http://ollama\.example"})
    end

    # Determinism: the same argv must be refused for the same reason on a box
    # with a key and on one without, or the operator on the second box fixes
    # the wrong thing first.
    it "fires ahead of the key refusal, so the diagnosis does not depend on the environment" do
      expect { with_env("OLLAMA_API_KEY" => nil) { cloud(api_base: "http://ollama.example") } }
        .to raise_error(Lain::CLI::Backend::PlaintextEndpoint)
    end

    it "accepts an https --api-base" do
      expect { with_key { cloud(api_base: "https://ollama.example") } }.not_to raise_error
    end

    it "leaves the local arm's plaintext base alone" do
      expect { local(api_base: "http://localhost:11434") }.not_to raise_error
    end

    it "is a Lain::Error, so the exe maps it to a clean Thor::Error" do
      expect(Lain::CLI::Backend::PlaintextEndpoint.ancestors).to include(Lain::Error)
    end
  end

  describe ".default_model" do
    it "keeps the local arm on the provider's own default" do
      expect(described_class.default_model(described_class::LOCAL)).to eq(Lain::Provider::Ollama::DEFAULT_MODEL)
    end

    it "defaults the cloud arm to a cloud model rather than qwen3:4b" do
      answer = described_class.default_model(described_class::CLOUD)
      expect(answer).not_to eq(Lain::Provider::Ollama::DEFAULT_MODEL)
      expect(answer).to end_with("-cloud")
    end

    # It is a CLASS method precisely so that Backend#model -- read per turn by
    # three collaborators -- cannot build a Deployment::Cloud, cannot re-read
    # ENV, and cannot raise about a missing key. Asking with the environment
    # empty is the whole assertion.
    it "answers for the cloud arm with no key in the environment at all" do
      expect(with_env("OLLAMA_API_KEY" => nil) { described_class.default_model(described_class::CLOUD) })
        .to eq(described_class::CLOUD_DEFAULT_MODEL)
    end

    # A default that fell to the GUESSED 8,192 fallback would have a fresh
    # cloud session compacting on turn one against a window it is nowhere
    # near. The shipped table is what stops that, so the default has to BE in
    # it -- which is a different claim from "some cloud model is in it".
    it "picks a default the shipped window book can actually answer for" do
      expect(Lain::ContextWindow::CLOUD_WINDOWS).to have_key(described_class::CLOUD_DEFAULT_MODEL)
    end

    # The membership above is the mechanism; THIS is the claim. The shipped
    # book answers :guessed for the local default -- 8,192, which a cloud
    # session is nowhere near -- and a default that inherited it would have a
    # fresh run compacting on turn one.
    it "resolves to a PUBLISHED window, not the guess the local default falls to" do
      cloud_window = Lain::ContextWindow.default.resolve(described_class::CLOUD_DEFAULT_MODEL)
      local_window = Lain::ContextWindow.default.resolve(Lain::Provider::Ollama::DEFAULT_MODEL)
      expect(cloud_window.provenance).to eq(:published)
      expect(local_window.provenance).to eq(:guessed)
      expect(cloud_window.window_tokens).to be > local_window.window_tokens
    end
  end

  # BLOCKER 1. There is one --api-base flag and two tiers that can be ollama;
  # handing the chat's base to a tier built for the summarizer's name sent
  # OLLAMA_API_KEY, as a bearer token, to a host the other arm's flag chose.
  # WHOSE --api-base it is. The rule lives here as a pure function of two
  # names; Backend applies it and passes only the base that survives, so the
  # tier is never handed one it would drop. The first version of the rule --
  # "the tier whose name is the chat's" -- is the one this table exists to stop
  # coming back: it reads as obviously right and silently moved every LOCAL
  # summarizer beside an anthropic or bedrock chat off the host --api-base named.
  describe ".claims_base?" do
    [
      ["ollama", "ollama", true, "one ollama arm, and it is the chat's"],
      ["ollama", "anthropic", true, "the only ollama arm there is"],
      ["ollama", "bedrock", true, "the only ollama arm there is"],
      ["ollama", nil, true, "no chat provider named at all"],
      ["ollama", "", true, "an empty chat provider is not ollama-shaped either"],
      ["ollama-cloud", "ollama-cloud", true, "the cloud arm IS the chat's"],
      ["ollama-cloud", "ollama", false, "--provider named the other ollama arm, and it has the base"],
      ["ollama", "ollama-cloud", false, "likewise, the other way round"]
    ].each do |name, chat_provider, expected, why|
      it "is #{expected} for #{name.inspect} beside --provider #{chat_provider.inspect} (#{why})" do
        expect(described_class.claims_base?(name, chat_provider)).to be(expected)
      end
    end

    # The property behind the table, and the one that makes the rule safe: the
    # base is never NOBODY's. Whenever a tier is denied it, --provider names an
    # ollama arm -- which is the arm that claims it.
    it "always leaves the base claimed by some ollama arm when it denies one" do
      denied = [%w[ollama-cloud ollama], %w[ollama ollama-cloud]]
      expect(denied.map { |_, chat| described_class.claims_base?(chat, chat) }).to all(be(true))
    end
  end

  # SHOULD-FIX. A constructor that accepts a keyword and silently drops it is
  # how the caller's mistake becomes invisible at the one site that could have
  # caught it -- and it is how the regression above stayed hidden. Fixed by
  # elimination rather than by a raise: the filtering happens before the call,
  # so every base handed here is one this tier uses.
  describe "the base it is handed" do
    def summarizer(**overrides) = described_class.new(chat: false, **overrides)

    it "uses a base on a summarizer tier rather than discarding it" do
      provider = summarizer(name: described_class::LOCAL, api_base: "http://127.0.0.1:11500")
                 .provider(channel: Lain::Channel::Null.instance, queue: true,
                           journal: Lain::Channel::Null.instance)
      expect(endpoint_of(provider)).to eq("http://127.0.0.1:11500")
    end

    it "uses it on the chat arm too" do
      provider = local(api_base: "http://127.0.0.1:11500")
                 .provider(channel: Lain::Channel::Null.instance, queue: true,
                           journal: Lain::Channel::Null.instance)
      expect(endpoint_of(provider)).to eq("http://127.0.0.1:11500")
    end

    # Whichever arm it belongs to, a plaintext base on the CLOUD arm is still
    # refused -- the safety rule does not depend on who claimed the flag.
    it "still refuses a plaintext base on a summarizer-tier cloud arm" do
      expect { with_key { summarizer(name: described_class::CLOUD, api_base: "http://internal.example") } }
        .to raise_error(Lain::CLI::Backend::PlaintextEndpoint)
    end

    it "keeps the cloud default when handed no base at all" do
      provider = with_key do
        summarizer(name: described_class::CLOUD)
          .provider(channel: Lain::Channel::Null.instance, queue: true, journal: Lain::Channel::Null.instance)
      end
      expect(endpoint_of(provider)).to eq("https://ollama.com")
    end
  end

  # SHOULD-FIX. The refusal must name the flag that selected THIS arm, per
  # Endpoint's stated rule -- a message naming --provider when the operator set
  # --summarizer-provider tells them to change something they never typed.
  describe "which flag a refusal names" do
    it "names --provider on the chat's arm" do
      expect { with_key { cloud(api_base: "http://ollama.example") } }
        .to raise_error(Lain::CLI::Backend::PlaintextEndpoint, /--provider ollama-cloud/)
    end

    it "takes the flag as a field, so it can never name a flag nobody set" do
      flags = with_key do
        [cloud.send(:flag), described_class.new(name: described_class::CLOUD, chat: false).send(:flag)]
      end
      expect(flags).to eq(%w[--provider --summarizer-provider])
    end

    # The reachable half, and what keeps the field from being a literal with
    # extra steps: a summarizer tier is handed no base, so the plaintext
    # message is chat-only -- but the KEY refusal reaches both arms.
    it "says which flag asked for a key, on the summarizer arm" do
      expect { with_env("OLLAMA_API_KEY" => nil) { described_class.new(name: described_class::CLOUD, chat: false) } }
        .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey,
                        /--summarizer-provider ollama-cloud is what asked for it/)
    end

    it "says which flag asked for a key, on the chat arm" do
      expect { with_env("OLLAMA_API_KEY" => nil) { cloud } }
        .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey,
                        /--provider ollama-cloud is what asked for it/)
    end

    # Annotated, NEVER replaced: the deployment stays the one authority on what
    # is wrong with a key, and its three diagnoses must survive intact.
    it "keeps the deployment's own diagnosis and class underneath the annotation" do
      expect { with_key(" ") { described_class.new(name: described_class::CLOUD, chat: false) } }
        .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey,
                        %r{only whitespace.*settings/keys.*--summarizer-provider}m)
    end
  end

  # SHOULD-FIX. Stated in capitals in the class docstring and, until this
  # example, enforced by nothing: a planted `@held_key = ENV.fetch(...)` left
  # the whole suite green.
  describe "what the tier keeps" do
    let(:secret) { "sk-do-not-retain" }

    def held_by(tier) = tier.instance_variables.map { |name| tier.instance_variable_get(name) }

    it "holds the key in no instance variable of its own" do
      tier = with_key(secret) { cloud }
      expect(held_by(tier).grep(String)).not_to include(a_string_including(secret))
    end

    # The wider claim: not through anything it kept either, at any depth an
    # #inspect can reach.
    it "holds nothing that reaches the key through an object it kept" do
      tier = with_key(secret) { cloud }
      expect(held_by(tier).map(&:inspect).join).not_to include(secret)
    end

    # The other half: it keeps no Deployment::Cloud, whose #to_h is unredacted
    # by construction and cannot be otherwise while api_key is a public reader.
    it "keeps no deployment at all" do
      tier = with_key(secret) { cloud }
      expect(held_by(tier).grep(Lain::Provider::Ollama::Deployment::Cloud)).to be_empty
    end
  end

  # NIT. Unreachable from argv -- Backend runs the value through Endpoint first
  # -- but this is a public class with a documented public constructor, and a
  # bare URI::InvalidURIError is not a Lain::Error, so the exe drops it to a
  # backtrace instead of naming the flag.
  describe "a base that is not a URL at all" do
    it "refuses it as a Lain error naming the flag, not a raw URI error" do
      expect { with_key { cloud(api_base: "not a url") } }
        .to raise_error(Lain::CLI::Backend::InvalidEndpoint, /--api-base "not a url"/)
    end

    it "refuses a scheme-less host the same way rather than reading it as secure" do
      expect { with_key { cloud(api_base: "localhost:11434") } }
        .to raise_error(Lain::CLI::Backend::InvalidEndpoint)
    end
  end
end
