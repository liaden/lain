# frozen_string_literal: true

module Lain
  class Provider
    class Admission
      # A Journal-duck decorator over any {Admission}, so the admission object
      # never learns a journal exists and {Null} and a real gate are wrapped
      # alike.
      #
      # == Only a caller that queued is journaled, and no threshold was invented
      #
      # {Admission#enter} returns {NO_WAIT} exactly when the caller took a slot
      # on its first attempt, before the clock was ever read. That distinction
      # is EXACT, so "did this caller queue?" is answered by the gate rather
      # than by a cutoff chosen here -- emitting per admission would put a
      # record on every turn of an ordinary session and bury the ones that mean
      # something.
      #
      # The decorator does not measure time and wants no clock: the wait is the
      # figure `enter` already yields, and re-timing it would both duplicate the
      # reading and add a second site naming the monotonic clock, which spec
      # pins to {RunClock::MONOTONIC} alone.
      #
      # The resolution is READ OFF the wrapped gate, never defaulted. As a
      # defaulted keyword it described a gate built with a non-default poll
      # interval by a figure it does not run at.
      #
      # {#try_enter} forwards untouched: it never queues by construction, so a
      # busy endpoint there is a SKIP, and filing a skip under `provider_wait`
      # would describe it with the wrong noun.
      #
      # Wrap ONCE, nearest the admission: a provider handed an already-wrapped
      # admission must not decorate again, or every wait double-journals.
      class Journal
        # @param admission [#enter] the real gate every call forwards to
        # @param journal [#<<] where {Telemetry::ProviderWait} records land
        def initialize(admission:, journal:)
          @admission = admission
          @journal = journal
        end

        # @return [Float] the granularity a reported wait is quantised to,
        #   which is the wrapped gate's own poll interval
        def resolution_seconds = @admission.poll_interval
        # The CANONICAL spelling when the gate came from {Admission.for}, which
        # keys on {Admission.canonical} -- so records for one server aggregate
        # under one name however each caller spelled it.
        # @return [String] the resolved endpoint the wrapped gate governs
        def endpoint = @admission.endpoint
        # @return [Integer, Float] callers the wrapped gate allows inside at once
        def width = @admission.width
        # @return [Float] the wrapped gate's acquire deadline, in seconds
        def deadline = @admission.deadline
        # @return [Integer] callers inside right now
        def in_flight = @admission.in_flight

        # Enter, journaling the wait if there was one.
        #
        # The record is cut INSIDE the admitted block, so `in_flight` counts
        # this caller. A {Busy} refusal is journaled and re-raised unchanged.
        #
        # `admitted` is not defensive bookkeeping: {Busy} is NOT this gate's
        # private exception, so a block doing work behind a SECOND admission
        # raises the same class, and a bare `rescue Busy` would read "the work I
        # was let in to do was refused" as "the gate refused me" -- inventing a
        # refusal on an idle gate, and emitting both a wait and a refusal for
        # one call. The flag is set before the emit, because the gate admitted
        # this caller the moment the block began.
        #
        # @yieldparam waited [Float] seconds spent queued; {NO_WAIT} if it never was
        # @return the block's value
        # @raise [Busy] whatever the wrapped admission raised
        def enter
          admitted = false
          @admission.enter do |waited|
            admitted = true
            emit(kind: :waited, waited_seconds: waited) unless waited == NO_WAIT
            yield waited
          end
        rescue Busy
          emit(kind: :refused) unless admitted
          raise
        end

        # Forwarded untouched: a caller that declines to queue has no wait to
        # report, and its refusal is a skip rather than a saturation reading.
        # @return the block's value, or {REFUSED}
        def try_enter(&block) = @admission.try_enter(&block)

        private

        def emit(kind:, waited_seconds: nil)
          @journal << Telemetry::ProviderWait.new(
            kind:, waited_seconds:, endpoint: @admission.endpoint,
            resolution_seconds:, in_flight: @admission.in_flight
          )
        end
      end
    end
  end
end
