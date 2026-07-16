# frozen_string_literal: true

module Lain
  class Context
    # Folds a recipient's pending actor messages into the message tail: the
    # parent's read-side of the orchestration message-DAG (OM-3). Like {Recall},
    # it is NOT part of the default pipeline but an opt-in stage a custom
    # pipeline composes AFTER CacheBreakpoints -- so the folded messages ride the
    # same UNCACHED SUFFIX Reminder's and Recall's tails do, landing strictly
    # after the last neutral marker. Today's exchange therefore never rewrites
    # yesterday's cached prefix, which is the whole reason a long-lived actor's
    # continuous event stream can be projected into the parent's prompt without
    # breaking the turn-boundary cache invariant.
    #
    # The messages are a pure PROJECTION over the shared event log, never a
    # mutable queue: an injected {Event::Projection}, folded to `recipient`, at
    # the parent's turn start. The default policy is "fold all pending", where
    # PENDING means since the last fold (T23 panel #3): a {Cursor} high-water
    # mark over the recipient's mailbox sequence keeps an already-folded
    # message from re-rendering every turn -- without it nothing would ever
    # stop being "pending" and the re-prefill would grow without bound. The
    # cursor is the parent's fold-policy state (the same kind of injected
    # run-state as Session), NOT a mutation of the mailbox: the log underneath
    # is append-only and every folded event stays queryable in the Store.
    #
    # The fold is rendered as an ordinary `<mailbox>` TEXT block, deliberately
    # NOT a `tool_result`: an actor message is not the answer to a tool_use, so
    # rendering it as one would masquerade in the parent's single within-turn
    # user message and corrupt gate 2. A tagged text block at the tail is exactly
    # what {Recall} does, and it is invisible to the tool_result-shaped machinery.
    class Mailbox < Combinator
      include TailInjection

      # How many of the recipient's mailbox messages have been folded. A count
      # over the recipient-filtered sequence is a stable mark because the log
      # is append-only -- earlier entries never move or vanish. Injected and
      # shared across the per-turn Mailbox rebuilds (a grown log means a new
      # Projection, so the combinator is reconstructed each turn; the cursor is
      # what persists), and advanced only when a fold actually renders, so a
      # guard-blocked turn skips nothing.
      class Cursor
        attr_reader :position

        def initialize
          @position = 0
        end

        def advance(count)
          @position += count
          self
        end
      end

      def initialize(projection:, recipient:, cursor: Cursor.new)
        super()
        @projection = projection
        @recipient = recipient
        @cursor = cursor
        freeze
      end

      def call(messages)
        return messages if messages.empty?
        return messages unless MessageEnvelope.wrap(messages.last).user?

        pending = @projection.mailbox(@recipient).to_a.drop(@cursor.position)
        return messages if pending.empty?

        @cursor.advance(pending.size)
        append_to_last(messages, [mailbox_block(pending)])
      end

      private

      def mailbox_block(pending)
        lines = pending.filter_map { |event| line_for(event) }
        { "type" => "text", "text" => "<mailbox>\n#{lines.join("\n")}\n</mailbox>" }
      end

      # `from | text` for a message that carries renderable text; a detached or
      # text-less message contributes nothing rather than a blank line. The
      # named text-less case: a one-shot spawn's :message ({Tools::Subagent::
      # Lineage#message}) carries `result`/`final`, not `text` -- its result
      # already rode back as the tool_result, so re-rendering it here would
      # duplicate it. Only actor `note`s (which carry `text`) fold.
      def line_for(event)
        text = event.body&.fetch("text", nil)
        "#{event.from} | #{text}" unless text.nil?
      end
    end
  end
end
