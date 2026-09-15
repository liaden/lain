# frozen_string_literal: true

module Lain
  module Compaction
    # The live {Agent::PipelineSource}: which Context THIS turn renders through.
    #
    # OBSERVE feeds {Cold} its two signals by different routes because they
    # exist at different moments: the idle gap is measured at render time off
    # the injected clock, while the cache-read count exists only on a model
    # RESPONSE, which the render seam never sees (`context_for`'s `usage:` is
    # the last-turn INPUT token count, an Integer, not the usage Hash
    # {Cold#observe} reads). So this is also a `#<<` sink, the duck
    # {StatusFeed} answers, riding the same journal fan-out.
    #
    # DECIDE is one pass: candidate head, {Need}, {Scheduler}, and only then
    # this turn's derivation. It answers the base Context ITSELF on a defer --
    # byte-identical, not merely equivalent, which is the whole DEFER contract.
    #
    # A compacting turn renders a DERIVED chain rather than a render-time
    # projection: {Derived} materializes a second lineage in the Store and
    # substitutes its projection as the rendered messages, so the session
    # timeline stays the lossless record and advances only by committed turns.
    # Substituting MESSAGES rather than handing `#render` a different timeline
    # is load-bearing -- a strategy may hold a live oracle and a mutable memo,
    # and {Scheduler::COMPOSE}'s `Ractor.make_shareable` would deep-freeze that
    # graph in SILENCE. The derivation therefore runs here, off the pipeline,
    # and only a frozen array of finished messages crosses into it.
    #
    # A committed compaction is HELD. The session records its cut -- the
    # source digest it collapsed up to, the head it was committed at, and each
    # newly collapsed range's replacement -- and every later turn derives from
    # the source root with those ranges held at their recorded bytes, so a
    # signal that clears renders the same replacement rather than the full
    # history, and the prefix a provider caches stops moving. A cut advances
    # only when a later compaction commits past it, and retreats when the
    # head's chain stops containing its commit head ({HeldCut}).
    #
    # This object is NOT `Ractor.shareable?` and must not become so: it holds
    # the mutable {Cold} and the live {Oracle::Eager}. What it hands BACK is
    # shareable, and {SummarySnapshot} keeps the two compatible -- the
    # summaries riding into the derivation are a frozen copy of what the Eager
    # held, never the Eager.
    class Source
      # The per-turn decision, journaled on EVERY turn including a deferring
      # one. Nothing reports this choice back to `Agent#render_request`, so
      # this record is the only trace it happened -- and on a bench whose
      # deliverable is comparability, an unrecorded decision is a missing
      # measurement. {Scheduler} journals the richer accounting, but only when
      # it compacts.
      #
      # `would_not_shrink` names the one refusal a reader could not otherwise
      # tell from a plain defer: the signals fired, the scheduler said now, and
      # the rewrite would not have made the prompt smaller. Not `would_inflate`
      # -- {Scheduler::Rewrite#shrinks?} asks for a strict saving, so a
      # byte-NEUTRAL rewrite is declined too, and calling that inflation would
      # be a claim the measurement never made.
      #
      # `nothing_droppable` names the other unreadable defer: `#decide` returns
      # before {Need} is even consulted when {Head#empty?}, so a signal that
      # fired reads back as `signals: []` exactly like a turn nowhere near
      # threshold, and `ctx 100%` cannot be told from `ctx 100% and nothing
      # left to cut`. Set from {Head#empty?} alone, on every decision including
      # a compacting one, so the field says what it always could have said
      # rather than only on the turns a reader happens to suspect.
      #
      # `window_tokens`/`used_tokens` are the denominator and the numerator
      # `:approaching_window` fired (or did not) on; without them a journal
      # from an ollama run reading `approaching_window` every turn was
      # indistinguishable from a genuinely full context. `used_tokens` is nil
      # before any turn carries usage, which is absence and not zero.
      #
      # `provenance` is a FIELD rather than an inference because a GUESSED
      # window withdraws `:approaching_window` before this record is written,
      # so the signal list alone cannot tell a DENIED trigger from one that
      # never fired. Measured: `qwen3:4b` at 7,500 used against a guessed 8,192
      # (92% full, denied) and `claude-opus-4-8` at 7,500 against a published
      # 1,000,000 (0.75% full, nothing warranted) journal an IDENTICAL
      # `signals: []`. It also names the one place a human-facing surface
      # disagrees with the record: the HUD clamps and shows `ctx:92%` on that
      # same turn while compaction can never fire.
      CompactionDecision = Data.define(:compacted, :signals, :head_bytes,
                                       :summary_hits, :summary_misses, :cold, :would_not_shrink,
                                       :window_tokens, :used_tokens, :provenance, :nothing_droppable) do
        include Telemetry::Journalable
      end

      # Null Object for the summary store: a run with no oracle wired takes a
      # snapshot of honest MISSES and renders pure elision lines.
      module NoSummaries
        module_function

        def held(_digest) = nil
      end

      # WHAT collapses a span this run, and what to CALL the arm it makes.
      #
      # One value in one slot rather than two arguments, for a measured reason:
      # {CLI::Backend} sits AT the `Metrics/ClassLength` cap, so
      # `--compact-strategy`'s own string cannot reach here as a second keyword
      # (CLAUDE.md: extract, never loosen a Max). It has to reach here at all
      # because the {Scheduler} that journals a compaction is handed a PIPELINE
      # rather than a policy, and so can name neither.
      #
      # `name` is NEVER NIL: an unflagged run is not "no arm", it is the CONTROL
      # arm, named {Telemetry::Compaction::EAGER_CONTROL_ARM}. nil would fold
      # the control arm into "a record written before this field existed", the
      # one thing {Telemetry::Compaction}'s nil is reserved for.
      #
      # SHALLOW-frozen, and not a `Data`, because of what it carries.
      # `Ractor.shareable?` would have to deep-freeze the policy, and
      # {Strategy::Summarizing} holds a live oracle and a mutable memo that must
      # never be frozen. `Data` is refused separately: a `Data.define ... do`
      # block's body counts toward {Source}'s own `Metrics/ClassLength` where a
      # nested class counts as one line. Neither costs anything real -- nothing
      # compares two of these, and the one member that outlives construction,
      # `name`, is a frozen interned String.
      class Collapse
        # @param value [Collapse, Strategy::Base, nil] a choice, a bare
        #   strategy from a caller with a policy but no word for it, or nil
        #   from a caller that named no arm at all
        # @return [Collapse]
        def self.of(value) = value.is_a?(self) ? value : new(policy: value)

        # The name is interned for {Strategy::Base#name}'s reason: an anonymous
        # class's `to_s` is a freshly built MUTABLE String, and this one is read
        # back into a journalled record.
        def initialize(policy: nil, name: nil)
          @policy = policy
          @name = -(name || policy&.name || Telemetry::Compaction::EAGER_CONTROL_ARM).to_s
          freeze
        end

        attr_reader :policy, :name
      end

      # A turn whose derived chain the Messages API would have rejected, and
      # the uncompacted render it fell back to.
      #
      # ITS OWN TYPE rather than a {Telemetry::ContextDerived} carrying empty
      # `spans`: that record's `cut` field exists precisely to make an empty
      # collapse readable, and a fallback wearing a derivation's badge would put
      # back the ambiguity it was added to destroy.
      #
      # `consecutive` is what keeps this from being the silent-stop mode
      # wearing a badge. A deterministic strategy over a stable history refuses
      # IDENTICALLY every turn -- one refusal is an awkward history, forty in a
      # row is a session that has stopped compacting. See {Derived} for why the
      # streak is journalled rather than raised on.
      DerivationRefused = Data.define(:strategy, :violations, :consecutive) do
        include Telemetry::Journalable
      end

      # How long since the cache was last touched, extracted so the Source
      # holds a measurement rather than a raw `Time` and an ivar it has to keep
      # in step by hand.
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

      # How this run prices a compaction and when it must have one: everything
      # a {Scheduler} is built from except the pipeline it schedules.
      #
      # Its own object because those four values are one decision read at one
      # site, and because {Source#initialize} sits AT the
      # `Metrics/MethodLength` cap, which CLAUDE.md answers with an extraction
      # rather than a raised Max. `Integer(hard_cap)` stays at CONSTRUCTION: a
      # mis-wired cap must fail where it was wired and not on the first
      # compacting turn of a live chat, the same rule `keep_last` keeps.
      class Scheduling
        def initialize(hard_cap:, journal:, model:, price_book:)
          @hard_cap = Integer(hard_cap)
          @journal = journal
          @model = model
          @price_book = price_book
        end

        # @param compact [#call] this turn's pipeline combinator
        # @return [Scheduler]
        def call(compact)
          Scheduler.new(compact:, hard_cap: @hard_cap, journal: @journal, model: @model, price_book: @price_book)
        end
      end
      private_constant :Scheduling

      # Is this session STALLED -- a compaction it was told to want, and
      # nothing it can do about it -- on what evidence, and what a human gets
      # told. Its own value rather than two predicates inside {Reporting}
      # because the question is answerable independently of the routing, and a
      # truth reachable only through the object that routes it can only be
      # tested through that object.
      #
      # ONLY `:approaching_window` counts as warrant, and the narrowness is the
      # whole point. {Need} runs four detectors and three of them say nothing
      # about how full the window is -- {Need::PlanStepCompletion} in
      # particular is a plain boolean independent of history size, which
      # {Source#weigh} says "reaches it in an ordinary chat, with compaction on
      # by default". Keyed on any signal, a three-turn session using 10 of
      # 1,000,000 tokens is told its context is full on every completed plan
      # step.
      #
      # Keying on that one signal also makes the guessed-window guarantee
      # STRUCTURAL. {Source#need_for} withdraws `:approaching_window` when the
      # denominator was guessed, but the withdrawal is scoped to that signal
      # and not to this report: a second detector firing over the same turn
      # would otherwise quote {ContextWindow::CONSERVATIVE_FALLBACK}'s 8,192 at
      # a human as though it were the model's window, which is the defect that
      # withdrawal exists to prevent, one surface further out.
      class Diagnosis
        # @param decision [CompactionDecision] this turn's, as it is journalled
        # @param head [Head] the span it was taken over, asked for
        #   {Head#declined?} alone -- the one cause of an empty head this
        #   object can ESTABLISH rather than guess
        # @return [Diagnosis]
        def self.of(decision:, head:) = new(decision:, declined: head.declined?)

        def initialize(decision:, declined:)
          @decision = decision
          @declined = declined
          freeze
        end

        # @return [CompactionDecision] what the journal is owed regardless
        attr_reader :decision

        # @return [Boolean]
        def stalled? = @decision.nothing_droppable && warranted?

        # What an operator is told. Two clauses and a remedy, because the
        # report is useless without the last one: a human reading "nothing can
        # be compacted" still has to guess between unpinning, `--compact-keep`
        # and starting over.
        #
        # @return [String]
        def line = "compaction is warranted (#{@decision.signals.join(", ")}) #{cause}. #{occupancy}; #{remedy}"

        private

        def warranted? = @decision.signals.include?(Need::ApproachingWindow::KIND)

        # {Head#empty?} is true for FOUR unrelated reasons and this object can
        # only establish one of them. A declined boundary says so itself; the
        # other three -- a history shorter than `keep_last`, a droppable span
        # every message of which was pinned, and a history a held compaction
        # cut has already collapsed up to keep_last -- are indistinguishable
        # from a {Head}, which exposes no count of what it had before the pin
        # filter or the cut. So they are named as the disjunction they are.
        # Asserting any one would be a sentence the measurement does not
        # support, and the pinned case is the one whose remedy the others
        # point away from.
        #
        # A decline is unreachable through a {Derivation} today ({Boundary}
        # argues why), so that clause is written for a {Head} taken over a raw
        # history rather than for a shape this path is expected to meet.
        def cause
          return "but the boundary declined the only legal cut -- it would split a tool-use pair" if @declined

          "and nothing is droppable -- every earlier turn is inside keep_last, pinned, or already compacted"
        end

        # `--` for an unmeasured numerator is {ContextWindow::Occupancy}'s own
        # render of absence, which is not zero.
        def occupancy = "#{@decision.used_tokens || "--"}/#{@decision.window_tokens} tokens"

        def remedy
          return "lower --compact-keep so the cut falls clear of the pair, or start a new session" if @declined

          "unpin a turn, lower --compact-keep, or start a new session"
        end
      end

      # Where a turn's decision goes, to both of its audiences: the journal
      # takes EVERY decision -- an unrecorded one is a missing measurement --
      # while an operator is told only when the fact changes.
      #
      # Holding that difference is why this is an object rather than two ivars.
      # {Source} decides per turn and records unconditionally, so it has no
      # place to remember that a human has already been told, and repeating one
      # line every turn of a stuck session is how a line that matters becomes
      # one a human scrolls past. Latched on the EDGE and re-armed when the
      # condition clears rather than counted: a session that recovers and
      # stalls again is two separate facts worth one line each.
      #
      # It decides nothing and words nothing -- {Diagnosis} owns both.
      class Reporting
        def initialize(journal:, sink:)
          @journal = journal
          @sink = sink
          @stalled = false
        end

        # @param diagnosis [Diagnosis] this turn's
        # @return [self]
        def record(diagnosis)
          @journal << diagnosis.decision
          stalled = diagnosis.stalled?
          @sink.puts(diagnosis.line) if stalled && !@stalled
          @stalled = stalled
          self
        end
      end
      private_constant :Reporting

      # The run's shared summary store; readable so callers can check they hold
      # the same one the tool observer fires into.
      attr_reader :eager

      # The arm this run collapses spans under, by the name a bench groups on.
      # Read by whoever journals a compaction, since the {Scheduler} that
      # writes the record is handed a pipeline and cannot name the policy.
      #
      # @return [String] frozen, and never nil -- see {Collapse}
      attr_reader :collapse_strategy

      # @param need [Need] the detector bank; owns the byte threshold and the
      #   approaching-window RATIO, so this object never restates either
      # @param cold [Cold] cache-warmth state, fed by {#<<} and {#observe_idle}
      # @param hard_cap [Integer] the history size, in {Head#bytesize}'s byte
      #   proxy, that forces a compaction even while the cache is warm
      # @param keep_last [Integer] trailing messages kept verbatim -- the ONE
      #   number {Head} and {Context::Compact} must agree on. Checked HERE
      #   against {Compaction.validate_keep_last} (a keep_last of 0 makes a
      #   derivation replace the ENTIRE history with a summary of nothing), so
      #   a bad wiring fails at construction rather than on the first turn of a
      #   live chat. The validated number is then held by {Derived} and asked
      #   back for the {Head}, never kept in a second ivar here: the {Boundary}
      #   the derivation cuts at and the {Head} {Need} measures must come from
      #   the SAME keep_last, and two copies is how they drift.
      # @param eager [#held] the live summary store; the Null holds nothing
      # @param strategy [Collapse, Strategy::Base, nil] which policy collapses
      #   a span. nil is the un-flagged wiring, which collapses into the run's
      #   own eager tier -- see {Derived}. Injected ONCE, never fetched per
      #   turn: a model-backed strategy holds a memo whose absence turns one
      #   range's two questions into two model calls.
      # @param journal [#<<] where the decision lands; the Null channel by
      #   default, so no caller guards `if journal`
      # @param model [String, nil] priced for {Scheduler}'s cost accounting
      # @param price_book [PriceBook] how `model`'s usage becomes dollars
      # @param clock [#call] answers the current Time. Injected, never read
      #   inline: `Time.now` in the render path would make a replayed run
      #   non-deterministic, the same reason {StatusFeed} takes one.
      # @param context_window [#resolve] the window book {#decide} asks about
      #   the LIVE model each turn. The default degrades to a conservative
      #   fallback for a model no Anthropic-shaped table carries (`ollama`,
      #   `ollama`); a blank model still raises there, which is a wiring bug
      #   rather than a provider. A live chat is handed
      #   {CLI::Backend#context_window} instead -- the SAME instance
      #   {Agent#occupancy} and the {StatusFeed} divide by, so this record's
      #   threshold and the figure a human reads are one calculation.
      # @param sink [Lain::Sink] where an operator is told that a warranted
      #   compaction had nothing to drop. The Null sink by default, so a
      #   headless caller writes no guard and changes no bytes. It arrives HERE
      #   rather than staying with the collapse policy because {Head}
      #   disclaims the judgement and {Boundary} refuses to raise: this is the
      #   only object holding the head, the need and the occupancy at once.
      def initialize(need:, cold:, hard_cap:, keep_last:, eager: NoSummaries, strategy: nil,
                     journal: Channel::Null.instance, model: nil, price_book: PriceBook.default,
                     clock: -> { Time.now }, context_window: ContextWindow.default, sink: Sink::Null.new)
        arm = Collapse.of(strategy)
        @need = need
        @context_window = context_window
        @cold = cold
        @eager = eager
        @reporting = Reporting.new(journal:, sink:)
        @collapse_strategy = arm.name
        @idle = IdleGap.new(clock:)
        @scheduling = Scheduling.new(hard_cap:, journal:, model:, price_book:)
        @derived = Derived.new(keep_last: Compaction.validate_keep_last(keep_last), strategy: arm.policy, journal:)
      end

      # The observe half's response leg. A turn's own usage carries the
      # `cache_read_input_tokens` count {Cold} reads and nothing on the render
      # seam does, so this rides {CLI::JournalTee} as one more fan-out leg and
      # recognizes its event by duck rather than by class (see {#turn_usage?}).
      #
      # @param event [Object] anything from the journal; unrecognized events are
      #   inert, since a fan-out leg is fed everything
      # @return [self]
      def <<(event)
        return self unless turn_usage?(event)

        @cold.observe(event)
        # Measured from HERE, not from the last render, which would fold the
        # model round trip into the gap.
        @idle.touch
        self
      end

      # {Agent::PipelineSource}'s duck.
      #
      # @param base [Context] the Agent's own Context
      # @param timeline [Timeline] the history as of this render
      # @param usage [Integer, nil] the LAST-TURN input tokens -- nil before any
      #   turn, which {Need::ApproachingWindow} distinguishes from zero. A
      #   cumulative total here would latch the signal on permanently, and a
      #   zero would read as an empty context on a resumed session.
      # @param session [Session] the run's Session, for its plan-step signal
      #   and the compaction cuts it has recorded -- and records a new one
      # @return [Context] `base` itself, or a copy carrying this turn's pipeline
      def context_for(base:, timeline:, usage:, session:)
        observe_idle
        held_cut = HeldCut.on(session:, timeline:, derived: @derived, arm: @collapse_strategy)
        decide(base:, held_cut:, usage:, session:, pins: pinned(held_cut.walk, session))
      end

      private

      # `#usage` ALONE is not the duck: {Telemetry::OracleAnswer} answers it
      # too and its usage Hash carries no cache fields, so a landed oracle
      # answer would read as a zero cache-read and confirm a WARM cache cold
      # (verified 2026-07-25). A record that also names why the model stopped
      # is a turn's.
      def turn_usage?(event) = event.respond_to?(:usage) && event.respond_to?(:stop_reason)

      # Only ever a PENDING mark: the next zero cache-read confirms or cancels
      # it (see {Cold}), and it is a no-op on a TTL-less provider.
      def observe_idle = @cold.idle!(@idle.elapsed)

      # The pin-set, translated once. A pin is a turn DIGEST and
      # {Context::Compact} only ever sees projected TEXT -- a turn's content
      # address folds `meta` and `causal_parents` that no projection carries,
      # so hashing the projection instead misses every lookup in silence. This
      # is the only object holding both the timeline and the session, and
      # making the mapping ONCE is what stops {Head} and the Compact naming
      # different messages.
      #
      # `#pinned?` and never `#pins`: the latter sorts the whole set on every
      # call and this is a per-turn membership test.
      def pinned(walk, session)
        Context::PinnedMessages.new(
          walk.turns.zip(walk.messages).filter_map { |turn, message| message if session.pinned?(turn.digest) }
        )
      end

      # Is a compaction warranted at all? Emptiness is asked for with `#empty?`,
      # never a zero byte count: an empty Head measures 2, the bytes of `"[]"`.
      # With nothing droppable there is no compaction whatever the signals say
      # -- which is also how a history whose every droppable turn is PINNED
      # declines here rather than reaching Compact's empty-summarizable path
      # and paying a cache break for {SummarySnapshot::NOTHING}.
      #
      # The occupancy is built AFTER {Need#check}, off the same two numbers,
      # so that `check`'s own `window!` guard reports a wiring bug in terms of
      # the parameter it names. {Need::ApproachingWindow} measures this exact
      # value internally, so what travels on to {#record} is what the signal
      # was decided on.
      #
      # The head is taken past the held cut: what a cut already collapsed is
      # not droppable again, so a threshold measures only what it has not.
      def decide(base:, held_cut:, usage:, session:, pins:)
        head = Head.new(messages: held_cut.remaining, keep_last: @derived.keep_last, pins:)
        resolution = window_for(base)
        need = need_for(head:, usage:, session:, resolution:)
        occupancy = ContextWindow::Occupancy.of(used_tokens: usage, window_tokens: resolution.window_tokens)
        provenance = resolution.provenance
        return defer(base:, held_cut:, need:, head:, occupancy:, provenance:) if head.empty? || !need.needed?

        weigh(base:, held_cut:, head:, need:, pins:, occupancy:, provenance:)
      end

      # Which signals fired AND are allowed to have fired -- one question, so
      # one method. {Need} answers the first half from the numbers it is given;
      # only the caller holding the window book can answer the second, because
      # only it knows whether the denominator was measured, published or
      # guessed. (Splitting the two across {#decide} tripped Metrics/AbcSize,
      # which was naming this method rather than asking for a raised limit.)
      #
      # `:approaching_window` is the one signal whose whole content is a
      # comparison against a number the bench may have INVENTED, and what it
      # buys is an irreversible lossy rewrite of the run's own history. A
      # guessed denominator therefore does not get to fire it: QA watched a
      # real 32,768-token qwen3 runner read as ~300% full against
      # {ContextWindow::CONSERVATIVE_FALLBACK}'s 8,192 and lain rewrite its
      # history three times, at 75-78% of the window it actually had.
      #
      # ONLY the guess. A shipped-table hit is a real published number
      # ({Provider#context_window_tokens} is nil for every provider but
      # ollama), so suppressing that too would switch compaction off for every
      # Anthropic arm in silence, taking {Scheduler#forced?} with
      # it. And it is withdrawn HERE rather than inside {Need}, because giving
      # detector state a second field for who vouched for the window would make
      # every `#fired?` a place provenance could be read. What is withdrawn is
      # still RECORDED: {#record} journals the provenance on every decision, so
      # a denied signal is legible rather than merely absent.
      def need_for(head:, usage:, session:, resolution:)
        need = @need.check(head_bytes: head.bytesize, used_tokens: usage,
                           window_tokens: resolution.window_tokens,
                           plan_step_completed: PlanSteps.pending?(session))
        resolution.authoritative? ? need : need.without(Need::ApproachingWindow::KIND)
      end

      # Off the LIVE Context, every turn, never captured at construction:
      # `/model` writes into {Context::ModelSwitch}'s slot mid-session, so a
      # window resolved once at startup would go on measuring occupancy against
      # the model the run began with -- and an over-estimate is the failure
      # that never fires rather than the one that fires early.
      #
      # A blank model raises here rather than degrading to a threshold nobody
      # chose; it is a wiring bug, and this bench fails loudly on one.
      #
      # A {ContextWindow::WindowResolution} and not the bare Integer, because
      # the number alone cannot say whether it was measured, published or
      # guessed -- see {#need_for}.
      #
      # @return [ContextWindow::WindowResolution]
      def window_for(base) = @context_window.resolve(base.model)

      # Then WHEN, and only then WHETHER IT HELPS. {Scheduler#evaluate} is pure
      # and journals nothing, so asking it first settles the whole
      # warm-under-cap band -- the steady state once the byte threshold is
      # crossed -- before the floor's measurement is paid for. Both halves
      # matter: the floor's `Compact#call` and two dumps measured 3.6 ms on an
      # 84 KB history, wasted on every turn the scheduler was going to defer
      # anyway, and a turn deferred on TIMING would have been journaled as an
      # inflation refusal, over-counting the refusals a bench reads by the
      # whole warm-defer population.
      #
      # THE FLOOR is the last of the three questions: a rewrite that would not
      # SHRINK the rendered history is refused however loudly the signals
      # fired. It measures the DERIVED chain's own projection -- the very array
      # a render will send -- through the scheduler that would journal it, so
      # the refusal and the accounting read one {Scheduler::Rewrite}.
      #
      # Measured 2026-07-25: {SummarySnapshot}'s per-message attestation (role,
      # digest, byte counts, a line per block) costs ~230 bytes, so over small
      # messages the summary is BIGGER than what it replaces -- six of them go
      # 571 -> 1,144 bytes -- and it breaks the cache prefix to do it. Not a
      # hypothetical: {Need::PlanStepCompletion} is a plain boolean independent
      # of history size, so a completed plan step on a short history with a
      # cold cache reaches it in an ordinary chat, with compaction on by
      # default.
      #
      # Once a cut holds, the rewrite is measured against the HELD render and
      # not the full history, which any cut already beats: an advance has to
      # shrink what the turn would otherwise send. The held render is taken
      # FIRST, so on a turn that advances, the last edge journaled is the chain
      # the turn actually sends.
      def weigh(base:, held_cut:, head:, need:, pins:, occupancy:, provenance:)
        return defer(base:, held_cut:, need:, head:, occupancy:, provenance:) unless timely?(need, head)

        unadvanced = held_cut.messages
        snapshot = SummarySnapshot.take(messages: head.messages, eager: @eager)
        outcome = @derived.over(held_cut.timeline, walk: held_cut.walk, pins:, snapshot:, cut: held_cut.seam)
        return defer(base:, held_cut:, need:, head:, occupancy:, provenance:, outcome:) if outcome.refused?

        scheduler = scheduler_for(outcome.replay)
        rewrite = scheduler.measure(unadvanced)
        unless rewrite.shrinks?
          return defer(base:, held_cut:, need:, head:, occupancy:, provenance:, outcome:, would_not_shrink: true)
        end

        commit(base:, held_cut:, head:, need:, outcome:, scheduler:, rewrite:, occupancy:, provenance:)
      end

      # {Scheduler#evaluate} is the PURE half of the policy and never reads the
      # combinator its scheduler was built around, which is what lets the
      # timing question be asked BEFORE this turn's derivation exists -- so the
      # identity pipeline stands in for one not yet decided on.
      #
      # Not a micro-optimization: a derivation writes ~22 objects into the
      # Store and journals an edge, and paying that on every warm-under-cap
      # turn would fill the experiment record with derivations no render ever
      # used, on top of asking a model-backed strategy for summaries nothing
      # reads.
      def timely?(need, head)
        scheduler_for(Context::Identity).evaluate(need:, cold: @cold.cold?,
                                                  history_size: head.bytesize).compact?
      end

      # A turn that compacts no FURTHER still renders the cut that holds: the
      # base itself only while none does.
      def defer(base:, held_cut:, need:, head:, occupancy:, provenance:, outcome: Derived::Outcome::NOTHING,
                would_not_shrink: false)
        record(need:, head:, compacted: false, outcome:, occupancy:, provenance:, would_not_shrink:)
        holding(base, held_cut)
      end

      # `head.bytesize` to {Need} and to the hard-cap comparison -- the count
      # {Head} took when it sliced the span, never a second `Canonical.dump` --
      # and the WHOLE history's measurement to {Scheduler}, whose accounting
      # reports the before/after a render actually sends rather than a head OF
      # the head.
      #
      # The scheduler answers `base` ITSELF when it defers, so identity -- not
      # equivalence -- decides whether this turn's Context is a copy.
      # `compacted:` is READ back off the pipeline rather than assumed from
      # {#timely?}: the two agree, but the flag is journaled, and a record
      # claiming a rewrite that did not ship is a corrupted measurement.
      #
      # `ran_under:` is `base.model` off the LIVE Context, because the
      # scheduler is priced at CONSTRUCTION for the model {Scheduling} was
      # built with -- naming what is actually answering is what lets it refuse
      # a stale quote after a `/model` switch rather than journal opus dollars
      # for a sonnet turn. `collapse_strategy:` rides beside it for the mirror
      # reason: the scheduler is handed a PIPELINE and can name no policy, so
      # the accounting can be grouped by arm with no launch command to hand.
      #
      # The advance is recorded only HERE, once this turn's pipeline is chosen:
      # a summary that failed collapsed nothing and cannot shrink the render,
      # so no cut exists until its replacement text does.
      def commit(base:, held_cut:, head:, need:, outcome:, scheduler:, rewrite:, occupancy:, provenance:)
        provider = BASE_PROVIDER.call(flattened_twin(base))
        pipeline = scheduler.pipeline(need:, cold: @cold.cold?, history_size: head.bytesize,
                                      base: provider, rewrite:, ran_under: base.model,
                                      collapse_strategy: @collapse_strategy)
        compacted = !pipeline.equal?(provider)
        record(need:, head:, compacted:, outcome:, occupancy:, provenance:)
        return holding(base, held_cut) unless compacted

        held_cut.advance(outcome)
        base.with_pipeline(pipeline)
      end

      # The held render onto the live base, through the same flattened twin a
      # compacting turn composes over, and WITHOUT a {Scheduler}: nothing was
      # decided this turn, so there is no compaction for one to journal.
      def holding(base, held_cut)
        held = held_cut.outcome
        return base if held.refused?

        base.with_pipeline(HOLD.call(held.replay, BASE_PROVIDER.call(flattened_twin(base))))
      end

      # The MAIN chat Context is deliberately not `Ractor.shareable?`: `/model`
      # writes a live {Context::ModelSwitch} into its model slot, which is
      # mutable by design. A provider closing over THAT fails
      # {Scheduler::COMPOSE}'s `make_shareable` on the first compacting turn of
      # every real `lain chat` -- found by wiring this live, invisible to a
      # spec that builds a plain Context.
      #
      # The render pipeline does not depend on the model (`#pipeline_for` never
      # reads it, and both Contexts report the same `#requires`), so the
      # PROVIDER is built from a twin whose slot is flattened to a frozen
      # {Context::StaticModel} while the pipeline is applied to the LIVE base
      # -- which keeps `/model` switchable from the next turn on.
      def flattened_twin(base) = base.with_model(base.model)

      # Built here, judged by {Diagnosis} and routed by {Reporting} -- the
      # record every turn, the operator only when the fact moves.
      #
      # `summary_hits`/`summary_misses` are the collapse POLICY's, not a
      # snapshot's: a model-backed strategy reports its OWN content-address hit
      # rate, which is the only count a mis-keyed address shows up in -- as a
      # number that never rises.
      def record(need:, head:, compacted:, outcome:, occupancy:, provenance:, would_not_shrink: false)
        decision = CompactionDecision.new(compacted:, signals: need.signals, head_bytes: head.bytesize,
                                          summary_hits: outcome.hits, summary_misses: outcome.misses,
                                          cold: @cold.cold?, would_not_shrink:,
                                          window_tokens: occupancy.window_tokens,
                                          used_tokens: occupancy.used_tokens, provenance:,
                                          nothing_droppable: head.empty?)
        @reporting.record(Diagnosis.of(decision:, head:))
      end

      # A fresh Scheduler per turn, because the combinator it is frozen around
      # is this turn's. Both are cheap frozen values.
      def scheduler_for(compact) = @scheduling.call(compact)

      # The base render strategy as a `->(workspace)` provider, asked of the
      # Context PER RENDER.
      #
      # `#pipeline_for` and nothing else: `base.class.pipeline(workspace)`
      # silently discards an injected pipeline, and a hand-rolled stand-in that
      # omits {Context::Reminder} drops the session's live reminders from every
      # compacting render with nothing failing -- the composed `#requires` is a
      # union, so it still reports the same capabilities.
      #
      # A provider rather than the combinator `#pipeline_for` returns, because
      # a raw combinator would freeze whatever Workspace it was built around,
      # and Reminder must see the LIVE one.
      #
      # A module-scope lambda, for the reason {Scheduler::COMPOSE} spells out:
      # a Proc built inside an instance method captures that instance as its
      # `self`, which would carry this object -- its live Eager, its Cold, its
      # journal -- into the pipeline and fail `Ractor.make_shareable`.
      BASE_PROVIDER = lambda do |base|
        Ractor.make_shareable(->(workspace) { base.pipeline_for(workspace) })
      end
      private_constant :BASE_PROVIDER

      # {Scheduler::COMPOSE}'s shape, for a held render no scheduler decided:
      # the replay rides ahead of the base, and it is a module-scope lambda for
      # that constant's reason -- a Proc built in a method would carry this
      # object into a pipeline that must be shareable.
      HOLD = lambda do |replay, provider|
        Ractor.make_shareable(->(workspace) { replay >> Context.combinator_for(provider, workspace) })
      end
      private_constant :HOLD
    end
  end
end

# AFTER the class body: each of these reopens {Lain::Compaction::Source}, and
# {Derived} names {Source::DerivationRefused}, so the class they hang off has
# to exist first.
require_relative "source/derived"
require_relative "source/held_cut"
require_relative "source/plan_steps"
