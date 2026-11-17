# frozen_string_literal: true

module Lain
  # The Ruby half of the lain-daemon wire. `crates/lain-daemon` is a msgpack-RPC
  # daemon on a Unix socket, out of process by the placement rule.
  # {Client} owns the wire over a {Transport} it is handed. Path policy
  # stays in Ruby: the daemon is handed its socket and tracing paths via argv
  # and never computes its own.
  module Core
    # Raised for every in-flight call the daemon's death stranded AND for every
    # call after it -- a dead boundary must never fail silently or be quietly
    # retried into.
    class Died < Error
      # @param status [Process::Status]
      def initialize(status)
        super("lain-daemon died: #{status}")
      end
    end
  end
end
