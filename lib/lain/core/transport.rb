# frozen_string_literal: true

module Lain
  module Core
    # How a {Client} is given its wire. A CONTRACT, not a base class -- nothing
    # inherits from it, and {Child} (which predates the name) already satisfies
    # it as "the transport that spawns a local daemon". The second
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
    #     something describing the termination -- {Core::Died} interpolates it
    #     into a message an operator reads.
    #
    #     **The socket is never in that set**: #start gave it away. So a
    #     transport that merely ATTACHES owns nothing by the time #stop runs and
    #     only reports, while {Child} -- the reason the message exists at all --
    #     provisioned a PROCESS the client cannot reach, so its #stop TERMs and
    #     reaps that. Called more than once per client ({Client#perish} on wire
    #     death, {Client#stop} on voluntary teardown, and a voluntary stop runs
    #     BOTH), so it must be idempotent and must keep answering.
    #
    # There is NO liveness obligation on #stop, and no #pid. An earlier draft
    # required every #stop to EOF the wire, which only a transport that owns a
    # process can do; {Client#stop} collapses its own read side instead, which
    # is what makes this contract implementable by something that merely
    # attaches. {Mock} is the executable statement of that minimum.
    #
    # Nor is there an obligation not to RAISE: {Client#stop} completes the
    # teardown in an `ensure` whatever #stop does, so a transport may fail
    # loudly (a far end already gone is one `IOError` away) without stranding
    # the reader fiber on a live socket.
    module Transport
    end
  end
end
