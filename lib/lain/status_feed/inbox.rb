# frozen_string_literal: true

module Lain
  class StatusFeed
    # {Event::Projection#pending}({Tools::AskHuman::HUMAN}) mirrored
    # incrementally: what is still addressed to the human and not yet named a
    # causal parent by a committed turn. Held as two standing sets rather than
    # re-run as a fresh fold on every event -- an O(n) refold per event (O(n^2)
    # over a session) measured at 8.5s for an 8k-event history.
    #
    # ⚠️ THE ARRIVAL SIDE IS O(1); {#committed} IS NOT. Resolving a head's chain
    # is O(chain), paid once per committed turn: 0.15ms at chain 100, 0.33ms at
    # 500, 0.99ms at 2000. That is per COMMIT, not per event, and nothing beside
    # a model round trip -- but it does grow with the session, and a walk that
    # stopped at the first already-{#consumed} digest would answer identically.
    # It is not written that way ON PURPOSE:
    # {Frontend::Neovim::InboxView#consume} walks the whole chain, and a second,
    # cleverer answer is how the parity spec between the two starts passing
    # while the two surfaces disagree. Change both or neither.
    #
    # ⚠️ CONSUMPTION COUNTS COMMITTED-TURN EDGES ONLY. A {Tools::AskHuman#reply}
    # answer is a `:message`, and Projection's own doc is explicit that a
    # `:message`'s `causal_parents` is lineage, not consumption -- so the human
    # answering does NOT retire their own question; the assistant commit that
    # folds it in does. {Frontend::Neovim::InboxView} is held to the same rule
    # by a parity spec, and the two agreeing is what makes the HUD's number and
    # the `lain://inbox` buffer the same claim.
    #
    # THE COMMITTED TURN ARRIVES AS A {Telemetry::TurnUsage}, not as a `:turn`
    # Event, and that is why {#committed} exists beside {#consumed}:
    # `SessionRecord::Scribe#catch_up` appends committed turns straight to the
    # session JOURNAL, never to the tee {StatusFeed} rides -- turn records are
    # record data, not live-view telemetry -- so a count that waited for the
    # Event only ever climbed (2 published against a `lain://inbox` drawing one,
    # measured live). The usage record names the committed head, so the cited
    # digests are read off that head's chain in the run's {Store}.
    #
    # A SPAWNED chain's turn is a third carrier and it names its edges directly:
    # {StatusFeed} hands them to {#retire} off a {Telemetry::QuestionsConsumed},
    # whose own doc holds why the turn itself cannot be routed. It exists because
    # a question a subagent RELAYED -- re-addressed to the human under its
    # parent's correlation -- can be consumed only by the child's own turn, so no
    # other carrier could ever retire it.
    #
    # The same record has a second producer: a settled {Approval::Gate} writes
    # one with `turn: nil` naming the question it asked, which no committed turn
    # ever cites because a gate is no tool call. It arrives on the same carrier
    # and needs nothing new here -- {#retire} reads only the digests.
    #
    # All three write the same standing {#consumed} set, so a replay delivering
    # more than one retires once.
    class Inbox
      # @param store [Store] where a committed head's chain is resolved. Defaulted
      #   to an EMPTY one rather than required: `ChatLaunch` builds the feed that
      #   owns this object before `Wiring` exists at all. An empty Store is a real
      #   object that resolves no head, so an unbound inbox counts arrivals and
      #   retires nothing -- no caller asks whether it has a store yet.
      def initialize(store: Store.new)
        @store = store
        # Consumption is a STANDING set rather than "remove from whatever is
        # pending right now" because a replayed log can deliver the turn before
        # the question it consumes. `@pending` is insertion-ordered.
        @consumed = Set.new
        @pending = {}
      end

      # @param store [Store] the run's object database, once there is one
      # @return [void]
      def bind_store(store)
        @store = store
        nil
      end

      # Named for WHICH set it counts: this object holds two, so a bare `#size`
      # would name neither.
      #
      # @return [Integer] what the HUD publishes as `inbox_count`
      def pending_size = @pending.size

      # A `:message` addressed to the human joins the pending set unless a
      # committed turn already cited it -- the out-of-order case above.
      #
      # @param event [#to, #digest] the arriving message
      # @return [void]
      def arrived(event)
        @pending[event.digest] = true if event.to == INBOX_RECIPIENT && !@consumed.include?(event.digest)
        nil
      end

      # A command, and named as one: `#consumed` read as a query for the very set
      # it writes, which is the one reading it must not have.
      #
      # @param digests [Enumerable<String>] a committed turn's `causal_parents`,
      #   as a replayed `:turn` Event carries them
      # @return [void]
      def retire(digests)
        digests.each do |digest|
          @consumed << digest
          @pending.delete(digest)
        end
        nil
      end

      # The live chat's carrier: a committed head, whose chain names the edges.
      #
      # @param head_digest [String] the digest a {Telemetry::TurnUsage} names
      # @return [void]
      def committed(head_digest) = retire(cited_by_chain(head_digest))

      private

      # {Frontend::Neovim::InboxView#consume}'s expression, and its never-raise
      # rule with it: {StatusFeed} rides the {CLI::JournalTee}, which re-raises
      # a sink's failure into the agent loop, so a head this object cannot walk
      # is a MISS, never a raise that costs the turn over a status line.
      #
      # ⚠️ THE RESCUE IS AS WIDE AS THAT PROMISE, deliberately, and it was not.
      # `MissingObject` alone covers only the head the store does not HOLD (no
      # Store bound yet, a replay from the middle of a session). A head it holds
      # that names something other than a turn walks straight into
      # `NoMethodError: undefined method 'parent' for an instance of
      # Event::Payload` -- every message ever written puts such a digest in the
      # same store -- and that one went out through the tee. So any StandardError
      # here reads as "this head names nothing to retire": a status surface
      # answering "nothing pending" about a store it cannot make sense of beats
      # costing a turn to draw a number, and it is why this class derives the
      # payment BEFORE calling the walk ({StatusFeed#observe_commit}).
      def cited_by_chain(head_digest)
        Timeline.new(head_digest:, store: @store).to_a.flat_map(&:causal_parents)
      rescue StandardError
        []
      end
    end
  end
end
