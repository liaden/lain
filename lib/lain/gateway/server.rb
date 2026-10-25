# frozen_string_literal: true

require "digest"
require "json"
require "openssl"
require "socket"
require "timeout"
require "uri"

module Lain
  module Gateway
    # The gateway's loopback listener. A body reaches the upstream only after
    # {Inspection} passes it and the human, shown it whole, says yes; every
    # outcome is logged with the body's digest, never the body.
    #
    # Each connection is read on its own thread, so a silent client stalls only
    # itself and the identity path answers while a prompt is open. The asking
    # is one request at a time, in the order the requests were read, on one
    # asking thread. A client that hung up before its answer is dropped rather
    # than forwarded, and so is one that only closed its writing side. One
    # request per connection, then `Connection: close`.
    class Server
      # @!attribute [r] endpoint
      #   @return [String] the request path, one the upstream serves
      # @!attribute [r] bytes
      #   @return [Integer] the body's length
      # @!attribute [r] body
      #   @return [String] the body exactly as it would be forwarded
      # @!attribute [r] flagged
      #   @return [Array<String>] what {Inspection} noticed without refusing
      Request = Data.define(:endpoint, :bytes, :body, :flagged)

      LOOPBACK = "127.0.0.1"
      # Seconds a client has to send its whole request.
      READ_DEADLINE = 10
      # Each connection holds a thread and up to a body's worth of memory, so a
      # flood is answered 503 rather than met with a thread apiece.
      MAX_CONNECTIONS = 64
      MAX_ASKS = 16
      # Seconds {#stop} gives each open connection to send its 503.
      STOP_GRACE = 2
      # A refused client may still be sending, and closing on unread bytes resets the
      # connection before it reads its answer.
      DRAIN_SECONDS = 1
      MAX_DRAIN = 1024 * 1024
      MAX_LINE = 8 * 1024
      MAX_HEADERS = 100
      JSON_TYPE = "application/json"
      REASONS = { 200 => "OK", 400 => "Bad Request", 403 => "Forbidden", 404 => "Not Found",
                  408 => "Request Timeout", 411 => "Length Required", 413 => "Content Too Large",
                  500 => "Internal Server Error", 502 => "Bad Gateway", 503 => "Service Unavailable" }.freeze

      NOT_LOOPBACK = "the gateway binds only to loopback (#{LOOPBACK}), not %<bind>p".freeze
      CANNOT_LISTEN = "the gateway cannot listen on #{LOOPBACK} port %<port>d: %<reason>s".freeze
      MALFORMED = "the request is not HTTP/1.x the gateway can read"
      CONFLICTING = "the request sends %<name>s twice with different values"
      FOREIGN = "the gateway answers only a Host of 127.0.0.1 or localhost on its own port, with no Origin"
      NOT_SERVED = "the gateway serves only POST %<paths>s and GET #{IDENTITY_PATH}".freeze
      NO_LENGTH = "the gateway reads only a body sent with a Content-Length"
      TIMED_OUT = "the request did not arrive whole within #{READ_DEADLINE}s".freeze
      WRONG_TOKEN = "the token is missing or wrong"
      DECLINED = "the human declined to forward this request"
      UNASKED = "the human could not be asked: %<reason>s"
      TOO_MANY_CONNECTIONS = "the gateway holds #{MAX_CONNECTIONS} connections already".freeze
      TOO_MANY_ASKS = "the gateway has #{MAX_ASKS} requests waiting for the human already".freeze
      STOPPED = "the gateway stopped before answering"
      NOT_JSON = "the upstream answered %<type>p, not #{JSON_TYPE}, so nothing of it was relayed".freeze

      # An answer to write, or a refusal's.
      Reply = Data.define(:status, :body)

      # A request waiting its turn at the console, and where its answer goes.
      Ask = Data.define(:socket, :request, :answer)

      # A request that ends here, answered with its status and reason.
      class Refusal < Lain::Error
        attr_reader :status, :outcome, :fields

        def initialize(status, reason, outcome: "refused", **fields)
          super(reason)
          @status = status
          @outcome = outcome
          @fields = fields
        end
      end

      # The client hung up before its request was whole.
      class Gone < Lain::Error; end

      # The client did not send its request whole within {READ_DEADLINE}.
      class TimedOut < Lain::Error; end

      # {#stop} ended the connection before its answer.
      class Stopping < Lain::Error; end

      # @param bind [String] {LOOPBACK}
      # @param port [Integer] 0 for any free port, read back through {#port}
      # @param upstream [Upstream]
      # @param inspection [#call] `(body) -> Inspection::Verdict`
      # @param console [#approve?] the human, asked with a {Request}
      # @param journal [#record] the gateway's own log
      # @param token [String] proves this gateway to a client through {IDENTITY_PATH}
      # @raise [ArgumentError] for a bind address off loopback
      # @raise [Lain::Error] naming the port, when it is taken or not ours to take
      def initialize(bind:, port:, upstream:, inspection:, console:, journal:, token:)
        raise ArgumentError, format(NOT_LOOPBACK, bind:) unless bind == LOOPBACK

        @upstream = upstream
        @inspection = inspection
        @console = console
        @journal = journal
        @token = token
        @paths = UPSTREAMS.fetch(upstream.base).fetch(:paths)
        @listener = listen(port)
        @asks = Thread::Queue.new
        @queueing = Mutex.new
        @readers = ThreadGroup.new
        @turned_away = Thread::Queue.new
        @asker = nil
        @turner = nil
      end

      # @return [Integer] the port the listener holds
      def port = @listener.local_address.ip_port

      # @return [String] where a client reaches this gateway, carrying the token
      def url = "http://#{LOOPBACK}:#{port}/?token=#{@token}"

      # Serves until {#stop} closes the listener, or the caller is interrupted.
      #
      # @return [nil]
      def run
        @asker = asking
        @turner = turning_away
        loop { attend(@listener.accept) }
      rescue IOError, Errno::EBADF
        nil
      end

      # Closes the listener, ends the open prompt, and answers 503 to every
      # connection still open, killing any that has not finished within {STOP_GRACE}.
      #
      # @return [nil]
      def stop
        @listener.close unless @listener.closed?
        [@asks, @turned_away].each(&:close)
        [@asker, @turner].compact.each { finish(_1.kill) }
        @readers.list.each { _1.raise(Stopping, STOPPED) }.each { finish(_1) }
        nil
      end

      private

      def listen(port)
        TCPServer.new(LOOPBACK, port)
      rescue SystemCallError => e
        raise Lain::Error, format(CANNOT_LISTEN, port:, reason: e.message)
      end

      # A thread that ends by an exception hands it to #join, which stop has no use for.
      def finish(thread)
        thread.join(STOP_GRACE) || thread.kill.join
      rescue StandardError
        nil
      end

      def attend(socket)
        return turn_away(socket) if @readers.list.size >= MAX_CONNECTIONS

        @readers.add(Thread.new { serve(socket) }.tap { _1.report_on_exception = false })
      end

      # One thread answers every connection over the cap, in turn; past a cap of its own
      # a connection is closed unanswered.
      def turn_away(socket)
        return socket.close if @turned_away.size >= MAX_CONNECTIONS

        @turned_away << socket
      end

      def turning_away
        Thread.new do
          while (socket = @turned_away.pop)
            refuse(socket, Refusal.new(503, TOO_MANY_CONNECTIONS, outcome: "busy"))
            socket.close
          end
        end
      end

      def asking
        Thread.new do
          while (ask = @asks.pop)
            ask.answer << turn(ask)
          end
        end
      end

      # @return [Symbol, StandardError] the answer, or why the console gave none
      def turn(ask)
        return :gone unless present?(ask.socket)

        @console.approve?(ask.request) ? :approved : :declined
      rescue StandardError => e
        e
      end

      def serve(socket)
        socket.binmode
        reply = Timeout.timeout(READ_DEADLINE, TimedOut) { read_request(socket) }.call
        write(socket, reply) if reply
      rescue Stopping
        refuse(socket, Refusal.new(503, STOPPED, outcome: "stopped"))
      rescue TimedOut
        refuse(socket, Refusal.new(408, TIMED_OUT, outcome: "timed out"))
      rescue Refusal => e
        refuse(socket, e)
      rescue Gone, IOError, SystemCallError
        nil
      rescue StandardError => e
        refuse(socket, Refusal.new(500, "the gateway failed: #{e.class}", outcome: "failed"))
      ensure
        socket.close
      end

      # @return [#call] what answers the request, once it has been read whole
      def read_request(socket)
        verb, target, headers = read_head(socket)
        admit(headers)
        path, query = target.split("?", 2)
        return -> { identity(query) } if verb == "GET" && path == IDENTITY_PATH
        raise Refusal.new(404, format(NOT_SERVED, paths: @paths.join(", "))) unless served?(verb, path)

        body = read_body(socket, headers)
        -> { relay(socket, path, body) }
      end

      def served?(verb, path) = verb == "POST" && @paths.include?(path)

      # A browser page, or a name rebound to loopback, sends its own Host or an Origin.
      def admit(headers)
        host = field(headers, "host").to_s.downcase
        raise Refusal.new(403, FOREIGN) if headers.key?("origin") || !hosts.include?(host)
      end

      def hosts = ["#{LOOPBACK}:#{port}", "localhost:#{port}"]

      def identity(query)
        raise Refusal.new(403, WRONG_TOKEN) unless token?(given_token(query))

        Reply.new(status: 200, body: JSON.generate({ digest: Digest::SHA256.hexdigest(@token) }))
      end

      def given_token(query)
        URI.decode_www_form(query.to_s).assoc("token")&.last.to_s
      rescue ArgumentError
        ""
      end

      def token?(given)
        OpenSSL.fixed_length_secure_compare(Digest::SHA256.digest(given), Digest::SHA256.digest(@token))
      end

      def relay(socket, path, body)
        summary = summary(path, body)
        verdict = @inspection.call(body)
        raise Refusal.new(403, verdict.reason, **summary) if verdict.refuse

        case decision(socket, Request.new(endpoint: path, bytes: body.bytesize, body:, flagged: verdict.flagged))
        in :gone then dropped(summary)
        in :declined then raise Refusal.new(403, DECLINED, outcome: "declined", **summary)
        in StandardError => e then raise unasked(e, summary)
        in :approved then forward(path, body, summary)
        end
      end

      # The asking thread looks before it asks, for a client that left while it
      # waited its turn; this looks again, for one that left mid-prompt.
      def decision(socket, request)
        answer = Thread::Queue.new
        enqueue(Ask.new(socket:, request:, answer:), summary(request.endpoint, request.body))
        verdict = answer.pop
        present?(socket) ? verdict : :gone
      end

      def unasked(error, summary)
        Refusal.new(403, format(UNASKED, reason: error.message), outcome: "unasked", **summary)
      end

      def enqueue(ask, summary)
        @queueing.synchronize do
          raise Refusal.new(503, TOO_MANY_ASKS, outcome: "busy", **summary) if @asks.size >= MAX_ASKS

          @asks << ask
        end
      end

      def dropped(summary)
        record("client gone", **summary)
        nil
      end

      # A client closing its end reads as an empty peek; one still waiting has nothing to read.
      def present?(socket)
        ![nil, ""].include?(socket.recv_nonblock(1, Socket::MSG_PEEK, exception: false))
      rescue IOError, SystemCallError
        false
      end

      # Logged before the send, so a body that left is on record however the exchange ends.
      def forward(path, body, summary)
        record("forwarded", **summary)
        response = @upstream.forward(path, body)
        unless response.content_type == JSON_TYPE
          raise Refusal.new(502, format(NOT_JSON, type: response.content_type.to_s), outcome: "unrelayed", **summary)
        end

        record("answered", status: response.code.to_i, **summary)
        Reply.new(status: response.code.to_i, body: response.body.to_s)
      rescue Upstream::ForwardFailed, Upstream::MissingKey => e
        raise Refusal.new(502, e.message, outcome: "failed", **summary)
      end

      def read_head(socket)
        verb, target, version = line(socket).split(" ", 3)
        raise Refusal.new(400, MALFORMED) unless target && version&.match?(%r{\AHTTP/1\.[01]\z})

        [verb, target, headers(socket)]
      end

      # @return [Hash{String=>Array<String>}] every value each name was sent with
      def headers(socket)
        lines = Enumerator.produce { line(socket) }.lazy.take_while { !_1.empty? }.first(MAX_HEADERS + 1)
        raise Refusal.new(400, MALFORMED) if lines.size > MAX_HEADERS

        lines.map { pair(_1) }.group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
      end

      def pair(text) = text.split(":", 2).then { |name, value| [name.strip.downcase, value.to_s.strip] }

      def field(headers, name)
        values = headers.fetch(name, [])
        raise Refusal.new(400, format(CONFLICTING, name:)) if values.uniq.size > 1

        values.first
      end

      # Read to the LF, so a line ended without its CR is refused rather than waited on.
      def line(socket)
        text = socket.gets("\n", MAX_LINE) or raise Gone
        raise Refusal.new(400, MALFORMED) unless text.end_with?("\r\n")

        text.delete_suffix("\r\n")
      end

      def read_body(socket, headers)
        length = content_length(headers)
        socket.write("HTTP/1.1 100 Continue\r\n\r\n") if field(headers, "expect").to_s.casecmp?("100-continue")
        body = socket.read(length).to_s
        raise Gone unless body.bytesize == length

        body
      end

      def content_length(headers)
        length = Integer(field(headers, "content-length").to_s, 10, exception: false)
        raise Refusal.new(411, NO_LENGTH) if headers.key?("transfer-encoding") || length.nil? || length.negative?
        raise Refusal.new(413, Inspection::TOO_LARGE) if length > Inspection::MAX_BYTES

        length
      end

      def refuse(socket, refusal)
        record(refusal.outcome, reason: refusal.message, **refusal.fields)
        write(socket, Reply.new(status: refusal.status, body: JSON.generate({ error: refusal.message })))
        drain(socket)
      rescue IOError, SystemCallError
        nil
      end

      def drain(socket)
        socket.close_write
        Timeout.timeout(DRAIN_SECONDS) { socket.read(MAX_DRAIN) }
      rescue Timeout::Error
        nil
      end

      # Only the content type and a recomputed length are relayed, so no upstream header reaches the client.
      def write(socket, reply)
        socket.write("HTTP/1.1 #{reply.status} #{REASONS.fetch(reply.status, "")}\r\n" \
                     "Content-Type: #{JSON_TYPE}\r\nContent-Length: #{reply.body.bytesize}\r\n" \
                     "Connection: close\r\n\r\n", reply.body)
      end

      def summary(path, body) = { endpoint: path, bytes: body.bytesize, digest: Digest::SHA256.hexdigest(body) }

      def record(outcome, **fields) = @journal.record({ type: "gateway", outcome:, **fields })
    end
  end
end
