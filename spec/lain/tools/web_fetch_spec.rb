# frozen_string_literal: true

# A minimal Faraday-response duck: status, headers, body -- what the tool reads
# for redirect detection. Specs never hit the network; the connection injected.
WebFetchStubResponse = Struct.new(:status, :headers, :body, keyword_init: true)

# The request/options/env shapes Faraday hands the streaming block. The tool
# sets `req.options.on_data`; the connection drives it with body chunks.
WebFetchFakeEnv = Struct.new(:status, keyword_init: true)

class WebFetchFakeOptions
  attr_accessor :on_data
end

class WebFetchFakeRequest
  def options = @options ||= WebFetchFakeOptions.new
end

# A connection that answers every #get through an injected responder, drives the
# streaming callback with the response body in one chunk, and records the args it
# was called with (so "no auth header" is provable). Mirrors Faraday 2's shape:
# `conn.get(url) { |req| req.options.on_data = proc }`, body delivered via on_data.
class WebFetchStubConnection
  attr_reader :calls

  def initialize(&responder)
    @responder = responder
    @calls = []
  end

  def get(url, *args)
    @calls << [url, args]
    response = @responder.call(url)
    deliver(response) { |req| yield req if block_given? }
    response
  end

  private

  def deliver(response)
    request = WebFetchFakeRequest.new
    yield request
    on_data = request.options.on_data
    return unless on_data

    body = response.body.to_s
    on_data.call(body, body.bytesize, WebFetchFakeEnv.new(status: response.status))
  end
end

# A LAZY streaming connection for the memory-bound probe: it generates fixed-size
# chunks on demand and counts how many it fed, so a spec can prove the tool STOPS
# reading past the cap rather than buffering the whole body first.
class WebFetchStreamingConnection
  attr_reader :chunks_fed

  def initialize(total_chunks:, chunk_size:, status: 200)
    @total_chunks = total_chunks
    @chunk_size = chunk_size
    @status = status
    @chunks_fed = 0
  end

  def get(_url, *_args)
    request = WebFetchFakeRequest.new
    yield request if block_given?
    drive(request.options.on_data)
    WebFetchStubResponse.new(status: @status, headers: {}, body: "")
  end

  private

  # Raising out of on_data (the tool's byte cap) unwinds this loop -- exactly how
  # Faraday aborts a stream -- so a bounded read leaves chunks_fed small.
  def drive(on_data)
    env = WebFetchFakeEnv.new(status: @status)
    @total_chunks.times do
      chunk = "x" * @chunk_size
      @chunks_fed += 1
      on_data.call(chunk, @chunks_fed * @chunk_size, env)
    end
  end
end

