# frozen_string_literal: true

module Lain
  module Telemetry
    # A hand-edited request resent from the editor: the EDIT's projection
    # record, never the wire's. It IS a {RequestSent} by inheritance, so every
    # projection that diffs or renders requests treats it identically, under its
    # own journal discriminator.
    #
    # The distinct type is the provenance stamp. {Middleware::JournalRequests}
    # documents that "a request_sent with no following turn_usage is how a
    # failure reads", so recording a hand-edit as a plain request_sent would
    # fabricate one failed real dispatch per edit. The stamp lives in the TYPE
    # rather than in `extra`, because `extra` is exactly what Request.new needs
    # to rebuild the request -- a marker there would ride onto the wire on any
    # rebuild-and-dispatch.
    #
    # A resend that goes on to dispatch leaves its own ORDINARY request_sent/
    # turn_usage pair (the loop saw an ordinary Request), joined to this record
    # by digest; an unbridged one leaves this record alone. So the failure
    # reading survives intact either way.
    class RequestResent < RequestSent
    end
  end
end
