# frozen_string_literal: true

require "bigdecimal"

module Lain
  module Plan
    # The seam expected-value decision. At each plan seam the linear shape asks:
    # rewrite the prefix NOW (pay one cache write of the shorter prefix), or
    # DEFER to the next seam (keep resending the chunk's tokens as warm cache
    # reads)? This weighs the one-off rewrite cost against the payback of never
    # resending those tokens again over the turns the chunk is estimated to run.
    #
    # It follows {Compaction::Scheduler}'s template -- a frozen policy whose
    # `#call` is a pure function of its arguments, journaling its full accounting
    # as it commits -- but the profile and prices arrive PER SEAM (a sweep varies
    # them across arms) while the arm's `model` is fixed at construction.
    #
    # Both sides are priced through the provider's real {CacheProfile} --
    # `write_multiplier` for the rewrite, `read_multiplier` for the resend --
    # times the model's plain input rate from the {PriceBook}, rather than the
    # PriceBook's own cache_creation/cache_read rows: the profile is the
    # first-class home for a provider's cache premium, with no second constant to
    # drift (a Guard-spec pins the two encodings equal for the shipped models).
    #
    # Under a NO_CACHING provider (both multipliers 1.0) a large chunk still
    # answers `rewrite_now`, and that is HONEST EV, not a degenerate case:
    # without a cache there is nothing to protect, but compaction still shortens
    # every future turn's FULL-PRICE input resend. The only path that defers
    # regardless is an UNPRICED arm (`model: nil`), where both sides are zero.
    #
    # BOTH operands are the compaction subsystem's canonical-BYTE proxy and both
    # rates are per TOKEN, so each side crosses through {Lain::ProxyBytes#to_tokens}
    # first -- the one divisor, shared with {Compaction::Scheduler}. The divisor
    # cancels in `payback > rewrite_cost`, so it moves the journaled dollars and
    # never the verdict; a spec re-derives every verdict from the unconverted
    # arithmetic to hold that.
    class SeamDecision
      # The annotation-tier turn estimate per S/M/L class -- the fallback used
      # when no Journal calibration is supplied yet (`median_turns` returns
      # nil until a class has closed chunks). Deliberately coarse and
      # overridable-by-data: calibration replaces these with measured medians,
      # and the drift between an annotation and its measurement is itself the
      # journaled signal these records report.
      ANNOTATION_TURNS = { "S" => 2, "M" => 5, "L" => 13 }.freeze

      # @param model [String, Symbol, nil] the arm's model, priced through
      #   `prices`. nil is a legitimate unpriced configuration (the
      #   {Compaction::Scheduler} precedent): both sides price at zero, so the
      #   decision defers while still recording the turn estimate.
      # @param journal [#<<] where every decision lands; the Null channel by
      #   default so no caller guards `if journal`.
      def initialize(model: nil, journal: Channel::Null::INSTANCE)
        @model = model&.to_s
        @journal = journal
        freeze
      end

      # Weigh one seam and journal the verdict.
      #
      # @param chunk [#size, #bytes_before, #bytes_after] the runtime-measured
      #   chunk: its S/M/L annotation, the current prefix byte proxy, and the
      #   shorter prefix a rewrite would leave, both as plain Integer BYTE
      #   counts. (The same canonical-byte proxy the compaction subsystem
      #   measures history in, named for its unit; this method wraps
      #   them in {Lain::ProxyBytes} before either reaches a price.)
      # @param profile [CacheProfile] the provider's cache economics
      # @param prices [PriceBook] the model-price map
      # @param calibration [#median_turns, nil] Journal-calibrated medians;
      #   nil (or a class it has no history for) falls back to {ANNOTATION_TURNS}
      # @return [Telemetry::SeamDecision] the journaled record (also pushed onto
      #   the journal), carrying the verdict and both sides' inputs
      def call(chunk:, profile:, prices:, calibration: nil)
        size = chunk.size.to_s
        # Wrapped HERE, inline, where {Compaction::Scheduler} wraps on its
        # measurement object instead ({Compaction::Scheduler::Rewrite#dropped}
        # and `#remaining`). The two idioms differ for a reason and a reader
        # should not copy the wrong one: that Scheduler OWNS its measurement --
        # `#measure` builds the Rewrite -- while `chunk` here is a foreign duck
        # a caller owns, so this policy has nowhere to hang the crossing but its own
        # entry point. Same divisor, same value object, different seam.
        removed = ProxyBytes.new(count: [chunk.bytes_before - chunk.bytes_after, 0].max)
        after = ProxyBytes.new(count: chunk.bytes_after)
        # median_turns is trusted to answer an Integer/Float or nil (the
        # Calibration contract); a non-numeric here would surface downstream.
        calibrated = calibration&.median_turns(size)
        turns = calibrated || ANNOTATION_TURNS.fetch(size)
        commit(size:, turns:, calibrated: !calibrated.nil?, removed:, after:,
               cost: rewrite_cost(after, profile, prices),
               pay: payback(removed, turns, profile, prices))
      end

      private

      # Build the record, journal it, and hand it back -- the decide-then-journal
      # commit {Compaction::Scheduler#pipeline} makes for its own accounting.
      def commit(size:, turns:, calibrated:, removed:, after:, cost:, pay:)
        record = Telemetry::SeamDecision.new(
          size:, estimated_turns: turns, calibrated:,
          bytes_removed: removed.count, bytes_after: after.count,
          rewrite_cost: cost, payback: pay, verdict: pay > cost ? :rewrite_now : :defer
        )
        @journal << record
        record
      end

      # One cache write of the shorter prefix: its bytes CROSSED INTO TOKENS at
      # the input rate, marked up by the profile's write premium.
      #
      # The crossing is {Lain::ProxyBytes#to_tokens} and it is not optional: the
      # operand counts bytes while every {PriceBook} rate is per token, so
      # multiplying them directly overstates by the bytes-per-token ratio -- the
      # defect this guards against, which {Compaction::Scheduler} shared until
      # the same crossing landed there. One divisor, defined once, used by both.
      #
      # @param bytes_after [Lain::ProxyBytes] the shorter prefix a rewrite leaves
      # @param profile [CacheProfile] the provider's cache economics
      # @param prices [PriceBook] the model-price map
      def rewrite_cost(bytes_after, profile, prices)
        return BigDecimal(0) if @model.nil?

        input_rate(prices) * bytes_after.to_tokens * multiplier(profile.write_multiplier)
      end

      # What NOT rewriting costs: the dropped span resent at the provider's
      # per-turn read rate (its cache discount where one exists, full input
      # under NO_CACHING) every one of the estimated remaining turns. Crosses
      # into tokens exactly as {#rewrite_cost}'s operand does.
      #
      # @param removed [Lain::ProxyBytes] the span a rewrite would drop
      # @param turns [Integer, Float] the estimated remaining turns
      # @param profile [CacheProfile] the provider's cache economics
      # @param prices [PriceBook] the model-price map
      def payback(removed, turns, profile, prices)
        return BigDecimal(0) if @model.nil?

        input_rate(prices) * removed.to_tokens * multiplier(profile.read_multiplier) * multiplier(turns)
      end

      def input_rate(prices)
        prices.price(@model).input
      end

      # Every multiplicand crosses into BigDecimal via its String form, so a
      # Float multiplier (1.25) or a fractional calibrated median never
      # contaminates the exact decimal arithmetic PriceBook mandates.
      def multiplier(value)
        value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
      end
    end
  end
end