RSpec.describe Lain::Tools::WebFetch do
  subject(:tool) { described_class.new(connection:) }

  let(:connection) do
    WebFetchStubConnection.new { |_url| WebFetchStubResponse.new(status: 200, headers: {}, body: "<h1>Example</h1>") }
  end

  it "has a model-facing name and description" do
    expect(tool.name).to eq("web_fetch")
    expect(tool.description).to be_a(String)
    expect(tool.description).not_to be_empty
  end

  # Tier 1 with structural bounds: safety is the byte-cap / redirect-cap / no
  # auth headers, NOT an approval gate. requires_approval? MUST be false.
  it "is not gated by approval (tier 1, bounded by structure)" do
    expect(tool.requires_approval?).to be(false)
  end

  it "retrieves a URL's text content" do
    result = tool.call({ url: "https://example.com" }, nil)
    expect(result).to be_ok
    expect(result.content).to include("Example")
  end

  it "never sends an auth header (calls the connection with only the url)" do
    tool.call({ url: "https://example.com" }, nil)
    url, args = connection.calls.first
    expect(url).to eq("https://example.com")
    expect(args).to be_empty
  end

  it "builds a default connection that carries no credential header" do
    keys = described_class.new.default_connection.headers.keys.map(&:downcase)
    expect(keys).not_to include("authorization")
    expect(keys).not_to include("cookie")
    expect(keys).not_to include("proxy-authorization")
  end

  describe "byte cap bounds the READ, not just the returned string" do
    it "truncates a body larger than the byte cap and labels it" do
      connection = WebFetchStubConnection.new do |_url|
        WebFetchStubResponse.new(status: 200, headers: {}, body: "0123456789ABCDEF")
      end
      result = described_class.new(connection:, byte_cap: 10).call({ url: "https://example.com" }, nil)
      expect(result).to be_ok
      expect(result.content).to include("0123456789")
      expect(result.content).not_to include("ABCDEF")
      expect(result.content).to match(/truncat/i)
    end

    # The substantive fix: the cap must abort the READ, so a lying/absent
    # Content-Length cannot stream unbounded into memory. Assert the tool STOPS
    # pulling chunks shortly past the cap -- not merely that the string is short.
    it "stops reading once accumulated bytes exceed the cap" do
      connection = WebFetchStreamingConnection.new(total_chunks: 100_000, chunk_size: 256)
      result = described_class.new(connection:, byte_cap: 1024).call({ url: "https://example.com" }, nil)

      expect(result).to be_ok
      expect(result.content.bytesize).to be < (1024 + 256)
      # 1024 / 256 = 4 chunks fill the cap; the 5th trips it. Nowhere near 100_000.
      expect(connection.chunks_fed).to be <= 6
    end
  end

  describe "redirect cap" do
    let(:connection) do
      WebFetchStubConnection.new do |_url|
        WebFetchStubResponse.new(status: 302, headers: { "location" => "https://example.com/next" }, body: "")
      end
    end

    it "refuses once redirects exceed the cap, as a loud error Result" do
      tool = described_class.new(connection:, redirect_cap: 2)
      result = tool.call({ url: "https://example.com" }, nil)
      expect(result).to be_error
      expect(result.content).to match(/redirect/i)
    end

    it "follows a redirect within the cap and returns the final body" do
      hops = { "https://example.com" => WebFetchStubResponse.new(status: 302,
                                                                 headers: { "location" => "https://example.com/final" },
                                                                 body: ""),
               "https://example.com/final" => WebFetchStubResponse.new(status: 200, headers: {}, body: "landed") }
      connection = WebFetchStubConnection.new { |url| hops.fetch(url) }
      result = described_class.new(connection:, redirect_cap: 3).call({ url: "https://example.com" }, nil)
      expect(result).to be_ok
      expect(result.content).to include("landed")
    end

    # SSRF: a redirect that hops to an internal/disallowed host is refused, and
    # the disallowed host is NEVER contacted.
    it "refuses a redirect to a disallowed host and never contacts it" do
      contacted = []
      connection = WebFetchStubConnection.new do |url|
        contacted << url
        WebFetchStubResponse.new(status: 302, headers: { "location" => "http://169.254.169.254/latest" }, body: "")
      end
      tool = described_class.new(connection:, allowlist: ["example.com"])
      result = tool.call({ url: "https://example.com" }, nil)
      expect(result).to be_error
      expect(result.content).to match(/allowlist/i)
      expect(contacted).to eq(["https://example.com"])
    end
  end

  describe "errors are loud Results, not crashes" do
    it "reports a non-2xx status as an error Result naming the status" do
      connection = WebFetchStubConnection.new do |_url|
        WebFetchStubResponse.new(status: 500, headers: {}, body: "boom")
      end
      result = described_class.new(connection:).call({ url: "https://example.com" }, nil)
      expect(result).to be_error
      expect(result.content).to match(/500/)
    end

    it "reports a raising client as an error Result rather than crashing" do
      connection = WebFetchStubConnection.new { |_url| raise Faraday::ConnectionFailed, "no route to host" }
      result = described_class.new(connection:).call({ url: "https://example.com" }, nil)
      expect(result).to be_error
      expect(result.content).to match(/no route to host/)
    end

    # A 3xx whose Location cannot be parsed must be a handled error Result --
    # URI::InvalidURIError must not escape #perform.
    it "turns a malformed redirect Location into a handled error, not a crash" do
      connection = WebFetchStubConnection.new do |_url|
        WebFetchStubResponse.new(status: 302, headers: { "location" => "http:// bad host/" }, body: "")
      end
      tool = described_class.new(connection:)
      result = nil
      expect { result = tool.call({ url: "https://example.com" }, nil) }.not_to raise_error
      expect(result).to be_error
      expect(result.content).to match(/redirect|url/i)
    end
  end

  describe "domain allowlist (optional structural bound)" do
    it "refuses a host that is not on the allowlist" do
      tool = described_class.new(connection:, allowlist: ["example.com"])
      result = tool.call({ url: "https://evil.test/steal" }, nil)
      expect(result).to be_error
      expect(result.content).to match(/allowlist/i)
    end

    it "allows a host that is on the allowlist" do
      tool = described_class.new(connection:, allowlist: ["example.com"])
      result = tool.call({ url: "https://example.com" }, nil)
      expect(result).to be_ok
    end
  end

  describe "scheme guard (only http/https egress)" do
    it "refuses a non-http(s) initial URL without contacting the connection" do
      contacted = []
      connection = WebFetchStubConnection.new do |url|
        contacted << url
        WebFetchStubResponse.new(status: 200, headers: {}, body: "root:x:0:0")
      end
      result = described_class.new(connection:).call({ url: "file:///etc/passwd" }, nil)
      expect(result).to be_error
      expect(result.content).to match(/scheme|http/i)
      expect(contacted).to be_empty
    end

    it "refuses a redirect to a non-http(s) scheme and never fetches it" do
      contacted = []
      connection = WebFetchStubConnection.new do |url|
        contacted << url
        WebFetchStubResponse.new(status: 302, headers: { "location" => "file:///etc/passwd" }, body: "")
      end
      result = described_class.new(connection:).call({ url: "https://example.com" }, nil)
      expect(result).to be_error
      expect(result.content).to match(/scheme|http/i)
      expect(contacted).to eq(["https://example.com"])
    end
  end
end
