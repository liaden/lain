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
    #
    # Refuses (raising MissingObject) a `parent:` digest the store does not
    # already hold -- the referential-integrity check at the API boundary
    # that keeps every chain reachable from any Store non-dangling. Checked
    # inside the same #synchronize as the write, so a concurrent #put cannot
    # race between the check and the insert. An object with no `parent`
    # method (Memory::Index puts Items alongside Nodes) is treated as
    # parentless, same as one whose `parent` is nil.
    def put(turn)
      @monitor.synchronize do
        validate_parent!(turn) unless @objects.key?(turn.digest)
        @objects[turn.digest] ||= turn
      end
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

    private

    # `turn.parent` when `turn` responds to it, else parentless -- see #put.
    # The duck check cuts the other way too: an object whose `parent` means
    # something OTHER than "digest of my predecessor in this store" (today only
    # Turn and Memory::Index::Node reach here, and both mean exactly that) would
    # be misvalidated -- give such an object a differently-named accessor.
    # Reads `@objects` directly (never `#key?`): `Monitor` is reentrant, so a
    # second `#synchronize` here would not deadlock, but it would be a
    # pointless second lock acquisition inside one already held.
    def validate_parent!(turn)
      parent = turn.respond_to?(:parent) ? turn.parent : nil
      return if parent.nil? || @objects.key?(parent)

      raise MissingObject, "no object #{parent.inspect} in store: putting #{turn.digest.inspect} would dangle"
    end
  end
end
