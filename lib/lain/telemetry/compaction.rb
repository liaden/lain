# frozen_string_literal: true

require "bigdecimal"

module Lain
  module Telemetry
    module Carriers
      # A compaction record must name what fired it and land on one of the
      # three cache states the scheduler's policy actually reaches. Both stay
      # REQUIRED: a record with no trigger or an unknown cache state is a bug,
      # and neither has a "we cannot say" reading the way the dollars do.
      #
      # The two cost figures MAY be absent (nil), which is the one thing this
      # guard adds: a scheduler that cannot stand behind its dollars emits
      # neither. It emits neither TOGETHER -- one figure beside a missing one
      # would read as a real zero on the missing side, which is exactly the
      # confusion absence exists to remove.
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
    # decision only ever reaches `:cold` or `:forced` here: an unforced warm
    # decision always DEFERS (see {Compaction::Scheduler#evaluate}) and never
    # reaches a journal at all. `:warm` completes the enum for a reader who
    # expects the full vocabulary; it is not a value this scheduler
    # emits today.
    #
    # `bytes_before`/`bytes_after` are the SAME canonical-byte-length proxy
    # {Compaction::Need::TokenThreshold} and {Context::Compact} already use in
    # place of a real tokenizer (see either's header for why a deterministic
    # proxy is the only property needed here) -- one consistent unit across
    # the compaction subsystem, not a second, incompatible one. They are named
    # for that unit because they were not before, and it cost a reader:
    # `tokens_before / window_tokens` read 80% occupancy against a session every
    # other reader put at 32%, because the numerator counted BYTES and the
    # denominator provider-measured TOKENS (QA round 5). `head_bytes` on
    # {Compaction::Source}'s sibling record already named the unit honestly;
    # this record is the one that did not.
    #
    # WIRE COMPATIBILITY: old journals are NOT migrated and no shim reads them.
    # A record written before this rename carries `tokens_before`/`tokens_after`
    # holding exactly these byte figures under the misleading name -- so a
    # pre-chunk NDJSON line is still readable, but only by a reader who knows
    # that. Anything crossing the two units goes through
    # {Lain::ProxyBytes#to_tokens}, which is the only place a
    # byte count becomes a token count at all.
    #
    # `cost_saved`/`cost_spent` are ESTIMATES, not payments: unlike
    # {TurnUsage}, no model call happens inside a compaction -- `Compact`'s
    # summarizer is a pure, already-injected, deterministic function (see its
    # own header) -- so there is no real {Lain::Usage} to price against.
    # `cost_saved` prices the byte delta at the model's plain input rate:
    # what continuing to resend the dropped span every subsequent turn
    # would have cost. `cost_spent` prices `bytes_after` at the
    # cache_creation rate ONLY when `cache_state` is `:forced` -- rewriting
    # the message tier while the cache was still warm is exactly what forces
    # that write -- and is zero on `:cold`, matching {Compaction::Scheduler}'s
    # own "a cold cache runs the compaction for free" rationale. Both are
    # zero, DOCUMENTED the way {Salvaged}'s zero-cost gap is, when the
    # scheduler carries no `model` to price with: an unpriced scheduler is a
    # legitimate configuration today (nothing downstream reads cost from it
    # yet), not a caller error worth raising over.
    #
    # `model` names the tier those dollars are QUOTED IN, and it is the field
    # that keeps the two zeros above from being one zero. Without it a
    # compaction priced through a degrading fallback -- what an unpriced local
    # model gets from `CLI::Backend::COMPACTION_PRICES`, so that a `--provider
    # ollama` chat compacts instead of crashing -- is byte-identical on the
    # record to a genuinely free one, and the record is exactly where
    # `price_book.rb:48-50` refuses to tell that lie ("a silently-free model is
    # a lie" on a cost bench). nil keeps its existing meaning: no model to price
    # with, both figures zero, a legitimate configuration.
    #
    # After a `/model` switch the scheduler's construction-time price and the
    # tier that actually ran come apart: the compaction WINDOW follows the live
    # model per turn, and the price lookup did not follow it. This record settles
    # that by REFUSING: both cost figures are then nil -- absent, not zero --
    # and `model` names the tier the compaction actually ran under, the only
    # fact left that a reader can use. `PriceBook`'s refusal to price an
    # unlisted model (`price_book.rb:112`) is the same doctrine one tier up: a
    # figure that cannot be stood behind is not emitted.
    #
    # Absence is nil on BOTH figures or on neither ({Carriers::Compaction}
    # enforces the pair), and it is deliberately not a zero: `cost_spent`
    # legitimately zeroes on a `:cold` compaction and both zero on an unpriced
    # scheduler, so a switched run reporting zero would be indistinguishable
    # from a compaction that genuinely ran for free. Ask {#priced?} rather
    # than comparing against `"0.0"`. A nil `model` keeps its OWN meaning --
    # the unpriced configuration, zeros beside no model at all -- which is a
    # different state from a refusal and journals differently.
    #
    # So `model` now carries THREE meanings, separable only through
    # {#priced?}: the tier the figures are quoted in (priced, no switch), the
    # tier that RAN (refused, no figures), or nothing at all (unpriced). That
    # is a real cost and it was paid deliberately. The alternative was to name
    # the live tier in the unpriced case too, which reads more uniformly and
    # would have changed the bytes an unpriced run has always journaled --
    # `model` going from nil to a model id beside the same two zeros, for a
    # configuration where no quote was ever made or invalidated. Byte-identity
    # for the untouched state won. The visible seam is that the "still names the
    # model it ran under" contract holds for a REFUSAL and not for an unpriced
    # run, where `ran_under` is known and deliberately discarded.
    #
    # Held as fixed-point decimal STRINGS, not `BigDecimal`: `Canonical.normalize`
    # deliberately does not support `BigDecimal` (it has no canonical wire
    # form), and every `Data` field here must already be an immutable, JSON-safe
    # value to keep this record `Ractor.shareable?` -- the same "canonical wire
    # form" idiom {RequestSent}'s `payload` and {TurnUsage}'s `usage` already
    # use for anything that is not natively JSON-safe. `model` is frozen for
    # that same reason -- {TurnUsage} freezes its own for it. {Telemetry.fixed_point}
    # is the one formatter both this record and {SeamDecision} quote through, and
    # it is where the nil-as-refusal above is honoured.
    #
    # `collapse_strategy` names the POLICY that collapsed the span --
    # `--compact-strategy`'s own value verbatim (a leaf like `"elide-tools"`,
    # or a composition like `"elide-tools+summarize-conversation"`), or
    # {Compaction::EAGER_CONTROL_ARM} for a run that never set the flag. It is
    # a SEPARATE axis from {ContextDerived#strategy}, which names the
    # DERIVATION CLASS that ran, not the collapse policy behind it -- the same
    # hazard the byte/token rename above paid for once already, one field
    # short of two units sharing one name. `collapse_strategy` is the name
    # this record owns; `strategy` stays the other record's.
    #
    # nil is NOT "no strategy". {Backend::SpanSummarizer}'s own doc
    # (`backend/span_summarizer.rb:19-36`) argues an unflagged run still HAS a
    # policy -- the eager tool-result tier, the control arm every
    # `--compact-strategy` run is measured against -- so a caller building
    # this record for that run passes {Compaction::EAGER_CONTROL_ARM}
    # explicitly, never nil. That is the same doctrine `cost_saved`/
    # `cost_spent` already keep for a switched-model refusal above: a real
    # state gets a name, not a fold into the absence a reader would misread as
    # "nothing to say". nil is reserved for the one case that predates this
    # field: a journal written before this chunk, where the kwarg was never
    # offered at all -- {#initialize} defaults it so that old caller still
    # builds and reads exactly as it always has.
    #
    # Emitted from {Compaction::Scheduler}'s existing `if decision.compact?`
    # guard in `#pipeline` -- REPLACING the lighter `CompactionScheduled` record
    # that guard used to build (`reason`/`tier` alone). There is one record at
    # that call site, not two synchronized ones: extending what was already
    # there, not adding a second, independently-guarded emission path.
    Compaction = Data.define(:trigger, :cache_state, :bytes_before, :bytes_after, :cost_saved, :cost_spent,
                             :model, :collapse_strategy) do
      include Journalable

      # `model:` and `collapse_strategy:` both default, so every constructor
      # that predates either keeps building the record it always did.
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
      # compaction ran under a model its scheduler was not priced for, so the
      # quote was refused (see the header).
      #
      # It is NOT "these dollars can be trusted", and a consumer must not read
      # it that way. A true here still admits a zero that was never really
      # measured: a live chat prices through the zero-fallback
      # `CLI::Backend::COMPACTION_PRICES` (backend.rb:78-92), so an UNLISTED
      # model with no switch at all journals `"0.0"`/`"0.0"` beside its own
      # name and answers true, folding into a sum as "broke even". That
      # fallback is a reasoned decision belonging to the CLI, not to this
      # record; refusing it too is ticketed separately. Until then this
      # predicate answers "no switch happened", which is less than it sounds.
      def priced? = !cost_saved.nil?

      # The cost delta {Compare} attributes to the scheduling policy:
      # positive means the compaction paid for itself, negative means it cost
      # more than it saved (a forced-warm rewrite on a small delta, say).
      #
      # nil, never zero, when the record quotes nothing: a consumer that sums
      # these gets a loud `TypeError` rather than a total that silently counted
      # a refusal as a compaction which paid for itself.
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
      # `--compact-strategy` -- see the header for why that is a real policy
      # (the eager tool-result tier) and not an absence of one, and so
      # deliberately not nil. The compaction wiring reads this; nothing in this
      # file constructs a record against it.
      EAGER_CONTROL_ARM = "eager"
    end
  end
end
