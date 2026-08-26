# frozen_string_literal: true

require "monitor"

module Lain
  # An append-only, content-addressed object database — git's, in miniature.
  #
  # Separating the store from the Timeline is what makes forking O(1): a Timeline
  # is only a (head digest, store) pair, so branching allocates nothing and a
  # shared prefix is stored once. Entries are never mutated and never removed, so
  # writes are idempotent and an unreachable branch leaves garbage behind exactly
  # as an unreferenced git object does.
  class Store
    class MissingObject < Error; end

    def initialize
      @objects = {}
      @monitor = Monitor.new
    end

    # Returns the digest. Storing the same turn twice is a no-op, because the
    # digest already names its content.
    #
    # Refuses (MissingObject) any predecessor digest the store does not already
    # hold -- the referential-integrity check that keeps every chain reachable
    # from any Store non-dangling. Checked inside the same #synchronize as the
    # write, so a concurrent #put cannot race between check and insert. An object
    # with no predecessor edges (Memory::Index puts Items alongside Nodes) is
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

    # The predecessor digests `object` requires the store to already hold: a
    # Memory::Index::Node's `#parent`, or an Event's `#render_parent` (which its
    # `#parent` aliases, hence the `uniq`), `#causal_parents` and the
    # `#payload_digest` naming its out-of-line body. All duck-typed, so an object
    # whose `#parent` means something OTHER than "digest of my predecessor in
    # this store" would be misvalidated -- give such an object a differently
    # named accessor. An object naming no edge (Memory::Item) is parentless.
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

    # Refuses the FIRST missing predecessor edge, in the message the original
    # single-parent turn put pinned byte-for-byte across the Ruby and Rust
    # stores -- extended to events, never reworded. Reads `@objects` directly
    # rather than `#key?`: `Monitor` is reentrant so it would not deadlock, but
    # it would be a pointless second acquisition of a lock already held.
    #
    # Asks `#empty?` of the rejected edges rather than whether a `#find` result
    # was nil, and that is why this reads as it does. A nil INSIDE
    # `causal_parents` is an edge naming nothing, but `find` answers nil for it
    # exactly as it answers nil for "every edge is present" -- so the sentinel
    # swallowed the malformed edge and minted the event. `parent_edges`'
    # `filter_map` already drops a root's nil `#parent`, so no legitimate edge
    # arrives here as nil.
    def validate_parents!(object)
      dangling = parent_edges(object).reject { |digest| @objects.key?(digest) }
      return if dangling.empty?

      raise MissingObject,
            "no object #{dangling.first.inspect} in store: putting #{object.digest.inspect} would dangle"
    end
  end
end
