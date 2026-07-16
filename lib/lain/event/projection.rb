# frozen_string_literal: true

module Lain
  class Event
    # Read-only views over a log of {Event}s. Each projection is a PURE FOLD:
    # given the same log and the same injected data it returns the same answer,
    # mutates nothing, and holds no accumulated state of its own -- the same
    # property that lets {Timeline} walk an ancestry lazily and lets {Usage}
    # aggregate order-independently.
    #
    # `usage` is INJECTED, never read off an event: the caller folds the
    # Journal's `turn_usage` records into a `digest => Usage` map and hands it
    # in. Spend must not ride an event's payload or meta, because the digest is
    # content-only (a rewound-then-regenerated turn is the SAME content at a
    # DIFFERENT cost -- see {Telemetry::TurnUsage}); the join lives in the
    # Journal, and this map is that join already resolved.
    class Projection
      # @param events [Enumerable<Event>] the log, in append order -- materialized
      #   here, because the folds re-enumerate and a one-shot Enumerator would
      #   silently fold to empty the second time; a log that has grown since
      #   construction means constructing a new Projection over it
      # @param usage [Hash{String=>Usage}] digest => summed usage, Journal-derived
      def initialize(events = [], usage: {})
        # Copied, not aliased: `Array#to_a` returns the receiver, so without the
        # `dup` a caller that later appends to its own Array would silently
        # mutate this projection's log and every view over it. A projection is a
        # pure fold, which is a lie the instant its inputs can change underneath.
        @events = events.to_a.dup.freeze
        @usage = usage
      end

      # Exactly the :message events addressed to `recipient`, in log order. A
      # mailbox is nothing but this filter. Lazy, so a consumer reads one
      # message without materializing the whole log.
      #
      # @param recipient [String, Symbol]
      # @return [Enumerator::Lazy<Event>]
      def mailbox(recipient)
        wanted = Canonical.normalize(recipient)
        @events.lazy.select { |event| event.kind == :message && event.to == wanted }
      end

      # The recipient's messages still pending: a :message is pending iff no
      # committed :turn in the log names it a causal parent (decision 2). "Folded"
      # is thus a pure function of the log, never a consumed queue -- a dispatch
      # that never commits re-folds everything. Purity is NOT agreement: the
      # live log is mutable between a render and its commit, so two calls over
      # separately-read logs CAN disagree about the pending set. Render and
      # commit must both fold ONE frozen per-turn snapshot of it
      # ({Context::Mailbox::Snapshot}) -- neither may read the log live.
      # Consumption counts :turn edges ONLY: a :message or :spawn carries
      # causal_parents for lineage, which is not consumption.
      #
      # @param recipient [String, Symbol]
      # @return [Enumerator::Lazy<Event>]
      def pending(recipient)
        consumed = consumed_by_turns
        mailbox(recipient).reject { |event| consumed.include?(event.digest) }
      end

      # The :snapshot in force at `turn`: the last snapshot taken at or before
      # that turn, where a turn's number is how many :turn events precede it in
      # the log. Nil before the first snapshot. One left fold, carrying the
      # running turn count and the snapshot last seen within the window.
      #
      # @param turn [Integer]
      # @return [Event, nil]
      def workspace_at(turn)
        @events.each_with_object(count: 0, current: nil) do |event, state|
          state[:count] += 1 if event.kind == :turn
          state[:current] = event if event.kind == :snapshot && state[:count] <= turn
        end.fetch(:current)
      end

      # The tool_result references the causal ancestry of `event` chains back
      # to: every tool_result block carried by an event reachable through
      # `causal_parents`, each source visited once. Empty when the chain reaches
      # no tool_result.
      #
      # @param event [Event]
      # @return [Array<Hash>] the tool_result blocks, in causal-walk order
      def provenance(event)
        causal_closure(event).flat_map { |source| tool_results(source) }
      end

      # Total usage over the UNIQUE digests reachable from the given timelines.
      # A branched history shares its prefix; keying on the content address
      # collapses that prefix to one entry, so it is counted once no matter how
      # many branches walk through it -- the payoff of the content-addressed DAG,
      # and why {Usage} is a commutative monoid.
      #
      # A digest absent from the injected map contributes {Usage.zero}. That
      # silence is policy, not proof: user turns and un-instrumented turns are
      # genuinely free, but a Journal-join gap prices identically, and this fold
      # cannot tell the two apart -- a caller auditing spend must validate the
      # join upstream.
      #
      # @param timelines [Array<Timeline>]
      # @return [Usage]
      def usage(*timelines)
        unique_digests(timelines).sum(Usage.zero) { |digest| @usage.fetch(digest, Usage.zero) }
      end

      private

      # The digests every committed :turn names among its causal parents -- the
      # consumed set {#pending} subtracts. A Set because membership is the only
      # question asked of it, once per candidate message.
      def consumed_by_turns
        @events.each_with_object(Set.new) do |event, consumed|
          consumed.merge(event.causal_parents) if event.kind == :turn
        end
      end

      # The transitive causal ancestry of `event`: every log-resident event
      # reachable through `causal_parents`, depth-first along the (already
      # sorted) edges. An explicit work-stack, NOT recursion -- a 10,000-link
      # causal chain is a log shape, not an error, and recursion turned it into
      # SystemStackError. `Set#add?` answers nil for a digest already seen, so a
      # shared causal ancestor is yielded once; a digest naming an event outside
      # this log simply resolves to nothing. Parents push reversed so the stack
      # pops them in their sorted order.
      def causal_closure(event)
        return enum_for(:causal_closure, event) unless block_given?

        stack = event.causal_parents.reverse
        drain(stack, Set.new) do |source|
          yield source
          stack.concat(source.causal_parents.reverse)
        end
      end

      # Drains the work-stack, yielding each log-resident event the first time
      # its digest surfaces. `Set#add?` answers nil on a repeat, and an off-log
      # digest resolves to nothing, so neither reaches the caller.
      def drain(stack, seen)
        until stack.empty?
          digest = stack.pop
          source = seen.add?(digest) && by_digest[digest]
          yield source if source
        end
      end

      # Memoized on first provenance walk rather than built eagerly: the hot
      # per-turn path (Mailbox's #pending snapshot) never asks for it, so a
      # projection constructed every turn should not pay an O(log) index it
      # will not use (panel NIT #3).
      def by_digest
        @by_digest ||= @events.to_h { |event| [event.digest, event] }
      end

      # The tool_result blocks an event carries in its content, or none when the
      # event is detached (no carried body) or carries no content blocks.
      def tool_results(event)
        blocks = event.body.is_a?(Hash) ? event.body["content"] : nil
        Array(blocks).select { |block| block.is_a?(Hash) && block["type"] == "tool_result" }
      end

      # Every timeline's ancestry merged into one Set of content addresses; the
      # Set is what collapses the shared prefix to a single entry.
      def unique_digests(timelines)
        timelines.flatten.each_with_object(Set.new) do |timeline, digests|
          digests.merge(timeline.ancestor_digests)
        end
      end
    end
  end
end
