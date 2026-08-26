# frozen_string_literal: true

require "bigdecimal"

module Lain
  module Telemetry
    module Carriers
      # The S/M/L set is {Plan::SIZES}, held VERBATIM rather than referenced:
      # this carrier's class body evaluates at telemetry load time, before the
      # plan/ unit loads.
      #
      # BOTH cost figures are required, which is where this differs from the
      # sibling {Compaction}: a seam decision has no refusal to express, and
      # {#net} does `BigDecimal(payback)` unconditionally. The shared
      # {Telemetry.fixed_point} is nil-tolerant for {Compaction}'s sake, so
      # without this an unquoted side would journal `null` into a money field
      # and surface only later, in a reader.
      class SeamDecision < Declarative::Carrier
        attribute :size
        attribute :verdict
        attribute :rewrite_cost
        attribute :payback
        validates :size, inclusion: { in: %w[S M L], message: "must be one of S/M/L, got %<value>s" }
        validates :verdict, inclusion: { in: %i[rewrite_now defer],
                                         message: "must be rewrite_now or defer, got %<value>s" }
        validates :rewrite_cost, presence: { message: "must quote what the rewrite costs, got nil" }
        validates :payback, presence: { message: "must quote what deferring costs, got nil" }
      end
    end

    # Every seam's full EV accounting: `rewrite_cost` is one cache write of the
    # shorter prefix a rewrite would leave, `payback` is resending the dropped
    # span at the provider's per-turn resend rate over the estimated remaining
    # turns. BOTH operands are recorded, not just the verdict, so {Compare} can
    # re-derive each cost from the record alone and check it against what the
    # chunk actually consumed. `calibrated: false` on a mis-sized annotation is
    # what keeps estimate-vs-actual drift visible rather than silently absorbed.
    #
    # `bytes_removed`/`bytes_after` are the compaction subsystem's
    # canonical-BYTE-length proxy, and they SAY so because the pair was once
    # named for tokens beside provider-measured token counts in the same NDJSON
    # stream. WIRE COMPATIBILITY, as for the sibling {Compaction}: old journals
    # are NOT migrated and no shim reads them -- a record written before that
    # rename carries these exact figures under `tokens_removed`/`tokens_after`.
    #
    # `rewrite_cost`/`payback` are held as fixed-point decimal STRINGS for
    # exactly {Compaction}'s reason: `Canonical.normalize` has no canonical wire
    # form for `BigDecimal`, and every field must be immutable and JSON-safe to
    # keep the record `Ractor.shareable?`. `estimated_turns` may be fractional,
    # since a calibrated median is.
    SeamDecision = Data.define(:size, :estimated_turns, :calibrated, :bytes_removed, :bytes_after,
                               :rewrite_cost, :payback, :verdict) do
      include Journalable

      def initialize(size:, estimated_turns:, calibrated:, bytes_removed:, bytes_after:,
                     rewrite_cost:, payback:, verdict:)
        size = size.to_s
        verdict = verdict.to_sym
        rewrite_cost = Telemetry.fixed_point(rewrite_cost)
        payback = Telemetry.fixed_point(payback)
        Carriers::SeamDecision.check!(size:, verdict:, rewrite_cost:, payback:)

        super(
          size: -size, estimated_turns:, calibrated: calibrated ? true : false,
          bytes_removed: Integer(bytes_removed), bytes_after: Integer(bytes_after),
          rewrite_cost:, payback:, verdict:
        )
      end

      # @return [Boolean] whether the decision rewrites the seam now.
      def rewrite? = verdict == :rewrite_now

      # The EV margin {Compare} reads: positive means the rewrite pays for
      # itself over the estimated remaining turns, negative means deferring is
      # cheaper. Mirrors {Compaction#cost_delta}.
      #
      # @return [BigDecimal]
      def net
        BigDecimal(payback) - BigDecimal(rewrite_cost)
      end
    end
  end
end
