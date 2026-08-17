# frozen_string_literal: true

require "json"
require "socket"

# A real HTTP upstream, on a real ephemeral port, that can DIE MID-BODY.
#
# WebMock hands a stubbed body back as one chunk and a cassette stores it as one
# blob (spec/lain/provider/ollama/streamed_failure_spec.rb:5-9 says so, and
# lain.gemspec:77-80 makes the sibling point about VCR), so neither can express
# the two things the retry defects are made of: WHERE the chunk boundaries fall,
# and a connection that stops existing between them. This can. It speaks NDJSON
# (Ollama `/api/chat`) and SSE (Anthropic `/v1/messages`), and it scripts each
# CONNECTION separately, so attempt 1 and attempt 2 differ -- which is the whole
# shape of a retry bug.
#
# == Using it
#
#   StreamingUpstream.ndjson(
#     StreamingUpstream.script.chunks(first, second).sever,
#     StreamingUpstream.script.chunks(third, done).close
#   ) do |upstream|
#     provider_pointed_at(upstream.url).complete(request)
#   end
#
# The block runs inside `NetworkAccess.permit_loopback`, taken on the port the
# kernel just assigned -- which is why the permission takes a port and not a URL:
# binding 0 is the only way to survive a 12-wide `rake pspec`, and the port is
# not knowable until after the bind. Everything is torn down in an `ensure`: the
# acceptor thread, every connection thread (each closing its socket on the way
# out), the listening socket, and the permission.
#
# Do NOT tag an example that uses this `:vcr`, and do not call it inside
# `VCR.use_cassette`. A cassette that is REPLAYING makes `permit_loopback` inert
# rather than merely lower-precedence, and the resulting
# `VCR::Errors::UnhandledHTTPRequestError` names neither the port nor the
# cassette. See spec/support/network_access.rb.
#
# == Endings, and what a client sees
#
# `close` writes the terminating zero-length chunk and closes: a clean end of
# stream. `sever` sets `SO_LINGER 0` and closes, which is a hard RST -- the
# client raises `Errno::ECONNRESET`, which Faraday's `:net_http` adapter maps to
# `Faraday::ConnectionFailed`, which IS in
# `Connection::MiddlewareStack#retry_exceptions`, so faraday-retry retries it and
# the NEXT script serves. `stall` stops emitting and holds the socket open: no
# FIN, no RST, nothing -- the shape a stall detector has to notice, since a
# request timeout is the only other thing that ends it.
#
# Measured, because the retry cards depend on it: a RST does NOT destroy bytes
# already sitting in the client's RECEIVE queue. Linux drains that queue before
# surfacing the reset -- 60/60 whole-chunk delivery at a zero settle delay, and
# 60/60 again with eight CPU hogs saturating the box -- so a severed attempt's
# chunks really do reach the assembler, which is what makes a splice reproducible
# rather than merely plausible. No settle sleep is needed, and one must not be
# added: it would make the instrument's timing a guess.
#
# ⚠️ Read the boundary of that claim before scripting a large body. `SO_LINGER 0`
# still discards the SERVER's unsent send buffer, and the two queues are not the
# same thing. Measured whole at 1, 8, 64 and 256 KiB and at 4 MiB, but at **1 MiB
# only 262136 of 1048654 bytes arrived, surfacing as `EOFError` rather than
# `Errno::ECONNRESET`**. Keep scripted chunks at realistic NDJSON/SSE sizes --
# tens to hundreds of bytes -- and a truncated body with the wrong exception
# class will not be mistaken for a provider bug.
#
# This file DEFINES ONLY. `spec_helper.rb` globs `spec/support/**/*.rb` into
# every worker of every run, so there is no `RSpec.configure` here, no thread, no
# bind, and no `Dir.chdir` -- loading it costs a few class definitions.
class StreamingUpstream
  # Only the loopback literal that a committed example pins in
  # spec/network_posture_spec.rb. `localhost` and `::1` are permitted too, but
  # nothing holds them there, so they would break silently.
  HOST = "127.0.0.1"

  # Named threads, so the watchdog's dump says whose they are and a leak check
  # can look for them by name (spec/support/watchdog.rb prints `Thread#name`).
  THREAD_PREFIX = "streaming-upstream"

  CONTENT_TYPES = { ndjson: "application/x-ndjson", sse: "text/event-stream" }.freeze

  # The zero-length chunk that ends a `Transfer-Encoding: chunked` body.
  TERMINATOR = "0\r\n\r\n"

  # A clean end of stream.
  class Close
    def finish(session)
      session.write(TERMINATOR)
      session.flush
      session.close
    end
  end

  # A hard RST. `SO_LINGER` with a zero timeout is what makes `close` abort the
  # connection instead of draining it -- a FIN would read as a clean, truncated
  # stream, which is a different defect from the one being reproduced.
  class Sever
    LINGER = [1, 0].pack("ii").freeze

    def finish(session)
      session.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, LINGER)
      session.close
    end
  end

  # Neither FIN nor RST: stop emitting and hold the socket open. Sleeps until
  # the connection thread is killed at teardown, which runs `#serve`'s ensure.
  class Stall
    def finish(_session) = sleep
  end

  CLOSE = Close.new.freeze
  SEVER = Sever.new.freeze
  STALL = Stall.new.freeze

  # One HTTP chunk, written and flushed on its own boundary. Net::HTTP reads a
  # chunked body chunk-by-chunk, so this boundary is the one `on_data` sees --
  # measured through both Net::HTTP and Faraday.
  Chunk = Data.define(:bytes) do
    # A zero-length chunk IS the chunked-encoding terminator, so `.chunk("")`
    # would silently end the stream cleanly and override whatever ending the
    # script names -- `script.chunk("").chunk(body).sever` delivered zero chunks
    # and no error, a clean success from a script that says "sever". The endings
    # are already unrepresentable-if-wrong; this makes the chunks so too.
    def initialize(bytes:)
      raise ArgumentError, "a scripted chunk cannot be empty: a zero-length chunk ends the stream" if
        bytes.to_s.empty?

      super
    end

    # `flush` is belt-and-braces: TCPSocket#sync is already true, so removing it
    # changes nothing today. It stays because the boundary is the point.
    def emit(session)
      session.write("#{bytes.bytesize.to_s(16)}\r\n#{bytes}\r\n")
      session.flush
    end
  end

  # Dead air between chunks, or before the first one. A pause before any chunk
  # lands AFTER the response headers, which is the real shape: Ollama answers
  # the headers and then thinks.
  Pause = Data.define(:seconds) do
    def emit(_session) = sleep(seconds)
  end

  # What one connection is scripted to do. Immutable: every builder returns a new
  # Script, so a `let` can be shared between examples and refined per example
  # without one leaking into the next.
  Script = Data.define(:emissions, :ending) do
    def chunk(bytes) = append(Chunk.new(bytes))
    def chunks(*list) = list.inject(self) { |script, bytes| script.chunk(bytes) }
    def pause(seconds) = append(Pause.new(seconds))
    def close = with(ending: CLOSE)
    def sever = with(ending: SEVER)
    def stall = with(ending: STALL)

    def append(emission) = with(emissions: (emissions + [emission]).freeze)
  end

  # What a client sent, kept so a consumer can assert on the payload it built.
  Request = Data.define(:verb, :path, :headers, :body)

  # What a client sent, and how to read it off a socket. Parsing lives with the
  # value rather than on the server because they are different jobs: the server
  # owns the listener, the script queue and the teardown; this owns one
  # HTTP/1.1 request-head grammar, and nothing about it changes when the
  # lifecycle does.
  class Request
    def self.read(socket)
      verb, path, = socket.gets.to_s.split
      headers = read_headers(socket)
      new(verb:, path:, headers:, body: read_body(socket, headers))
    end

    # `take_while` stops at the blank line and IO#each_line reads lazily, so
    # exactly the header block is consumed and the body is left on the socket.
    def self.read_headers(socket)
      socket.each_line.take_while { |line| line != "\r\n" }.to_h do |line|
        name, value = line.split(":", 2)
        [name.to_s.downcase, value.to_s.strip]
      end
    end

    # Read even when nothing will assert on it: an unread body can leave the
    # client blocked on a full send buffer, which reads as a stall this harness
    # invented.
    def self.read_body(socket, headers)
      length = headers["content-length"].to_i
      length.positive? ? socket.read(length).to_s : ""
    end

    private_class_method :read_headers, :read_body
  end

  class << self
    # An empty script that ends cleanly. Build from it: `.chunks(a, b).sever`.
    def script = Script.new(emissions: [].freeze, ending: CLOSE)

    def ndjson(*scripts, &block) = run(:ndjson, scripts, &block)
    def sse(*scripts, &block) = run(:sse, scripts, &block)

    # Bind, permit, yield, and tear down whatever happened. The permission is
    # taken INSIDE this method because the port it names does not exist until
    # the line above it has run.
    def run(dialect, scripts)
      RealStreaming.install
      upstream = new(dialect:, scripts:)
      NetworkAccess.permit_loopback(upstream.port) { yield upstream }
    ensure
      upstream&.stop
    end
  end

  def initialize(dialect:, scripts:)
    @content_type = CONTENT_TYPES.fetch(dialect)
    @scripts = scripts.dup
    @server = TCPServer.new(HOST, 0)
    @requests = []
    @connections = []
    @sessions = []
    @lock = Mutex.new
    @acceptor = Thread.new { accept_loop }
  end

  def port = @server.addr[1]

  def url = "http://#{HOST}:#{port}"

  # The requests served so far, oldest first. A copy: the acceptor appends to the
  # original from its own thread.
  def requests = @lock.synchronize { @requests.dup }.freeze

  # Killing a connection thread runs `#serve`'s ensure, so a stalled socket is
  # closed rather than left to the GC. The acceptor goes first: once it is dead
  # the connection list has stopped growing and can be read without the lock
  # racing a new entry into it.
  #
  # The sockets are then closed AGAIN, from a registry the acceptor fills before
  # it spawns anything. A thread can exist for an instant before
  # `start_connection`'s append registers it, and a thread that escapes that
  # window would keep its fd for the rest of the worker's life -- which under
  # 12-wide load is a leak that presents as an unrelated exhaustion. Registering
  # the SESSION synchronously, ahead of the thread, closes that hole from the
  # side that matters: `close` is idempotent here because `#serve` guards on
  # `closed?`, so the ordinary path pays one extra predicate.
  def stop
    @acceptor.kill.join
    @connections.each { |thread| thread.kill.join }
    @sessions.each { |session| session.close unless session.closed? }
    @server.close
  end

  private

  # Ends when `stop` closes the listening socket and `accept` raises IOError.
  # `report_on_exception` is off because that raise is the exit, not a fault.
  def accept_loop
    name_thread("acceptor")
    Kernel.loop { start_connection(@server.accept) }
  end

  # The script is chosen HERE, on the single acceptor thread, so connection order
  # decides script order deterministically even when two clients overlap. The
  # session is registered BEFORE the thread exists, which is what makes `stop`'s
  # second pass able to close an fd whose thread never made it into the list.
  def start_connection(session)
    script = next_script
    @sessions << session
    @connections << Thread.new { serve(session, script) }
  end

  # Matching OllamaWire::QueueTransport and Provider::Mock: the last script
  # repeats once the queue runs out, so "severs every connection" is one script.
  def next_script
    raise "StreamingUpstream was given no scripts" if @scripts.empty?

    @scripts.size > 1 ? @scripts.shift : @scripts.first
  end

  # One connection per thread, so a stalled one does not block the next -- a
  # retry after a stall must still be able to connect, or the example hangs
  # instead of failing.
  def serve(session, script)
    name_thread("connection")
    record(Request.read(session))
    write_headers(session)
    script.emissions.each { |emission| emission.emit(session) }
    script.ending.finish(session)
  ensure
    session.close unless session.closed?
  end

  def name_thread(role)
    Thread.current.name = "#{THREAD_PREFIX} #{port} #{role}"
    Thread.current.report_on_exception = false
  end

  def record(request) = @lock.synchronize { @requests << request }

  def write_headers(session)
    session.write("HTTP/1.1 200 OK\r\nContent-Type: #{@content_type}\r\n" \
                  "Transfer-Encoding: chunked\r\n\r\n")
    session.flush
  end

  # WebMock does not merely decide WHETHER a Net::HTTP request may go out. On the
  # request it ALLOWS, it strips the caller's block -- `super(request, nil, &nil)`,
  # webmock-3.26.2 net_http.rb:105 -- reads the whole body itself, and replays it
  # afterwards through `Net::WebMockHTTPResponse#read_body`, which hands it over
  # in ONE `dest <<` (net_http_response.rb:28). That is the same "a stubbed body
  # arrives as one chunk" limitation
  # spec/lain/provider/ollama/streamed_failure_spec.rb:5-9 records, except it
  # applies to a REAL socket too -- and it is worse than coalescing: a connection
  # severed mid-body raises inside WebMock's own read, so the bytes that DID
  # arrive never reach the caller at all. A harness with no chunk boundaries and
  # no partial delivery cannot express either retry defect.
  #
  # Note what does NOT help: `WebMock.allow_net_connect!` lands on that same
  # branch, so opening the whole network would buy nothing. The only way through
  # is to stop that branch from handling the request at all, and this is the
  # narrowest version of it -- run the ORIGINAL, unpatched `Net::HTTP#request`
  # for exactly the requests NetworkAccess has ALREADY decided may reach a
  # socket, and leave every other request to WebMock untouched.
  #
  # The predicate is `NetworkAccess.bypass?` itself, not a second copy of it, so
  # a request this streams and a request the suite refuses cannot disagree. It is
  # therefore inert in the ordinary case: no permission held (or a cassette
  # inserted) means `super`, and the suite's offline posture is exactly what
  # spec/network_posture_spec.rb proves it to be.
  #
  # One consequence worth knowing before debugging a missing assertion: a request
  # that takes this path skips WebMock's own bookkeeping, so `assert_requested`
  # and `have_been_made` cannot see it. Ask the upstream instead -- `#requests` is
  # why it keeps them.
  module RealStreaming
    ORIGINAL = WebMock::HttpLibAdapters::NetHttpAdapter::OriginalNetHTTP.instance_method(:request)

    # `NetworkAccess.bypass?` asks for `#parsed_uri` and reads only `#host` and
    # `#port` off the answer, so this is both -- and, crucially, it CANNOT RAISE.
    #
    # It used to be `URI::HTTP.build(host:, port:)`, which was a latent trap:
    # `URI`'s host check is stricter than `Net::HTTP`'s, and this module is
    # prepended process-wide and permanently. So `Net::HTTP.new("127.0.0.1 ")` --
    # or `""`, `"not a host"`, `"%zz"`, `"[::1"`, `"user:pw@evil.example.com"` --
    # would take down ANY request in a worker that had already run one
    # StreamingUpstream example, with a `URI` error naming neither WebMock nor
    # this harness, and only when the example order put the two together. A
    # `pspec`-only flake with a misleading message. Reading two fields off a
    # Struct has no such failure mode.
    Destination = Struct.new(:host, :port) do
      def parsed_uri = self
    end

    def request(request, body = nil, &block)
      return super unless RealStreaming.streaming?(self)

      # WebMock's `start` parks a StubSocket on the connection and calls it
      # started; the original `request` would write into that and read nothing
      # back. This is WebMock's own repair for the same problem, and the reason
      # it is safe to skip the rest of its branch. It is defined on WebMock's
      # SUBCLASS, so `install` must never fire while WebMock is disabled -- the
      # prepend would land on the original class, which has no such method.
      ensure_actual_connection if started?
      ORIGINAL.bind_call(self, request, body, &block)
    end

    def self.streaming?(http)
      NetworkAccess.bypass?(Destination.new(http.address, http.port))
    end

    # NOT at load, and the difference is invisible until you read `ancestors`:
    # `WebMock.enable!` REPLACES the `Net::HTTP` constant with a subclass of the
    # original (webmock net_http.rb:19-25), and it does so after spec_helper's
    # support glob has run. A prepend at load therefore lands on the ORIGINAL
    # class, where it sits BEHIND the subclass's own `request` and never runs --
    # the symptom being a perfectly healthy-looking predicate and a body that
    # still arrives in one piece. So it is installed on whatever `Net::HTTP` is
    # by the time an upstream is served, once per process, and the guard asks
    # the only question that matters: is this module first in the CURRENT chain?
    def self.install
      Net::HTTP.prepend(self) unless Net::HTTP.ancestors.first.equal?(self)
    end
  end

  # The bytes a chunk carries, in each dialect. Separated from the server because
  # they are a different job: the server owns the socket, this owns the wire
  # format -- and it borrows the two serializers the suite already has rather
  # than restating either shape.
  module Wire
    module_function

    def ndjson_line(hash) = "#{JSON.generate(hash)}\n"

    # One streamed `/api/chat` fragment: `done` is false, so StreamAssembler
    # concatenates it and waits for the terminal line.
    def ollama_content(text, model: Lain::Provider::Ollama::DEFAULT_MODEL)
      ndjson_line("model" => model, "message" => { "role" => "assistant", "content" => text }, "done" => false)
    end

    # The terminal line, built through OllamaWire so the done_reason mapping and
    # the token-count keys stay stated once.
    def ollama_done(response)
      ndjson_line(OllamaWire.body_hash(response).merge("message" => terminal_message(response)))
    end

    # The done line carries the terminal metadata and no prose: whatever content
    # and thinking this response holds has already gone out as scripted
    # fragments, and StreamAssembler CONCATENATES across lines, so repeating it
    # would double every consumer's expected text. tool_calls survive untouched,
    # because they have no fragment form -- Ollama emits a call whole, on its own
    # line.
    def terminal_message(response)
      message = OllamaWire.message_hash(response)
      message.merge(message.slice("content", "thinking").transform_values { "" })
    end

    def sse_frame(event) = "event: #{event["type"]}\ndata: #{JSON.generate(event)}\n\n"

    # A whole Response, one frame per event, so a script can serve a PREFIX of a
    # real stream and then sever -- which is exactly "opens two content blocks
    # and dies before closing them".
    def sse_frames(response) = AnthropicSSE.events(response).map { |event| sse_frame(event) }
  end
end
