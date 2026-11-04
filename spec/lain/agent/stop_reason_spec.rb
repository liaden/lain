# frozen_string_literal: true

# Why an ask stopped, read off the error's type and its causes, never its
# message: the text is the provider's to change, and a record classified by it
# would silently re-classify the day the words moved.
RSpec.describe Lain::Agent::StopReason do
  def caused_by(cause, error)
    raise cause
  rescue StandardError
    begin
      raise error
    rescue StandardError => e
      e
    end
  end

  def status_error(status) = Lain::Provider::Ollama::APIStatusError.new("status #{status}", status:)

  it "names a budget ceiling" do
    expect(described_class.for(Lain::Budget::Exceeded.new("loop ran 25 iterations"))).to eq(:ceiling)
  end

  it "names a prompt refused for not fitting the context" do
    refusal = Lain::Middleware::RequestBudget::OverWindow.new("refused", prompt_tokens: 9, window_tokens: 8,
                                                                         source: "ollama")

    expect(described_class.for(refusal)).to eq(:over_window)
  end

  # A stall never reaches an ask as itself: the provider re-raises it as its
  # own APIError, so the stall survives only as the cause.
  it "names a stalled stream by its cause, not as the transport failure it is wrapped in" do
    stall = Lain::Provider::HTTP::Streaming::StalledStreamError.new("no chunk for 30.0s")

    wrapped = caused_by(stall, Lain::Provider::Anthropic::APIError.new("no chunk"))

    expect(described_class.for(wrapped)).to eq(:stalled_stream)
  end

  it "names a stop this ask was asked for, wherever it sits in the causes" do
    expect(described_class.for(Lain::Stopped.new("stopped"))).to eq(:stopped)
    expect(described_class.for(caused_by(Lain::Stopped.new("stopped"), Lain::Error.new("unwound")))).to eq(:stopped)
  end

  describe "a provider quota" do
    let(:quota) { Lain::Provider::HTTP::QuotaError.new("session usage limit reached") }

    def wrapped_quota(response: nil)
      error = response ? Lain::Provider::HTTP::QuotaError.new(response, "session usage limit reached") : quota
      caused_by(error, status_error(429))
    end

    it "names a quota by its cause, ahead of the 429 transport reading" do
      expect(described_class.for(wrapped_quota)).to eq(:quota)
    end

    it "still calls a plain 429 transport" do
      expect(described_class.for(caused_by(Lain::Provider::HTTP::RateLimitError.new("slow"), status_error(429))))
        .to eq(:transport)
    end

    it "gives the provider's words as the detail, bounded" do
      expect(described_class.detail(wrapped_quota)).to eq("session usage limit reached")
      long = caused_by(Lain::Provider::HTTP::QuotaError.new("x" * 5000), status_error(429))
      expect(described_class.detail(long).length).to eq(described_class::DETAIL_LIMIT)
    end

    it "has no detail for an error that is not a quota" do
      expect(described_class.detail(status_error(429))).to be_nil
    end

    it "reads the reset from Retry-After as a time" do
      response = Struct.new(:status, :body, :headers).new(429, "", { "retry-after" => "120" })

      reset = Time.iso8601(described_class.reset_at(wrapped_quota(response:)))

      expect(reset).to be_within(5).of(Time.now + 120)
    end

    it "reads Retry-After off a real Faraday header set," do
      headers = Faraday::Utils::Headers.new("Retry-After" => "120")
      response = Struct.new(:status, :body, :headers).new(429, "", headers)

      expect(Time.iso8601(described_class.reset_at(wrapped_quota(response:)))).to be_within(5).of(Time.now + 120)
    end

    it "has no reset when the response carries no header" do
      expect(described_class.reset_at(wrapped_quota)).to be_nil
    end
  end

  describe "a transport failure" do
    it "names a round trip that never reached the wire" do
      expect(described_class.for(Lain::Provider::Ollama::PreWireError.new("refused"))).to eq(:transport)
    end

    it "names a round trip that got no status back at all" do
      expect(described_class.for(Lain::Provider::Anthropic::APIError.new("connection reset"))).to eq(:transport)
    end

    it "names a server-side failure" do
      expect(described_class.for(status_error(503))).to eq(:transport)
    end

    # Both fail for the moment rather than for the request: a timeout and a
    # rate limit answer differently a little later.
    it "names a request timeout and a rate limit" do
      expect(described_class.for(status_error(408))).to eq(:transport)
      expect(described_class.for(status_error(429))).to eq(:transport)
    end

    it "names an endpoint too busy to take the call" do
      expect(described_class.for(Lain::Provider::Admission::Busy.new("busy"))).to eq(:transport)
    end

    # The request's own fault -- a bad key, a model the server does not have --
    # fails the same way every time, which no transport does.
    it "does not name a status the request itself earned" do
      expect(described_class.for(status_error(401))).not_to eq(:transport)
    end
  end

  describe "a request the provider rejected by its own status" do
    it "names a bad key and a model the server does not have" do
      expect(described_class.for(status_error(401))).to eq(:rejected)
      expect(described_class.for(status_error(404))).to eq(:rejected)
    end

    it "leaves a momentary or server-side status to the transport" do
      expect([408, 429, 503].map { |status| described_class.for(status_error(status)) }).to all(eq(:transport))
    end
  end

  describe ".status" do
    it "answers the status a rejected request earned" do
      expect(described_class.status(status_error(404))).to eq(404)
    end

    it "answers nothing for a failure that carries no status" do
      expect(described_class.status(Lain::Error.new("x"))).to be_nil
    end
  end

  it "says middleware for a member that raised" do
    failed = Lain::Middleware::MemberFailed.new(Object.new, RuntimeError.new("boom"))

    expect(described_class.for(failed)).to eq(:middleware)
    expect(Lain::Telemetry::RunInterrupted::REASONS).to include(:middleware)
  end

  it "reads a member failure only at the head of the chain, as the ceiling is" do
    failed = Lain::Middleware::MemberFailed.new(Object.new, RuntimeError.new("boom"))
    outer = Lain::Error.new("wrapped")
    allow(outer).to receive(:cause).and_return(failed)

    expect(outer.cause).to be(failed)
    expect(described_class.for(outer)).to eq(:torn)
  end

  it "says torn for anything it cannot place" do
    expect(described_class.for(Lain::Error.new("no known kind"))).to eq(:torn)
    expect(described_class.for(RuntimeError.new("a bug"))).to eq(:torn)
  end

  # Faraday's retry middleware already re-sends a failed connection and a
  # momentary status, so only what reaches past it may be retried again above.
  describe ".dropped?" do
    def chained(*errors) = errors.drop(1).reduce(errors.first) { |cause, error| caused_by(cause, error) }

    def round_trip_failure(*causes) = chained(*causes, Lain::Provider::Ollama::APIError.new("round trip failed"))

    # The adapter's own shape: Faraday::SSLError wraps the OpenSSL error and takes its message.
    def tls_failure(message)
      openssl = OpenSSL::SSL::SSLError.new(message)
      round_trip_failure(openssl, Faraday::SSLError.new(openssl))
    end

    def read_eof = tls_failure("SSL_read: unexpected eof while reading")

    it "is true for a TLS read that ended early" do
      expect(described_class.dropped?(read_eof)).to be(true)
    end

    it "is false for a certificate the handshake refused" do
      refused = tls_failure("SSL_connect returned=1 errno=0 peeraddr=127.0.0.1:443 state=error: " \
                            "certificate verify failed (self-signed certificate)")

      expect(described_class.dropped?(refused)).to be(false)
    end

    it "is false for an end of file or an OpenSSL error no Faraday::SSLError carries" do
      bare = [EOFError.new("end of file reached"), OpenSSL::SSL::SSLError.new("SSL_read: unexpected eof while reading")]

      expect(bare.map { |cause| described_class.dropped?(round_trip_failure(cause)) }).to eq([false, false])
    end

    it "is false for an end of file the adapter raised as a failed connection" do
      failed = round_trip_failure(EOFError.new("end of file reached"), Faraday::ConnectionFailed.new("eof"))

      expect(described_class.dropped?(failed)).to be(false)
    end

    it "is false for a server-side status" do
      expect(described_class.dropped?(status_error(503))).to be(false)
    end

    it "is false for a stalled stream" do
      stalled = round_trip_failure(Lain::Provider::HTTP::Streaming::StalledStreamError.new("stalled stream"))

      expect(described_class.dropped?(stalled)).to be(false)
    end

    it "is false when a stop unwound through the drop" do
      stopped = caused_by(read_eof, Lain::Stopped.new("stopped"))

      expect(described_class.dropped?(stopped)).to be(false)
    end

    it "still reads a drop that ends the run as transport" do
      expect(described_class.for(read_eof)).to eq(:transport)
    end
  end

  it "answers only reasons the run_interrupted record accepts" do
    reasons = [Lain::Error.new("x"), Lain::Stopped.new("x"), status_error(500)].map { |error| described_class.for(error) }

    expect(Lain::Telemetry::RunInterrupted::REASONS).to include(*reasons)
  end
