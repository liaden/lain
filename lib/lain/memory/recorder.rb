# frozen_string_literal: true

require "active_support/core_ext/module/delegation"

module Lain
  module Memory
    # The one mutable holder of a live {Memory::Index}, single-threaded like
    # {Agent::Accounting}. `Index#write` is pure -- it returns a new Index and
    # leaves its receiver untouched -- so something has to hold "the current
    # one" for a session's tools to share. That something is the Recorder.
    #
    # #fetch delegates to the current snapshot, which means a Recorder
    # satisfies the same duck a bare Index does: {Tools::MemoryRead.new(index:
    # recorder)} works with no constructor contract change, and a read
    # constructed against the Recorder always sees the most recent write.
    #
    # Deliberately NOT a singleton, and nothing here enforces one-Recorder-
    # per-Store: two Recorders sharing an underlying Store is a legitimate
    # bench arm (e.g. comparing a tool that writes through one Recorder
    # against a read-only view held by another). The actual invariant --
    # "the Agent wires exactly one Recorder into a session's tools" -- is a
    # wiring fact the caller is responsible for, not something this class
    # could check without also deciding who else is allowed to hold a
    # reference, which is not its business.
    class Recorder
      def initialize(index: Index.empty)
        @index = index
      end

      # The current snapshot. Exposed (rather than just #root) so a caller can
      # #checkout an earlier root to inspect what a prior write superseded.
      attr_reader :index

      delegate :root, :fetch, to: :index

      # Swaps in the Index that results from writing item, and returns the new
      # root -- the one fact a caller (the memory_write tool) needs to report.
      def write(item)
        @index = index.write(item)
        root
      end
    end
  end
end
