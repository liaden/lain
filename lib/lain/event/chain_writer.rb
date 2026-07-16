# frozen_string_literal: true

module Lain
  class Event
    # The one home for message-writing and correlation. Before this, both the
    # `head && (head.correlation || head_digest)` identity derivation and the
    # payload-then-envelope write lived as three separate copies: Timeline's
    # `next_correlation`, {Tools::Subagent::Lineage}'s `put`/`identity`, and
    # {Tools::AskHuman}'s `write_message`/`identity`. All three now delegate
    # here, and the digests they produce are unchanged -- this is an
    # extraction, not a new derivation.
    #
    # Every :message/:spawn event a caller writes passes through {#put}, which
    # makes it the one funnel {#observer} sees -- the seam a future session
    # scribe (T13) folds, since causal edges point BACKWARD (a message names
    # what it answers, never the reverse) and the shared Store has no
    # enumerator of its own to walk forward from.
    class ChainWriter
      # Swallows every write. Satisfies the observer duck (`#call`) but sends
      # events nowhere -- {Sink::Null}'s idiom, so a caller with nothing
      # watching never writes an `if observer` guard.
      class Null
        # @return [self]
        def call(_event)
          self
        end
      end

      # TL-2 (pinned): a chain is named by its root event's digest, no
      # separate id machinery. The root cannot contain its own address, so it
      # carries no correlation and falls back to its own digest; every
      # descendant already carries the root digest, inherited unchanged. The
      # `head &&` guard is what makes this total over the empty chain (`head`
      # nil) without a separate `empty?` check.
      #
      # @param timeline [Timeline]
      # @return [String, nil]
      def self.correlation_of(timeline)
        head = timeline.head
        head && (head.correlation || timeline.head_digest)
      end

      # @param observer [#call] invoked with every event {#put} writes, once
      #   each, in write order. Never consulted for identity or digest math --
      #   it observes, it never participates.
      def initialize(observer: Null.new)
        @observer = observer
      end

      # Writes one :message/:spawn event into `parent`'s shared Store: a
      # kind-tagged {Payload} out of line, then the envelope that addresses it
      # by digest, correlated to `parent`'s chain identity. `payload_digest`
      # is a Store edge (referential integrity), so the payload must land
      # first or the envelope's own put would dangle -- the same discipline
      # {Timeline#commit} follows for :turn events.
      #
      # A raising observer raises OUT of this method, deliberately: the write
      # has already landed (payload and envelope are durably in the Store
      # before the observer runs), so a raise means the OBSERVATION failed --
      # e.g. the session record could not be written -- and swallowing that
      # would be silent record loss, the failure class this seam exists to
      # close. Callers may re-put idempotently: content addressing makes the
      # retry a no-op on the Store side.
      #
      # @return [Event] the event just written
      def put(parent, kind:, from:, to:, causal_parents:, body:)
        payload = Payload.new(kind:, body:)
        event = Event.new(kind:, from:, to:, causal_parents:,
                          correlation: self.class.correlation_of(parent),
                          payload_digest: payload.digest, body: payload.body)
        parent.store.put(payload)
        parent.store.put(event)
        @observer.call(event)
        event
      end
    end
  end
end
