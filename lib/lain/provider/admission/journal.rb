# frozen_string_literal: true

module Lain
  class Provider
    class Admission
      # A Journal-duck decorator over any {Admission}: {Isolation::Journal}'s
      # shape, applied to the capacity seam. `enter` and `try_enter` forward to
      # the wrapped admission untouched, and a caller that actually QUEUED
      # additionally leaves a {Telemetry::ProviderWait} record -- so the
      # admission object never learns a journal exists, and {Null} and a real
      # {Admission} are wrapped by the same decorator without either knowing.
      #
      # == Only a caller that queued is journaled, and no threshold was invented
      #
      # {Admission#enter} yields the seconds queued and returns {NO_WAIT}
      # exactly when the caller took a slot on its first attempt, before the
      # clock was ever read. That distinction is EXACT, so "did this caller
      # queue?" is answered by the gate rather than by a cutoff chosen here --
      # which matters, because emitting per admission would put a record on
      # every turn of an ordinary session and bury the ones that mean something.
      # An idle endpoint journals nothing at all.
      #
      # The decorator does not measure time. It has no clock and wants none: the
      # wait is the figure `enter` already yields, and re-timing it here would
      # both duplicate the reading and add a second site naming the monotonic
      # clock, which `run_clock_spec.rb` pins to {RunClock::MONOTONIC} alone.
      #
      # The resolution a wait is reported at is READ OFF the wrapped gate
      # ({Admission#poll_interval}), never defaulted. It was a defaulted keyword
      # once, which meant wrapping a gate built with a non-default poll interval
      # described it with a figure it does not run at -- and a default that can
      # be wrong is worse than a required argument, worse again than simply
      # asking the subject. That reader is the one attribute this decorator
      # added to {Admission}'s surface, and it is a reader, never a writer.
      #
      # == What is NOT journaled
      #
      # {#try_enter} forwards untouched. It never queues by construction (the
      # eager oracle's contract is that the producing turn does not wait on it),
      # so a busy endpoint there is a SKIP, and a skip is not a wait: filing it
      # under `provider_wait` would put a record on every turn whose eager
      # summary was declined and describe it with the wrong noun.
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
        # this caller. A {Busy} refusal is journaled and re-raised unchanged --
        # the decorator observes, and never converts a refusal into a return
        # value.
        #
        # `admitted` is what makes that honest, and it is not defensive
        # bookkeeping. {Busy} is NOT this gate's private exception: a block
        # doing work behind a second admission raises the same class, so a bare
        # `rescue Busy` reads "the work I was let in to do was refused" as "the
        # gate refused me" -- inventing a refusal for an admitted caller on an
        # idle gate, and emitting BOTH a wait and a refusal for one call when
        # the caller had queued first. The flag is set before the emit, because
        # the gate admitted this caller the moment the block began.
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
