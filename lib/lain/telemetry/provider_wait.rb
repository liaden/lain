# frozen_string_literal: true

module Lain
  module Telemetry
    module Guards
      # A provider-wait record must land on one of the two outcomes a queued
      # caller can have, name the endpoint it queued for, and carry a wait
      # figure exactly when it completed one -- so a refusal can never be
      # written as though it were a wait that finished, which is the very
      # distinction the record exists to make.
      #
      # `resolution_seconds` is guarded hardest, because it is the field the
      # record's honesty rests on. It went unvalidated once, and a nil arrived
      # as `0.0` -- a record claiming the wait was measured EXACTLY, which is
      # the single misreading the field exists to prevent. Zero is refused for
      # that reason and not merely for being falsy.
      class ProviderWait < Guard
        attribute :kind
        attribute :endpoint
        attribute :waited_seconds
        attribute :resolution_seconds
        validates :kind, inclusion: { in: %i[waited refused],
                                      message: "must be one of waited/refused, got %<value>s" }
        validates :endpoint, presence: { message: "must name the resolved endpoint the caller queued for, got nil" }
        validates :waited_seconds, presence: { message: "must name the seconds queued, got nil" },
                                   if: -> { kind == :waited }
        validates :waited_seconds, absence: { message: "must be absent on a refusal -- no wait completed" },
                                   if: -> { kind == :refused }
        validates :resolution_seconds,
                  presence: { message: "must name the granularity the wait was read at, got nil" }
        validates :resolution_seconds,
                  numericality: { greater_than: 0,
                                  message: "must be positive -- zero would claim the wait is exact" },
                  allow_nil: true
      end
    end

    # One caller's encounter with a saturated provider: `kind` names the
    # OUTCOME -- `:waited` for a caller that queued and was then admitted,
    # `:refused` for one that exhausted {Provider::Admission#deadline} and was
    # told the endpoint was busy. There is deliberately no third kind for the
    # ordinary case: a caller admitted on its first attempt emits NOTHING, so
    # the presence of a record is itself the signal and an unloaded session
    # journals nothing at all. That is what keeps this off the "thousands of
    # records nobody reads" path without anybody picking a threshold.
    #
    # `endpoint` is the RESOLVED endpoint, not the flag that produced it, for
    # {Provider::Admission}'s own reason -- one `--api-base` serves every tier,
    # so only the resolved string tells a hosted turn from a local one. It is
    # also the CANONICAL spelling of that server rather than the caller's, since
    # {Provider::Admission.for} canonicalises before it builds and `#endpoint`
    # reports what the gate was keyed on: a caller that said
    # `http://127.0.0.1:11434` journals `http://localhost:11434`. That is the
    # property this field needs, not an accident of it -- `endpoint` is what a
    # report sums a server's waits over, and two spellings of one ollama must
    # not become two rows. It matches the endpoint {Provider::Admission::Busy}
    # names, so a refusal message and a record agree.
    #
    # == `waited_seconds` is a reading, not a measurement
    #
    # Admission learns a slot is free only when a waiter next wakes, so the
    # figure is quantised to the poll interval: measured 0.0501s reported
    # against a ~0.040s true queue. `resolution_seconds` travels beside it and
    # names that granularity, so a reader can see that 0.05 against a 0.05
    # resolution means "queued at all" rather than "queued for 50ms" -- the
    # record refuses to present a quantised reading as a measurement by making
    # its resolution unskippable, and its {Guards::ProviderWait} carrier is what
    # makes that a guarantee rather than a convention. For the same reason the
    # wait is rounded to milliseconds: digits below the resolution are noise
    # dressed as precision, and an NDJSON line a human scans is worse for
    # carrying them.
    #
    # The DISTINCTION is exact even though the magnitude is not -- a caller that
    # took a slot on its first attempt never reads the clock at all
    # ({Provider::Admission::NO_WAIT}) -- which is what lets the emitter decide
    # "queued or not" without inventing a threshold.
    #
    # `in_flight` is how many callers were inside the endpoint when the record
    # was cut, so a report can tell one queued caller behind a single holder
    # from a genuinely saturated server. Width is deliberately NOT carried: it
    # is constant per endpoint for a process's life, and
    # {Provider::Admission::Null#width} is `Float::INFINITY`, which is not JSON.
    #
    # Emitted by {Provider::Admission::Journal}, the Journal-duck decorator that
    # wraps ANY admission's `enter`/`try_enter` -- never by an admission itself,
    # which stays journal-ignorant, exactly as {Isolation::Journal} keeps every
    # isolation backend.
    ProviderWait = Data.define(:kind, :endpoint, :waited_seconds, :resolution_seconds, :in_flight) do
      include Journalable

      def initialize(kind:, endpoint:, resolution_seconds:, in_flight: 0, waited_seconds: nil)
        kind = kind.to_sym
        Guards::ProviderWait.check!(kind:, endpoint:, waited_seconds:, resolution_seconds:)

        super(
          kind:,
          endpoint: endpoint.to_s.dup.freeze,
          # Qualified, not bare: a `def` inside a `Data.define` block keeps the
          # ENCLOSING module's cref, so an unqualified constant would be looked
          # up in Telemetry and raise NameError.
          waited_seconds: waited_seconds&.to_f&.round(ProviderWait::WAIT_PRECISION),
          resolution_seconds: resolution_seconds.to_f,
          in_flight: in_flight.to_i
        )
      end
    end

    class ProviderWait
      # Decimal places kept on {#waited_seconds}: milliseconds, already finer
      # than any poll interval this gate is likely to run at, and the reopen is
      # where it can live at all -- a constant assigned inside the `Data.define`
      # block above would land in {Telemetry}, not on this class.
      WAIT_PRECISION = 3
    end
  end
end
