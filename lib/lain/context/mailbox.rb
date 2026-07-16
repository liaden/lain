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
    # mutable queue: "pending" is DERIVED, not marked (decision 2 / panel B2) --
    # a :message is pending until a committed :turn names it a causal parent, so
    # this combinator holds NO fold-state of its own, two renders over the same
    # snapshot fold byte-identically, and a dispatch that never commits re-folds
    # everything. The assistant commit is what advances the fold, by recording
    # the folded digests as its turn's causal_parents.
    #
    # THE PRECONDITION THAT MAKES RENDER AND COMMIT AGREE: both fold the SAME
    # frozen per-turn {Snapshot}, captured once by the Agent at turn start
    # ({Source#capture}). The shared log is MUTABLE between the two reads -- an
    # actor replies during the provider round trip, the OM-3 point -- so purity
    # of the derivation alone does NOT make the two sides agree; reading the log
    # live at commit claimed a mid-dispatch arrival as a causal parent of a turn
    # that never rendered it, marking it consumed and losing it from every
    # future fold (panel probe #2). Neither side may read the log live;
    # agreement is a property of construction, one pure function over one
    # immutable input.
    #
    # The fold is rendered as an ordinary `<mailbox>` TEXT block, deliberately
    # NOT a `tool_result`: an actor message is not the answer to a tool_use, so
    # rendering it as one would masquerade in the parent's single within-turn
    # user message and corrupt gate 2. A tagged text block at the tail is exactly
    # what {Recall} does, and it is invisible to the tool_result-shaped machinery.
    class Mailbox < Combinator
      include TailInjection

      # The projection for ONE turn, as a frozen value: the pending set derived
      # once, over events fixed at construction. The render-side {Mailbox}
      # combinator folds `pending`; the commit records `folded` as the turn's
      # causal_parents. One object, one derivation, so the two sides cannot
      # disagree -- which no pair of separate reads over the mutable log could
      # guarantee.
      class Snapshot
        # The pending :message events for the recipient, in log order.
        attr_reader :pending

        def initialize(recipient:, events:)
          @pending = Event::Projection.new(events).pending(recipient).to_a.freeze
          freeze
        end

        # The digests the assistant commit stamps as this turn's causal_parents.
        def folded = pending.map(&:digest)
      end

      # The Agent's read-side of its inbox: a recipient over the append-only
      # message {Tools::Subagent::Log}. {#capture} is the ONE live read of that
      # mutable log, at turn start; everything downstream -- the render-side
      # fold and the commit-side causal_parents -- consumes the {Snapshot} it
      # returns.
      class Source
        def initialize(recipient:, log:)
          @recipient = recipient
          @log = log
        end

        # The per-turn snapshot over (timeline-at-turn-start, log-as-of-now).
        # The timeline's turns carry the causal_parents that mark consumption,
        # so the snapshot's pending set already excludes anything an earlier
        # commit consumed -- and a message arriving after this read stays
        # pending for the NEXT turn's capture, never claimed by this one.
        #
        # @param timeline [Timeline] the head this turn renders from
        # @return [Snapshot]
        def capture(timeline)
          Snapshot.new(recipient: @recipient, events: timeline.to_a + @log.to_a)
        end
      end

      # The Agent's default inbox: a plain Agent has nothing addressed to it, so
      # nothing folds and every assistant commit records causal_parents [] --
      # keeping the default path's turn digest byte-identical to a pre-mailbox
      # turn. One module satisfies both ducks (`capture` answers itself, an
      # empty snapshot), so the Agent writes no `if mailbox` guard. A module,
      # like {Tools::Subagent::Log::Null}: there is no per-instance state.
      module Null
        def self.capture(_timeline) = self

        def self.pending = []

        def self.folded = []
      end

      def initialize(snapshot:)
        super()
        @snapshot = snapshot
        freeze
      end

      def call(messages)
        return messages if messages.empty?
        return messages unless MessageEnvelope.wrap(messages.last).user?

        pending = @snapshot.pending
        return messages if pending.empty?

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
