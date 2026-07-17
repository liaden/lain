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
    #
    # `causal_parents` defaults to the empty set (a plain turn hashes exactly as
    # before); the Agent passes the mailbox messages this turn folded so they
    # stop being pending (decision 2). Each is a Store edge, so {Store#put}
    # refuses a turn naming a message the store has not already seen -- the same
    # referential-integrity guard `parent` and `payload_digest` ride.
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

    # The event where two branches diverged, or nil if they share no history.
    # Walking two chains and comparing digests is all that cache-break
    # localization needs.
    def diverge_at(other)
      meet(other).head
    end

    # TL-3 (pinned, 2026-07-17): the causal ancestry order -- reachability over
    # BOTH parent edges, render and causal, git's "all parents" -- has no unique
    # greatest lower bound: a criss-cross fan-in leaves incomparable maximal
    # common ancestors, and any singleton answer would be arbitrary. So this
    # takes git merge-base's shape: the SET of maximal lower bounds (the common
    # causal ancestors that are not ancestors of another common one), as frozen
    # digests in digest order -- the one canonical order incomparable elements
    # admit. A pure projection over the Store; #meet/#diverge_at stay
    # render-edge and untouched, because cache-break localization needs answers
    # that are stable as causal edges land.
    def causal_meets(other)
      same_store!(other)
      CausalAncestry.new(store).meets(head_digest, other.head_digest)
    end

    # TL-3 (pinned, 2026-07-17): the checkpoint primitive. The deepest common
    # dominator of the two heads over the UNION graph -- render and causal
    # edges together, under a virtual root spanning the closure's forest
    # roots: the latest event EVERY path from that root to both heads must
    # pass through, i.e. the latest point no in-flight branch can bypass,
    # which is what makes it the synchronization/safe-compaction answer.
    # Unlike #causal_meets this IS a true meet-semilattice (a node's
    # dominators are totally ordered, so the deepest common dominator is the
    # unique nearest common ancestor on the dominator tree); its laws run
    # under the same shared group as the render meet, dominance injected.
    #
    # The CRDT causal-stability caveat, inherent and documented rather than a
    # bug: one quiet participant stalls the frontier. An open subagent branch
    # (spawned, not yet folded) keeps this answer at or before its spawn
    # point however far the parent advances, until the branch speaks or
    # closes -- mitigated operationally by actors' explicit stop.
    #
    # Pure and computed on demand. Timelines are frozen, so the memo lives on
    # the injected {Dominators}, keyed by head-digest pair -- sound because
    # the arguments anchor the closure and events are immutable, so a pair's
    # union graph can never change. Callers wanting cross-call memoization
    # hold one Dominators and pass it; the default answers one-shot. An
    # all-the-way-up answer is the empty Timeline: the virtual root is a
    # modeling artifact and never leaves the projection.
    def dominator_meet(other, dominators: Dominators.new(store))
      same_store!(other)
      checkout(dominators.meet(head_digest, other.head_digest))
    end

    # TL-2 (pinned): the chain's identity, by the same derivation
    # {Tools::Subagent::Lineage} and {Tools::AskHuman} address a chain with --
    # a chain is named by its root event's digest, no separate id machinery.
    # Public so any caller can address a Timeline by identity without reaching
    # into `head.correlation`; {Event::ChainWriter.correlation_of} is the one
    # shared implementation.
    def correlation
      Event::ChainWriter.correlation_of(self)
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

    # #commit's own name for the value #correlation already derives -- kept
    # as a distinct, private name because "the correlation to stamp on the
    # NEXT turn" is a different intent from "this chain's identity," even
    # though {Event::ChainWriter.correlation_of} answers both the same way.
    def next_correlation = correlation

    def same_store!(other)
      return if store.equal?(other.store)

      raise CrossStore, "cannot compare Timelines backed by different stores"
    end
  end

  class Timeline
    # {Timeline#causal_meets}'s collaborator: the causal ancestry ORDER --
    # reachability over BOTH parent edges, render and causal, git's "all
    # parents". It takes the Store rather than a head because the order
    # belongs to the shared DAG; a Timeline is only one pointer into it.
    class CausalAncestry
      def initialize(store)
        @store = store
      end

      # {Timeline#causal_meets}'s set, computed where the order lives: the
      # common causal ancestors of the two heads that are not ancestors of
      # another common one (git merge-base's maximal lower bounds), as
      # frozen digests in digest order.
      def meets(head_a, head_b)
        mine = closure([head_a])
        common = closure([head_b]).keys.select { |digest| mine.key?(digest) }
        maximal(common).sort.freeze
      end

      # Reflexive-transitive closure of the seeds, seeds included (nil seeds
      # -- the empty Timeline -- contribute nothing, which is what keeps
      # #causal_meets total). Iterative with an explicit frontier: causal
      # chains reach thousands of events deep, and Ruby's stack does not.
      def closure(seeds)
        seen = {}
        frontier = seeds.compact
        while (digest = frontier.pop)
          unless seen.key?(digest)
            seen[digest] = true
            frontier.concat(edges(@store.fetch(digest)))
          end
        end
        seen
      end

      # The members of `digests` no other member sits above. A member is
      # non-maximal exactly when it is reachable from another member's
      # parents, so ONE closure over all those parents finds every
      # non-maximal member at once, instead of one walk per candidate pair.
      def maximal(digests)
        covered = closure(digests.flat_map { |digest| edges(@store.fetch(digest)) })
        digests.reject { |digest| covered.key?(digest) }
      end

      private

      def edges(event)
        [event.render_parent, *event.causal_parents].compact
      end
    end
  end

  class Timeline
    # {Timeline#dominator_meet}'s collaborator and its memo's home: Timeline
    # values are frozen, so "computed on demand, memoized by head-digest
    # pair" caches here, on the query object a caller holds. Safe under
    # concurrent actor fibers without a lock: every memo value is a pure
    # function of its key over immutable events, so the worst interleaving
    # recomputes the same answer, and each Hash operation is atomic under
    # the GVL.
    class Dominators
      def initialize(store)
        @store = store
        @meets = {}
      end

      # The deepest common dominator's digest, or nil where the meet climbs
      # all the way to the virtual root (which includes either head being
      # nil -- the empty Timeline is the bottom element and absorbs).
      def meet(head_a, head_b)
        return nil if head_a.nil? || head_b.nil?

        @meets.fetch([head_a, head_b].sort) do |key|
          @meets[key] = Tree.new(@store, key).meet(head_a, head_b)
        end
      end

      # The dominance order itself, exposed because the semilattice's laws
      # are stated against it (the render-ancestry predicate is strictly
      # weaker): every virtual-root path to `node` passes through
      # `dominator`. Reflexive; nil, the empty Timeline's head, sits below
      # everything and above only itself.
      def dominates?(dominator, node)
        return true if dominator.nil?
        return false if node.nil?

        Tree.new(@store, [dominator, node]).chain(node).include?(dominator)
      end

      # One dominator tree over the union closure of its seed heads --
      # Cooper/Harvey/Kennedy, "A Simple, Fast Dominance Algorithm":
      # immediate dominators by intersect-walks over a rank order, then any
      # meet is the tree's nearest common ancestor. Their worklist collapses
      # to a single sweep here because the union graph is acyclic (content
      # addressing: an event can only name earlier digests), so topological
      # order processes every predecessor before its successors and one
      # pass is already the fixed point.
      class Tree
        # The virtual root over the closure's forest roots. A modeling
        # artifact: it has no digest and must never leave this class --
        # callers see nil where a walk reaches it.
        ROOT = Object.new
        private_constant :ROOT

        def initialize(store, heads)
          @preds = flow_predecessors(store, heads)
          @rank = topological_rank
          @idom = immediate_dominators
        end

        def meet(head_a, head_b)
          ancestor = intersect(head_a, head_b)
          ancestor.equal?(ROOT) ? nil : ancestor
        end

        # The node itself, then each strictly-shallower dominator, deepest
        # first, the virtual root excluded.
        def chain(node)
          Enumerator.new do |yielder|
            current = node
            until current.equal?(ROOT)
              yielder << current
              current = @idom.fetch(current)
            end
          end
        end

        private

        # node => flow-graph predecessors: its union-graph parents, or the
        # virtual root under the closure's forest roots.
        def flow_predecessors(store, heads)
          CausalAncestry.new(store).closure(heads).keys.to_h do |digest|
            event = store.fetch(digest)
            parents = [event.render_parent, *event.causal_parents].compact.uniq
            [digest, parents.empty? ? [ROOT] : parents]
          end
        end

        def successors
          @successors ||= @preds.each_with_object({}) do |(digest, parents), children|
            parents.each { |parent| (children[parent] ||= []) << digest }
          end
        end

        # Kahn's algorithm from the virtual root. ANY topological rank
        # serves the intersect walks: an immediate dominator is a proper
        # ancestor, so its rank is strictly smaller.
        def topological_rank
          indegree = @preds.transform_values(&:length)
          frontier = [ROOT]
          rank = {}
          while (node = frontier.shift)
            rank[node] = rank.length
            frontier.concat(released_children(node, indegree))
          end
          rank
        end

        # The successors whose last unprocessed predecessor was `node`.
        def released_children(node, indegree)
          successors.fetch(node, []).select { |child| (indegree[child] -= 1).zero? }
        end

        def immediate_dominators
          @idom = { ROOT => ROOT }
          @preds.keys.sort_by { |digest| @rank.fetch(digest) }.each do |digest|
            @idom[digest] = @preds.fetch(digest).reduce { |left, right| intersect(left, right) }
          end
          @idom
        end

        # CHK's intersect: leapfrog the deeper finger up its dominator
        # chain until the fingers agree -- the nearest common ancestor.
        def intersect(left, right)
          until left == right
            left = @idom.fetch(left) while @rank.fetch(left) > @rank.fetch(right)
            right = @idom.fetch(right) while @rank.fetch(right) > @rank.fetch(left)
          end
          left
        end
      end
    end
  end
end
