# frozen_string_literal: true

module Lain
  # An immutable (head digest, store) pair over a content-addressed DAG.
  #
  # Because a Timeline holds only a head digest, forking is free and committing to
  # two Timelines that share a head produces two branches whose common prefix is
  # stored exactly once. Time-travel (#rewind, #checkout) is pointer movement.
  #
  # A Timeline is an element of the DAG's render order, not the owner of it:
  # the meet lives on {Dag::RenderAncestry}, and #ancestor_of? is its predicate.
  #
  # Named branch refs are deliberately absent for now; a branch here is just a
  # Timeline value that somebody is holding.
  #
  # Closer to a git ref than to a Range: a Range is bounded enumeration over a
  # receiver that owns its elements, where a Timeline is a movable pointer into
  # a Store it does not own and that other Timelines share.
  class Timeline
    CrossStore = Dag::CrossStore

    attr_reader :head_digest, :store

    # The store is required: a default from {Dag::Factory} is the Rust store
    # once that is selected, and this timeline cannot commit into it.
    def self.empty(store:)
      new(head_digest: nil, store:)
    end

    # Referential integrity, and deliberately NOT a {Lain::Declarative}
    # declaration. A declaration states the shape of a value; this rule is one
    # predicate against an INJECTED COLLABORATOR (does this store hold this
    # digest), and stating it declaratively costs eleven lines where the clause
    # costs one.
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
    #
    # `causal_parents` defaults to the empty set (a plain turn hashes exactly as
    # before); the Agent passes the mailbox messages this turn folded, because
    # a message stays pending until a committed turn names it a causal parent --
    # folding is read off the log, never popped from a queue. Each is a Store
    # edge, so {Store#put} refuses a turn naming a message the store has not
    # already seen -- the same referential-integrity guard `parent` and
    # `payload_digest` ride.
    def commit(role:, content:, meta: {}, causal_parents: [])
      turn = Event.turn(role:, content:, parent: head_digest, meta:, correlation: next_correlation, causal_parents:)
      # The envelope's payload_digest is a Store edge (referential integrity),
      # so the body must land first or the envelope's own put would dangle. The
      # turn CARRIES the very Payload it addresses (Event.turn built it), so
      # storing is a reuse, never a rebuild -- one digest pass per object.
      store.put(turn.carried_payload)
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

    # Shareable without a deep copy because a Turn's content is already frozen.
    # A digest off this chain bounds nothing, so the walk runs to the root and
    # answers every turn, dropping `onto`: a stale prefix is never spliced.
    #
    # @param after [String, nil] an ancestor's digest; only the turns after it are projected
    # @param onto [Array<Hash>] the messages up to `after`, kept when the walk reaches it
    # @return [Array<Hash>] deep frozen, root first
    def messages(after: nil, onto: NO_MESSAGES)
      turns = ancestors.take_while { |turn| turn.digest != after }
      fresh = EventLog::Messages.project(turns.reverse)
      reached?(turns, after) ? (onto + fresh).freeze : fresh
    end

    def length
      ancestors.count
    end

    # `#find`/`#any?` stop pulling from `#ancestors`' generator the moment the
    # block is satisfied, unlike `ancestor_digests.include?` -- which builds
    # the whole mapped Array before asking. That difference is invisible in
    # the result (both answer the same true/false); it only shows up in how
    # many turns the walk fetched to get there.
    def include?(digest)
      ancestors.any? { |turn| turn.digest == digest }
    end

    def ancestor_of?(other)
      Dag.same_store!(self, other)
      return true if empty?

      other.include?(head_digest)
    end

    # Pinned: the chain's identity, by the same derivation
    # {Tools::Subagent::Lineage} and {Tools::AskHuman} address a chain with --
    # a chain is named by its root event's digest, no separate id machinery.
    # Public so any caller can address a Timeline by identity without reaching
    # into `head.correlation`; {EventLog::ChainWriter.correlation_of} is the one
    # shared implementation.
    def correlation
      EventLog::ChainWriter.correlation_of(self)
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
      "#<Lain::Timeline #{empty? ? "empty" : "#{Canonical.abbreviate(head_digest)}... (#{length})"}>"
    end
    alias inspect to_s

    private

    NO_MESSAGES = [].freeze
    private_constant :NO_MESSAGES

    # The walk stopped at `after` when the oldest turn it kept stands on it.
    def reached?(turns, after)
      !after.nil? && (turns.empty? ? head_digest : turns.last.parent) == after
    end

    # #commit's own name for the value #correlation already derives -- kept
    # as a distinct, private name because "the correlation to stamp on the
    # NEXT turn" is a different intent from "this chain's identity," even
    # though {EventLog::ChainWriter.correlation_of} answers both the same way.
    def next_correlation = correlation
  end
end
