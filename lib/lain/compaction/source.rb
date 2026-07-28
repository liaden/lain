# frozen_string_literal: true

module Lain
  module Compaction
    # The live {Agent::PipelineSource}: which Context THIS turn renders through.
    #
    # Two halves, deliberately kept apart.
    #
    # OBSERVE feeds {Cold} the two signals it needs and nothing else decides on.
    # They arrive by different routes because they exist at different moments:
    # the idle gap is measured at render time from the injected clock, while the
    # cache-read count only exists on a model RESPONSE, which the render seam
    # never sees -- `context_for`'s `usage:` is A2's last-turn INPUT token count,
    # an Integer, not the usage Hash `Cold#observe` reads. So this object is also
    # a `#<<` sink (see {#<<}), the same duck {StatusFeed} answers, and rides the
    # same journal fan-out.
    #
    # DECIDE is one pass, in the order `bench/plan_sweep/driver.rb` established:
    # derive the candidate head, ask {Need} whether a compaction is warranted,
    # let {Scheduler} choose, and -- only then -- derive this turn's context
    # timeline. It answers the base Context ITSELF when the scheduler defers --
    # byte-identical, not merely equivalent, which is the whole DEFER contract --
    # and `base.with_pipeline` of the composed pipeline when it does not.
    #
    # == What a compacting turn renders
    #
    # A DERIVED chain, not a render-time projection. {Derived} materializes a
    # second lineage in the source's own Store and substitutes its projection as
    # the rendered messages; {Context::Compact} is no longer composed here at
    # all. The session timeline stays the lossless record and its head advances
    # only by committed turns -- a derivation writes replacement events into the
    # Store and never onto the chain the Agent holds.
    #
    # Substituting MESSAGES rather than handing `#render` a different timeline
    # is the Open decisions ruling, and it is load-bearing rather than
    # cosmetic: a strategy may hold a live oracle and a mutable memo, and
    # {Scheduler::COMPOSE}'s `Ractor.make_shareable` would deep-freeze that
    # graph in SILENCE. The derivation therefore runs here, off the pipeline,
    # and only a frozen array of finished messages crosses into it.
    #
    # It is NOT `Ractor.shareable?` and must not become so: it holds the mutable
    # {Cold} and the live {Oracle::Eager}. What it HANDS BACK is shareable, which
    # is the constraint that matters, and {SummarySnapshot} is what makes the two
    # compatible -- the summaries riding into the derivation are a frozen copy of
    # what the Eager held, never the Eager.
    class Source
      # The per-turn decision, journaled on EVERY turn including a deferring
      # one. `Agent#render_request` delegates this choice to a collaborator that
      # reports nothing back, so what is written here is the only trace it
      # happened -- and on a bench whose deliverable is comparability, an
      # unrecorded decision is a missing measurement. {Scheduler} journals the
      # richer {Telemetry::Compaction} accounting, but only when it compacts;
      # this record covers the defers and carries the snapshot's hit rate, which
      # is the bench's read on whether the eager fires are landing at all.
      #
      # `would_not_shrink` names the one refusal a reader could not otherwise
      # tell from a plain defer: the signals fired, the scheduler said now, and
      # the rewrite was declined because it would not have made the prompt
      # smaller (see {#shrinks?}). Silence there would read as "nothing was
      # warranted". It is `would_not_shrink` and not `would_inflate` because
      # {#shrinks?} asks for a strict saving -- a byte-NEUTRAL rewrite is
      # declined too, and calling that inflation would be a claim the
      # measurement never made.
      CompactionDecision = Data.define(:compacted, :signals, :head_bytes,
                                       :summary_hits, :summary_misses, :cold, :would_not_shrink) do
        include Telemetry::Journalable
      end

      # Null Object for the summary store: an Eager that holds nothing, so a run
      # with no oracle wired takes a snapshot of honest MISSES and renders pure
      # elision lines. A `nil` eager guarded at the take would be the same
      # behavior with a conditional in front of it.
      module NoSummaries
        module_function

        def held(_digest) = nil
      end

      # A turn whose derived chain the Messages API would have rejected, and
      # the uncompacted render it fell back to.
      #
      # ITS OWN TYPE rather than a {Telemetry::ContextDerived} carrying empty
      # `spans`: that record's `cut` field exists precisely to make an empty
      # collapse readable, and a fallback wearing a derivation's badge would put
      # back the ambiguity it was added to destroy.
      #
      # `consecutive` is what keeps this from being the silent-stop mode wearing
      # a badge. A deterministic strategy over a stable history refuses
      # IDENTICALLY every turn -- one refusal is an awkward history, forty in a
      # row is a session that has stopped compacting -- and the two are
      # indistinguishable from a record that counts nothing. See {Derived} for
      # why the streak is journalled rather than raised on.
      DerivationRefused = Data.define(:strategy, :violations, :consecutive) do
        include Telemetry::Journalable
      end

      # How long since the cache was last touched -- the observe half's clock,
      # extracted so the Source holds a measurement rather than a raw `Time` and
      # a bare ivar it has to keep in step by hand.
      class IdleGap
        def initialize(clock:)
          @clock = clock
          @touched = clock.call
        end

        # @return [Numeric] seconds since the last {#touch}, or since this
        #   object was built when no response has landed yet
        def elapsed = @clock.call - @touched

        def touch = (@touched = @clock.call)
      end
      private_constant :IdleGap

      # @param need [Need] the detector bank; owns the byte threshold and the
      #   approaching-window RATIO, so this object never restates either
      # @param cold [Cold] cache-warmth state, fed by {#<<} and {#observe_idle}
      # @param hard_cap [Integer] the history size, in {Head#bytesize}'s byte
      #   proxy, that forces a compaction even while the cache is warm
      # @param keep_last [Integer] trailing messages kept verbatim -- the ONE
      #   number {Head} and {Context::Compact} must agree on
      # @param eager [#held] the live summary store; the Null holds nothing
      # @param strategy [Strategy::Base, nil] which policy collapses a span,
      #   `--compact-strategy`'s answer. nil is the un-flagged wiring, which
      #   collapses into the run's own eager tier exactly as {Context::Compact}
      #   did -- see {Derived}. Injected ONCE, never fetched per turn: a
      #   model-backed strategy holds a memo whose absence turns one range's two
      #   questions into two model calls (`summarizing.rb:220-239`).
      # @param journal [#<<] where the decision lands; the Null channel by
      #   default, so no caller guards `if journal`
      # @param model [String, nil] priced for {Scheduler}'s cost accounting
      # @param price_book [PriceBook] how `model`'s usage becomes dollars
      # @param clock [#call] answers the current Time. Injected, never read
      #   inline: `Time.now` in the render path would make a replayed run
      #   non-deterministic, the same reason {StatusFeed} takes one.
      # @param context_window [#window_tokens] the window book {#decide} asks
      #   about the LIVE model each turn. The default degrades to a conservative
      #   fallback for a model no Anthropic-shaped table carries (`ollama`,
      #   `bedrock`), because an unsupported provider must still run; a blank
      #   model still raises there, which is a wiring bug rather than a provider.
      def initialize(need:, cold:, hard_cap:, keep_last:, eager: NoSummaries, strategy: nil,
                     journal: Channel::Null.instance, model: nil, price_book: PriceBook.default,
                     clock: -> { Time.now }, context_window: ContextWindow.default)
        @need = need
        @context_window = context_window
        @cold = cold
        @hard_cap = Integer(hard_cap)
        @eager = eager
        @journal = journal
        @model = model
        @price_book = price_book
        @idle = IdleGap.new(clock:)
        @derived = Derived.new(keep_last: validated_keep_last(keep_last), strategy:, journal:)
      end

      # The observe half's response leg. A turn's own usage carries the
      # `cache_read_input_tokens` count {Cold} reads, and nothing on the render
      # seam does -- so this rides {CLI::JournalTee} as one more fan-out leg,
      # exactly as {StatusFeed} does, and recognizes its event by duck rather
      # than by class.
      #
      # `#usage` ALONE is not that duck: {Telemetry::OracleAnswer} answers it
      # too, and its usage Hash has no cache fields, so a landed oracle answer
      # would read as a zero cache-read and confirm a WARM cache cold. A record
      # that also names why the model stopped is a turn's own.
      #
      # @param event [Object] anything from the journal; unrecognized events are
      #   inert, since a fan-out leg is fed everything
      # @return [self]
      def <<(event)
        return self unless turn_usage?(event)

        @cold.observe(event)
        # The cache was demonstrably touched at this moment, so the next turn's
        # idle gap is measured from HERE rather than from the last render --
        # which would fold the model round trip into it.
        @idle.touch
        self
      end

      # {Agent::PipelineSource}'s duck.
      #
      # @param base [Context] the Agent's own Context
      # @param timeline [Timeline] the history as of this render
      # @param usage [Integer, nil] A2's LAST-TURN input tokens -- nil before any
      #   turn, which {Need::ApproachingWindow} distinguishes from zero. Passed
      #   through untouched: a cumulative total here would latch the signal on
      #   permanently, and a zero would read as an empty context on a resumed
      #   session.
      # @param session [Session] the run's Session, for its plan-step signal
      # @return [Context] `base` itself, or a copy carrying this turn's pipeline
      def context_for(base:, timeline:, usage:, session:)
        observe_idle
        turns = timeline.to_a
        messages = projected(turns)
        decide(base:, timeline:, messages:, usage:, session:, pins: pinned(turns, messages, session))
      end

      private

      # {Head} owns the rule -- a keep_last of 0 makes a derivation replace the
      # ENTIRE history with a summary of nothing -- and asking it against an
      # empty history is how a bad wiring fails HERE rather than on the first
      # turn of a live chat.
      #
      # The validated number is then held by {Derived} and asked back for the
      # Head, rather than kept in a second ivar here. One number, one owner: the
      # {Boundary} the derivation cuts at and the {Head} {Need} measures have to
      # be computed from the SAME keep_last, and two copies is how they drift.
      def validated_keep_last(keep_last)
        Head.new(messages: [], keep_last:)
        keep_last
      end

      # A turn's own usage, and only that. `#usage` ALONE is not the duck:
      # {Telemetry::OracleAnswer} answers it too and its usage Hash carries no
      # cache fields, so a landed oracle answer would read as a zero cache-read
      # and confirm a WARM cache cold (panel-verified 2026-07-25). A record that
      # also names why the model stopped is a turn's.
      def turn_usage?(event) = event.respond_to?(:usage) && event.respond_to?(:stop_reason)

      # Idle time as this object can honestly measure it: since the cache was
      # last touched by a response, or since construction before the first one.
      # A no-op on a TTL-less provider, and only ever a PENDING mark -- the next
      # zero cache-read confirms or cancels it (see {Cold}).
      def observe_idle = @cold.idle!(@idle.elapsed)

      # {Context#render}'s projection, which is also {Head.from_timeline}'s. The
      # full list is built ONCE here because both halves of the decision need
      # it: {Head} slices the candidate span out of it, and {Scheduler} measures
      # its before/after accounting over the whole thing.
      def projected(turns) = turns.map { |turn| { "role" => turn.role, "content" => turn.content } }

      # The pin-set, translated once. A pin is a turn DIGEST and {Context::Compact}
      # only ever sees projected TEXT -- a turn's content address folds `meta`
      # and `causal_parents` that no projection carries, so the two are not
      # interchangeable and deriving one from the other by hashing the wrong
      # bytes misses every lookup in silence. This is the only object holding
      # both the timeline and the session, so it is the only place the mapping
      # can be made; making it ONCE and handing the same value to {Head} and to
      # the Compact is what stops them naming different messages.
      #
      # `#pinned?` and never `#pins`: the latter sorts the whole set on every
      # call (session.rb:164) and this is a per-turn membership test.
      def pinned(turns, messages, session)
        Context::PinnedMessages.new(
          turns.zip(messages).filter_map { |turn, message| message if session.pinned?(turn.digest) }
        )
      end

      # Is a compaction warranted at all? An empty head is asked for with
      # `#empty?`, never a zero byte count: an empty Head measures 2, the bytes
      # of `"[]"`. With nothing droppable there is no compaction to perform
      # whatever the signals say -- which is also how a history whose every
      # droppable turn is PINNED declines here rather than reaching Compact's
      # empty-summarizable path and paying a cache break for
      # {SummarySnapshot::NOTHING}.
      def decide(base:, timeline:, messages:, usage:, session:, pins:)
        head = Head.new(messages:, keep_last: @derived.keep_last, pins:)
        need = @need.check(messages: head.messages, used_tokens: usage, window_tokens: window_for(base),
                           plan_step_completed: session.plan_step_completed?)
        return defer(base:, need:, head:) if head.empty? || !need.needed?

        weigh(base:, timeline:, messages:, head:, need:, pins:)
      end

      # Off the LIVE Context, every turn, never captured at construction:
      # `/model` writes into {Context::ModelSwitch}'s slot mid-session
      # (model_switch.rb:20-22), so a window resolved once at startup would go
      # on measuring occupancy against the model the run began with -- and an
      # over-estimate is the failure that never fires rather than the one that
      # fires early. `Context#model` reads that slot at read time, which is
      # exactly what makes the derivation follow the switch.
      #
      # A blank model raises here rather than on the first `#compaction_source`
      # call, which is later but no quieter: it is a wiring bug, and this bench
      # fails loudly on one rather than degrading to a threshold nobody chose.
      def window_for(base) = @context_window.window_tokens(base.model)

      # Then WHEN, and only then WHETHER IT HELPS. {Scheduler#evaluate} is pure
      # and journals nothing (only `#pipeline` does), so asking it first costs
      # nothing and settles the entire warm-under-cap band -- the steady state
      # once the byte threshold is crossed -- before the floor's measurement is
      # paid for. Both halves of that matter: the floor's `Compact#call` and two
      # dumps measured 3.6 ms on an 84 KB history, wasted on every turn the
      # scheduler was going to defer regardless, and a turn deferred on TIMING
      # would have been journaled as an inflation refusal, over-counting the
      # refusals a bench reads by the whole warm-defer population.
      def weigh(base:, timeline:, messages:, head:, need:, pins:)
        return defer(base:, need:, head:) unless timely?(need, head)

        outcome = @derived.over(timeline, pins:, snapshot: SummarySnapshot.take(messages: head.messages,
                                                                                eager: @eager))
        return defer(base:, need:, head:, outcome:) if outcome.refused?
        return defer(base:, need:, head:, outcome:, would_not_shrink: true) unless shrinks?(outcome.replay, messages)

        commit(base:, messages:, head:, need:, outcome:)
      end

      # {Scheduler#evaluate} is the PURE half of the policy and never reads the
      # combinator its scheduler was built around, which is what lets the timing
      # question be asked BEFORE this turn's derivation exists -- so the unit
      # stands in for the pipeline that has not been decided on yet.
      #
      # Asking it first is not a micro-optimization. A derivation writes ~22
      # objects into the Store and journals an edge, and paying that on every
      # warm-under-cap turn -- the steady state once the byte threshold is
      # crossed -- would fill the experiment record with derivations no render
      # ever used, on top of asking a model-backed strategy for summaries
      # nothing reads.
      def timely?(need, head)
        scheduler_for(Context::Identity).evaluate(need:, cold: @cold.cold?,
                                                  history_size: head.bytesize).compact?
      end

      def defer(base:, need:, head:, outcome: Derived::Outcome::NOTHING, would_not_shrink: false)
        record(need:, head:, compacted: false, outcome:, would_not_shrink:)
        base
      end

      # The floor: a rewrite that would not SHRINK the rendered history is
      # refused however loudly the signals fired -- and it now measures the
      # DERIVED chain's own projection, which is the very array a render will
      # send, rather than a second computation of it.
      #
      # Measured 2026-07-25: {SummarySnapshot}'s per-message attestation (role,
      # digest, byte counts, a line per block) costs ~230 bytes, so over small
      # messages the summary is BIGGER than what it replaces -- six of them go
      # 571 -> 1,144 bytes -- and it breaks the cache prefix to do it. That is
      # not a hypothetical: {Need::PlanStepCompletion} is a plain boolean
      # independent of history size, so a completed plan step on a short history
      # with a cold cache reaches it in an ordinary chat, with compaction on by
      # default.
      #
      # It asks the real question rather than a proxy for it -- the very rewrite
      # that would ship, measured -- at the price of two `Canonical.dump`s, paid
      # only on a turn the scheduler has already committed to (see {#weigh}).
      #
      # STRICT: a byte-NEUTRAL rewrite is declined too. It buys nothing and
      # still breaks the cache prefix, so `<=` would be a rewrite that costs a
      # full cache write to change nothing. Pinned at the crossover, byte for
      # byte, in the spec.
      def shrinks?(replay, messages)
        Canonical.dump(replay.call(messages)).bytesize < Canonical.dump(messages).bytesize
      end

      # `head.messages` to {Need} (a {Head} itself is not dumpable), the WHOLE
      # message list to {Scheduler} (its accounting re-slices whatever it is
      # handed, so a head would journal a before/after for a head OF the head),
      # and `head.bytesize` for the hard-cap comparison rather than a third
      # `Canonical.dump` of bytes already measured.
      #
      # The scheduler answers `base` ITSELF when it defers, so identity -- not
      # equivalence -- is what decides whether this turn's Context is a copy.
      # `compacted:` is READ back off the pipeline rather than assumed from
      # {#timely?}: `#pipeline` re-runs the same pure evaluation, so it will
      # agree, but the flag is journaled and a record claiming a rewrite that
      # did not ship would be a corrupted measurement, not a stale comment.
      # `ran_under:` is `base.model` off the LIVE Context -- the same read
      # {#window_for} makes, and the other half of the pair C1 opened. The
      # scheduler is priced for `@model` at CONSTRUCTION, so naming what is
      # actually answering is what lets it refuse a stale quote after a
      # `/model` switch rather than journal opus dollars for a sonnet turn.
      def commit(base:, messages:, head:, need:, outcome:)
        provider = BASE_PROVIDER.call(flattened_twin(base))
        pipeline = scheduler_for(outcome.replay).pipeline(need:, cold: @cold.cold?, history_size: head.bytesize,
                                                          base: provider, messages:, ran_under: base.model)
        compacted = !pipeline.equal?(provider)
        record(need:, head:, compacted:, outcome:)
        compacted ? base.with_pipeline(pipeline) : base
      end

      # The MAIN chat Context is deliberately not `Ractor.shareable?`: `/model`
      # writes a live {Context::ModelSwitch} into its model slot, which is
      # mutable by design and says so (model_switch.rb:20-22). A provider
      # closing over THAT therefore fails {Scheduler::COMPOSE}'s
      # `make_shareable` on the first compacting turn of every real `lain chat`
      # -- found by wiring this live (A8), invisible to a spec that builds a
      # plain Context.
      #
      # The render pipeline does not depend on the model: `#pipeline_for` never
      # reads it, and both Contexts report the same `#requires`. So the PROVIDER
      # is built from a twin whose slot is flattened to a frozen
      # {Context::StaticModel}, while the pipeline is applied to the LIVE base
      # (see {#commit}), which keeps `/model` switchable from the next turn on.
      # Shareability is established, not skipped.
      def flattened_twin(base) = base.with_model(base.model)

      # `summary_hits`/`summary_misses` are the collapse POLICY's, not a
      # snapshot's. The un-flagged policy reads the eager tier through this
      # turn's {SummarySnapshot} and reports exactly what it did before; a
      # model-backed strategy reports its OWN content-address hit rate, which is
      # the count a mis-keyed address is invisible in except as a number that
      # never rises. A policy holding nothing reports honest zeros.
      def record(need:, head:, compacted:, outcome:, would_not_shrink: false)
        @journal << CompactionDecision.new(compacted:, signals: need.signals, head_bytes: head.bytesize,
                                           summary_hits: outcome.hits, summary_misses: outcome.misses,
                                           cold: @cold.cold?, would_not_shrink:)
      end

      # A fresh Scheduler per turn, because the combinator it is frozen around
      # is this turn's. Both are cheap frozen values.
      def scheduler_for(compact)
        Scheduler.new(compact:, hard_cap: @hard_cap, journal: @journal, model: @model, price_book: @price_book)
      end

      # The base render strategy as a `->(workspace)` provider, asked of the
      # Context PER RENDER.
      #
      # `#pipeline_for` and nothing else: `base.class.pipeline(workspace)`
      # silently discards an injected pipeline, and a hand-rolled stand-in that
      # omits {Context::Reminder} drops the session's live reminders from every
      # compacting render with nothing failing -- the composed `#requires` is a
      # union, so it still reports the same capabilities.
      #
      # A provider rather than the combinator `#pipeline_for` returns, because a
      # raw combinator would freeze whatever Workspace it was built around, and
      # Reminder must see the LIVE one (see {Context#initialize}'s warning).
      #
      # A module-scope lambda, for the reason {Scheduler::COMPOSE} spells out: a
      # Proc built inside an instance method captures that instance as its
      # `self`, which would carry this object -- its live Eager, its Cold, its
      # journal -- into the pipeline and fail `Ractor.make_shareable`. Here
      # `self` is the Source CLASS, and the frozen `base` arrives as an argument.
      BASE_PROVIDER = lambda do |base|
        Ractor.make_shareable(->(workspace) { base.pipeline_for(workspace) })
      end
      private_constant :BASE_PROVIDER
    end
  end
end

# AFTER the class body, the placement rule `effect/handler.rb` follows: {Derived}
# reopens {Lain::Compaction::Source} and names {Source::DerivationRefused}, so
# the class it hangs off has to exist first.
require_relative "source/derived"
