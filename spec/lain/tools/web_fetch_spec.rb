# frozen_string_literal: true

# A minimal Faraday-response duck: status, headers, body -- what the tool reads
# for redirect detection. Specs never hit the network; the connection injected.
WebFetchStubResponse = Struct.new(:status, :headers, :body, keyword_init: true)

# The request/options/env shapes Faraday hands the streaming block. The tool
# sets `req.options.on_data`; the connection drives it with body chunks. The env
# carries `response_headers` because Faraday's really does: net_http's
# `save_http_response` runs before `read_body`, so an aborted read still knows
# what content type it was reading.
WebFetchFakeEnv = Struct.new(:status, :response_headers, keyword_init: true)

class WebFetchFakeOptions
  attr_accessor :on_data
end

class WebFetchFakeRequest
  def options = @options ||= WebFetchFakeOptions.new
end

# A connection that answers every #get through an injected responder, drives the
# streaming callback with the response body, and records the args it was called
# with (so "no auth header" is provable). Mirrors Faraday 2's shape:
# `conn.get(url) { |req| req.options.on_data = proc }`, body delivered via on_data.
#
# It delivers the body the way a SOCKET does, and both halves of that are load
# bearing. The bytes are ASCII-8BIT: a Ruby string literal is UTF-8, so a stub
# that handed the literal straight through lied about the one thing F1 turned on
# and every example here passed over the defect. And the body arrives in SEVERAL
# chunks, so a multi-byte character can straddle a boundary -- a single-chunk
# stub reproduces the tagging bug but never the truncation one.
class WebFetchStubConnection
  # Small enough that every body in this file is multi-chunk. The é in
  # "Le café ..." lands across the first boundary at exactly this size.
  DEFAULT_CHUNK_SIZE = 7

  attr_reader :calls

  def initialize(chunk_size: DEFAULT_CHUNK_SIZE, &responder)
    @chunk_size = chunk_size
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

    stream(response, on_data)
  end

  # Faraday passes the same env to every on_data call and a RUNNING TOTAL as the
  # second argument, so the callback can be driven exactly as the adapter does.
  def stream(response, on_data)
    env = WebFetchFakeEnv.new(status: response.status, response_headers: response.headers)
    received = 0
    chunks(response.body.to_s.b).each do |chunk|
      received += chunk.bytesize
      on_data.call(chunk, received, env)
    end
  end

  # An empty body still yields once, with an empty chunk -- Faraday's
  # `request.on_data.call(+'', 0, self) unless yielded`.
  def chunks(body)
    slices = (0...body.bytesize).step(@chunk_size).map { |offset| body.byteslice(offset, @chunk_size) }
    slices.empty? ? [body] : slices
  end
end

# A LAZY streaming connection for the memory-bound probe: it generates fixed-size
# chunks on demand and counts how many it fed, so a spec can prove the tool STOPS
# reading past the cap rather than buffering the whole body first.
class WebFetchStreamingConnection
  attr_reader :chunks_fed

  def initialize(total_chunks:, chunk_size:, status: 200, headers: {}, byte: "x")
    @total_chunks = total_chunks
    @chunk_size = chunk_size
    @status = status
    @headers = headers
    @byte = byte
    @chunks_fed = 0
  end

  def get(_url, *_args)
    request = WebFetchFakeRequest.new
    yield request if block_given?
    drive(request.options.on_data)
    WebFetchStubResponse.new(status: @status, headers: @headers, body: "")
  end

  private

  # Raising out of on_data (the tool's byte cap, or its refusal of a non-text
  # body) unwinds this loop -- exactly how Faraday aborts a stream -- so a
  # bounded read leaves chunks_fed small.
  def drive(on_data)
    env = WebFetchFakeEnv.new(status: @status, response_headers: @headers)
    @total_chunks.times do
      chunk = (@byte * @chunk_size).b
      @chunks_fed += 1
      on_data.call(chunk, @chunks_fed * @chunk_size, env)
    end
  end
end

# A connection that delivers a caller-supplied LIST of chunks verbatim, so an
# example can control each chunk's ENCODING as well as its bytes. Faraday's own
# `env.rb:179` emits a UTF-8 `+''`, and adapters other than net_http hand back
# UTF-8 strings, so a body really can arrive as a mix -- which is what the
# accumulating buffer has to survive.
class WebFetchChunkedConnection
  def initialize(chunks, status: 200, headers: {})
    @chunks = chunks
    @status = status
    @headers = headers
  end

  def get(_url, *_args)
    request = WebFetchFakeRequest.new
    yield request if block_given?
    drive(request.options.on_data)
    WebFetchStubResponse.new(status: @status, headers: @headers, body: "")
  end

  private

  def drive(on_data)
    env = WebFetchFakeEnv.new(status: @status, response_headers: @headers)
    received = 0
    @chunks.each do |chunk|
      received += chunk.bytesize
      on_data.call(chunk, received, env)
    end
  end
end

