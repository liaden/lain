# frozen_string_literal: true

module Lain
  module Core
    # How a {Client} is given its wire. This is a CONTRACT, not a base class --
    # nothing inherits from it, and {Child} (which predates the name) already
    # satisfies it as "the transport that spawns a local daemon". A second
    # implementation attaches to a daemon someone else started, over a socket
    # family {Child} knows nothing about; that difference is the whole reason
    # the seam is named.
    #
    # Two messages, and deliberately no third:
    #
    #   #start -> IO
    #     A CONNECTED, READY socket. Ownership passes to the caller: the client
    #     closes it, and a transport must not read, write, or close it after
    #     handing it over. Provisioning failures raise in the transport's own
    #     words ({Child::Unreachable}, {Core::Died}) -- never a nil socket.
    #
    #   #stop -> Object
    #     Release whatever this transport provisioned AND STILL OWNS, and return
    #     something that describes the termination.
    #
    #     **The socket is never in that set.** #start gave it away; the client
    #     closes it in {Client#stop}, and a transport that closed it here would
    #     be closing an fd it no longer owns. So a transport that merely
    #     ATTACHES to a daemon someone else started -- the AF_VSOCK case this
    #     seam exists for -- owns nothing by the time #stop runs: it releases
    #     nothing and only reports. {Child} is the other case, and the reason
    #     the message exists at all: it provisioned a PROCESS, which the client
    #     cannot reach, so its #stop TERMs and reaps that.
    #
    #     The return value is interpolated into {Core::Died}'s message, so an
    #     operator reads it: {Child} returns a `Process::Status`, an attaching
    #     transport returns whatever names the far end it was dialing. Called
    #     more than once per client -- {Client#perish} runs it on wire death and
    #     {Client#stop} runs it on voluntary teardown, and a voluntary stop runs
    #     BOTH (the collapse below EOFs the reader, which perishes) -- so it must
    #     be idempotent and must keep answering after the first call.
    #
    # There is NO liveness obligation on #stop, and no #pid. An earlier draft
    # required every #stop to EOF the wire, which is implementable only by a
    # transport that owns a process; {Client#stop} collapses its own read side
    # instead, so the reader fiber ends because the client shut its half. That
    # is what makes this contract implementable by something that merely
    # attaches. {Mock} is the executable statement of the minimum: handed its
    # socket, it provisions nothing, so its #stop releases nothing and reports.
    #
    # Nor is there an obligation not to RAISE. {Client#stop} completes the
    # teardown in an `ensure` whatever #stop does, so a transport is free to
    # fail loudly (a far end already gone is one `IOError` away) without
    # stranding the reader fiber on a live socket. The raise reaches the caller
    # after the client is fully torn down.
    module Transport
    end
  end
end

require_relative "transport/mock"
