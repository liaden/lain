# frozen_string_literal: true

require "bigdecimal"

module Lain
  module Telemetry
    module Guards
      # A seam-EV verdict must name a REAL chunk size class it weighed (not just
      # any non-nil string -- an "XL" reaching this record through the calibrated
      # estimate path would otherwise journal silently) and land on one of the
      # two answers the policy reaches. The S/M/L set is {Plan::SIZES}, held
      # verbatim here rather than referenced: this Guard's class body evaluates
      # at telemetry load time, before the plan/ unit loads.
      #
      # BOTH cost figures are required, and this record is where they differ from
      # the sibling {Compaction}'s: a seam decision has no refusal to express.
      # {#net} does `BigDecimal(payback)` unconditionally and {Plan::SeamDecision}
      # only ever quotes both sides, so a nil is a caller bug. It is named here
      # because the shared {Telemetry.fixed_point} is nil-tolerant for
      # {Compaction}'s sake -- without this validation an unquoted side would
      # journal `null` into a money field and only surface later, in a reader.
      class SeamDecision < Guard
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

    # Every seam's full EV accounting (PC-4): the size class weighed (`size`),
    # the turns-remaining estimate it priced payback over (`estimated_turns`)
    # and whether that estimate came from Journal calibration (`calibrated`,
    # false when the annotation default stood in), the span a rewrite would
    # drop (`bytes_removed`) and the shorter prefix it would leave
    # (`bytes_after`, priced by `rewrite_cost`), and BOTH priced sides --
    # `rewrite_cost` (one cache write of that shorter prefix) versus `payback`
    # (resending the dropped span at the provider's per-turn resend rate --
    # its cache read discount where one exists, full input where it does not --
    # over the estimated remaining turns) -- so {Compare} can audit the
    # rewrite-now/defer decision,
    # AND re-derive each cost from the record alone, against what the chunk
    # ACTUALLY consumed. Recording both operands (removed AND after)
    # matches the sibling {Compaction} record, which carries `bytes_before`
    # and `bytes_after` for the same self-contained-audit reason.
    # `calibrated: false` on a mis-sized annotation is what keeps the
    # estimate-vs-actual drift visible rather than silently absorbed.
    #
    # Both figures are the compaction subsystem's canonical-BYTE-length proxy,
    # and they say so because they did not before: the pair was named for tokens
    # beside provider-measured token counts in the same NDJSON stream, which is
    # the confusion UX5 named. Renaming only the {Compaction} half would have
    # relocated it, since this record's own header declares the two a matched
    # pair. WIRE COMPATIBILITY, as for the sibling: old journals are NOT
    # migrated and no shim reads them -- a record written before this rename
    # carries `tokens_removed`/`tokens_after` holding exactly these byte figures
    # under that misleading name.
    #
    # `rewrite_cost`/`payback` are held as fixed-point decimal STRINGS, not
    # `BigDecimal`, for exactly the reason {Compaction}'s `cost_saved`/
    # `cost_spent` are: `Canonical.normalize` has no canonical wire form for
    # `BigDecimal`, and every field must be an immutable, JSON-safe value to
    # keep this record `Ractor.shareable?`. `estimated_turns` is a plain
    # Integer or Float (a calibrated median may be fractional) -- both JSON-safe
    # and already immutable. Both figures format through {Telemetry.fixed_point},
    # the one formatter every priced record quotes through; unlike {Compaction}
    # this record REQUIRES them (see {Guards::SeamDecision}).
    #
    # Emitted by {Plan::SeamDecision#call} -- the same decide-then-journal
    # pairing {Compaction::Scheduler} makes for its own {Compaction} accounting,
    # one seam, one durable verdict.
    SeamDecision = Data.define(:size, :estimated_turns, :calibrated, :bytes_removed, :bytes_after,
                               :rewrite_cost, :payback, :verdict) do
      include Journalable

      def initialize(size:, estimated_turns:, calibrated:, bytes_removed:, bytes_after:,
                     rewrite_cost:, payback:, verdict:)
        size = size.to_s
        verdict = verdict.to_sym
        rewrite_cost = Telemetry.fixed_point(rewrite_cost)
        payback = Telemetry.fixed_point(payback)
        Guards::SeamDecision.check!(size:, verdict:, rewrite_cost:, payback:)

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
