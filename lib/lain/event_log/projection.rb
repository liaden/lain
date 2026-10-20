# frozen_string_literal: true

module Lain
  module EventLog
    # Read-only views over a log of {Ext::Event}s. Each projection is a PURE FOLD:
    # same log and same injected data, same answer; no accumulated state.
    class Projection
      # @param events [Enumerable<Ext::Event>] the log, in append order -- materialized
      #   here, because the folds re-enumerate and a one-shot Enumerator would
      #   silently fold to empty the second time
      def initialize(events = [])
        # Copied, not aliased: `Array#to_a` returns the receiver, so without the
        # `dup` a caller appending to its own Array would mutate this
        # projection's log -- and a pure fold whose inputs can change is a lie.
        @events = events.to_a.dup.freeze
      end

      # Exactly the :message events addressed to `recipient`, in log order.
      # Lazy, so a consumer reads one message without materializing the log.
      #
      # @param recipient [String, Symbol]
      # @return [Enumerator::Lazy<Ext::Event>]
      def mailbox(recipient)
        wanted = Canonical.normalize(recipient)
        @events.lazy.select { |event| event.kind == :message && event.to == wanted }
      end

      # The recipient's messages still pending: a :message is pending iff no
      # committed :turn in the log names it a causal parent. "Folded" is thus a
      # pure function of the log, never a consumed queue. Purity is NOT
      # agreement: the live log is mutable between a render and its commit, so
      # render and commit must both fold ONE frozen per-turn snapshot of it
      # ({Context::Mailbox::Snapshot}) -- neither may read the log live.
      # Consumption counts :turn edges ONLY: a :message or :spawn carries
      # causal_parents for lineage, which is not consumption.
      #
      # @param recipient [String, Symbol]
      # @return [Enumerator::Lazy<Ext::Event>]
      def pending(recipient)
        consumed = consumed_by_turns
        mailbox(recipient).reject { |event| consumed.include?(event.digest) }
      end

      # The :snapshot in force at `turn`: the last snapshot taken at or before
      # that turn, where a turn's number is how many :turn events precede it in
      # the log. Nil before the first snapshot.
      #
      # @param turn [Integer]
      # @return [Ext::Event, nil]
      def workspace_at(turn)
        @events.each_with_object(count: 0, current: nil) do |event, state|
          state[:count] += 1 if event.kind == :turn
          state[:current] = event if event.kind == :snapshot && state[:count] <= turn
        end.fetch(:current)
      end

      # The tool_result references the causal ancestry of `event` chains back
      # to: every tool_result block carried by an event reachable through
      # `causal_parents`, each source visited once.
      #
      # @param event [Ext::Event]
      # @return [Array<Hash>] the tool_result blocks, in causal-walk order
      def provenance(event)
        causal_closure(event).flat_map { |source| tool_results(source) }
      end

      private

      # The digests every committed :turn names among its causal parents -- the
      # consumed set {#pending} subtracts. A Set: membership is the only
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
      # SystemStackError. Parents push reversed so the stack pops them in their
      # sorted order.
      def causal_closure(event)
        return enum_for(:causal_closure, event) unless block_given?

        stack = event.causal_parents.reverse
        drain(stack, Set.new) do |source|
          yield source
          stack.concat(source.causal_parents.reverse)
        end
      end

      # `Set#add?` answers nil on a repeat and an off-log digest resolves to
      # nothing, so neither reaches the caller: each event yields exactly once.
      def drain(stack, seen)
        until stack.empty?
          digest = stack.pop
          source = seen.add?(digest) && by_digest[digest]
          yield source if source
        end
      end

      # Memoized on the first provenance walk rather than built eagerly: the hot
      # per-turn path (Mailbox's #pending snapshot) never asks for it, so a
      # projection constructed every turn should not pay an O(log) index it
      # will not use.
      def by_digest
        @by_digest ||= @events.to_h { |event| [event.digest, event] }
      end

      # The tool_result blocks an event carries in its content, or none when the
      # event is detached (no carried body) or carries no content blocks.
      #
      # Deliberately NOT lensed. The `type` test asks a question
      # {Tool::ResultBlock.wrap} does not answer -- it accepts any Hash and
      # checks no type, so a lens can only go on AFTER the shape is known -- and
      # what comes back is the block itself, because #provenance answers the wire
      # hash a caller may hand to {Canonical}, which refuses a lens. These blocks
      # are OBSERVED, not built: two of the three in `projection_spec.rb` carry
      # no `is_error`, so a lens reader reaching for that key would raise on
      # them; the `fetch` readers are sound only where {Tool::ResultBlock.of}
      # built the block.
      def tool_results(event)
        blocks = event.body.is_a?(Hash) ? event.body["content"] : nil
        Array(blocks).select { |block| block.is_a?(Hash) && block["type"] == "tool_result" }
      end
    end
  end
end
