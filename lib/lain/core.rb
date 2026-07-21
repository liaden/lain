# frozen_string_literal: true

module Lain
  # The Ruby half of the out-of-process exec boundary. `crates/lain-core` is a
  # msgpack-RPC daemon on a Unix socket -- out of process by the placement rule
  # (async, I/O-bound, isolation-relevant work never runs inside the Ruby
  # process; see ext/lain/CLAUDE.md). {Child} owns the daemon's lifecycle;
  # {Client} owns the wire. Path policy stays in Ruby: the daemon is handed its
  # socket and tracing paths via argv and never computes its own.
  module Core
    # The daemon is gone: the exit status or fatal signal, verbatim, in the
    # error's own words. Raised for every in-flight call the death stranded AND
    # for every call after it -- a dead exec boundary must never fail silently
    # or be quietly retried into.
    class Died < Error
      # @param status [Process::Status]
      def initialize(status)
        super("lain-core died: #{status}")
      end
    end
  end
end

require_relative "core/child"
require_relative "core/client"