end

# The read-phase prefix `dropped?` keys on is the openssl binding's wording, so
# it is pinned here against the errors a real Provider::Ollama raises off a
# loopback TLS server, never only against strings typed into a spec.
RSpec.describe Lain::Agent::StopReason, ".dropped? on a real TLS wire", :seam do
  let(:key) { OpenSSL::PKey::RSA.new(2048) }
  let(:cert) do
    OpenSSL::X509::Certificate.new.tap do |cert|
      cert.version = 2
      cert.serial = 1
      cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=localhost")
      cert.public_key = key.public_key
      cert.not_before = Time.now - 60
      cert.not_after = Time.now + 3600
      extensions = OpenSSL::X509::ExtensionFactory.new(cert, cert)
      cert.add_extension(extensions.create_extension("subjectAltName", "DNS:localhost,IP:127.0.0.1"))
      cert.add_extension(extensions.create_extension("basicConstraints", "CA:TRUE", true))
      cert.sign(key, OpenSSL::Digest.new("SHA256"))
    end
  end
  let(:dir) { Dir.mktmpdir("tls-wire") }
  let(:trusted) { File.join(dir, "cert.pem").tap { |path| File.write(path, cert.to_pem) } }

  after { FileUtils.rm_rf(dir) }

  # Sends 1 NDJSON chunk of a 200, then closes the socket under the TLS
  # session without a close_notify: the client's read ends early.
  def serve_one_chunk_then_drop(ssl, raw)
    ssl.accept
    head = +""
    head << ssl.readpartial(65_536) until head.include?("\r\n\r\n")
    body = head.split("\r\n\r\n", 2)[1].to_s
    body << ssl.readpartial(65_536) while body.bytesize < head[/content-length: (\d+)/i, 1].to_i
    message = { "model" => "m", "message" => { "role" => "assistant", "content" => "half " }, "done" => false }
    line = "#{JSON.generate(message)}\n"
    ssl.write("HTTP/1.1 200 OK\r\ncontent-type: application/x-ndjson\r\ntransfer-encoding: chunked\r\n\r\n" \
              "#{line.bytesize.to_s(16)}\r\n#{line}\r\n")
    ssl.flush
    sleep 0.05
    raw.close
  end

  def failure_off_the_wire(cert_file)
    tcp = TCPServer.new("127.0.0.1", 0)
    context = OpenSSL::SSL::SSLContext.new.tap do |ctx|
      ctx.cert = cert
      ctx.key = key
    end
    server = Thread.new do
      raw = tcp.accept
      serve_one_chunk_then_drop(OpenSSL::SSL::SSLSocket.new(raw, context), raw)
    rescue StandardError
      raw&.close
    end
    asked(tcp.addr[1], cert_file)
  ensure
    server&.join(5)
    tcp&.close
  end

  def asked(port, cert_file)
    kept = ENV.fetch("SSL_CERT_FILE", nil)
    ENV["SSL_CERT_FILE"] = cert_file
    provider = Lain::Provider::Ollama.local(api_base: "https://localhost:#{port}")
    agent = Lain::Agent.new(model_caller: Lain::Agent::ModelCaller.new(provider:), toolset: Lain::Toolset.new([]),
                            context: Lain::Context.new(model: "m", max_tokens: 64))
    NetworkAccess.permit_loopback(port) { agent.ask("hi") }
    raise "the wire answered; nothing dropped"
  rescue Lain::Provider::Ollama::APIError => e
    e
  ensure
    ENV["SSL_CERT_FILE"] = kept
  end

  def tls_cause(error) = Enumerator.produce(error, &:cause).take_while(&:itself).find { _1.is_a?(Faraday::SSLError) }

  it "is true for the error a stream that lost its peer mid-body raises" do
    dropped = failure_off_the_wire(trusted)

    expect(tls_cause(dropped)).to be_a(Faraday::SSLError)
    expect(described_class.dropped?(dropped)).to be(true)
  end

  it "is false for the error a refused certificate raises" do
    refused = failure_off_the_wire(File::NULL)

    expect(tls_cause(refused)).to be_a(Faraday::SSLError)
    expect(described_class.dropped?(refused)).to be(false)
  end
end
