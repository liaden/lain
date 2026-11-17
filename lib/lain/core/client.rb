# frozen_string_literal: true

require "async"
require "msgpack"

module Lain
  module Core
    # The wire half of the exec boundary. ONE reader-loop fiber drains the
    # socket and resolves an msgid->{Promise} map, so N concurrent callers
    # interleave safely by construction. The daemon completes out of order BY
    # CONTRACT (crates/lain-rpc/src/lib.rs), and msgid demux is the client's
    # side of that bargain. A {Transport} provisions the wire and describes its
    # own termination; this class owns bytes.
    class Client
      # Matched EXACTLY against ping's reported version on connect. Tracks
      # crates/lain-daemon/Cargo.toml -- an exact string, not a range, because the
      # wire contract has no negotiation.
      PROTOCOL_VERSION = "0.1.0"

      # Refusing up front beats misdecoding frames later; the message names both
      # versions so the fix (rebuild one side) is legible.
      class VersionMismatch < Error
        def initialize(pinned, reported)
          super("lain-daemon protocol mismatch: client pins #{pinned.inspect}, daemon reports #{reported.inspect}")
        end
      end

      # The daemon's error string, verbatim, for one request. The connection is
      # fine; only this call failed.
      class Refused < Error; end

      # Startup must always be bounded: an unbounded handshake would park
      # {.start} forever against a mute daemon, which the connect budget alone
      # cannot see because accept succeeded.
      class HandshakeTimeout < Error
        def initialize(budget)
          super("lain-daemon accepted but never answered the ping handshake within #{budget}s")
        end
      end

      # Distinct from {Died} on purpose: "you stopped this client, build a new
      # one" is a caller bug's message, where "died: exit 0" would read as a
      # daemon mystery.
      class Stopped < Error
        def initialize
          super("lain-daemon client stopped; calls after #stop want a new client")
        end
      end

      REQUEST = 0
      RESPONSE = 1
      PUSH = 2
      # msgpack-RPC msgids are u32 (the server rejects anything else); wrap
      # rather than grow into a bignum it would refuse.
      MSGID_LIMIT = 2**32

      # Startup is always bounded; only settled, versioned {#call}s may wait
      # indefinitely.
      HANDSHAKE_BUDGET = 2.0

      # The transport is injected rather than built here: one may spawn a local
      # daemon, another attach to one, and this class owns bytes either way. Must run inside
      # an Async reactor -- the
      # reader fiber parents itself to the current task, and the caller owns
      # getting {#stop} called before that task ends.
      #
      # `pushes` is an Async::Queue that receives `[method, params]` for each
      # server push; the caller drains it, so subscriber code never runs on the
      # reader fiber. The queue is unbounded and the subscriber must drain it (the
      # server bounds its own side at 256 per connection). Without one, or once it
      # is closed, pushes are dropped and `notes` hears of it once.
      def self.start(transport:, version: PROTOCOL_VERSION, handshake_budget: HANDSHAKE_BUDGET, pushes: nil,
                     notes: Sink::Null.new)
        new(transport:, socket: transport.start, version:, pushes:, notes:).handshake(budget: handshake_budget)
      end

      def initialize(transport:, socket:, version: PROTOCOL_VERSION, pushes: nil, notes: Sink::Null.new)
        # Without a reactor the reader fiber has no parent to run under and
        # the first #call deadlocks obscurely; refuse in words instead.
        raise Error, "Core::Client must be built inside an Async reactor (Sync/Async block)" unless Async::Task.current?

        @transport = transport
        @socket = socket
        @version = version
        @pushes = pushes
        @notes = notes
        @dropped_noted = false
        @msgid = 0
        @pending = {}
        @stopping = false
        @writing = Mutex.new
        @reader = Async { drain }
      end

      # One msgpack-RPC round trip: `[0, msgid, method, params]` out, the
      # matching `[1, msgid, error, result]` back, however many other calls land
      # in between. Concurrent callers each park on their own promise.
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

      # Bounded and self-cleaning HERE, not in {.start}: this is the startup
      # surface however the client was composed, an accept-then-silence daemon
      # must fail in the budget's words from either door, and a failed startup
      # must never leak a running daemon or a captive reader fiber.
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

      # Parks the calling fiber until the reader has stopped, whether the far
      # end hung up, the bytes went bad, or {#stop} ran.
      # @return [Died, Stopped] why the connection ended
      def wait
        @reader.wait
        @died
      end

      # The transport is released TWICE on this path, by design: here, and again
      # in {#perish} once the collapse EOFs the reader. {Transport} requires
      # idempotence for exactly that reason.
      def stop
        @stopping = true
        @transport.stop
      ensure
        # In an `ensure` because a transport is allowed to RAISE from #stop (an
        # attaching transport closing an already-gone far end is one IOError
        # away). Skipping the collapse would leave the reader parked on a live
        # socket and the reactor would never return -- a hang, not a failure.
        collapse
      end

      private

      # Shutting OUR read half EOFs the reader loop; only then close the socket,
      # so the reader never reads a closed IO. This is what makes the wait
      # terminate for a transport that owns no process: one that spawned a daemon
      # TERMs it and the dropped connection EOFs us for free, but a transport that
      # merely ATTACHED has nothing to kill, and relying on the far end to hang
      # up would park this fiber forever. It is also what keeps "#stop must EOF
      # the wire" off the {Transport} contract.
      #
      # #close_read is `shutdown(SHUT_RD)`, not a close: on Linux, bytes already
      # buffered stay readable, so a response that landed just before teardown
      # is still delivered and the reader EOFs only once drained (measured, with
      # a forked daemon writing and the parent busy-waiting so no fiber could be
      # scheduled in between). It also leaves `closed?` false, which is why the
      # trailing #close is the line that reclaims the fd -- and why it gets its
      # own `ensure`, since {Task#wait} re-raises whatever killed the reader.
      def collapse
        @socket.close_read unless @socket.closed?
        @reader.wait
      ensure
        @socket.close unless @socket.closed?
      end

      def within(budget, &step)
        Async::Task.current.with_timeout(budget, &step)
      rescue Async::TimeoutError
        raise HandshakeTimeout, budget
      end

      def register(promise)
        @msgid = (@msgid + 1) % MSGID_LIMIT
        # Only reachable with 2**32 calls still in flight, but Hash#[]= here
        # would strand that oldest caller forever and misdeliver its response;
        # a coordination impossibility must fail in words.
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
        # {Died} carrying the transport's own account of the termination, so
        # the raise happens in {#settle} with the true cause, not here as a
        # bare EPIPE.
      end

      def settle(outcome)
        # dup for the same reason #call dups @died: one shared instance,
        # raised per awaiting fiber, would have its backtrace rewritten.
        raise outcome.dup if outcome.is_a?(Exception)

        error, result = outcome
        raise Refused, error unless error.nil?

        result
      end

      # `MessagePack::Unpacker` reads the socket itself -- msgpack is
      # self-delimiting, so there is no framing to invent -- and each read parks
      # this fiber, not the reactor. EOF (an IOError subclass), socket-level
      # errors and undecodable bytes all end the connection the same way,
      # through {#perish}, loudly: an unrescued error here would kill the reader
      # SILENTLY, parking every pending caller forever and dumping the unhandled
      # task failure to stderr through Async's console logger -- the
      # Journal-interleave hazard, invisible to the AST spec because async
      # writes it, not lain.
      def drain
        MessagePack::Unpacker.new(@socket).each { |frame| deliver(frame) }
        perish
      rescue MessagePack::MalformedFormatError, SystemCallError, IOError
        perish
      end

      def deliver(frame)
        kind, *fields = frame
        case kind
        when RESPONSE then respond(*fields.first(3))
        when PUSH then push(*fields) if well_formed_push?(fields)
        end
      end

      # An msgid nobody is awaiting (an error reply echoing a junk id this
      # client never sent) resolves nothing -- dropping it beats killing the
      # reader that every OTHER call is parked on.
      def respond(msgid = nil, error = nil, result = nil)
        @pending.delete(msgid)&.resolve([error, result])
      end

      # The server orders pushes among themselves but not against responses, so
      # nothing here may assume a push precedes or follows any call's reply.
      def push(method, params)
        return note_dropped(method) unless @pushes

        @pushes.enqueue([method, params])
      rescue Async::Queue::ClosedError
        note_dropped(method)
      end

      def well_formed_push?(fields)
        fields.size == 2 && fields.first.is_a?(String) && fields.last.is_a?(Array)
      end

      def note_dropped(method)
        return if @dropped_noted

        @dropped_noted = true
        @notes.puts("lain-daemon push #{method.inspect} dropped: no subscriber (further drops not noted)")
      end

      # Releasing the transport rather than merely observing matters for one
      # that owns a process: its #stop is TERM-then-reap, and a bare reap here
      # once assumed the child was already dead, so a daemon that closed the
      # socket while staying alive parked this fiber in wait2 forever. A
      # transport that only attaches forces no exit and simply reports.
      # {Transport#stop} runs here AND in {#stop}; the contract tolerates that.
      def perish
        status = release
        @died = @stopping ? Stopped.new : Died.new(status)
        @pending.each_value { |promise| promise.resolve(@died) }
        @pending.clear
      end

      # A transport is allowed to fail here (the far end may already be gone),
      # and {#perish} must resolve every parked caller regardless: letting the
      # raise escape into the reader task strands them forever AND dumps an
      # unhandled-task JSON blob onto stderr -- the Journal-interleave hazard
      # {#drain} exists to avoid. Measured, not assumed. The raise itself reads
      # as well as a status in {Died}'s message, so it is what comes back.
      def release
        @transport.stop
      rescue StandardError => e
        e
      end
    end
  end
end
