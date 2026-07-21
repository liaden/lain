# frozen_string_literal: true

require "async"
require "msgpack"

module Lain
  module Core
    # The wire half of the exec boundary. ONE reader-loop fiber drains the
    # socket and resolves an msgid->{Promise} map; {#call} writes a frame,
    # registers its promise, and awaits -- so N concurrent callers interleave
    # safely by construction. The daemon completes out of order BY CONTRACT
    # (crates/lain-core/src/rpc.rs), and msgid demux is the client's side of
    # that bargain. {Child} owns the process; this class owns bytes.
    class Client
      # The daemon version this client speaks, matched EXACTLY against ping's
      # reported version on connect. Tracks crates/lain-core/Cargo.toml -- an
      # exact string, not a range, because the wire contract has no negotiation.
      PROTOCOL_VERSION = "0.1.0"

      # The daemon speaks a different protocol version than this client pins.
      # Refusing up front beats misdecoding frames later; the message names
      # both versions so the fix (rebuild one side) is legible.
      class VersionMismatch < Error
        def initialize(pinned, reported)
          super("lain-core protocol mismatch: client pins #{pinned.inspect}, daemon reports #{reported.inspect}")
        end
      end

      # The server answered this one request with its error slot (unknown
      # method, invalid params): the daemon's error string, verbatim. The
      # connection is fine; only this call failed.
      class Refused < Error; end

      # The daemon accepted the connection but never answered the ping
      # handshake. Startup must always be bounded: an unbounded handshake
      # would park {.start} forever against a mute daemon (the connect budget
      # alone cannot see this -- accept succeeded).
      class HandshakeTimeout < Error
        def initialize(budget)
          super("lain-core accepted but never answered the ping handshake within #{budget}s")
        end
      end

      # Calls after a voluntary {#stop} -- distinct from {Died} on purpose:
      # "you stopped this client, build a new one" is a caller bug's message,
      # while "died: exit 0" would read as a daemon mystery.
      class Stopped < Error
        def initialize
          super("lain-core client stopped; calls after #stop want a new client")
        end
      end

      REQUEST = 0
      RESPONSE = 1
      # msgpack-RPC msgids are u32 (the server rejects anything else); wrap
      # rather than grow into a bignum it would refuse.
      MSGID_LIMIT = 2**32

      # How long {.start} waits for the ping handshake before declaring the
      # daemon mute. Same spirit as {Child::CONNECT_BUDGET}: startup is always
      # bounded; only settled, versioned {#call}s may wait indefinitely (the
      # C1 carried seam).
      HANDSHAKE_BUDGET = 2.0

      # Spawn a {Child}, connect, handshake. Must run inside an Async reactor:
      # the reader fiber parents itself to the current task, and the caller
      # owns getting {#stop} called before that task ends. A handshake that
      # fails OR times out cleans up after itself (see {#handshake}) -- no
      # orphaned daemon, no captive reader fiber.
      def self.start(paths:, binary: Child::BINARY, version: PROTOCOL_VERSION,
                     handshake_budget: HANDSHAKE_BUDGET)
        child = Child.new(paths:, binary:)
        new(child:, socket: child.start, version:).handshake(budget: handshake_budget)
      end

      def initialize(child:, socket:, version: PROTOCOL_VERSION)
        # Without a reactor the reader fiber has no parent to run under and
        # the first #call deadlocks obscurely; refuse in words instead.
        raise Error, "Core::Client must be built inside an Async reactor (Sync/Async block)" unless Async::Task.current?

        @child = child
        @socket = socket
        @version = version
        @msgid = 0
        @pending = {}
        @stopping = false
        @writing = Mutex.new
        # The one reader for the connection's whole life: every response frame
        # passes through it and wakes exactly the fiber whose msgid it carries.
        @reader = Async { drain }
      end

      # @return [Integer] the daemon's pid (a spec's SIGKILL target, a UI's display)
      def pid = @child.pid

      # One msgpack-RPC round trip: `[0, msgid, method, params]` out, the
      # matching `[1, msgid, error, result]` back, however many other calls
      # land in between. Parks the calling fiber; concurrent callers each park
      # on their own promise.
      #
      # @param method [String]
      # @param params [Array]
      # @return [Object] the response's result slot
      # @raise [Died] the daemon is gone (now, or before this call)
      # @raise [Refused] the daemon answered with its error slot
      def call(method, params = [])
        # A dup per raise: raising one shared instance from N fibers would
        # rewrite its backtrace N times; each caller gets its own copy.
        raise @died.dup if @died

        promise = Promise.new
        msgid = register(promise)
        write_frame([REQUEST, msgid, method, params])
        settle(promise.await)
      end

      # The exact-match version gate, run once on connect. Bounded and
      # self-cleaning HERE, not in {.start}: this is the startup surface
      # however the client was composed, an accept-then-silence daemon must
      # fail in the budget's words from either door, and a failed startup
      # must never leak a running daemon or a captive reader fiber (the
      # client owns its child -- {#perish} already TERMs it on wire death).
      # @return [self]
      # @raise [HandshakeTimeout] naming the budget, never a bare TimeoutError
      # @raise [VersionMismatch]
      def handshake(budget: HANDSHAKE_BUDGET)
        reported = within(budget) { call("ping") }.fetch("version")
        raise VersionMismatch.new(@version, reported) unless reported == @version

        self
      rescue StandardError
        stop
        raise
      end

      # Orderly teardown: TERM+reap the child; the EOF that causes ends the
      # reader loop (failing any in-flight call, with {Stopped} rather than
      # {Died} because this death was asked for); only then close our half of
      # the socket, so the reader never reads a closed IO.
      def stop
        @stopping = true
        @child.stop
        @reader.wait
        @socket.close unless @socket.closed?
      end

      private

      def within(budget, &step)
        Async::Task.current.with_timeout(budget, &step)
      rescue Async::TimeoutError
        raise HandshakeTimeout, budget
      end

      def register(promise)
        @msgid = (@msgid + 1) % MSGID_LIMIT
        # Only reachable with 2**32 calls still in flight, but Hash#[]= here
        # would strand that oldest caller forever and misdeliver its response;
        # a coordination impossibility must fail in words (probes/c2/msgid_wrap).
        raise Error, "msgid #{@msgid} wrapped onto a still-pending call" if @pending.key?(@msgid)

        @pending[@msgid] = promise
        @msgid
      end

      # Writers serialize under a fiber-parking Mutex: a partial write yields
      # the fiber, and two frames interleaved mid-frame would poison the
      # stream for every caller.
      def write_frame(frame)
        @writing.synchronize { @socket.write(MessagePack.pack(frame)) }
      rescue SystemCallError, IOError
        # The socket died under the write. The reader loop sees the same death
        # and fails every pending promise -- including this call's -- with
        # {Died} carrying the child's real status, so the raise happens in
        # {#settle} with the true cause, not here as a bare EPIPE.
      end

      def settle(outcome)
        # dup for the same reason #call dups @died: one shared instance,
        # raised per awaiting fiber, would have its backtrace rewritten.
        raise outcome.dup if outcome.is_a?(Exception)

        error, result = outcome
        raise Refused, error unless error.nil?

        result
      end

      # The reader loop. `MessagePack::Unpacker` reads the socket itself --
      # msgpack is self-delimiting, so there is no framing to invent -- and
      # each read parks this fiber, not the reactor. EOF (an IOError
      # subclass), socket-level errors, and undecodable bytes all end the
      # connection the same way: through {#perish}, loudly. An unrescued
      # error here would kill the reader SILENTLY -- every pending caller
      # parked forever, and the unhandled task failure dumped to stderr by
      # Async's console logger (the Journal-interleave hazard, invisible to
      # the AST spec because async writes it, not lain).
      def drain
        MessagePack::Unpacker.new(@socket).each { |frame| deliver(frame) }
        perish
      rescue MessagePack::MalformedFormatError, SystemCallError, IOError
        perish
      end

      def deliver(frame)
        kind, msgid, error, result = frame
        # The server only sends responses; a frame of any other shape, or an
        # msgid nobody is awaiting (an error reply echoing a junk id this
        # client never sent), resolves nothing -- dropping it beats killing
        # the reader that every OTHER call is parked on.
        @pending.delete(msgid)&.resolve([error, result]) if kind == RESPONSE
      end

      # The connection is over: FORCE the exit this is about to report --
      # {Child#stop} is TERM-then-reap -- then fail every in-flight call with
      # the status and make every future call fail the same way. A bare reap
      # here once assumed the child was already dead; a daemon that closes
      # the socket while staying alive would park this fiber in wait2
      # forever (probes/c2/misbehaving_daemons case 3).
      def perish
        status = @child.stop
        @died = @stopping ? Stopped.new : Died.new(status)
        @pending.each_value { |promise| promise.resolve(@died) }
        @pending.clear
      end
    end
  end
end
