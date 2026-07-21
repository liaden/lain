# frozen_string_literal: true

require "bigdecimal"

module Lain
  module Plan
    # PC-4: the seam expected-value decision. At each plan seam the linear shape
    # asks: rewrite the prefix NOW (pay one cache write of the shorter prefix),
    # or DEFER to the next seam (keep resending the chunk's tokens as warm cache
    # reads)? This is the policy that answers it, weighing the one-off rewrite
    # cost against the payback of never resending those tokens again over the
    # turns the chunk is estimated to still run.
    #
    # It follows {Compaction::Scheduler}'s template -- a frozen policy object
    # whose `#call` is a pure function of its arguments, journaling its full
    # accounting as it commits to a verdict -- but the profile and prices arrive
    # PER SEAM (a sweep varies them across arms), while the arm's `model` is
    # fixed at construction. The fork-per-step shape journals the same record as
    # seam-density VALIDATION (it never rewrites); live wiring into either shape
    # is P6's, not this card's.
    #
    # Both sides are priced through the provider's real {CacheProfile} (F1) --
    # `write_multiplier` for the rewrite, `read_multiplier` for the resend --
    # times the model's plain input rate from the {PriceBook}, rather than the
    # PriceBook's own cache_creation/cache_read rows: the profile is F1's
    # first-class home for a provider's cache premium/discount, with no second
    # constant to drift (a Guard-spec pins the two encodings equal for the
    # shipped models).
    #
    # Under a NO_CACHING provider (both multipliers 1.0) a large chunk still
    # answers `rewrite_now`, and that is HONEST EV, not a degenerate case:
    # without a cache there is nothing to protect, but there is everything to
    # save -- compaction shortens every future turn's FULL-PRICE input resend,
    # so `payback = tokens_removed x input x 1.0 x turns` genuinely outweighs
    # the one-off `rewrite_cost = tokens_after x input x 1.0`. The only path
    # that defers regardless is an UNPRICED arm (`model: nil`), where both
    # sides are zero -- see {#initialize}.
    class SeamDecision
      # The annotation-tier turn estimate per S/M/L class -- the fallback used
      # when no Journal calibration is supplied yet (P5's `median_turns` returns
      # nil until a class has closed chunks). Deliberately coarse and
      # overridable-by-data: calibration replaces these with measured medians,
      # and the drift between an annotation and its measurement is itself the
      # journaled signal PC-4/PC-5 report.
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
      # @param chunk [#size, #tokens_before, #tokens_after] the runtime-measured
      #   chunk: its S/M/L annotation, the current prefix token proxy, and the
      #   shorter prefix a rewrite would leave. (The same byte/token proxy the
      #   compaction subsystem measures history in -- units cancel in the ratio.)
      # @param profile [CacheProfile] the provider's cache economics (F1)
      # @param prices [PriceBook] the model-price map (CE-6)
      # @param calibration [#median_turns, nil] P5's Journal-calibrated medians;
      #   nil (or a class it has no history for) falls back to {ANNOTATION_TURNS}
      # @return [Telemetry::SeamDecision] the journaled record (also pushed onto
      #   the journal), carrying the verdict and both sides' inputs
      def call(chunk:, profile:, prices:, calibration: nil)
        size = chunk.size.to_s
        removed = [chunk.tokens_before - chunk.tokens_after, 0].max
        # median_turns is trusted to answer an Integer/Float or nil (P5's
        # Calibration contract); a non-numeric here would surface downstream.
        calibrated = calibration&.median_turns(size)
        turns = calibrated || ANNOTATION_TURNS.fetch(size)
        commit(size:, turns:, calibrated: !calibrated.nil?, removed:, after: chunk.tokens_after,
               cost: rewrite_cost(chunk.tokens_after, profile, prices),
               pay: payback(removed, turns, profile, prices))
      end

      private

      # Build the record, journal it, and hand it back -- the decide-then-journal
      # commit {Compaction::Scheduler#pipeline} makes for its own accounting.
      def commit(size:, turns:, calibrated:, removed:, after:, cost:, pay:)
        record = Telemetry::SeamDecision.new(
          size:, estimated_turns: turns, calibrated:, tokens_removed: removed, tokens_after: after,
          rewrite_cost: cost, payback: pay, verdict: pay > cost ? :rewrite_now : :defer
        )
        @journal << record
        record
      end

      # One cache write of the shorter prefix: its tokens at the input rate,
      # marked up by the profile's write premium.
      def rewrite_cost(tokens_after, profile, prices)
        return BigDecimal(0) if @model.nil?

        input_rate(prices) * tokens_after * multiplier(profile.write_multiplier)
      end

      # What NOT rewriting costs: the dropped tokens resent at the provider's
      # per-turn read rate (its cache discount where one exists, full input
      # under NO_CACHING) every one of the estimated remaining turns.
      def payback(removed, turns, profile, prices)
        return BigDecimal(0) if @model.nil?

        input_rate(prices) * removed * multiplier(profile.read_multiplier) * multiplier(turns)
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
