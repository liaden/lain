# frozen_string_literal: true

require "socket"

# A connection that never OPENS and a connection that never ANSWERS are two
# different failures, and {MiddlewareStack#setup_timeout} used to price them the
# same: it set `faraday.options.timeout` and nothing else, and Faraday derives
# `open_timeout` from `timeout` when only one is given
# (`Faraday::Adapter#request_timeout`). So an address that swallows the SYN held
# `connect()` for the full 300s -- and because `:post` is in
# `retry_options[:methods]` and `Faraday::ConnectionFailed` is in
# `retry_exceptions`, it held it four times. Twenty minutes, printing nothing.
# The stall clock cannot help: it arms on the first body chunk, and there is no
# body.
#
# The 300s protects a real shape -- a local model that thinks for six minutes
# (provider/ollama.rb) -- so it does not move. Opening a TCP socket is not that
# shape, and now has its own budget.
#
# Which is the whole of what moved, and the second `describe` below is here to
# keep it that way: a server that ACCEPTS and then says nothing still costs
# 4 x `request_timeout`. That case is not this card's, and shortening it would
# be the over-correction.
#
# Every example here drives a REAL socket, because the subject is what the
# kernel does with a SYN and neither WebMock nor a cassette has an opinion about
# that. Untagged with `:vcr` and never inside `VCR.use_cassette`, for the reason
# spec/lain/provider/http/stall_protection_spec.rb states: a replaying cassette
# makes `permit_loopback` inert.
#
# The numbers are scaled, not chosen. The shipped connect budget is 5s and the
# shipped request timeout is 300s; both are pinned unscaled in "the shipped
# defaults" below. What the timed examples prove is the SHAPE -- the connect
# phase ends at its own budget, the first-byte wait still gets the request
# timeout, and the two arrive at the built connection as different numbers.
RSpec.describe "the connect budget", :seam do
  let(:connect_budget) { 0.25 }

  def ollama_config(url, connect: connect_budget, request_timeout: 5, max_retries: nil)
    zero_retry_config(max_retries:).tap do |config|
      config.ollama_api_base = url
      config.request_timeout = request_timeout
      config.connect_timeout = connect
    end
  end

  def request(**overrides)
    Lain::Request.new(model: "qwen3:4b", max_tokens: 64, stream: false,
                      messages: [{ role: "user", content: "hi" }], **overrides)
  end

  # What ended the turn and how long it took. Both matter: a connect budget is a
  # claim about WHEN, and `expect { }.to raise_error` cannot say both in one
  # breath.
  def turn_outcome(url, **options)
    provider = Lain::Provider::Ollama.new(config: ollama_config(url, **options))
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = capture { provider.complete(request) }
    { error:, seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started }
  end

  def capture
    yield
    nil
  rescue StandardError => e
    e
  end

  # An endpoint whose SYN goes nowhere, built out of the kernel's accept queue
  # rather than out of an unroutable address: a bound listener re-`listen`ed to a
  # zero-length queue, with one sacrificial connection already parked in it, so
  # every further SYN is DROPPED. `tcp_abort_on_overflow` is 0 by default, which
  # is what makes the drop silent rather than an RST.
  #
  # A merely closed port would not do. It answers RST in microseconds, and an
  # instant refusal is the one connect failure that never needed a budget.
  def blackholed_endpoint
    server = TCPServer.new(StreamingUpstream::HOST, 0)
    server.listen(0)
    port = server.addr[1]
    filler = TCPSocket.new(StreamingUpstream::HOST, port)
    NetworkAccess.permit_loopback(port) { yield("http://#{StreamingUpstream::HOST}:#{port}", port) }
  ensure
    filler&.close
    server&.close
  end

  # Accepts the connection, then says nothing at all: the legitimate shape a
  # local model in prompt evaluation makes, and the one the request timeout is
  # there for.
  def silent_endpoint
    server = TCPServer.new(StreamingUpstream::HOST, 0)
    port = server.addr[1]
    accepted = []
    acceptor = Thread.new { loop { accepted << server.accept } }
    acceptor.name = "connect-budget-silent"
    NetworkAccess.permit_loopback(port) { yield("http://#{StreamingUpstream::HOST}:#{port}") }
  ensure
    acceptor&.kill
    accepted&.each(&:close)
    server&.close
  end

  describe "an endpoint that accepts no connection" do
    it "gives up within a small multiple of the connect budget, not of the request timeout" do
      outcome = nil
      blackholed_endpoint { |url, _port| outcome = turn_outcome(url) }

      expect(outcome[:seconds]).to be_between(connect_budget * 4, connect_budget * 12)
    end

    # A GUARD, not a driver: both clauses were already true before the connect
    # budget existed. `Net::OpenTimeout`'s "Failed to open TCP connection to
    # host:port" reaches the caller as an APIError through machinery this card
    # did not touch (NET_HTTP_EXCEPTIONS -> ConnectionFailed -> wrapping_errors),
    # so this passes against unfixed code -- it takes twenty seconds to do it,
    # which is the example above's business, not this one's. What it protects is
    # the error CONTRACT: a connect budget that ended the wait by escaping as a
    # raw Faraday class, or by losing the address, would fail here.
    #
    # Both halves in one example, because they are two claims about the same
    # object and the endpoint costs a second to exhaust.
    it "fails with the provider's own API error, naming the address it could not reach" do
      outcome = nil
      reached = nil
      blackholed_endpoint do |url, port|
        outcome = turn_outcome(url)
        reached = "#{StreamingUpstream::HOST}:#{port}"
      end

      expect(outcome[:error]).to be_a(Lain::Provider::Ollama::APIError)
        .and(have_attributes(message: a_string_including(reached)))
    end
  end

  # The other half of the same decision, and the one an over-correction breaks:
  # bounding connect must not shorten the wait for the first byte.
  describe "an endpoint that accepts and then says nothing" do
    it "waits out the request timeout rather than ending at the connect budget" do
      outcome = nil
      silent_endpoint { |url| outcome = turn_outcome(url, request_timeout: 1.5, max_retries: 0) }

      expect(outcome[:seconds]).to be_between(1.4, 4.0)
    end
  end

  describe "the shipped defaults" do
    # Untouched on purpose: a local model that thinks for six minutes is a real
    # shape, and all of that silence is post-connect.
    it "leaves the request timeout at the three hundred seconds it always had" do
      expect(Lain::Provider::HTTP::Configuration.new.request_timeout).to eq(300)
    end

    it "bounds the connect phase well under it" do
      config = Lain::Provider::HTTP::Configuration.new

      expect(config.connect_timeout).to be_between(1, 10).and(be < config.request_timeout)
    end
  end

  # Asserted on the BUILT connection, never on the Configuration. Faraday derives
  # one timeout from the other, so a Configuration holding two numbers proves
  # nothing about what the adapter is handed -- and `options.open_timeout` reads
  # nil, not 300, when the derivation is the thing doing the work.
  describe "the built Faraday connection" do
    let(:options) do
      Lain::Provider::Ollama::Transport
        .new(Lain::Provider::HTTP::Configuration.new).connection.connection.options
    end

    it "carries the request timeout as its read budget" do
      expect(options.timeout).to eq(300)
    end

    it "carries the connect budget as its own separate number" do
      expect(options.open_timeout).to be_a(Numeric).and(be < options.timeout)
    end

    # The probe asks for two seconds because a metadata lookup that cannot answer
    # promptly has answered. A connect budget longer than the whole round trip
    # would hand that wait straight back.
    it "never lets the connect budget outlast a shorter round trip" do
      probe = Lain::Provider::Ollama::Transport
              .new(Lain::Provider::HTTP::Configuration.new).probe_connection.connection.options

      expect(probe.open_timeout).to eq(Lain::Provider::Ollama::Transport::PROBE_TIMEOUT_SECONDS)
    end
  end

  describe "the environment override" do
    it "takes its budget from LAIN_CONNECT_TIMEOUT" do
      budget = with_env("LAIN_CONNECT_TIMEOUT" => "3") do
        Lain::Provider::HTTP::Configuration.new.connect_timeout
      end

      expect(budget).to eq(3.0)
    end

    # The off switch, and it is the old behaviour exactly: no separate connect
    # number, so Faraday derives one from `request_timeout` as it always did.
    it "reads zero there as folding connect back into the request timeout" do
      connection = with_env("LAIN_CONNECT_TIMEOUT" => "0") do
        Lain::Provider::Ollama::Transport.new(Lain::Provider::HTTP::Configuration.new).connection.connection
      end

      expect([connection.options.open_timeout, connection.options.timeout]).to eq([nil, 300])
    end

    it "refuses a budget that is not a number, where a human is still looking" do
      config = Lain::Provider::HTTP::Configuration.new
      config.connect_timeout = 12

      expect { config.connect_timeout = "soon" }
        .to raise_error(ArgumentError, /LAIN_CONNECT_TIMEOUT=0/)
      expect(config.connect_timeout).to eq(12)
    end
  end
end