RSpec.describe Lain::Tools::WebFetch do
  subject(:tool) { described_class.new(connection:) }

  let(:connection) do
    WebFetchStubConnection.new { |_url| WebFetchStubResponse.new(status: 200, headers: {}, body: "<h1>Example</h1>") }
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

  # F1: the tool hands its bytes to Tool::Result, which reaches Canonical, which
  # raises on any byte >= 0x80. Faraday hands a body back ASCII-8BIT, so every
  # non-ASCII page crashed the turn. The tool is the layer that knows it asked
  # for text, so decoding belongs here -- never in Canonical.
  describe "bytes off the socket become text Canonical accepts" do
    def fetching(body, headers: {}, **options)
      connection = WebFetchStubConnection.new { |_url| WebFetchStubResponse.new(status: 200, headers:, body:) }
      described_class.new(connection:, **options).call({ url: "https://example.com/page" }, nil)
    end

    it "returns a page containing non-ASCII text as valid UTF-8" do
      result = fetching("Le café était bon")

      expect(result).to be_ok
      expect(result.content.encoding).to eq(Encoding::UTF_8)
      expect(result.content).to be_valid_encoding
      expect(result.content).to include("café")
    end

    it "survives canonicalisation when the body carries a CP1252 smart quote" do
      result = fetching("don\x92t stop believing")

      expect(result).to be_ok
      expect { Lain::Canonical.dump(result.content) }.not_to raise_error
      expect(result.content).to include("don’t")
    end

    it "decodes with the charset the response names rather than guessing" do
      result = fetching("Привет".encode(Encoding::WINDOWS_1251),
                        headers: { "content-type" => "text/plain; charset=windows-1251" })

      expect(result).to be_ok
      # The ladder alone reads these bytes as CP1252 and yields "Ïðèâåò"; only
      # the declared charset gets the Cyrillic back.
      expect(result.content).to include("Привет")
    end

    # An aborted read has no response, so the DECLARED CHARSET of a truncated
    # body can only come from the headers the cap captured off the streaming
    # env. Without them the ladder reads these bytes as CP1252 and the page
    # arrives as "Ïðèâåò " -- believable mojibake, this card's whole subject,
    # reached through the one path where the header is not in hand.
    it "keeps the declared charset of a body the cap truncated" do
      result = fetching("Привет мир".encode(Encoding::WINDOWS_1251),
                        headers: { "content-type" => "text/plain; charset=windows-1251" },
                        byte_cap: 8)

      expect(result).to be_ok
      expect(result.content.split("\n\n").first).to eq("Привет ")
      expect(result.content).not_to include("Ï")
    end

    it "treats a structured text type under application/* as text" do
      result = fetching('{"place":"café"}', headers: { "content-type" => "application/json; charset=utf-8" })

      expect(result).to be_ok
      expect(result.content).to include("café")
    end

    it "treats an absent Content-Type as text" do
      result = fetching("<h1>café</h1>")

      expect(result).to be_ok
      expect(result.content).to include("café")
    end

    # The decode ladder NEVER fails, so a PNG decodes to "‰PNG" -- plausible
    # garbage. Whether this is text at all is a separate question, answered from
    # Content-Type before anyone asks how to decode.
    it "refuses a binary body by naming its content type" do
      result = fetching("\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR", headers: { "content-type" => "image/png" })

      expect(result).to be_error
      expect(result.content).to include("image/png")
      expect(result.content).not_to include("PNG\r\n")
    end

    # An aborted read never returns a response, so the content type has to come
    # off the streaming env -- Faraday saves headers before the first chunk.
    it "refuses a binary body whose read the cap aborted" do
      result = fetching("\x89PNG\r\n\x1a\n" * 100, headers: { "content-type" => "image/png" }, byte_cap: 16)

      expect(result).to be_error
      expect(result.content).to include("image/png")
    end

    # "Absent means text" on its own reopens the door the header check closes:
    # the ladder never fails, so a bare PNG would arrive as `‰PNG` -- valid
    # UTF-8, canonicalising clean, presented to the model as a page.
    it "refuses a binary body that arrives with no Content-Type at all" do
      result = fetching("\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x01\x00")

      expect(result).to be_error
      expect(result.content).to match(/binary/i)
      expect(result.content).not_to include("PNG")
    end

    it "still treats an unlabelled body that reads as prose as text" do
      result = fetching("<h1>Le café</h1>\n<p>était bon</p>")

      expect(result).to be_ok
      expect(result.content).to include("café")
    end

    # The CP1252 rung reinterprets EVERY byte, so applying it to a page the
    # server declared UTF-8 turns one mangled byte into whole-body mojibake --
    # the same failure class the boundary rounding exists to prevent.
    it "scrubs a declared-UTF-8 page with one bad byte instead of re-reading it as CP1252" do
      result = fetching("café \x92 quote", headers: { "content-type" => "text/html; charset=utf-8" })

      expect(result.content).to eq("café � quote")
      expect(result.content).not_to include("cafÃ©")
    end

    # Same judgement without a declared charset: a body still holding valid
    # multi-byte UTF-8 after the damage is dropped was UTF-8 with damage, not
    # CP1252 -- CP1252 bytes do not spell multi-byte UTF-8 by accident.
    it "scrubs an undeclared page that is predominantly valid UTF-8" do
      result = fetching("#{"é" * 5}\x80#{"é" * 5}")

      expect(result.content).to eq("ééééé�ééééé")
    end

    # Encoding.find also answers to `locale`, `external`, `internal` and
    # `filesystem`, which resolve to whatever the PROCESS is configured for --
    # so honouring one would let a remote header make this tool's output depend
    # on the box rather than on the bytes.
    it "never resolves a charset that names the process's own encoding" do
      allow(Encoding).to receive(:find).and_call_original
      result = fetching("don\x92t stop", headers: { "content-type" => "text/plain; charset=locale" })

      expect(Encoding).not_to have_received(:find).with("locale")
      expect(result.content).to include("don’t")
    end

    # RFC 9110 forbids the whitespace, but a lenient server sends it and
    # silently discarding the charset it DID name is worse than accepting it.
    it "reads a charset the server spelled with spaces around the equals sign" do
      result = fetching("Привет".encode(Encoding::WINDOWS_1251),
                        headers: { "content-type" => "text/plain; charset = windows-1251" })

      expect(result.content).to include("Привет")
    end

    # Faraday's own empty chunk is UTF-8 (`env.rb:179`) and adapters other than
    # net_http hand back UTF-8 strings, so chunks really can disagree. A buffer
    # that took its encoding from whichever chunk first carried a high byte
    # raises Encoding::CompatibilityError the moment a later one differs.
    it "accumulates chunks whose encodings disagree" do
      connection = WebFetchChunkedConnection.new(["Le café".b, +" était bon", (+"").force_encoding(Encoding::UTF_8)])
      result = described_class.new(connection:).call({ url: "https://example.com" }, nil)

      expect(result).to be_ok
      expect(result.content).to eq("Le café était bon")
    end
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

    # The cap lands on an arbitrary byte, and the decode ladder turns a split
    # character into BELIEVABLE mojibake ("cafÃ") rather than a visible loss --
    # so the cap rounds down to the last whole character and returns <= cap
    # bytes rather than exactly cap.
    it "truncates at the cap on a character boundary, not mid-character" do
      # "café" is five bytes; a cap of four falls between the é's two.
      connection = WebFetchStubConnection.new do |_url|
        WebFetchStubResponse.new(status: 200, headers: {}, body: "café au lait")
      end
      result = described_class.new(connection:, byte_cap: 4).call({ url: "https://example.com" }, nil)

      expect(result).to be_ok
      expect(result.content).to be_valid_encoding
      expect(result.content.split("\n\n").first).to eq("caf")
      expect(result.content).not_to include("Ã")
    end

    # Rounding down means the body is <= the cap, so reporting the CAP tells the
    # model "truncated at 4 bytes" beside a three-byte body.
    it "labels the truncation with the bytes actually returned, not the cap" do
      connection = WebFetchStubConnection.new do |_url|
        WebFetchStubResponse.new(status: 200, headers: {}, body: "café au lait")
      end
      result = described_class.new(connection:, byte_cap: 4).call({ url: "https://example.com" }, nil)

      expect(result.content).to include("truncated at 3 bytes")
    end

    it "renders a cap that lands before the first whole character as the label alone" do
      connection = WebFetchStubConnection.new do |_url|
        WebFetchStubResponse.new(status: 200, headers: {}, body: "école")
      end
      result = described_class.new(connection:, byte_cap: 1).call({ url: "https://example.com" }, nil)

      expect(result.content).to eq("[web_fetch: truncated at 0 bytes]")
    end

    # The cap bounds a body we are going to RETURN. A body we have already
    # decided to discard should not be streamed at all -- the type is known on
    # the first chunk, so the read aborts there rather than at the cap.
    it "aborts a non-text body on the first chunk instead of streaming it to the cap" do
      connection = WebFetchStreamingConnection.new(total_chunks: 100_000, chunk_size: 8192,
                                                   headers: { "content-type" => "image/png" })
      result = described_class.new(connection:).call({ url: "https://example.com/big.png" }, nil)

      expect(result).to be_error
      expect(result.content).to include("image/png")
      expect(connection.chunks_fed).to eq(1)
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
      expect(result.content).to include("500")
    end

    # A non-2xx body is never returned, so the status is the answer the model
    # needs -- screening it would replace "404" with a refusal about a content
    # type nobody asked about.
    it "reports a non-2xx status even when its body is binary" do
      connection = WebFetchStubConnection.new do |_url|
        WebFetchStubResponse.new(status: 404, headers: { "content-type" => "image/png" }, body: "\x89PNG\r\n\x1a\n")
      end
      result = described_class.new(connection:).call({ url: "https://example.com/missing.png" }, nil)

      expect(result).to be_error
      expect(result.content).to include("404")
    end

    it "reports a raising client as an error Result rather than crashing" do
      connection = WebFetchStubConnection.new { |_url| raise Faraday::ConnectionFailed, "no route to host" }
      result = described_class.new(connection:).call({ url: "https://example.com" }, nil)
      expect(result).to be_error
      expect(result.content).to include("no route to host")
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
