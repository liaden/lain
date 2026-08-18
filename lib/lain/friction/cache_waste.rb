# frozen_string_literal: true

require "bigdecimal"

module Lain
  module Friction
    # Joins the two halves of a cache-waste meter that shipped separately:
    # {Bench::Rewrites} knows WHERE a prompt prefix broke, the Journal's
    # `turn_usage` records know what the next call was BILLED for, and
    # {PriceBook} turns the difference into dollars. Journal bytes only -- no
    # Timeline, no provider, so two folds over the same entries agree.
    #
    # == Waste is a cache write that a BREAK preceded
    #
    # Not every `cache_creation_input_tokens` is waste. The first call of a
    # session buys a cache nobody had; a growing conversation buys the new
    # tail. What this counts is narrower: the cache creation billed on the call
    # whose prefix chain diverged from the previous call's ON THE SAME MODEL --
    # bytes that were already bought once and had to be bought again. Summing
    # every cache write instead would report a healthy session as a wasteful
    # one.
    #
    # == Segmentation is per MODEL, not per consecutive run
    #
    # `Request#prefix_digests` folds `model` into every chain entry (via
    # `fixed_prefix_digest`'s `{model, tools, system}` seed), so a `/model`
    # switch disagrees at every shared position and {Bench::Rewrites} reads it
    # as one rewrite at the earliest -- "indistinguishable from a real prefix
    # edit" (rewrites.rb:34-42, which tells callers to segment **per arm**).
    #
    # Per ARM, and deliberately not per consecutive RUN. The prompt cache is
    # keyed per `(model, prefix)`, so an intervening haiku call does not touch
    # the opus cache: two opus calls with a haiku call between them genuinely
    # share a cache and genuinely re-bill when the opus prefix breaks. Chunking
    # into maximal consecutive runs would put every call of an alternating
    # session in a run of length 1 and make this meter structurally incapable
    # of ever reporting anything -- silently, and on the sessions where `/model`
    # is used most. So calls are grouped by model (`group_by`, first-appearance
    # order) and compared within a group, while `model_switches` is counted
    # from consecutive boundaries because that is what a switch IS.
    #
    # The model is read from the request's `payload["model"]`: the payload IS
    # `Request#cache_payload`, so that field is the very byte the chain folds
    # in, and segmenting on it segments on exactly what made the chains
    # disagree.
    #
    # == Pairing, and the usage that belongs to somebody else
    #
    # `request_sent` lands before dispatch and `turn_usage` after, so the two
    # interleave one pair per turn. {Telemetry::TurnUsage} carries no
    # `request_digest`, so positional pairing is the only join the Journal
    # offers -- and it is not safe on its own. `Tools::Subagent` hands a child
    # the SESSION's journal, and its long-lived actor "outlives the parent's
    # asks", so a child's `turn_usage` can land between the parent's request
    # and the parent's own. Taken positionally that record is charged to the
    # parent and the parent's real usage is discarded.
    #
    # So a pair whose two models disagree OUTRIGHT is REFUSED, the request
    # stays pending for the record that is really its own, and the refusal is
    # counted ({#refused_usages}). Containment rather than equality, because
    # the fields legitimately differ in specificity -- a request may name an
    # alias where the usage reports the resolved snapshot. The residual is
    # therefore wider than "the same model": a child whose name CONTAINS, or is
    # CONTAINED BY, its parent's is also indistinguishable -- measured, a
    # `qwen3:8b` parent and a `qwen3:8b-instruct` child attribute 777,777 tokens
    # against a truth of 2,000, and ollama tag variants and alias/snapshot pairs
    # share that shape. Containment is still the right test, because equality
    # would refuse the ordinary alias/snapshot pair and make a normal session
    # noisy; this is a real residual limit of a journal with no request/usage
    # join key, not a fixable one.
    #
    # == Two stated limits, so neither is later mistaken for a defect
    #
    # The re-billed figure is an UPPER BOUND, which is why the report says "at
    # most". A break's depth is a message POSITION, and the billed
    # `cache_creation_input_tokens` is a token count covering the whole write --
    # so a call that both broke its prefix AND appended new messages has its
    # entire cache write attributed here, including the tail it would have paid
    # for anyway. Splitting the two would need per-message token accounting the
    # Journal does not record.
    #
    # TTL EXPIRY is the second over-attribution, and it is why "at most" carries
    # more than the paragraph above. Comparison groups are per MODEL over the
    # whole session, not per consecutive run, because the prompt cache is keyed
    # `(model, prefix)` -- so two calls of one model are compared however many
    # turns apart they sit. A prefix that broke only because the cache had
    # already EXPIRED is counted here as waste. This class does not read the
    # clock to exclude it; note it does not read it rather than cannot --
    # {Journal#record} stamps `ts` on every record, so the wall-clock gap
    # between any pair is already in the bytes walked here. Gating a comparison
    # on it is a follow-up, not a limit of the record.
    #
    # Only the MAIN agent's calls are covered. {Middleware::JournalRequests} is
    # wired into the main Agent's `model_middleware` alone (see
    # `CLI::Chronicle.instrumentation`), so a subagent's `turn_usage` has no
    # `request_sent` of its own to pair with. Every figure here is therefore
    # scoped to "priced main-agent calls", and the render says so.
    #
    # == What it emits
    #
    # Digests, token counts, model names and dollars. `payload` is read for one
    # field and never retained. That field is not trusted either: a model name
    # is echoed into a report, and a local model is routinely configured BY
    # PATH, so names are reduced to a safe token (see {SAFE_MODEL}) before they
    # can reach a render.
    class CacheWaste
      include Enumerable

      # The segment key for a call whose journal recorded no usable model --
      # an old journal, a provider that reports none, or a name this class
      # declines to echo. A Null Object rather than nil so segmentation,
      # `uniq` and the render never guard: it groups with its own kind, and it
      # matches no family token in {PriceBook}, so it declines to be priced
      # instead of being priced free.
      UNRECORDED_MODEL = "(no model recorded)"

      # A model NAME is a token: letters, digits and the separators vendors
      # actually use (`claude-opus-4-8`, `qwen3:8b`, `llama3.1-70b`). This
      # string is echoed into a report whose stated constraint is digests,
      # token counts and dollars, so anything else is not printed: a
      # path-shaped name keeps only its basename (the directories are where a
      # username lives), and whatever still fails becomes {UNRECORDED_MODEL}.
      #
      # The cost is that two local models whose paths differ but whose
      # basenames match would segment as one. That is a far better trade than
      # rendering `/home/<user>/models/...` into a file a user pastes into an
      # issue.
      SAFE_MODEL = /\A[A-Za-z0-9._:-]+\z/

      # A dollar figure that knows whether every token behind it could be
      # priced. {PriceBook} raises on an unknown model rather than guessing,
      # and a bare `BigDecimal` sum has nowhere to record that a rebill was
      # dropped -- so a partly-priceable journal rendered as a confident
      # `$0.000000`, which is the exact lie the raise exists to prevent. The
      # completeness travels WITH the number instead.
      Dollars = Data.define(:amount, :complete) do
        # Nothing was owed, and that is known exactly.
        def self.zero = new(amount: BigDecimal(0), complete: true)

        # Something was owed and could not be priced.
        def self.unknown = new(amount: BigDecimal(0), complete: false)

        def self.of(amount) = new(amount:, complete: true)

        def +(other)
          self.class.new(amount: amount + other.amount, complete: complete && other.complete)
        end

        def complete? = complete
      end

      # One model round trip the Journal actually BILLED: the request that went
      # out, paired with the usage that came back.
      Call = Data.define(:model, :chain, :chain_version, :usage) do
        # ROADMAP.md:221-225's cache-aware compaction scheduler sensor,
        # verbatim: "run only when the cache is already cold ... confirmed by
        # `cache_read_input_tokens == 0`". Reachable from a single record
        # through {CacheWaste.cache_fact}, so that scheduler never has to fold
        # a journal to ask it.
        def cold? = usage.cache_read_input_tokens.zero?

        def initialize(model:, chain:, chain_version:, usage:)
          super(model: -model.to_s, chain: Canonical.normalize(chain), chain_version:, usage:)
        end
      end

      # One attributed re-billing: the prefix broke at `depth`, and the call
      # after the break re-bought `rebilled_tokens` at cache-creation rates.
      Rebill = Data.define(:model, :depth, :rebilled_tokens, :cost) do
        def initialize(model:, depth:, rebilled_tokens:, cost:)
          super(model: -model.to_s, depth: Integer(depth), rebilled_tokens: Integer(rebilled_tokens), cost:)
        end
      end

      # Fold journal entries -- the {Journal.records} duck: parsed Hashes or
      # raw NDJSON lines -- into a priced waste attribution.
      #
      # @param entries [Enumerable<Hash, String>]
      # @param price_book [Lain::PriceBook]
      # @return [CacheWaste]
      def self.from_journal(entries, price_book: PriceBook.default)
        walk = Pairing.new
        Journal.records(entries).each { |record| walk.observe(record) }
        new(calls: walk.calls, refused_usages: walk.refused, price_book:)
      end

      # The cache sensor's own door: one `turn_usage` record in, one cache fact
      # out, with no request, no chain and no journal fold.
      #
      # ROADMAP.md:221-225's scheduler asks "is the cache cold RIGHT NOW" of
      # the record it has just observed. Making it reach {Call} through
      # {.from_journal} would re-parse every `request_sent` payload every turn,
      # and {Telemetry::RequestSent} notes those are O(n^2) in bytes across a
      # session -- so the cheap question gets a cheap answer.
      #
      # It RAISES on a usage-less record, where {Pairing} one screen down
      # declines -- deliberately, and the two are not in tension. `Pairing`
      # walks a whole journal a user handed to `lain friction`, where one torn
      # record must not destroy the report; this answers about a single record
      # the caller has just observed itself, where a malformed one is a bug in
      # the writer and not a fact about the session. A scheduler calling it per
      # observed record inherits that raise on purpose.
      #
      # @param record [Hash] one `turn_usage` journal record
      # @return [Call] whose `chain` is nil: no request was consulted
      # @raise [ArgumentError] if the record carries no usage
      def self.cache_fact(record)
        entry = Ledger::Index::Entry.from_record(record)
        Call.new(model: safe_name(entry.model), chain: nil, chain_version: nil, usage: entry.usage)
      end

      # Reduce a recorded model to a name safe to print, or {UNRECORDED_MODEL}.
      # See {SAFE_MODEL}.
      #
      # @param named [Object] whatever the journal recorded
      # @return [String]
      def self.safe_name(named)
        return UNRECORDED_MODEL unless named.is_a?(String)

        candidate = named.split(%r{[/\\]}).last.to_s
        SAFE_MODEL.match?(candidate) ? candidate : UNRECORDED_MODEL
      end

      # The pairing walk's state, which is genuinely a small state machine: a
      # request waiting for its usage, the calls completed so far, and the
      # usages refused because they belonged to somebody else.
      class Pairing
        attr_reader :calls, :refused

        def initialize
          @calls = []
          @refused = 0
          @pending = nil
        end

        def observe(record)
          case record["type"]
          when "request_sent" then @pending = record
          when "turn_usage" then pair(record)
          end
        end

        private

        # A refusal deliberately does NOT clear `@pending`: the usage belonged
        # to somebody else, so the request is still waiting for its own.
        def pair(record)
          return if @pending.nil?

          call = call_for(@pending, record)
          return @refused += 1 if call.nil?

          @calls << call
          @pending = nil
        end

        # nil means REFUSE: either the models disagree outright (a
        # concurrently-journaled subagent turn) or the record carries no usage.
        #
        # A usage-less record declines rather than raising. {Ledger::Index}
        # raises there because a bench whose headline metric is cost must not
        # price a corrupt payment as free -- but this is a report a user ran
        # over whatever journal they had, and the same doctrine {#price_for}
        # already applies to an unknown model says DECLINE, never fabricate and
        # never crash. The refusal is counted, so it is not silent either.
        def call_for(request, usage_record)
          entry = Ledger::Index::Entry.from_record(usage_record)
          requested = requested_model(request)
          return nil unless agrees?(requested, entry.model)

          Call.new(model: CacheWaste.safe_name(requested || entry.model), chain: request["prefix_digests"],
                   chain_version: request["prefix_chain_version"], usage: entry.usage)
        rescue ArgumentError
          nil
        end

        # Containment, not equality: a request may name an alias where the
        # usage reports the resolved snapshot, or vice versa. Only an outright
        # disagreement means the record is somebody else's.
        def agrees?(requested, reported)
          return true if requested.nil? || reported.nil?

          requested.include?(reported) || reported.include?(requested)
        end

        # The raw recorded name, un-sanitized, because it is compared against
        # the usage's before either is reduced for printing.
        def requested_model(request)
          payload = request["payload"]
          named = payload.is_a?(Hash) ? payload["model"] : nil
          named.is_a?(String) ? named : nil
        end
      end

      # @param calls [Enumerable<Call>] every billed call, in journal order
      # @param refused_usages [Integer] usages that belonged to somebody else
      # @param price_book [Lain::PriceBook]
      def initialize(calls:, refused_usages: 0, price_book: PriceBook.default)
        @price_book = price_book
        @calls = calls.to_a.freeze
        @refused_usages = refused_usages
        @model_switches = [consecutive_runs.size - 1, 0].max
        @rebills = @calls.group_by(&:model).values.flat_map { |arm| rebills_in(arm) }.freeze
        @unpriced_models = unpriceable_models.freeze
        freeze
      end

      # Every billed call, in journal order -- the per-call cache facts.
      # @return [Array<Call>]
      attr_reader :calls

      # Consecutive calls whose model changed. Reported rather than merely
      # skipped: an unexplained absence reads as a metric that missed something.
      # @return [Integer]
      attr_reader :model_switches

      # `turn_usage` records refused because they belonged to another agent, or
      # carried no usage at all.
      # @return [Integer]
      attr_reader :refused_usages

      # Models this journal used that {PriceBook} declines to price.
      # @return [Array<String>]
      attr_reader :unpriced_models

      # @yieldparam rebill [Rebill]
      # @return [Enumerator<Rebill>, self]
      def each(&block)
        return @rebills.each unless block

        @rebills.each(&block)
        self
      end

      # @return [Array<String>] every model this journal called, in first-use order
      def models = @calls.map(&:model).uniq

      # @return [Integer] tokens re-bought because a prefix broke
      def rebilled_tokens = @rebills.sum(&:rebilled_tokens)

      # @return [Dollars] what those tokens cost, and whether all of them could be priced
      def rebilled_cost = @rebills.sum(Dollars.zero) { |rebill| rebill.cost || Dollars.unknown }

      # What the cache BOUGHT, reported beside what it wasted: a waste figure
      # alone is an anti-metric (ROADMAP.md:233), since an agent that reads
      # nothing wastes nothing.
      #
      # @return [Integer] tokens served from the prompt cache
      def cached_tokens = @calls.sum { |call| call.usage.cache_read_input_tokens }

      # @return [Dollars] the dollars those cached reads saved against full input rates
      def cached_savings = @calls.sum(Dollars.zero) { |call| saving_on(call) }

      private

      # Only for {#model_switches}: a switch is by definition a CONSECUTIVE
      # change. Comparison groups come from `group_by` instead -- see the class
      # comment on why per-arm and per-run are different questions.
      def consecutive_runs
        @calls.chunk_while { |before, after| before.model == after.model }.to_a
      end

      def unpriceable_models
        @calls.map(&:model).uniq.reject { |model| price_for(model) }
      end

      # A call whose chain was never computed is skipped exactly as
      # {Bench::Rewrites} skips it, so its neighbours compare directly and the
      # break localizes on the later one that has a chain.
      def rebills_in(arm)
        arm.reject { |call| call.chain.nil? }
           .each_cons(2)
           .filter_map { |before, after| rebill_between(before, after) }
      end

      # The rewrite semantics -- shared-position rule, depth, and the
      # cross-format refusal -- stay entirely inside {Bench::Rewrites}: this
      # asks it about one consecutive pair rather than re-deriving any of it.
      def rebill_between(before, after)
        rewrite = Bench::Rewrites.new(chains: [[before.chain_version, before.chain],
                                               [after.chain_version, after.chain]]).first
        rewrite && Rebill.new(model: after.model, depth: rewrite.depth,
                              rebilled_tokens: after.usage.cache_creation_input_tokens,
                              cost: rebill_cost(after))
      end

      # nil is the REFUSAL, distinct from `Dollars.zero`: the caller turns it
      # into {Dollars.unknown} so the incompleteness survives the sum.
      def rebill_cost(call)
        price = price_for(call.model)
        price && Dollars.of(price.cache_creation * call.usage.cache_creation_input_tokens)
      end

      # Zero tokens at an unknown rate is exactly zero, so an unpriced model
      # only taints a figure that had tokens behind it.
      def saving_on(call)
        tokens = call.usage.cache_read_input_tokens
        return Dollars.zero if tokens.zero?

        price = price_for(call.model)
        price ? Dollars.of((price.input - price.cache_read) * tokens) : Dollars.unknown
      end

      # {PriceBook} raises rather than guessing, which is right for a bench
      # whose headline metric is cost and wrong for a report a user ran over
      # whatever journal they had. The refusal is caught here and surfaces as
      # {#unpriced_models}: tokens still counted, dollars withheld. A PriceBook
      # carrying an explicit fallback still prices everything.
      def price_for(model)
        @price_book.price(model)
      rescue PriceBook::UnknownModel
        nil
      end
    end
  end
end
