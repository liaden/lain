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
    # Refuses (raising MissingObject) any predecessor digest the store does not
    # already hold -- the referential-integrity check at the API boundary
    # that keeps every chain reachable from any Store non-dangling. Checked
    # inside the same #synchronize as the write, so a concurrent #put cannot
    # race between the check and the insert. An object with no predecessor
    # edges (Memory::Index puts Items alongside Nodes) is treated as
    # parentless, same as one whose edge is nil.
    def put(object)
      @monitor.synchronize do
        validate_parents!(object) unless @objects.key?(object.digest)
        @objects[object.digest] ||= object
      end
      object.digest
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

    # The predecessor digests `object` requires the store to already hold. A
    # Memory::Index::Node names one (`#parent`); an Event names three edges --
    # a single `#render_parent` (which its `#parent` aliases, hence the `uniq`),
    # a `#causal_parents` set, and a `#payload_digest` naming its out-of-line
    # body. All are duck-typed: an object whose `#parent` means something OTHER
    # than "digest of my predecessor in this store" (today only Event and
    # Memory::Index::Node reach here through it, and both mean exactly that)
    # would be misvalidated -- give such an object a differently-named accessor.
    # An object naming no edge (Memory::Item) is parentless.
    #
    # `payload_digest` is ordered AFTER the render edge so a chain built through
    # the public API (`Event.turn(parent: absent)`, whose body is also unstored)
    # still refuses on the render edge, the message that seam has always pinned.
    def parent_edges(object)
      single = %i[parent render_parent payload_digest].filter_map do |edge|
        object.public_send(edge) if object.respond_to?(edge)
      end
      causal = object.respond_to?(:causal_parents) ? object.causal_parents : []
      [*single.uniq, *causal]
    end

    # Refuses the FIRST predecessor edge the store does not already hold, in the
    # message the original single-parent turn put pinned byte-for-byte across the
    # Ruby and Rust stores -- extended to events, never reworded. Reads `@objects`
    # directly (never `#key?`): `Monitor` is reentrant, so a second `#synchronize`
    # here would not deadlock, but it would be a pointless second lock
    # acquisition inside one already held.
    def validate_parents!(object)
      dangling = parent_edges(object).find { |digest| !@objects.key?(digest) }
      return if dangling.nil?

      raise MissingObject, "no object #{dangling.inspect} in store: putting #{object.digest.inspect} would dangle"
    end
  end
end
