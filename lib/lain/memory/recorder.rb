# frozen_string_literal: true

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
    class Recorder
      def initialize(index: Index.empty)
        @index = index
      end

      # The current snapshot. Exposed (rather than just #root) so a caller can
      # #checkout an earlier root to inspect what a prior write superseded.
      attr_reader :index

      def root
        index.root
      end

      # Swaps in the Index that results from writing item, and returns the new
      # root -- the one fact a caller (the memory_write tool) needs to report.
      def write(item)
        @index = index.write(item)
        root
      end

      def fetch(id)
        index.fetch(id)
      end
    end
  end
end
