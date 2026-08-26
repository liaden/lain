# frozen_string_literal: true

require "bigdecimal"

module Lain
  module Telemetry
    module Carriers
      # `trigger` and `cache_state` stay REQUIRED: neither has a "we cannot
      # say" reading the way the dollars do.
      #
      # The two cost figures MAY be nil -- a scheduler that cannot stand behind
      # its dollars emits neither -- and they go TOGETHER, because one figure
      # beside a missing one reads as a real zero on the missing side, which is
      # the confusion absence exists to remove.
      class Compaction < Declarative::Carrier
        attribute :trigger
        attribute :cache_state
        attribute :cost_saved
        attribute :cost_spent
        validates :trigger, presence: { message: "must name the Need signal(s) that fired, got none" }
        validates :cache_state, inclusion: { in: %i[warm cold forced],
                                             message: "must be one of warm/cold/forced, got %<value>s" }
        validate :costs_quoted_together

        private

        def costs_quoted_together
          return if cost_saved.nil? == cost_spent.nil?

          errors.add(:cost_saved, "and cost_spent must be quoted together or not at all")
        end
      end
    end

    # Every compaction's full accounting: WHY it fired (`trigger`,
    # the {Compaction::Need} signals that were live) and WHAT cache state the
    # scheduler read (`cache_state`), so {Compare} can attribute a cost delta
    # to the scheduling policy rather than to the summarizer itself.
    #
    # `cache_state` is closed over `:warm`/`:cold`/`:forced`, but a compacting
    # decision only ever reaches `:cold` or `:forced` here -- an unforced warm
    # decision always DEFERS and never reaches a journal. `:warm` completes the
    # enum for a reader who expects the full vocabulary.
    #
    # `bytes_before`/`bytes_after` are the SAME canonical-byte-length proxy
    # {Compaction::Need::TokenThreshold} and {Context::Compact} use in place of
    # a real tokenizer -- one consistent unit across the subsystem. They are
    # NAMED for that unit because the old `tokens_before` name cost a reader:
    # `tokens_before / window_tokens` read 80% occupancy against a session every
    # other reader put at 32%, the numerator counting BYTES and the denominator
    # provider-measured TOKENS. Anything crossing the two units goes through
    # {Lain::ProxyBytes#to_tokens}, the only place a byte count becomes a token
    # count at all.
    #
    # WIRE COMPATIBILITY: old journals are NOT migrated and no shim reads them.
    # A record written before that rename carries these exact byte figures under
    # `tokens_before`/`tokens_after`, so an old NDJSON line is readable only by
    # a reader who knows it.
    #
    # `cost_saved`/`cost_spent` are ESTIMATES, not payments: no model call
    # happens inside a compaction, so there is no real {Lain::Usage} to price
    # against. `cost_saved` prices the byte delta at the plain input rate --
    # what resending the dropped span every subsequent turn would have cost.
    # `cost_spent` prices `bytes_after` at the cache_creation rate ONLY on
    # `:forced`, since rewriting the message tier while the cache is warm is
    # what forces that write, and is zero on `:cold` because a cold cache runs
    # the compaction for free. Both are zero when the scheduler carries no
    # `model` to price with, which is a legitimate configuration rather than a
    # caller error.
    #
    # `model` names the tier those dollars are QUOTED IN, and it is what keeps
    # the several zeros from being one zero: without it, a compaction priced
    # through the degrading `CLI::Backend::COMPACTION_PRICES` fallback is
    # byte-identical to a genuinely free one, and a silently-free model is a lie
    # on a cost bench.
    #
    # After a `/model` switch the scheduler's construction-time price and the
    # tier that actually ran come apart -- the compaction WINDOW follows the
    # live model per turn and the price lookup did not. This record settles that
    # by REFUSING: both figures go nil, absent rather than zero, and `model`
    # names the tier the compaction really ran under. Zero would be
    # indistinguishable from a `:cold` compaction or an unpriced scheduler, so
    # ask {#priced?} rather than comparing against `"0.0"`.
    #
    # `model` therefore carries THREE meanings, separable only through
    # {#priced?}: the tier the figures are quoted in, the tier that RAN with no
    # figures, or nothing at all. The alternative -- naming the live tier in the
    # unpriced case too -- reads more uniformly but would change the bytes an
    # unpriced run has always journaled, and byte-identity for the untouched
    # state won.
    #
    # Held as fixed-point decimal STRINGS, not `BigDecimal`:
    # `Canonical.normalize` deliberately does not support `BigDecimal` (it has
    # no canonical wire form), and every field here must already be an
    # immutable, JSON-safe value to keep the record `Ractor.shareable?`.
    # {Telemetry.fixed_point} is the one formatter this record and
    # {SeamDecision} both quote through, and where the nil-as-refusal is
    # honoured.
    #
    # `collapse_strategy` names the POLICY that collapsed the span --
    # `--compact-strategy`'s own value verbatim, or {Compaction::EAGER_CONTROL_ARM}
    # for a run that never set the flag. It is a SEPARATE axis from
    # {ContextDerived#strategy}, which names the DERIVATION CLASS that ran; the
    # distinct name is the byte/token hazard above, one field short of two
    # meanings sharing one word.
    #
    # nil is NOT "no strategy": an unflagged run still HAS a policy, the eager
    # tool-result tier every `--compact-strategy` run is measured against, so
    # such a caller passes {Compaction::EAGER_CONTROL_ARM} explicitly. nil is
    # reserved for a journal written before the field existed.
    Compaction = Data.define(:trigger, :cache_state, :bytes_before, :bytes_after, :cost_saved, :cost_spent,
                             :model, :collapse_strategy) do
      include Journalable

      # Both later fields default, so a constructor that predates either keeps
      # building the record it always did.
      def initialize(trigger:, cache_state:, bytes_before:, bytes_after:, cost_saved:, cost_spent:, model: nil,
                     collapse_strategy: nil)
        trigger = Array(trigger).map(&:to_sym).freeze
        cache_state = cache_state.to_sym
        cost_saved = Telemetry.fixed_point(cost_saved)
        cost_spent = Telemetry.fixed_point(cost_spent)
        Carriers::Compaction.check!(trigger:, cache_state:, cost_saved:, cost_spent:)
        super(trigger:, cache_state:, bytes_before: Integer(bytes_before), bytes_after: Integer(bytes_after),
              cost_saved:, cost_spent:, model: model&.to_s&.freeze,
              collapse_strategy: collapse_strategy&.to_s&.freeze)
      end

      # Does this record CARRY figures at all? False for exactly one cause: the
      # compaction ran under a model its scheduler was not priced for.
      #
      # It is NOT "these dollars can be trusted". A true here still admits a
      # zero that was never really measured, because a live chat prices through
      # the zero-fallback `CLI::Backend::COMPACTION_PRICES`, so an UNLISTED
      # model with no switch journals `"0.0"`/`"0.0"` beside its own name and
      # folds into a sum as "broke even". This predicate answers "no switch
      # happened", which is less than it sounds.
      def priced? = !cost_saved.nil?

      # The cost delta {Compare} attributes to the scheduling policy:
      # positive means the compaction paid for itself, negative means it cost
      # more than it saved (a forced-warm rewrite on a small delta, say).
      #
      # nil, never zero, when the record quotes nothing: a consumer that sums
      # these gets a loud `TypeError` rather than a total that silently counted
      # a refusal as a compaction that paid for itself.
      #
      # @return [BigDecimal, nil]
      def cost_delta
        return nil unless priced?

        BigDecimal(cost_saved) - BigDecimal(cost_spent)
      end
    end

    class Compaction
      # Reopened, NOT folded into the `Data.define ... do` block above: a
      # constant defined inside that block resolves against the enclosing
      # module (`Telemetry`), not the Data class itself -- the trap
      # `CacheProfile::MINIMUM_CACHEABLE_TOKENS` documents (CLAUDE.md).

      # What a caller passes for `collapse_strategy` when a run never set
      # `--compact-strategy` -- a real policy, the eager tool-result tier, and
      # so deliberately not nil.
      EAGER_CONTROL_ARM = "eager"
    end
  end
end
