# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "webmock/rspec"

RSpec.describe Lain::Provider::HTTP::EgressGuard do
  let(:url) { "https://api.anthropic.com/v1/messages" }
  let(:secret) { "spec-db-password-24bytes" }
  let(:api_key) { "sk-ant-egress-guard-spec-key" }
  let(:journal) { [] }
  let(:reads) { [] }
  let(:literals) do
    log = reads
    source_of([secret, api_key]).tap { |source| source.define_singleton_method(:egress) { (log << :read) && super() } }
  end

  # A secrets source as the board's answers it, split into refused and flagged.
  def source_of(refused, flagged = [])
    egress = Lain::Sensitivity::Secrets::Egress.new(refused:, flagged:)
    Class.new { define_method(:egress) { egress } }.new
  end

  def build_connection(literals: self.literals, hold: described_class::Unsupervised, max_retries: 0)
    config = zero_retry_config(max_retries:)
    config.anthropic_api_key = api_key
    config.http_middleware = [described_class.entry(literals:, journal:, hold:)]
    provider = Lain::Provider::HTTP::Providers::Anthropic.new(config)
    Lain::Provider::HTTP::Connection.new(provider, config)
  end

  def ok = { status: 200, body: "{}", headers: { "Content-Type" => "application/json" } }

  def body(*texts)
    { model: "claude-haiku-5-5", max_tokens: 64, system: "be terse",
      messages: texts.each_with_index.map { |text, at| { role: at.even? ? "user" : "assistant", content: text } } }
  end

  def refusal_of(payload, connection: build_connection)
    connection.post("/v1/messages", payload)
  rescue described_class::Refused => e
    e
  end

  describe "a request whose body holds a known secret" do
    it "is never sent, and raises Refused" do
      sent = stub_request(:post, url).to_return(ok)

      expect { build_connection.post("/v1/messages", body("the password is #{secret}")) }
        .to raise_error(described_class::Refused)
      expect(sent).not_to have_been_requested
    end

    it "journals the endpoint host and a count, never the value" do
      stub_request(:post, url).to_return(ok)

      refusal_of(body("#{secret} and again #{secret}"))

      expect(journal.map(&:to_journal)).to eq(
        [{ "type" => "egress_refused", "host" => "api.anthropic.com", "count" => 1, "turn" => 1 }]
      )
    end

    it "finds a value held in a nested content block" do
      sent = stub_request(:post, url).to_return(ok)
      nested = body("hi").merge(messages: [{ role: "user", content: [{ type: "tool_result", tool_use_id: "t1",
                                                                       content: [{ type: "text",
                                                                                   text: "x#{secret}y" }] }] }])

      expect(refusal_of(nested)).to be_a(described_class::Refused)
      expect(sent).not_to have_been_requested
    end

    it "does not quote the value in its message" do
      stub_request(:post, url).to_return(ok)

      expect(refusal_of(body(secret)).message).not_to include(secret)
    end
  end

  describe "the refusal's way out" do
    let(:history) { Array.new(9) { |at| at == 6 ? "tool said #{secret}" : "turn #{at + 1}" } }

    it "names the first turn carrying the value and how far to rewind" do
      stub_request(:post, url).to_return(ok)

      message = refusal_of(body(*history)).message

      expect(message).to include("message 7 of 9", "/rewind 3", "after a compaction")
    end

    it "refuses every later request the same way while the turn is still there" do
      sent = stub_request(:post, url).to_return(ok)
      connection = build_connection

      first = refusal_of(body(*history), connection:)
      later = refusal_of(body(*history, "and another question"), connection:)

      expect([first, later]).to all(be_a(described_class::Refused))
      expect(later.message).to include("message 7 of 10", "/rewind 4")
      expect(sent).not_to have_been_requested
    end

    it "names the system prompt and the way out when only it holds the value" do
      stub_request(:post, url).to_return(ok)

      refusal = refusal_of(body("hello").merge(system: "keep #{secret} safe"))

      expect(refusal.message).to include("in the system prompt", "memory", "instructions file", "unset the variable",
                                         "restart")
      expect(journal.map(&:turn)).to eq([nil])
    end

    it "names the tool schemas when only they hold the value" do
      stub_request(:post, url).to_return(ok)
      tools = [{ name: "deploy", description: "uses #{secret}", input_schema: { type: "object" } }]

      expect(refusal_of(body("hello").merge(tools:)).message).to include("in the tool schemas", "restart")
    end
  end

  it "sends a clean request even though the API key, a known literal, rides its headers" do
    sent = stub_request(:post, url).with(headers: { "x-api-key" => api_key }).to_return(ok)

    build_connection.post("/v1/messages", body("what is 2 + 2?"))

    expect(sent).to have_been_requested.once
    expect(journal).to be_empty
  end

  describe "a shape-only hit" do
    let(:token) { "ghp_Zq8xV2nL4tR7yW1kP9mB3cJ6hD0sF5gA2eU7" }

    it "is sent and journaled with its region count" do
      sent = stub_request(:post, url).to_return(ok)

      build_connection.post("/v1/messages", body("a token nobody listed: #{token}"))

      expect(sent).to have_been_requested.once
      expect(journal.map(&:to_journal)).to eq([{ "type" => "egress_flagged", "host" => "api.anthropic.com",
                                                 "regions" => 1, "values" => 0 }])
    end

    it "is refused when the hold declines it" do
      sent = stub_request(:post, url).to_return(ok)
      asked = []
      hold = ->(summary) { (asked << summary) && false }

      refusal = refusal_of(body("a token nobody listed: #{token}"), connection: build_connection(hold:))

      expect(refusal).to be_a(described_class::Refused)
      expect(asked.first).to include("api.anthropic.com", "1")
      expect(asked.first).not_to include(token)
      expect(sent).not_to have_been_requested
    end

    describe "in a follow-up request" do
      let(:other) { "glpat-Xk3mQ9vR2tY7wP4nL8bZ" }
      let(:first) { ["a token nobody listed: #{token}", "noted"] }

      def flags = journal.grep(Lain::Telemetry::EgressRefused::Flagged)

      it "does not detect again a message an earlier request carried" do
        stub_request(:post, url).to_return(ok)
        connection = build_connection
        connection.post("/v1/messages", body(*first))
        detected = []
        allow(Lain::Sensitivity::Regions).to receive(:detect).and_wrap_original do |original, text|
          (detected << text) && original.call(text)
        end

        connection.post("/v1/messages", body(*first, "thanks"))

        expect(detected.join).not_to include(token)
        expect(flags.size).to eq(1)
      end

      it "still journals a new high-entropy string" do
        stub_request(:post, url).to_return(ok)
        connection = build_connection
        connection.post("/v1/messages", body(*first))

        connection.post("/v1/messages", body(*first, "and another: #{other}"))

        expect(flags.map(&:regions)).to eq([1, 1])
      end

      it "asks again about a message the hold declined, since it was never sent" do
        stub_request(:post, url).to_return(ok)
        asked = []
        connection = build_connection(hold: ->(summary) { (asked << summary) && false })

        2.times { refusal_of(body(*first), connection:) }

        expect(asked.size).to eq(2)
      end
    end
  end

  describe "among many known values" do
    let(:many) { Array.new(40) { |at| "fake-many-literal-#{at.to_s.rjust(4, "0")}" } }
    let(:literals) { source_of([*many, "fa(ke).*+?[x]|{2}-pw"]) }

    it "finds the last one, and a value full of pattern characters only as itself" do
      sent = stub_request(:post, url).to_return(ok)

      expect(refusal_of(body("x #{many.last} y"))).to be_a(described_class::Refused)
      expect(refusal_of(body("x fa(ke).*+?[x]|{2}-pw y"))).to be_a(described_class::Refused)
      build_connection.post("/v1/messages", body("fake.*+?x"))
      expect(sent).to have_been_requested.once
    end
  end

  describe "a value hidden in the body's shape" do
    it "is refused as a Hash key, as in a tool call's input" do
      sent = stub_request(:post, url).to_return(ok)
      input = { secret => "v" }
      shaped = body("hi").merge(messages: [{ role: "assistant",
                                             content: [{ type: "tool_use", id: "t", name: "bash", input: }] }])

      expect(refusal_of(shaped)).to be_a(described_class::Refused)
      expect(sent).not_to have_been_requested
    end

    it "is refused as a Symbol value" do
      sent = stub_request(:post, url).to_return(ok)

      expect(refusal_of(body("hi").merge(metadata: { user_id: secret.to_sym }))).to be_a(described_class::Refused)
      expect(sent).not_to have_been_requested
    end
  end

  describe "a value the masker knows but does not refuse on" do
    let(:literals) { source_of([secret], %w[staging-eu-west /run/user/1000/ssh-agent.socket]) }

    it "is sent, and journaled as a flag with its count, never the value" do
      sent = stub_request(:post, url).to_return(ok)

      build_connection.post("/v1/messages", body("deploy to staging-eu-west via /run/user/1000/ssh-agent.socket"))

      expect(sent).to have_been_requested.once
      expect(journal.map(&:to_journal)).to eq([{ "type" => "egress_flagged", "host" => "api.anthropic.com",
                                                 "regions" => 0, "values" => 2 }])
    end
  end

  # The board's own source over a repository whose committed .env holds
  # ordinary config beside a secret, and an environment whose secret-shaped
  # names hold paths. Every value here is a spec-owned fake.
  describe "over a real secrets source", :seam do
    let(:high) { "Zq8xV2nL4tR7yW1kP9mB3cJ6hD0sF5gA" }
    let(:env) do
      { "DB_PASSWORD" => "spec-db-password-24bytes", "SSH_AUTH_SOCK" => "/run/user/1000/ssh-agent.socket",
        "PASSWORD_STORE_DIR" => "/home/probe/.password-store" }
    end
    let(:literals) do
      root = @root
      policy = Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home: @home, cwd: root, root:),
                                             home: @home, root:)
      history = Lain::Sensitivity::HistoryLiterals.new(root:, policy:).prime
      Lain::Sensitivity::Secrets::Source.new(child_env: Lain::Exec::ChildEnv.new(env:), history:)
    end

    around do |example|
      Dir.mktmpdir("egress-guard-source") do |dir|
        @home = File.join(dir, "home")
        @root = File.join(dir, "repo")
        FileUtils.mkdir_p([@home, @root])
        seed_repo(@root)
        example.run
      end
    end

    def seed_repo(root)
      SeedRepo.git(root, "init", "-q")
      SeedRepo.git(root, "config", "user.email", "test@example.com")
      SeedRepo.git(root, "config", "user.name", "Test")
      File.write(File.join(root, ".env"), "APP_ENV=staging-eu\nAPP_HOST=myapp.internal:8080\n" \
                                          "LOG_LEVEL=verbose-debug\nBUILD_SALT=#{high}\n")
      SeedRepo.git(root, "add", ".env")
      SeedRepo.git(root, "commit", "-q", "-m", "init")
    end

    [["deploy to staging-eu please", 1], ["the server listens on myapp.internal:8080", 1],
     ["set the log to verbose-debug", 1],
     ["systemd's agent listens at /run/user/1000/ssh-agent.socket by default", 1],
     ["pass keeps its store in /home/probe/.password-store", 1]].each do |sentence, values|
      it "sends #{sentence.inspect} and flags it" do
        sent = stub_request(:post, url).to_return(ok)

        build_connection.post("/v1/messages", body(sentence))

        expect(sent).to have_been_requested.once
        expect(journal.map(&:to_journal)).to eq([{ "type" => "egress_flagged", "host" => "api.anthropic.com",
                                                   "regions" => 0, "values" => values }])
      end
    end

    it "refuses a secret-named environment value" do
      sent = stub_request(:post, url).to_return(ok)

      expect(refusal_of(body("use spec-db-password-24bytes"))).to be_a(described_class::Refused)
      expect(sent).not_to have_been_requested
    end

    it "refuses a high-entropy value history holds under an ordinary name" do
      sent = stub_request(:post, url).to_return(ok)

      expect(refusal_of(body("the salt was #{high}"))).to be_a(described_class::Refused)
      expect(sent).not_to have_been_requested
    end
  end

  describe "ordinary chat history" do
    let(:literals) { source_of(%w[hunter2 dev]) }

    it "is not refused for a value under the literal floor, nor for a lineage digest" do
      sent = stub_request(:post, url).to_return(ok)
      digest = "blake3:#{"ab12" * 16}"

      build_connection.post("/v1/messages", body("user hunter2 typed dev; spawned_from #{digest}"))

      expect(sent).to have_been_requested.once
      expect(journal.grep(Lain::Telemetry::EgressRefused)).to be_empty
    end
  end

  it "runs once per attempt when a request is retried" do
    stub_request(:post, url).to_timeout.then.to_return(ok)

    build_connection(max_retries: 1).post("/v1/messages", body("hello"))

    expect(reads.size).to eq(2)
  end

  describe "before its literals are bound" do
    let(:literals) do
      Class.new { define_method(:egress) { raise Lain::Provider::HTTP::EgressGuard::NotBound, "not bound" } }.new
    end

    it "refuses a request that carries a body, naming why" do
      sent = stub_request(:post, url).to_return(ok)

      expect { build_connection.post("/v1/messages", body("hello")) }
        .to raise_error(described_class::Refused, /egress guard not ready/)
      expect(sent).not_to have_been_requested
    end

    it "passes a bodiless GET probe" do
      models = stub_request(:get, "https://api.anthropic.com/v1/models").to_return(ok)

      build_connection.get("/v1/models")

      expect(models).to have_been_requested.once
    end
  end

  it "is the entry shape the configured middleware seat takes" do
    entry = described_class.entry(literals:, journal:)

    expect(entry).to eq([described_class, { literals:, journal:, hold: described_class::Unsupervised }])
    expect(entry).to be_frozen
  end
end
