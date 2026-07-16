# frozen_string_literal: true

module Lain
  # An immutable (head digest, store) pair over a content-addressed DAG.
  #
  # Because a Timeline holds only a head digest, forking is free and committing to
  # two Timelines that share a head produces two branches whose common prefix is
  # stored exactly once. Time-travel (#rewind, #checkout) is pointer movement.
  #
  # Under the ancestry relation the Timelines over one Store form a meet
  # semilattice: +a <= b+ when a is an ancestor of b, +#meet+ is the greatest
  # common ancestor, and the empty Timeline is the bottom element (which is what
  # makes #meet total even for turns that share no history). #meet is therefore
  # idempotent, commutative, and associative -- laws the specs assert directly.
  #
  # Named branch refs are deliberately absent for now; a branch here is just a
  # Timeline value that somebody is holding.
  #
  # Closer to a git ref than to a Range: a Range is bounded enumeration over a
  # receiver that owns its elements, where a Timeline is a movable pointer into
  # a Store it does not own and that other Timelines share.
  class Timeline
    class CrossStore < Error; end

    attr_reader :head_digest, :store

    def self.empty(store: Store.new)
      new(head_digest: nil, store:)
    end

    def initialize(head_digest:, store:)
      raise Store::MissingObject, "no object #{head_digest.inspect}" if head_digest && !store.key?(head_digest)

      @head_digest = head_digest&.dup&.freeze
      @store = store
      freeze
    end

    def empty?
      head_digest.nil?
    end

    def head
      head_digest && store.fetch(head_digest)
    end

    # Returns a NEW Timeline; the receiver is untouched.
    #
    # Named `commit` rather than `append` on purpose. In Ruby `append` means
    # `Array#append` -- it mutates the receiver -- and `t = t.append(...)` would
    # read to both a human and to RuboCop's Style/RedundantSelfAssignment as a
    # redundant self-assignment worth deleting. Deleting it would silently drop
    # every turn. The git verb says what actually happens: a new object, named by
    # its content, with the old head as its parent.
    def commit(role:, content:, meta: {})
      turn = Turn.new(role:, content:, parent: head_digest, meta:, correlation: next_correlation)
      store.put(turn)
      self.class.new(head_digest: turn.digest, store:)
    end

    # Immutability makes this identity: appending to the value you are holding
    # cannot disturb anyone else holding it. Kept as a name for the intent.
    def fork
      self
    end

    def checkout(digest)
      self.class.new(head_digest: digest, store:)
    end

    # Rewinding past the root lands on the empty Timeline rather than raising:
    # `nil` absorbs, so the walk needs no early exit.
    def rewind(count = 1)
      digest = head_digest
      count.times { digest &&= store.fetch(digest).parent }
      checkout(digest)
    end

    # Head first, root last.
    def ancestors
      return enum_for(:ancestors) unless block_given?

      digest = head_digest
      while digest
        turn = store.fetch(digest)
        yield turn
        digest = turn.parent
      end
    end

    def ancestor_digests
      ancestors.map(&:digest)
    end

    # Root first, head last: the order a provider wants.
    def to_a
      ancestors.to_a.reverse
    end

    def length
      ancestors.count
    end

    def include?(digest)
      ancestor_digests.include?(digest)
    end

    def ancestor_of?(other)
      same_store!(other)
      return true if empty?

      other.include?(head_digest)
    end

    # Greatest common ancestor. Total: Timelines sharing no history meet at the
    # empty Timeline, the bottom element.
    def meet(other)
      same_store!(other)
      mine = ancestor_digests.to_h { |digest| [digest, true] }
      common = other.ancestor_digests.find { |digest| mine.key?(digest) }
      checkout(common)
    end
    alias & meet

    # The Turn where two branches diverged, or nil if they share no history.
    # Walking two chains and comparing digests is all that cache-break
    # localization needs.
    def diverge_at(other)
      meet(other).head
    end

    # Regular: two Timelines are equal exactly when they name the same turn.
    def ==(other)
      other.is_a?(Timeline) && head_digest == other.head_digest
    end
    alias eql? ==

    def hash
      [self.class, head_digest].hash
    end

    def to_s
      "#<Lain::Timeline #{empty? ? "empty" : "#{head_digest[0, 19]}... (#{length})"}>"
    end
    alias inspect to_s

    private

    # TL-2 (pinned): correlation is DERIVED by chain construction -- a chain is
    # named by its root event's digest, no separate id machinery. The root
    # cannot contain its own address, so it carries nil; the first descendant
    # reads the root digest off the head, and everyone below inherits it.
    def next_correlation
      return nil if empty?

      head.correlation || head_digest
    end

    def same_store!(other)
      return if store.equal?(other.store)

      raise CrossStore, "cannot compare Timelines backed by different stores"
    end
  end
end
