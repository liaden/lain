# frozen_string_literal: true

module Lain
  module Memory
    # An immutable (root digest, store) pair over a Merkle chain of writes --
    # Timeline's shape, applied to keyed memory instead of conversation.
    #
    # Each #write links a Node naming (id, item digest, previous node) and
    # returns a new Index; the receiver is untouched. Resolution walks head
    # first and keeps the first Node per id, which is last-write-wins, while
    # every superseded write stays reachable through #checkout.
    class Index
      include Enumerable

      class UnknownId < Error; end

      # The Merkle link between writes. The item's content lives in its own
      # store entry; the Node holds only the item's digest, so rewriting an id
      # never copies a body.
      class Node
        include ContentAddressed

        attr_reader :id, :item_digest, :parent, :digest

        def initialize(id:, item:, parent: nil)
          @id = Canonical.normalize(id)
          @item_digest = Canonical.normalize(item)
          @parent = parent&.dup&.freeze
          @digest = Canonical.digest(payload)
          freeze
        end

        # "item" holds the Item's digest, not its content -- compact on the
        # wire and parallel to Turn's "parent", which also names by digest.
        # The reader is #item_digest; the key must stay "item" because the key
        # is inside the digest, and changing it would re-address every node.
        def payload
          { "id" => id, "item" => item_digest, "parent" => parent }
        end

        def to_s
          "#<Lain::Memory::Index::Node #{id} #{digest[0, 19]}...>"
        end
        alias inspect to_s
      end

      attr_reader :root, :store

      def self.empty(store: Store.new)
        new(root: nil, store:)
      end

      def initialize(root:, store:)
        raise Store::MissingObject, "no object #{root.inspect}" if root && !store.key?(root)

        @root = root&.dup&.freeze
        @store = store
        freeze
      end

      def empty?
        root.nil?
      end

      # Returns a NEW Index; the receiver is untouched (see Timeline#commit for
      # why the verb is not `append`).
      def write(item)
        store.put(item)
        node = Node.new(id: item.id, item: item.digest, parent: root)
        store.put(node)
        self.class.new(root: node.digest, store:)
      end

      def checkout(digest)
        self.class.new(root: digest, store:)
      end

      # Head first: resolution below relies on this order -- the first node
      # matching an id is the most recent write.
      def nodes
        return enum_for(:nodes) unless block_given?

        digest = root
        while digest
          node = store.fetch(digest)
          yield node
          digest = node.parent
        end
      end

      # The full id => Item render. First seen wins per id, and the walk is
      # head first, so the most recent write is the one resolved and
      # superseded items are never fetched. Named #to_h rather than #entries
      # so Enumerable#entries keeps its meaning (see #each).
      def to_h
        nodes.uniq(&:id).to_h { |node| [node.id, store.fetch(node.item_digest)] }
      end

      # #find short-circuits at the head-most match, so resolving one id never
      # walks past it or fetches any other item's body.
      def fetch(id)
        node = nodes.find { |candidate| candidate.id == id }
        raise UnknownId, "no item #{id.inspect} in index" unless node

        store.fetch(node.item_digest)
      end

      # Membership by id. Not #include?: that is Enumerable's, and it answers
      # over the yielded Items. Store-parallel API; the consumer arrives with
      # Recall (unit 5-3.4).
      def key?(id)
        nodes.any? { |node| node.id == id }
      end

      # Sorted by id: iteration order must not depend on write order, or two
      # walks over the same root could render two different Manifests.
      def each
        return enum_for(:each) unless block_given?

        to_h.sort_by(&:first).each { |_id, item| yield item }
      end

      # Regular: two Indexes are equal exactly when they name the same node.
      def ==(other)
        other.is_a?(Index) && root == other.root
      end
      alias eql? ==

      def hash
        [self.class, root].hash
      end

      def to_s
        "#<Lain::Memory::Index #{empty? ? "empty" : "#{root[0, 19]}..."}>"
      end
      alias inspect to_s
    end
  end
end
