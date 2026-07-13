# frozen_string_literal: true

require "monitor"

module Lain
  # An append-only, content-addressed object database — git's, in miniature.
  #
  # Separating the store from the Timeline is what makes forking O(1). A Timeline
  # is only a (head digest, store) pair, so branching allocates nothing: both
  # branches read the same immutable objects, and a shared prefix is stored once.
  #
  # Entries are never mutated and never removed, so writes are idempotent and a
  # branch that becomes unreachable simply leaves garbage behind, exactly as an
  # unreferenced git object does.
  class Store
    class MissingObject < Error; end

    def initialize
      @objects = {}
      @monitor = Monitor.new
    end

    # Returns the digest. Storing the same turn twice is a no-op, because the
    # digest already names its content.
    def put(turn)
      @monitor.synchronize { @objects[turn.digest] ||= turn }
      turn.digest
    end

    def fetch(digest)
      @monitor.synchronize do
        @objects.fetch(digest) { raise MissingObject, "no object #{digest.inspect} in store" }
      end
    end

    def key?(digest)
      @monitor.synchronize { @objects.key?(digest) }
    end

    def size
      @monitor.synchronize { @objects.size }
    end
  end
end
