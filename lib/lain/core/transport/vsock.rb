# frozen_string_literal: true

require "socket"

module Lain
  module Core
    module Transport
      # Attaches to a lain-core daemon already listening on an AF_VSOCK port --
      # the {Transport} case the seam was named for. {Child} spawns a daemon and
      # reaches it through the filesystem; this one dials a (cid, port) pair,
      # which is how the same RPC crosses a hypervisor boundary unchanged once
      # the daemon runs inside a guest.
      #
      # It PROVISIONS NOTHING. Whoever started the daemon owns it, and #start
      # hands its one socket to the client, so by the time #stop runs this object
      # holds nothing to release -- see {Transport}, where that is the contract,
      # not an omission.
      class Vsock
        # The dial failed outright. Wrapped rather than passed through so the
        # failure names the far end: a bare Errno::ECONNRESET says nothing about
        # WHICH address was wrong, and a wrong port is the overwhelmingly likely
        # cause. Mirrors {Child::Unreachable}, which exists for the same reason.
        #
        # It is deliberately NOT the way "nothing is listening" is detected --
        # see #start.
        class Unreachable < Error
          def initialize(far_end, cause)
            super("lain-core could not be dialled on #{far_end}: #{cause.message}")
          end
        end

        # Kernel ABI from linux/vm_sockets.h, not Ruby constants: Socket exposes
        # AF_VSOCK but no VMADDR_* and no sockaddr_vm helper, so the address is
        # hand-packed below.
        #
        # LOCAL is the default by CONVENTION, not because the alternatives fail.
        # It is the documented way to name "a daemon in this same vsock context",
        # which is what the kernel's vsock_loopback serves and what a guest-local
        # daemon is. HOST is what a daemon INSIDE a guest dials to reach its
        # hypervisor. Measured on this kernel against a live listener bound to
        # CID_ANY, LOCAL and HOST are INDISTINGUISHABLE -- ping, arbitrary bytes,
        # a mebibyte and 8-way demux all pass over either -- so the default buys
        # legibility in {#far_end} and nothing more. (An earlier draft of this
        # comment claimed HOST connects and then fails ENOTCONN from the host;
        # that is true only when NOTHING is listening, and it is deleted rather
        # than qualified, because this file is where the microVM work will come
        # looking for CID semantics.)
        #
        # ANY is a bind-side wildcard and is not a dialable address at all: it is
        # refused ENODEV, deterministically, which is the only reliable refusal
        # this transport has and is how the specs reach that branch on purpose.
        VMADDR_CID_ANY = 0xFFFFFFFF
        VMADDR_CID_LOCAL = 1
        VMADDR_CID_HOST = 2

        # struct sockaddr_vm: family, reserved1, port, cid, then 4 bytes of
        # padding -- 16 bytes, matching struct sockaddr's size. The layout is
        # kernel ABI; a silent mismatch here binds a different address rather
        # than failing.
        SOCKADDR_VM = "SSLLCCCC"

        # @param port [Integer, String] the daemon's vsock port (the daemon
        #   publishes it; see VsockDaemon in the spec harness for the discovery
        #   half)
        # @param cid [Integer, String] which vsock context to dial
        # @raise [ArgumentError, TypeError] naming the offending value
        def initialize(port:, cid: VMADDR_CID_LOCAL)
          @port = decimal(port)
          @cid = decimal(cid)
        end

        # What this transport was dialling, in an operator's words. It is both
        # the termination report and the only diagnostic a wrong address gets,
        # so the two must not be able to drift apart.
        def far_end = "AF_VSOCK cid #{@cid} port #{@port}"

        # Dial the far end and hand the socket over; ownership passes to the
        # caller, which closes it.
        #
        # There is NO connect-time "nothing is listening" check here, and none is
        # possible: measured on vsock_loopback, dialling a port with no listener
        # raised ECONNRESET some runs and SUCCEEDED others (the first write then
        # failing ENOTCONN). ECONNREFUSED -- the TCP/Unix intuition -- never
        # appears at all. So {Unreachable} reports a refusal WHEN the kernel
        # happens to give one; the reliable signal that nobody is home is the
        # handshake going unanswered, which {Client} already bounds and names.
        #
        # @return [Socket] connected, ownership passed to caller
        # @raise [Unreachable]
        def start
          socket = Socket.new(Socket::AF_VSOCK, Socket::SOCK_STREAM, 0)
          connect(socket)
          socket
        end

        # Releases nothing -- the daemon belongs to whoever started it and the
        # socket belongs to the client -- and reports the address, which is what
        # {Core::Died} interpolates when this wire dies. Idempotent for free:
        # with nothing to release, every call is the first one.
        # @return [String]
        def stop = far_end

        private

        # Coerced HERE so a bad value fails at construction naming ITSELF, rather
        # than surviving to {#start} and arriving as a `TypeError` out of
        # `Array#pack` -- which would then be dressed as {Unreachable}, a lie
        # about a far end that was never an address.
        #
        # A String is the realistic caller (argv, a config file, the decimal text
        # the daemon publishes), and it is parsed base-10 EXPLICITLY: Ruby reads
        # `Integer("012345")` as octal 5349, so a zero-padded field would
        # otherwise dial a different port in silence. The radix is String-only --
        # `Integer(5252, 10)` raises -- hence the branch.
        def decimal(value) = value.is_a?(String) ? Integer(value, 10) : Integer(value)

        # The fd is ours until {#start} RETURNS it, so nothing may escape this
        # method leaving one open -- and that guarantee is unconditional, not a
        # list of the exceptions worth closing for. An earlier version rescued
        # only SystemCallError and leaked one descriptor per call on every other
        # path (measured: 50 dials with a String port, 7 open fds to 57, raising
        # out of `Array#pack`). {#initialize}'s coercion closed that particular
        # hole; the unconditional rescue is what stops the next one.
        #
        # `Socket.new` stays outside: when it raises there is no descriptor to
        # reclaim.
        def connect(socket)
          socket.connect([Socket::AF_VSOCK, 0, @port, @cid, 0, 0, 0, 0].pack(SOCKADDR_VM))
        rescue SystemCallError => e
          socket.close
          raise Unreachable.new(far_end, e)
        rescue StandardError
          socket.close
          raise
        end
      end
    end
  end
end
