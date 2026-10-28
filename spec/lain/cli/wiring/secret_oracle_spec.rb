# frozen_string_literal: true

require "json"
require "openssl"

RSpec.describe Lain::CLI::Wiring::SecretOracle do
  let(:root) { Dir.mktmpdir("secret-oracle-spec") }
  let(:backend) { Lain::CLI::Backend.new({ provider: "ollama", model: nil, max_tokens: 64 }, root:) }
  let(:journal) { [] }
  let(:token) { "0123456789abcdef0123456789abcdef" }
  let(:cloud) { { secret_oracle: "cloud", secret_oracle_model: "glm-5.3:cloud", gateway: "http://127.0.0.1:4000" } }
  let(:state) { Dir.mktmpdir("secret-oracle-state") }

  around do |example|
    with_env("XDG_STATE_HOME" => state) { example.run }
  ensure
    FileUtils.rm_rf(state)
  end

  before { Lain::Gateway::TokenFile.for(4000).write(token) }

  after { FileUtils.rm_rf(root) }

  def lending(value)
    egress = Lain::Sensitivity::Secrets::Egress.new(refused: [value], flagged: [])
    Class.new { define_method(:egress) { |**| egress } }.new
  end

  def tier_model(oracle) = oracle.tier(backend, journal).instance_variable_get(:@inner).model

  it "is off when the flag is absent or off" do
    expect([described_class.new({}), described_class.new({ secret_oracle: "off" })].map(&:on?)).to eq([false, false])
  end

  it "refuses a value the flag does not take" do
    expect { described_class.new({ secret_oracle: "remote" }) }.to raise_error(Lain::Error, /off, local or cloud/)
  end

  it "refuses --gateway unless --secret-oracle is cloud, naming the flag" do
    expect { described_class.new({ secret_oracle: "local", gateway: "http://127.0.0.1:4000" }) }
      .to raise_error(Lain::Error, /--gateway.*--secret-oracle cloud/)
  end

  it "refuses --secret-oracle-model when the oracle is off, naming the flag" do
    expect { described_class.new({ secret_oracle: "off", secret_oracle_model: "qwen3:8b" }) }
      .to raise_error(Lain::Error, /--secret-oracle-model/)
  end

  it "refuses cloud with no --gateway, naming the command that prints one" do
    expect { described_class.new({ secret_oracle: "cloud", secret_oracle_model: "glm-5.3:cloud" }) }
      .to raise_error(Lain::Oracle::SecretRead::NotAGateway, /lain gateway --upstream.*--gateway/)
  end

  it "refuses cloud with no --secret-oracle-model, naming it" do
    expect { described_class.new({ secret_oracle: "cloud", gateway: "http://127.0.0.1:4000" }) }
      .to raise_error(Lain::Error, /--secret-oracle-model/)
  end

  it "refuses cloud with a --gateway off loopback before any network, though a token file waits for its port" do
    expect { described_class.new(cloud.merge(gateway: "https://ollama.com:4000")) }
      .to raise_error(Lain::Oracle::SecretRead::NotAGateway, %r{https://ollama\.com is not one})
  end

  # The holder line a lock writes is the process's argv, so a token on the
  # command line would sit in a readable file for as long as the lock is held.
  describe "the token and the command line" do
    let(:lock) { Lain::FileLock.new(File.join(state, "spec.lock")) }

    it "refuses a --gateway that carries the token, so it never reaches argv" do
      expect { described_class.new(cloud.merge(gateway: "http://127.0.0.1:4000/?token=#{token}")) }
        .to raise_error(Lain::Oracle::SecretRead::NotAGateway, /token file/)
    end

    it "launches from a command line, and so a lock holder's line, that carries no token" do
      argv = ["chat", "--secret-oracle", "cloud", "--secret-oracle-model", "glm-5.3:cloud", "--gateway",
              cloud[:gateway]]
      stub_const("ARGV", argv)
      described_class.new(cloud)

      line = lock.hold { lock.holder }
      expect(line).to include("--gateway http://127.0.0.1:4000")
      expect(line).not_to include(token)
    end
  end

  describe "the cloud tier at launch", :seam do
    def answering(paths)
      stub_request(:get, %r{\Ahttp://127\.0\.0\.1:4000/lain-gateway/identity}).to_return do |request|
        nonce = URI.decode_www_form(URI(request.uri.to_s).query).assoc("nonce").last
        { status: 200, body: JSON.generate("proof" => OpenSSL::HMAC.hexdigest("SHA256", token, nonce), "paths" => paths) }
      end
    end

    before do
      backend.egress_literals.bind(lending("lent-secret-value-0123"), ledger: Lain::Sensitivity::Ledger.new)
      backend.egress_hold.bind(nil)
    end

    it "proves the gateway once while building the tier" do
      proved = answering(["/api/chat"])

      described_class.new(cloud).tier(backend, journal)

      expect(proved).to have_been_requested.once
    end

    it "refuses when the gateway's upstream does not serve the model's path" do
      answering(["/v1/messages"])

      expect { described_class.new(cloud).tier(backend, journal) }
        .to raise_error(Lain::Oracle::SecretRead::NotAGateway, %r{/v1/messages.*/api/chat})
    end
  end

  it "judges locally on the local default model unless --secret-oracle-model names another" do
    expect([tier_model(described_class.new({ secret_oracle: "local" })),
            tier_model(described_class.new({ secret_oracle: "local", secret_oracle_model: "qwen3:8b" }))])
      .to eq([Lain::Provider::Ollama::DEFAULT_MODEL, "qwen3:8b"])
  end

  it "refuses a cloud model name on the local tier" do
    expect do
      described_class.new({ secret_oracle: "local", secret_oracle_model: "glm-5.3:cloud" }).tier(backend, journal)
    end
      .to raise_error(Lain::Oracle::SecretRead::NotAGateway, /--secret-oracle cloud/)
  end

  it "guards the local oracle's requests with the backend's own egress literals" do
    stub_request(:post, "http://localhost:11434/api/chat")
    backend.egress_literals.bind(lending("lent-secret-value-0123"), ledger: Lain::Sensitivity::Ledger.new)
    backend.egress_hold.bind(nil)
    tier = described_class.new({ secret_oracle: "local" }).tier(backend, journal)

    expect { tier.ask(path: '"/home/user/lent-secret-value-0123"', tool: "read_file", region_count: "0") }
      .to raise_error(Lain::Provider::HTTP::EgressGuard::Refused)
    expect(a_request(:post, "http://localhost:11434/api/chat")).not_to have_been_made
  end
end
