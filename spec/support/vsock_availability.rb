# frozen_string_literal: true

require "socket"

# Answers "can this host bind an AF_VSOCK socket?" -- the precondition the
# :vsock tag's before-hook checks (spec/support/tags.rb, hand-back only; see
# .handback-T3.md -- T3 cannot edit that shared file itself) and that
# VsockDaemon relies on before it ever spawns a daemon.
#
# The answer comes from TRYING the bind and rescuing, never from parsing
# `lsmod` or shelling out: `vsock_loopback` autoloads unprivileged the first
# time any process opens an AF_VSOCK socket
# (references/firecracker-microvm-isolation.md, "the module autoloads"), so a
# real bind attempt is the only signal that cannot be stale.
module VsockAvailability
  # Kernel ABI, not a Ruby constant -- Ruby's Socket exposes AF_VSOCK but no
  # sockaddr_vm helper (verified: Socket.constants has AF_VSOCK/PF_VSOCK only,
  # nothing VMADDR_*). Values from linux/vm_sockets.h, re-verified against
  # this kernel at execution time.
  VMADDR_CID_ANY = 0xFFFFFFFF
  VMADDR_PORT_ANY = 0xFFFFFFFF

  # struct sockaddr_vm, hand-packed: family, reserved1, port, cid, then 4
  # bytes of padding -- 16 bytes total, matching struct sockaddr's size.
  SOCKADDR_VM = "SSLLCCCC"

  # @return [Boolean] never raises -- any bind failure (missing module, no
  #   permission, an exotic sandbox) reads as "unavailable", not as an error
  #   the caller must handle. The socket is closed on every path, including a
  #   failed bind, so no descriptor survives a call.
  def self.available?
    # Ruby's socket constants are #ifdef-guarded per platform at build time
    # (unlike a runtime bind failure, which SystemCallError below already
    # covers) -- a Ruby without AF_VSOCK support has no Socket::AF_VSOCK to
    # reference at all, and that reference would raise NameError before the
    # rescue clause ever sees it.
    return false unless Socket.const_defined?(:AF_VSOCK)

    socket = Socket.new(Socket::AF_VSOCK, Socket::SOCK_STREAM, 0)
    begin
      socket.bind([Socket::AF_VSOCK, 0, VMADDR_PORT_ANY, VMADDR_CID_ANY, 0, 0, 0, 0].pack(SOCKADDR_VM))
      true
    ensure
      socket.close
    end
  rescue SystemCallError, SocketError
    false
  end
end
