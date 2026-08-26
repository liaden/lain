# frozen_string_literal: true

module Lain
  class StatusFeed
    # {Event::Projection#pending}({Tools::AskHuman::HUMAN}) mirrored
    # incrementally: what is still addressed to the human and not yet named a
    # causal parent by a committed turn. The projection's exact semantics, held
    # as two standing sets rather than re-run as a fresh fold on every event,
    # which was an O(n) refold per event (O(n^2) over a session) that a review
    # pass measured at 8.5s for an 8k-event history.
    #
    # ⚠️ THE ARRIVAL SIDE IS O(1); {#committed} IS NOT, and the boast above does
    # not cover it. Resolving a head's chain is O(chain), paid once per
    # committed turn: measured 0.15ms at chain 100, 0.33ms at 500, 0.99ms at
    # 2000, and it is essentially the whole cost of this object (an unbound
    # inbox, whose walk is a miss, runs flat). That is nothing beside a model
    # round trip and it is not the refold this class was rewritten to remove --
    # it is per COMMIT, not per event -- but it does grow with the session, and
    # a walk that stopped at the first already-{#consumed} digest would answer
    # identically. It is not written that way ON PURPOSE:
    # {Frontend::Neovim::InboxView#consume} walks the whole chain, and a second,
    # cleverer answer is how the parity spec between the two starts passing
    # while the two surfaces disagree. Change both or neither.
    #
    # Extracted from {StatusFeed} for {JournaledUsage}'s reason, which was
    # {ModeState}'s and {Publication}'s before it: the cop naming that class's
    # line budget was naming a missing object. Counting an inbox is not deriving
    # a status struct -- and this one owns a collaborator none of the other
    # twelve fields has any use for, which is the {Store} below.
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
    # session JOURNAL, never to the tee {StatusFeed} rides ("turn records never
    # route -- they are record data, not live-view telemetry"), so a count that
    # waited for the Event only ever climbed (F76: 2 published against a
    # `lain://inbox` drawing one, measured live 2026-08-25). The usage record
    # names the committed head, so the cited digests are read off that head's
    # chain in the run's {Store} -- {Frontend::Neovim::InboxView#consume}'s
    # answer, ported rather than re-invented, because a second answer is how a
    # parity spec goes green while the two surfaces disagree. Both carriers
    # write the same standing {#consumed} set, so a replay delivering both
    # retires once.
    class Inbox
      # @param store [Store] where a committed head's chain is resolved.
      #   Defaulted to an EMPTY one rather than required: `ChatLaunch` builds
      #   the feed that owns this object before `Wiring` exists at all, and the
      #   session's Store does not exist until `Wiring#run` has built the Agent.
      #   An empty Store is a real object that resolves no head, so an unbound
      #   inbox counts arrivals and retires nothing -- no caller asks whether it
      #   has a store yet. See {#bind_store}.
      def initialize(store: Store.new)
        @store = store
        # `@consumed` is every digest a committed turn has ever cited; `@pending`
        # is the still-unconsumed questions, insertion-ordered. Consumption is a
        # STANDING set rather than "remove from whatever is pending right now"
        # because a replayed log can deliver the turn before the question it
        # consumes -- see #arrived.
        @consumed = Set.new
        @pending = {}
      end

      # @param store [Store] the run's object database, once there is one
      # @return [void]
      def bind_store(store)
        @store = store
        nil
      end

      # Named for WHICH set it counts: this object holds two, and `#size` on an
      # object with a `@consumed` set beside a `@pending` one names neither.
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
      # same store -- and that one went out through the tee. The narrower rescue
      # was survivable only while {Frontend::Neovim::InboxView} was the only
      # walker, because nvim's drain is not the agent's thread; this object put
      # the same walk on the HEADLESS path, where it is.
      #
      # So: any StandardError here reads as "this head names nothing to retire".
      # A status surface answering "nothing pending" about a store it cannot
      # make sense of is the correct failure -- the alternative is costing a
      # turn to draw a number -- and it is why this class derives the payment
      # BEFORE calling the walk ({StatusFeed#observe_commit}).
      def cited_by_chain(head_digest)
        Timeline.new(head_digest:, store: @store).to_a.flat_map(&:causal_parents)
      rescue StandardError
        []
      end
    end
  end
end
