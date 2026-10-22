# frozen_string_literal: true

module Lain
  class Context
    # Folds a recipient's pending actor messages into the message tail: the
    # parent's read-side of the orchestration message-DAG. Like {Recall}, an
    # opt-in stage a custom pipeline composes AFTER CacheBreakpoints, so the
    # folded messages ride the same UNCACHED SUFFIX Reminder's and Recall's
    # tails do. Today's exchange therefore never rewrites yesterday's cached
    # prefix, which is what lets a long-lived actor's continuous event stream be
    # projected into the parent's prompt at all.
    #
    # The messages are a pure PROJECTION over the shared event log, never a
    # mutable queue: "pending" is DERIVED, not marked -- a :message is pending
    # until a committed :turn names it a causal parent -- so this combinator
    # holds NO fold-state, two renders over one snapshot fold byte-identically,
    # and a dispatch that never commits re-folds everything.
    #
    # THE PRECONDITION THAT MAKES RENDER AND COMMIT AGREE: both fold the SAME
    # frozen per-turn {Snapshot}, captured once at turn start. The shared log is
    # MUTABLE between the two reads -- an actor replies during the provider round
    # trip, which is the whole point of projecting a shared log -- so purity of
    # the derivation alone does NOT make the two sides agree. Reading the log
    # live at commit claimed a mid-dispatch arrival as a causal parent of a turn
    # that never rendered it, marking it consumed and losing it from every future
    # fold. Neither side may read the log live.
    #
    # The fold renders as an ordinary `<mailbox>` TEXT block, deliberately NOT a
    # `tool_result`: an actor message is not the answer to a tool_use, so
    # rendering it as one would masquerade in the parent's single within-turn
    # user message and corrupt gate 2.
    class Mailbox < Combinator
      include TailInjection

      TAG = "mailbox"

      # The projection for ONE turn, as a frozen value. The render-side
      # {Mailbox} folds `pending`; the commit records `folded` as the turn's
      # causal_parents. One object, one derivation, so the two sides cannot
      # disagree -- which no pair of separate reads over the mutable log could
      # guarantee.
      class Snapshot
        # The pending :message events for the recipient, in log order.
        attr_reader :pending

        # @param recipient [String, nil] whose messages are pending
        # @param events [Enumerable<Ext::Event>] the log `recipient`'s pending set
        #   is derived from
        # @param pending [Array<Ext::Event>] given whole by an inbox that judges
        #   pending itself ({Live}), in place of the derivation
        def initialize(recipient: nil, events: [], pending: EventLog::Projection.new(events).pending(recipient).to_a)
          @pending = pending.dup.freeze
          freeze
        end

        # The digests the assistant commit stamps as this turn's causal_parents.
        def folded = pending.map(&:digest)

        # The turn's Context with this fold behind its pipeline. Applied after
        # the per-turn source chose that Context, so compaction never sees the
        # fold. Not Ractor-shareable: the lambda closes over a Context that may
        # hold the live `/model` slot, and it lives for 1 turn.
        #
        # @param context [Context]
        # @return [Context]
        def over(context)
          context.with_pipeline(->(workspace) { context.pipeline_for(workspace) >> Mailbox.new(snapshot: self) })
        end
      end

      # {#capture} is the ONE live read of the mutable {Tools::Subagent::Log},
      # at turn start; everything downstream -- the render-side fold and the
      # commit-side causal_parents -- consumes the {Snapshot} it returns.
      class Source
        def initialize(recipient:, log:)
          @recipient = recipient
          @log = log
        end

        # The timeline's turns carry the causal_parents that mark consumption,
        # so the snapshot's pending set already excludes anything an earlier
        # commit consumed -- and a message arriving after this read stays
        # pending for the NEXT turn's capture, never claimed by this one.
        #
        # @param timeline [Ext::Timeline] the head this turn renders from
        # @return [Snapshot]
        def capture(timeline)
          Snapshot.new(recipient: @recipient, events: timeline.to_a + @log.to_a)
        end
      end

      # The Agent's default inbox: nothing folds and every assistant commit
      # records causal_parents [], keeping the default path's turn digest
      # byte-identical to a pre-mailbox turn. One module satisfies both ducks
      # (`capture` answers itself, an empty snapshot whose `over` answers the
      # Context unchanged), so the Agent writes no `if mailbox` guard.
      module Null
        def self.capture(_timeline) = self

        def self.pending = []

        def self.folded = []

        def self.over(context) = context

        def self.post(**) = nil

        def self.pending?(_timeline) = false
      end

      def initialize(snapshot:)
        super()
        @snapshot = snapshot
        freeze
      end

      def call(messages)
        return messages if messages.empty?
        return messages unless MessageEnvelope.wrap(messages.last).user?

        lines = @snapshot.pending.filter_map { |event| line_for(event) }
        return messages if lines.empty?

        append_to_last(messages, [mailbox_block(lines)])
      end

      private

      def mailbox_block(lines)
        { "type" => "text", "text" => "<#{TAG}>\n#{lines.join("\n")}\n</#{TAG}>" }
      end

      # A text-less message contributes nothing rather than a blank line. The
      # named case: a one-shot spawn's :message carries `result`/`final`, not
      # `text` -- its result already rode back as the tool_result, so
      # re-rendering it here would duplicate it. Only actor `note`s fold.
      def line_for(event)
        text = event.body&.fetch("text", nil)
        "#{event.from} | #{text}" unless text.nil?
      end
    end
  end
end
