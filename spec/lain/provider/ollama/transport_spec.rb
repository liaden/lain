# frozen_string_literal: true

# The transport is what actually dials, so it is where "which server, and with
# whose credential" has to be true rather than declared. Two class-level claims
# used to answer both questions for every instance at once -- no auth header,
# and `local? == true` -- and both stop being true the moment a cloud
# configuration exists. This file pins the per-instance answers.
#
# The transport had no spec of its own; it was exercised through
# `spec/lain/provider/ollama_spec.rb`. Nothing was moved here -- every example
# below is new behaviour.
RSpec.describe Lain::Provider::Ollama::Transport do
  # A key that is obviously not one, and deliberately UNFROZEN: a literal in a
  # `frozen_string_literal: true` file is frozen already, which would hide an
  # accidental mutation of the caller's String.
  let(:key) { +"sk-ollama-not-a-real-key" }

  def config_with(**attrs)
    Lain::Provider::HTTP::Configuration.new.tap do |config|
      attrs.each { |name, value| config.public_send(:"#{name}=", value) }
    end
  end

  describe "#headers" do
    it "sends no authorization when the configuration carries no key" do
      expect(described_class.new(config_with).headers).to eq({})
    end

    # The Bedrock idiom (`Provider::HTTP::Providers::Bedrock:28-33`): the header
    # is built from Configuration, which is the one thing `Connection` can see.
    it "builds a bearer header from the configured key" do
      expect(described_class.new(config_with(ollama_api_key: key)).headers)
        .to eq("Authorization" => "Bearer #{key}")
    end

    # The credential is a Configuration option and NOT a
    # `configuration_requirement`. That list is class-level and
    # `Connection#ensure_configured!` refuses construction when any entry is
    # unset, so requiring the key here would refuse every LOCAL connection --
    # which is the whole default arm. The refusal that names OLLAMA_API_KEY
    # lives in `Deployment::Cloud`, where it is per-deployment.
    it "declares the key as an option without making it a requirement" do
      expect(described_class.configuration_options).to include(:ollama_api_base, :ollama_api_key)
      expect(described_class.configuration_requirements).to be_empty
    end

    it "leaves the caller's key String unmutated and unfrozen" do
      described_class.new(config_with(ollama_api_key: key)).headers

      expect(key).to eq("sk-ollama-not-a-real-key").and(satisfy { |k| !k.frozen? })
    end

    # The BYPASS path -- a Configuration built directly, no deployment in it.
    # `Configuration`'s generated setter (`http/configuration.rb:38-41`) coerces
    # a blank String to nil, so a whitespace key never becomes `Bearer `. That
    # setter is the guard here, NOT `Deployment::Cloud`, which is not in this
    # path at all.
    it "sends no header for a blank key, which the Configuration setter has already nilled" do
      expect(described_class.new(config_with(ollama_api_key: "   ")).headers).to eq({})
    end

    # The LIMIT of that guard, recorded rather than fixed: the setter
    # special-cases String and nothing else, so a non-String set directly still
    # reaches the wire. `Deployment::Cloud` refuses this by name and is the door
    # every shipped caller uses; this pins what the backstop alone does NOT do,
    # so nobody mistakes it for a validator.
    it "does not itself refuse a non-String key, which only Deployment::Cloud does" do
      expect(described_class.new(config_with(ollama_api_key: 12_345)).headers)
        .to eq("Authorization" => "Bearer 12345")
    end
  end

  # The header has to ride the REAL Faraday stack, not just the method, and it
  # has to ride BOTH connections: `#connection` serves the completion path and
  # `#probe_connection` is a second Connection built from a duped config. A
  # header wired onto one and not the other is the failure this pins -- and
  # `/api/show` is reached eagerly at launch by `--num-ctx`, so the probe path
  # is not hypothetical.
  describe "over the real transport", :webmock do
    subject(:transport) do
      described_class.new(config_with(ollama_api_base: "https://ollama.com", ollama_api_key: key))
    end

    let(:bearer) { "Bearer #{key}" }

    it "carries the bearer on a chat completion" do
      stub = stub_request(:post, "https://ollama.com/api/chat")
             .with(headers: { "Authorization" => bearer })
             .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: "{}")

      transport.sync_post({ model: "gpt-oss:120b" })

      expect(stub).to have_been_requested
    end

    it "carries the bearer on an /api/show probe" do
      stub = stub_request(:post, "https://ollama.com/api/show")
             .with(headers: { "Authorization" => bearer })
             .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: "{}")

      transport.model_details("gpt-oss:120b")

      expect(stub).to have_been_requested
    end

    it "carries the bearer on an /api/ps probe" do
      stub = stub_request(:get, "https://ollama.com/api/ps")
             .with(headers: { "Authorization" => bearer })
             .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: '{"models":[]}')

      transport.process_status

      expect(stub).to have_been_requested
    end

    it "sends no authorization header at all when no key is configured" do
      keyless = described_class.new(config_with(ollama_api_base: "https://ollama.com"))
      stub = stub_request(:post, "https://ollama.com/api/chat")
             .with { |request| !request.headers.key?("Authorization") }
             .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: "{}")

      keyless.sync_post({ model: "gpt-oss:120b" })

      expect(stub).to have_been_requested
    end
  end

  # BLOCKER: the block above asserts a literal it transcribes ITSELF
  # (`"Bearer #{key}"`), so it never mentions {Deployment::Cloud} and cannot
  # see the deployment's declaration drift. Mutation-proved: dropping the
  # `Bearer ` scheme from `Cloud#headers` left the block above green.
  #
  # These two close that by asserting the wire against
  # `Deployment::Cloud#headers` -- the declaration itself, never re-typed --
  # so the transport that SENDS and the deployment that DECLARES cannot
  # disagree without a failure. The pair is the reason the deployment's
  # `#headers` is allowed to exist at all while being merged nowhere: it is a
  # checked declaration, and this is the check.
  describe "agreeing with the deployment that declares the header" do
    let(:cloud) { Lain::Provider::Ollama::Deployment::Cloud.new(api_key: key) }
    let(:declared) { cloud.headers["Authorization"] }

    def transport_for(deployment)
      described_class.new(deployment.apply(Lain::Provider::HTTP::Configuration.new))
    end

    def json(body) = { status: 200, headers: { "Content-Type" => "application/json" }, body: }

    it "sends exactly what Deployment::Cloud declares, on chat, show and ps alike" do
      transport = transport_for(cloud)
      base = transport.api_base
      carries = { headers: { "Authorization" => declared } }
      chat = stub_request(:post, "#{base}/api/chat").with(**carries).to_return(**json("{}"))
      show = stub_request(:post, "#{base}/api/show").with(**carries).to_return(**json("{}"))
      ps = stub_request(:get, "#{base}/api/ps").with(**carries).to_return(**json('{"models":[]}'))

      transport.sync_post({ model: "m" })
      transport.model_details("m")
      transport.process_status

      expect([chat, show, ps]).to all(have_been_requested)
    end

    # The other half, and the one that makes the pair a statement about the
    # SPLIT rather than about the cloud arm: `Local#apply` nils the key, so the
    # same transport class over the local deployment sends no credential at all
    # to a loopback server.
    it "sends no Authorization at all on the local arm, on all three endpoints" do
      transport = transport_for(Lain::Provider::Ollama::Deployment::Local.new)
      base = transport.api_base
      keyless = ->(request) { !request.headers.key?("Authorization") }
      chat = stub_request(:post, "#{base}/api/chat").with(&keyless).to_return(**json("{}"))
      show = stub_request(:post, "#{base}/api/show").with(&keyless).to_return(**json("{}"))
      ps = stub_request(:get, "#{base}/api/ps").with(&keyless).to_return(**json('{"models":[]}'))

      transport.sync_post({ model: "m" })
      transport.model_details("m")
      transport.process_status

      expect([chat, show, ps]).to all(have_been_requested)
    end
  end

  # RULED ON, not an oversight. `#headers` hangs a Bearer on whatever base the
  # Configuration carries, loopback included -- so a key-bearing Configuration
  # handed straight to `Embedder::Ollama.new(config:)` would send a credential
  # to `http://localhost:11434`.
  #
  # It is NOT refused, deliberately: a local auth proxy in front of ollama is a
  # legitimate topology, and refusing it here would be lain deciding someone's
  # deployment for them. What makes it unreachable from lain's own paths is
  # `Local#apply` NILING the key -- an invariant that lives in the two `apply`
  # methods rather than in the object that sends, which is exactly why it is
  # written down here, next to the sending.
  describe "a key on a loopback base" do
    it "is sent, because a local auth proxy is a real topology and not ours to refuse" do
      transport = described_class.new(
        Lain::Provider::HTTP::Configuration.new.tap do |config|
          config.ollama_api_base = "http://localhost:11434"
          config.ollama_api_key = key
        end
      )

      expect(transport.headers).to eq("Authorization" => "Bearer #{key}")
      expect(transport.local?).to be(true)
    end

    # The guard that makes the above unreachable through lain's own doors.
    it "cannot arise from Local#apply, which nils the key on the way through" do
      configured = Lain::Provider::Ollama::Deployment::Local.new.apply(
        Lain::Provider::HTTP::Configuration.new.tap { |config| config.ollama_api_key = key }
      )

      expect(described_class.new(configured).headers).to eq({})
    end
  end

  # THE BYPASS PATH, and the reason this guard exists in the transport at all.
  # {Deployment::Cloud} refuses an unusable key by name, but it is not in every
  # path: a Configuration built DIRECTLY, with no deployment anywhere, reaches
  # the wire unfiltered. There the adapter used to raise a bare `ArgumentError`
  # -- outside {Lain::Error}, so outside `wrapping_errors` and every rescue in
  # the codebase -- whose message QUOTES the offending header value, i.e. the
  # live credential, defeating all three redaction guards from the outside.
  #
  # WIRE FORMAT, NOT POLICY, and the split is the point: {Deployment::Cloud}
  # answers "is this a credential a human plausibly meant to set" and names
  # `OLLAMA_API_KEY`; this answers "may this value be put in an HTTP header at
  # all", which is a fact about HTTP rather than about Ollama. Neither is a copy
  # of the other, and deleting either reopens a case the other never covered.
  describe "refusing to build a header the wire cannot carry" do
    # Locals, not constants: a constant here would trip
    # `Lint/ConstantDefinitionInBlock` and leak into the enclosing namespace.
    # The NUL is spelled `0.chr` so this file holds no literal control byte.
    canary = "CANARY9876"
    hostile = {
      "a CRLF" => "sk-paste\r\n#{canary}",
      "a bare CR" => "sk-paste\r#{canary}",
      "a bare LF" => "sk-paste\n#{canary}",
      "a tab" => "sk-paste\t#{canary}",
      "a NUL" => "sk-paste#{0.chr}#{canary}"
    }

    def transport_with(bad_key)
      described_class.new(config_with(ollama_api_base: "https://ollama.com", ollama_api_key: bad_key))
    end

    hostile.each do |description, bad_key|
      # Half the defect was the CLASS: a bare ArgumentError escapes every
      # rescue in the codebase, so nothing above the transport can contain it.
      it "raises a Lain::Error, not a bare ArgumentError, for #{description}" do
        expect { transport_with(bad_key).headers }.to raise_error(Lain::Error)
      end

      # The other half. A refusal that echoes the value has only moved the leak
      # out of the adapter and into us -- and ours is the one callers log.
      it "puts no fragment of the key in the message for #{description}" do
        expect { transport_with(bad_key).headers }.to raise_error(Lain::Error) do |error|
          expect(error.message).not_to include(canary)
          expect(error.message).not_to include("sk-paste")
        end
      end
    end

    it "names the configuration option, so the refusal is actionable" do
      expect { transport_with("sk-paste\r\n#{canary}").headers }
        .to raise_error(Lain::Error, /ollama_api_key/)
    end

    it "says what is wrong with the value" do
      expect { transport_with("sk-paste\r\n#{canary}").headers }
        .to raise_error(Lain::Error, /line break|control character/)
    end

    it "still builds the header for a key the wire can carry" do
      expect(transport_with("sk-perfectly-ordinary").headers)
        .to eq("Authorization" => "Bearer sk-perfectly-ordinary")
    end

    # The guard is on the VALUE, so it protects the REQUEST and not merely the
    # `#headers` call: nothing reaches Net::HTTP to be refused down there.
    it "refuses before any request is attempted" do
      stub = stub_request(:post, "https://ollama.com/api/chat")

      expect { transport_with("sk-paste\r\n#{canary}").sync_post({ model: "m" }) }
        .to raise_error(Lain::Error)
      expect(stub).not_to have_been_requested
    end
  end

  # A class predicate cannot describe an object whose endpoint is a constructor
  # argument. The answer routes through `Admission::Endpoint.local?` so that the
  # gate deciding a transport's concurrency and the transport describing itself
  # cannot disagree -- there is one definition of "local" in this codebase and
  # this is not a second one.
  describe "#local?" do
    it "answers true for the loopback default a bare configuration resolves to" do
      expect(described_class.new(config_with).local?).to be(true)
    end

    it "answers false for the hosted base a cloud configuration carries" do
      expect(described_class.new(config_with(ollama_api_base: "https://ollama.com")).local?).to be(false)
    end

    # Loopback has more than one spelling, and `Endpoint.local?` already folds
    # them. Inheriting that fold is the point of routing through it.
    it "answers true for every loopback spelling, not just the default one" do
      spellings = ["http://127.0.0.1:11434", "http://[::1]:11434", "http://LocalHost:11434/"]

      answers = spellings.map { |base| described_class.new(config_with(ollama_api_base: base)).local? }

      expect(answers).to all(be(true))
    end

    it "agrees with the gate that admits requests to the same endpoint" do
      transport = described_class.new(config_with(ollama_api_base: "https://ollama.com"))

      expect(transport.local?).to eq(Lain::Provider::Admission::Endpoint.local?(transport.api_base))
    end

    # `#remote?` is overridden alongside `#local?` and needs its own pin. The
    # base pair each delegate INDEPENDENTLY to the class
    # (`http/provider.rb:109-115`), so overriding one and inheriting the other
    # leaves a loopback transport answering `local?` true and `remote?` true at
    # the same time -- a contradiction introduced by fixing `local?`, not one
    # that was there before.
    it "answers remote? as the exact negation of local?, never both at once" do
      bases = [nil, "http://127.0.0.1:11434", "https://ollama.com", "unix:///var/run/ollama.sock"]

      answers = bases.map do |base|
        transport = described_class.new(base.nil? ? config_with : config_with(ollama_api_base: base))
        [transport.local?, transport.remote?]
      end

      expect(answers).to all(satisfy { |local, remote| local == !remote })
    end
  end
end
