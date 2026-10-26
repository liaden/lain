# frozen_string_literal: true

require "digest"
require "json"
require "openssl"
require "socket"
require "tmpdir"

RSpec.describe Lain::Gateway::Server, :seam do
  let(:secret) { "s3cr3t-value-0123456789" }
  let(:token) { "0123456789abcdef0123456789abcdef" }
  let(:nonce) { "fedcba9876543210" * 4 }
  let(:dir) { Dir.mktmpdir("gateway-server") }
  let(:log) { File.join(dir, "gateway.ndjson") }
  let(:journal) { Lain::Journal.open(log) }
  let(:inspection) { Lain::Gateway::Inspection.new(literals: [secret]) }
  let(:upstream) { Lain::Gateway::Upstream.for("https://ollama.com") }
  let(:server) do
    described_class.new(bind: "127.0.0.1", port: 0, upstream:, inspection:, console:, journal:, token:)
  end
  let(:body) { JSON.generate({ model: "glm-5.3:cloud", stream: false, messages: [{ role: "user", content: "hi" }] }) }
  let(:chat) { "https://ollama.com/api/chat" }

  # Answers only when the example pushes an answer, and counts how many prompts
  # were open at once, so overlap is seen rather than inferred from timing.
  let(:console) do
    Class.new do
      attr_reader :shown, :answers, :most_open

      def initialize
        @shown = []
        @answers = Thread::Queue.new
        @lock = Mutex.new
        @open = 0
        @most_open = 0
      end

      def approve?(request)
        @lock.synchronize do
          @shown << request
          @open += 1
          @most_open = [@most_open, @open].max
        end
        @answers.pop
      ensure
        @lock.synchronize { @open -= 1 }
      end
    end.new
  end

  def connect = TCPSocket.new("127.0.0.1", server.port).tap { _1.timeout = 5 }

  def host = "127.0.0.1:#{server.port}"

  def send_post(socket, payload, path: "/api/chat", head: "Host: #{host}\r\n")
    socket.write("POST #{path} HTTP/1.1\r\n#{head}Content-Type: application/json\r\n" \
                 "Authorization: Bearer client-key\r\nContent-Length: #{payload.bytesize}\r\n\r\n#{payload}")
    socket
  end

  def raw(request) = answer(connect.tap { _1.write(request) })

  def answer(socket)
    head, payload = socket.read.split("\r\n\r\n", 2)
    status, *fields = head.split("\r\n")
    headers = fields.to_h { _1.split(": ", 2).then { |name, value| [name.downcase, value] } }
    { status: status[%r{\AHTTP/1\.1 (\d{3})}, 1].to_i, headers:, body: payload }
  ensure
    socket.close
  end

  def post(payload, path: "/api/chat", head: "Host: #{host}\r\n") = answer(send_post(connect, payload, path:, head:))

  def get(path) = raw("GET #{path} HTTP/1.1\r\nHost: #{host}\r\n\r\n")

  def records = File.foreach(log).map { JSON.parse(_1) }

  def outcomes = records.map { _1["outcome"] }

  around { |example| with_env("OLLAMA_API_KEY" => "gateway-key") { example.run } }

  before do
    stub_request(:post, chat).to_return(
      status: 200, body: '{"message":{"content":"ok"}}',
      headers: { "Content-Type" => "application/json; charset=utf-8", "X-Upstream-Trace" => "trace-1" }
    )
    @serving = Thread.new { server.run }
  end

  after do
    server.stop
    @serving.join(5)
    journal.close
    FileUtils.rm_rf(dir)
  end

  describe "binding" do
    it "shows its token-free URL when inspected, never the token" do
      expect(server.inspect).to include(server.url)
      expect(server.inspect).not_to include(token)
    end

    it "listens on loopback, its URL carrying no token" do
      expect(server.url).to eq("http://127.0.0.1:#{server.port}")
      expect(server.port).to be_positive
      expect { connect.close }.not_to raise_error
    end

    %w[0.0.0.0 ::1].each do |bind|
      it "refuses to bind to #{bind}" do
        expect do
          described_class.new(bind:, port: 0, upstream:, inspection:, console:, journal:, token:)
        end.to raise_error(ArgumentError, /loopback/)
      end
    end

    it "refuses a port already taken with an error naming the port" do
      expect do
        described_class.new(bind: "127.0.0.1", port: server.port, upstream:, inspection:, console:, journal:, token:)
      end.to raise_error(Lain::Error, /port #{server.port}/)
    end
  end

  describe "who may reach it" do
    it "takes a Host of localhost with its port, in any case" do
      console.answers << true

      expect(post(body, head: "Host: LocalHost:#{server.port}\r\n")[:status]).to eq(200)
    end

    {
      "another host" => "Host: rebound.example:%<port>d\r\n",
      "loopback on another port" => "Host: 127.0.0.1:1\r\n",
      "no port" => "Host: 127.0.0.1\r\n",
      "no Host at all" => "",
      "an Origin" => "Host: 127.0.0.1:%<port>d\r\nOrigin: http://127.0.0.1:%<port>d\r\n"
    }.each do |shape, head|
      it "refuses a request with #{shape} before the console" do
        reply = post(body, head: format(head, port: server.port))

        expect(reply[:status]).to eq(403)
        expect(console.shown).to be_empty
      end
    end

    it "refuses the identity path to a foreign Host" do
      reply = raw("GET #{Lain::Gateway::IDENTITY_PATH}?nonce=#{nonce} HTTP/1.1\r\nHost: rebound.example\r\n\r\n")

      expect(reply[:status]).to eq(403)
    end
  end

  describe "a request it cannot read" do
    it "answers 400 to a line too long, and the client sees it" do
      expect(raw("GET /#{"a" * 20_000} HTTP/1.1\r\nHost: #{host}\r\n\r\n")[:status]).to eq(400)
    end

    it "answers 400 to a header line too long, rather than reading its tail as another header" do
      reply = raw("GET #{Lain::Gateway::IDENTITY_PATH}?nonce=#{nonce} HTTP/1.1\r\nHost: #{host}\r\n" \
                  "X-A: #{"a" * 9000}\r\n\r\n")

      expect(reply[:status]).to eq(400)
    end

    it "answers nothing and records nothing for a body cut short" do
      client = connect
      client.write("POST /api/chat HTTP/1.1\r\nHost: #{host}\r\nContent-Length: #{body.bytesize + 10}\r\n\r\n#{body}")
      client.close_write

      expect(client.read).to eq("")
      expect(records).to be_empty
    ensure
      client&.close
    end

    it "answers 400 at once to a request ending its lines with a bare LF" do
      reply = raw("POST /api/chat HTTP/1.1\nHost: #{host}\nContent-Length: 2\n\n{}")

      expect(reply[:status]).to eq(400)
    end

    it "answers 400 to 2 differing Content-Length headers, asking nothing" do
      reply = raw("POST /api/chat HTTP/1.1\r\nHost: #{host}\r\nContent-Length: #{body.bytesize}\r\n" \
                  "Content-Length: 2\r\n\r\n#{body}")

      expect(reply[:status]).to eq(400)
      expect(console.shown).to be_empty
    end

    it "cuts a client that does not finish within the deadline and logs it timed out, without a body" do
      stub_const("Lain::Gateway::Server::READ_DEADLINE", 0.3)
      silent = connect.tap { _1.write("POST /api/chat HTTP/1.1\r\nHost: #{host}\r\n") }

      expect(answer(silent)[:status]).to eq(408)
      expect(records).to contain_exactly(a_hash_including("outcome" => "timed out"))
      expect(records.first.keys).not_to include("body")
    end

    it "keeps serving others while a silent connection waits on its deadline" do
      silent = connect.tap { _1.write("POST /api/chat HTTP/1.1\r\n") }
      console.answers << true

      expect(post(body)[:status]).to eq(200)
    ensure
      silent.close
    end
  end

  describe "the identity endpoint" do
    let(:path) { Lain::Gateway::IDENTITY_PATH }

    # The token never crosses the wire: a client proves the gateway by the
    # HMAC of a nonce it chose, keyed by the token it already holds.
    it "answers the HMAC of the caller's nonce under its token, and the paths it serves" do
      reply = get("#{path}?nonce=#{nonce}")

      expect(reply[:status]).to eq(200)
      expect(JSON.parse(reply[:body]))
        .to eq("proof" => OpenSSL::HMAC.hexdigest("SHA256", token, nonce), "paths" => ["/api/chat"])
    end

    it "names the anthropic path for an anthropic upstream" do
      anthropic = described_class.new(bind: "127.0.0.1", port: 0, upstream: Lain::Gateway::Upstream.for(
        "https://api.anthropic.com"
      ), inspection:, console:, journal:, token:)
      serving = Thread.new { anthropic.run }
      reply = answer(TCPSocket.new("127.0.0.1", anthropic.port).tap do |socket|
        socket.write("GET #{path}?nonce=#{nonce} HTTP/1.1\r\nHost: 127.0.0.1:#{anthropic.port}\r\n\r\n")
      end)

      expect(JSON.parse(reply[:body])["paths"]).to eq(["/v1/messages"])
    ensure
      anthropic&.stop
      serving&.join(5)
    end

    ["", "?nonce=", "?nonce=#{"a" * 31}", "?nonce=#{"g" * 32}", "?nonce=#{"a" * 129}", "?token=#{"0" * 32}"]
      .each do |query|
      it "answers 400 to the query #{query[0, 24].inspect}, which carries no usable nonce" do
        expect(get("#{path}#{query}")[:status]).to eq(400)
      end
    end

    it "answers while a prompt is open" do
      waiting = send_post(connect, body)
      wait_until(reason: "the prompt") { console.shown.size == 1 }

      expect(get("#{path}?nonce=#{nonce}")[:status]).to eq(200)
    ensure
      console.answers << false
      answer(waiting)
    end

    it "is not served to a POST, which is neither asked about nor forwarded" do
      expect(post(body, path:)[:status]).to eq(404)
      expect(console.shown).to be_empty
    end
  end

  describe "a request the human approves" do
    before { console.answers << true }

    it "shows the console the endpoint, the byte count and the body" do
      post(body)

      expect(console.shown.map(&:to_h)).to contain_exactly(
        a_hash_including(endpoint: "/api/chat", bytes: body.bytesize, body:)
      )
    end

    it "sends the upstream the same body with the gateway's own key" do
      post(body)

      expect(a_request(:post, chat).with(body:, headers: { "Authorization" => "Bearer gateway-key" }))
        .to have_been_made.once
    end

    it "relays the upstream's answer with only its content type and a recomputed length" do
      reply = post(body)

      expect(reply).to include(status: 200, body: '{"message":{"content":"ok"}}')
      expect(reply[:headers].keys).to contain_exactly("content-type", "content-length", "connection")
      expect(reply[:headers]["content-length"]).to eq(reply[:body].bytesize.to_s)
    end

    it "logs a forwarded line carrying the body's digest and not the body" do
      post(body)

      expect(records).to include(a_hash_including("outcome" => "forwarded", "endpoint" => "/api/chat",
                                                  "digest" => Digest::SHA256.hexdigest(body)))
      expect(File.read(log)).not_to include("hi\"")
    end

    it "refuses an answer whose content type is not application/json, relaying none of it" do
      stub_request(:post, chat).to_return(status: 200, body: "data: {}\n\n",
                                          headers: { "Content-Type" => "text/event-stream" })

      reply = post(body)

      expect(reply[:status]).to eq(502)
      expect(reply[:body]).not_to include("data:")
      expect(outcomes).to include("unrelayed")
    end
  end

  it "answers 403 and forwards nothing when the human says n" do
    console.answers << false

    expect(post(body)[:status]).to eq(403)
    expect(a_request(:post, chat)).not_to have_been_made
    expect(outcomes).to include("declined")
  end

  it "refuses a body carrying a known secret without asking the console" do
    reply = post(JSON.generate({ model: "m", stream: false, messages: [{ role: "user", content: secret }] }))

    expect(reply[:status]).to eq(403)
    expect(reply[:body]).not_to include(secret)
    expect(console.shown).to be_empty
    expect(a_request(:post, chat)).not_to have_been_made
  end

  it "refuses a path the upstream does not serve without asking the console" do
    expect(post(body, path: "/api/generate")[:status]).to eq(404)
    expect(console.shown).to be_empty
  end

  it "asks about concurrent requests one at a time, in order" do
    first = send_post(connect, body)
    wait_until(reason: "the first prompt") { console.shown.size == 1 }
    second = send_post(connect, body.sub("hi", "again"))
    sleep 0.3

    expect(console.shown.size).to eq(1)
    console.answers << true
    wait_until(reason: "the second prompt") { console.shown.size == 2 }
    console.answers << true

    expect([answer(first), answer(second)].map { _1[:status] }).to eq([200, 200])
    expect(console.most_open).to eq(1)
    expect(console.shown.last.body).to include("again")
  end

  it "drops without asking a request whose client went away while it waited its turn" do
    first = send_post(connect, body)
    wait_until(reason: "the first prompt") { console.shown.size == 1 }
    send_post(connect, body.sub("hi", "gone")).tap { sleep 0.3 }.close
    console.answers << true
    answer(first)

    wait_until(reason: "a client gone record") { outcomes.include?("client gone") }
    expect(console.shown.size).to eq(1)
    expect(a_request(:post, chat)).to have_been_made.once
  end

  describe "limits" do
    def gateway_threads = Thread.list.count { |thread| thread.backtrace.to_a.any?(%r{gateway/server\.rb}) }

    it "answers 400 to more headers than it reads" do
      expect(raw("GET / HTTP/1.1\r\nHost: #{host}\r\n#{"X-A: b\r\n" * 101}\r\n")[:status]).to eq(400)
    end

    it "answers 413 to a body over the inspection's limit without reading it or asking" do
      length = Lain::Gateway::Inspection::MAX_BYTES + 1
      reply = raw("POST /api/chat HTTP/1.1\r\nHost: #{host}\r\nContent-Length: #{length}\r\n\r\n")

      expect(reply[:status]).to eq(413)
      expect(console.shown).to be_empty
    end

    it "answers 411 to a body sent with a Transfer-Encoding" do
      reply = raw("POST /api/chat HTTP/1.1\r\nHost: #{host}\r\nTransfer-Encoding: chunked\r\n" \
                  "Content-Length: 2\r\n\r\n{}")

      expect(reply[:status]).to eq(411)
    end

    it "answers 503 beyond its open connections, logged without a body" do
      stub_const("Lain::Gateway::Server::MAX_CONNECTIONS", 2)
      open = Array.new(2) { connect }
      wait_until(reason: "2 connections read") { gateway_threads >= 3 }

      expect(get("#{Lain::Gateway::IDENTITY_PATH}?nonce=#{nonce}")[:status]).to eq(503)
      expect(records).to contain_exactly(a_hash_including("outcome" => "busy"))
      expect(records.first.keys).not_to include("body")
    ensure
      open&.each(&:close)
    end

    it "answers 503 beyond its queued asks, without asking" do
      stub_const("Lain::Gateway::Server::MAX_ASKS", 1)
      shown = send_post(connect, body)
      wait_until(reason: "the first prompt") { console.shown.size == 1 }
      queued = send_post(connect, body.sub("hi", "queued"))
      sleep 0.3

      expect(post(body.sub("hi", "over"))[:status]).to eq(503)
      expect(outcomes).to include("busy")
      2.times { console.answers << false }
      [shown, queued].each { answer(_1) }
      expect(console.shown.map(&:body)).not_to include(a_string_including("over"))
    end

    it "answers 503 to an open prompt's client when stopped, and ends its threads" do
      waiting = send_post(connect, body)
      wait_until(reason: "the prompt") { console.shown.size == 1 }
      server.stop

      expect(answer(waiting)[:status]).to eq(503)
      expect(@serving.join(5)).to be_truthy
      expect(gateway_threads).to eq(0)
      expect(a_request(:post, chat)).not_to have_been_made
    end
  end

  it "refuses as unasked, not declined, when the console cannot answer" do
    allow(console).to receive(:approve?).and_raise(Lain::Frontend::GatewayConsole::Unanswered, "stdin is closed")

    expect(post(body)[:status]).to eq(403)
    expect(records).to include(a_hash_including("outcome" => "unasked",
                                                "reason" => a_string_including("stdin is closed")))
  end

  it "drops a request whose client went away while its prompt was open" do
    client = send_post(connect, body)
    wait_until(reason: "the prompt") { console.shown.size == 1 }
    client.close
    console.answers << true

    wait_until(reason: "a client gone record") { File.exist?(log) && outcomes.include?("client gone") }
    expect(a_request(:post, chat)).not_to have_been_made
  end
end
