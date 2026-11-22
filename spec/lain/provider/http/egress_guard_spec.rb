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

  def build_connection(literals: self.literals, hold: described_class::Unsupervised, max_retries: 0,
                       identity: described_class::Unaliased)
    config = zero_retry_config(max_retries:)
    config.anthropic_api_key = api_key
    config.http_middleware = [described_class.entry(literals:, journal:, hold:, identity:)]
    provider = Lain::Provider::HTTP::Providers::Anthropic.new(config)
    Lain::Provider::HTTP::Connection.new(provider, config)
  end

  def ok = { status: 200, body: "{}", headers: { "Content-Type" => "application/json" } }

  def body(*texts)
    { model: "claude-haiku-5-5", max_tokens: 64, system: "be terse",
      messages: texts.each_with_index.map { |text, at| { role: at.even? ? "user" : "assistant", content: text } } }
  end

  # A hold that supervises, answering each summary in turn from `answers`.
  def supervising(*answers, asked: [])
    Class.new do
      define_method(:supervises?) { true }
      define_method(:call) { |summary| (asked << summary) && answers.shift }
    end.new
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

    context "when the secret enters at a tool result" do
      def call_turn(name) = { role: "assistant", content: [{ type: "tool_use", id: name, name:, input: {} }] }

      def result_turn(text) = { role: "user", content: [{ type: "tool_result", tool_use_id: "x", content: text }] }

      def tool_request(*messages) = body("q").merge(messages:)

      it "names a count that lands on the settled turn before the tool call, not on the call" do
        stub_request(:post, url).to_return(ok)
        messages = [{ role: "user", content: "q" }, call_turn("a"), result_turn("got #{secret}"),
                    { role: "assistant", content: "ok" }, { role: "user", content: "next" }]

        expect(refusal_of(tool_request(*messages)).message).to include("message 3 of 5", "/rewind 4 ")
      end

      it "lands on the result of the earlier call when two calls run in a row" do
        stub_request(:post, url).to_return(ok)
        messages = [{ role: "user", content: "q" }, call_turn("a"), result_turn("fine"), call_turn("b"),
                    result_turn("got #{secret}")]

        expect(refusal_of(tool_request(*messages)).message).to include("message 5 of 5", "/rewind 2 ")
      end

      it "counts the whole request when the call is the first message" do
        stub_request(:post, url).to_return(ok)
        messages = [call_turn("a"), result_turn("got #{secret}")]

        expect(refusal_of(tool_request(*messages)).message).to include("/rewind 2 ")
      end
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

    it "is counted in a supervising hold's summary, which never carries the body" do
      stub_request(:post, url).to_return(ok)
      asked = []

      build_connection(hold: supervising(true, asked:)).post("/v1/messages", body("a token nobody listed: #{token}"))

      expect(asked.first).to include(endpoint: "api.anthropic.com/v1/messages", literal_hits: 0, flagged: 1)
      expect(asked.first.values.join(" ")).not_to include(token, "nobody listed")
    end

    describe "in a follow-up request" do
      let(:other) { %w[glpat- Xk3mQ9vR2tY7wP4nL8bZ].join }
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
        connection = build_connection(hold: supervising(false, false, asked:))

        2.times { refusal_of(body(*first), connection:) }

        expect(asked.size).to eq(2)
      end
    end
  end

  describe "under a supervising hold" do
    let(:sent) { stub_request(:post, url).to_return(ok) }

    it "asks before any byte leaves, naming the endpoint, the size and the body's digest" do
      asked = []
      sent_before = []
      registry = WebMock::RequestRegistry.instance
      pattern = sent.request_pattern
      hold = supervising(true, asked:)
      hold.define_singleton_method(:call) do |summary|
        (sent_before << registry.times_executed(pattern)) && super(summary)
      end

      build_connection(hold:).post("/v1/messages", body("what is 2 + 2?"))

      summary = asked.first
      expect(sent_before).to eq([0])
      expect(summary.keys).to contain_exactly(:endpoint, :bytes, :body_digest, :literal_hits, :flagged)
      expect(summary).to include(endpoint: "api.anthropic.com/v1/messages", literal_hits: 0, flagged: 0)
      expect(summary[:body_digest]).to match(/\Ablake3:\h{64}\z/)
      expect(summary[:bytes]).to be > "what is 2 + 2?".bytesize
      expect(sent).to have_been_requested.once
    end

    it "does not send a request the human denies, and says egress was denied" do
      sent

      refusal = refusal_of(body("what is 2 + 2?"), connection: build_connection(hold: supervising(false)))

      expect(refusal.message).to include("egress denied", "api.anthropic.com")
      expect(sent).not_to have_been_requested
    end

    it "asks once for a request its retry resends" do
      retried = stub_request(:post, url).to_timeout.then.to_return(ok)
      asked = []

      build_connection(hold: supervising(true, asked:), max_retries: 1).post("/v1/messages", body("hello"))

      expect(asked.size).to eq(1)
      expect(retried).to have_been_requested.twice
    end

    it "asks again for a different body, and for the same body sent again as a new request" do
      sent
      asked = []
      connection = build_connection(hold: supervising(true, true, true, asked:))

      connection.post("/v1/messages", body("hello"))
      connection.post("/v1/messages", body("hello", "hi", "again"))
      connection.post("/v1/messages", body("hello"))

      expect(asked.map { _1[:body_digest] }.uniq.size).to eq(2)
      expect(asked.size).to eq(3)
      expect(sent).to have_been_requested.times(3)
    end

    it "counts a credential shape in every request that carries it, not only the first" do
      sent
      asked = []
      token = "ghp_Ab9xQ7zK2mN4pR8sT1vW3yZ6cE5fH0jL"
      connection = build_connection(hold: supervising(true, true, asked:))

      connection.post("/v1/messages", body("here #{token}"))
      connection.post("/v1/messages", body("here #{token}", "ok", "again"))

      expect(asked.map { _1[:flagged] }).to eq([1, 1])
    end

    describe "over a value the masker knows but does not refuse on" do
      let(:literals) { source_of([secret], %w[supervised-flagged-value-0123]) }

      it "counts it as a known value, and never echoes it" do
        sent
        asked = []

        build_connection(hold: supervising(true, true, asked:)).tap do |connection|
          2.times { connection.post("/v1/messages", body("x supervised-flagged-value-0123")) }
        end

        expect(asked.map { _1[:literal_hits] }).to eq([1, 1])
        expect(asked.first.values.join(" ")).not_to include("supervised-flagged-value-0123")
      end
    end

    it "sends a bodiless GET without asking, under a supervising hold or an unbound one" do
      models = stub_request(:get, "https://api.anthropic.com/v1/models").to_return(ok)
      asked = []
      unbound = Lain::CLI::Backend::EgressHold.new("all").for(:agent)

      build_connection(hold: supervising(asked:)).get("/v1/models")
      build_connection(hold: unbound).get("/v1/models")

      expect(asked).to be_empty
      expect(models).to have_been_requested.twice
    end

    it "is not asked about a request the literals refuse" do
      sent
      asked = []

      refusal_of(body("the password is #{secret}"), connection: build_connection(hold: supervising(true, asked:)))

      expect(asked).to be_empty
      expect(sent).not_to have_been_requested
    end
  end

  it "neither asks the default hold nor digests the body for it" do
    sent = stub_request(:post, url).to_return(ok)
    allow(Lain::Canonical).to receive(:dump).and_call_original

    build_connection.post("/v1/messages", body("what is 2 + 2?"))

    expect(described_class::Unsupervised.supervises?).to be(false)
    expect(Lain::Canonical).not_to have_received(:dump)
    expect(sent).to have_been_requested.once
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

  describe "over a child env that lends a token" do
    let(:token) { "ghp_lent0account0token0value" }
    let(:account) { Class.new { define_method(:environment) { { "GH_TOKEN" => "ghp_lent0account0token0value" } } }.new }
    let(:child_env) { Lain::Exec::ChildEnv.new(env: {}, lend: Lain::Exec::ChildEnv::Lend.new(account)) }
    let(:literals) do
      Lain::Sensitivity::Secrets::Source.new(child_env:, history: Lain::Sensitivity::HistoryLiterals::Null)
    end

    it "refuses a body carrying the token once a child has been handed it" do
      sent = stub_request(:post, url).to_return(ok)
      child_env.call({})

      expect(refusal_of(body("my token is #{token}"))).to be_a(described_class::Refused)
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

  # The person and the box are aliased, never refused: a refusal is sticky, and
  # a home path rides almost every chat.
  describe "a body naming the home path and the account" do
    let(:identity) do
      Lain::Sensitivity::Secrets::Identity.current(env: { "HOME" => "/home/alice", "USER" => "alice" },
                                                   git: ->(_) {}, hostname: "wonder")
    end
    let(:sent) { [] }
    let(:connection) { build_connection(identity:) }

    before { stub_request(:post, url).to_return { |request| (sent << request.body) && ok } }

    def naming_home
      body("open /home/alice/dev/app/README.md", "alice's state is in /home/alice/.local/state/lain")
        .merge(system: "cwd: /home/alice/dev/app on wonder")
    end

    it "sends placeholders in every string in their place" do
      connection.post("/v1/messages", naming_home)

      expect(sent.sole).to include("/home/<lain:user>/dev/app/README.md", "<lain:user>'s state",
                                   "/home/<lain:user>/.local", "on <lain:host>")
      expect(sent.sole).not_to include("/home/alice", "alice", "wonder")
    end

    it "writes no refusal and refuses nothing later" do
      2.times { connection.post("/v1/messages", naming_home) }

      expect(sent.size).to eq(2)
      expect(journal.grep(Lain::Telemetry::EgressRefused)).to be_empty
    end

    it "sends the same bytes for the same body, so the cached prefix holds" do
      2.times { connection.post("/v1/messages", naming_home) }

      expect(sent.uniq.size).to eq(1)
    end

    it "leaves the caller's body as it was" do
      payload = naming_home

      connection.post("/v1/messages", payload)

      expect(payload[:messages].first[:content]).to eq("open /home/alice/dev/app/README.md")
    end

    it "aliases a value a JSON string leaf holds behind a literal escape" do
      at_srv = Lain::Sensitivity::Secrets::Identity.current(env: { "HOME" => "/srv/me" }, git: ->(_) {},
                                                            hostname: "wonder")

      build_connection(identity: at_srv).post("/v1/messages", body('{"cmd":"cd\\n/srv/me/dev"}'))

      expect(sent.sole).to include("/home/<lain:user>/dev")
      expect(sent.sole).not_to include("/srv/me")
    end

    # The real value no longer leaves, so there is nothing left to tell.
    it "no longer flags a home path the masker knows, once it is aliased" do
      flagging = build_connection(identity:, literals: source_of([], ["/home/alice/.password-store"]))

      flagging.post("/v1/messages", body("pass reads /home/alice/.password-store"))

      expect(sent.sole).to include("/home/<lain:user>/.password-store")
      expect(journal.grep(Lain::Telemetry::EgressRefused::Flagged)).to be_empty
    end

    it "still refuses a secret that spells the account name, judged before the alias" do
      payload = body("the password is alice-#{secret}")
      guarded = build_connection(identity:, literals: source_of(["alice-#{secret}"]))

      expect(refusal_of(payload, connection: guarded)).to be_a(described_class::Refused)
      expect(sent).to be_empty
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

    expect(entry).to eq([described_class, { literals:, journal:, hold: described_class::Unsupervised,
                                            identity: described_class::Unaliased }])
    expect(entry).to be_frozen
  end
end
