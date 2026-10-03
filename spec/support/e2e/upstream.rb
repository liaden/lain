# frozen_string_literal: true

require "json"
require "socket"

module E2E
  # A stand-in for ollama on a real loopback port, owned by the spec. It answers the status probes
  # itself and hands every other request to a handler, so a journey scripts only the turns.
  class Upstream
    HOST = "127.0.0.1"
    PROBES = lambda do |request|
      { "/api/ps" => ['{"models":[]}'], "/api/show" => ["{}"] }[request.path]&.then { |lines| Reply.new(lines:) }
    end

    # The body ends cleanly after the last line, so a reply with no done line is a stream cut short.
    # hold keeps the connection open, with no body, until #release.
    Reply = Data.define(:status, :lines, :hold) do
      def initialize(lines:, status: 200, hold: false) = super
    end

    Request = Data.define(:verb, :path, :body)

    def self.start(handler, probes: nil) = new(handler, probes:)

    def initialize(handler, probes: nil)
      @handler = handler
      @probes = probes || PROBES
      @server = TCPServer.new(HOST, 0)
      @requests = []
      @sessions = []
      @lock = Mutex.new
      @released = Thread::Queue.new
      @threads = []
      @acceptor = Thread.new { accept_loop }
    end

    def url = "http://#{HOST}:#{@server.addr[1]}"

    def requests
      @lock.synchronize { @requests.map { |request| { method: request.verb, path: request.path, body: request.body } } }
    end

    def release = @released.close

    def stop
      release
      @acceptor.kill.join
      @threads.each(&:kill)
      @sessions.each { |session| session.close unless session.closed? }
      @server.close
      @threads.each(&:join)
    end

    private

    def accept_loop
      Thread.current.report_on_exception = false
      Kernel.loop do
        session = @server.accept
        @lock.synchronize { @sessions << session }
        @threads << Thread.new { serve(session) }
      end
    end

    def serve(session)
      Thread.current.report_on_exception = false
      request = read(session)
      @lock.synchronize { @requests << request }
      probe = @probes.call(request)
      probe ? whole(session, probe) : answer(session, @handler.call(request))
    rescue Errno::EPIPE, Errno::ECONNRESET
      nil
    ensure
      session.close unless session.closed?
    end

    def read(session)
      raw = ::StreamingUpstream::Request.read(session)
      body = raw.body.empty? ? nil : JSON.parse(raw.body)
      Request.new(verb: raw.verb, path: raw.path, body:)
    end

    def answer(session, reply)
      return whole(session, reply) unless reply.status == 200

      stream_headers(session)
      @released.pop if reply.hold
      emit(session, reply)
    end

    def whole(session, reply)
      body = reply.lines.join
      reason = reply.status == 200 ? "OK" : "Error"
      session.write("HTTP/1.1 #{reply.status} #{reason}\r\nContent-Type: application/json\r\n" \
                    "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
    end

    def stream_headers(session)
      session.write("HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nTransfer-Encoding: chunked\r\n\r\n")
      session.flush
    end

    def emit(session, reply)
      reply.lines.each { |line| ::StreamingUpstream::Chunk.new(line).emit(session) }
      ::StreamingUpstream::CLOSE.finish(session)
    end
  end

  class Scripted
    def initialize(replies)
      @replies = replies.dup
      @lock = Mutex.new
    end

    def call(request)
      @lock.synchronize { @replies.shift } || raise("no scripted reply left for #{request.verb} #{request.path}")
    end
  end
end
