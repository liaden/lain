# frozen_string_literal: true

require "json"
require "fileutils"
require "time"

module Lain
  # A `#<<` sink -- the duck a {Journal} or {Channel} answers, so it rides
  # {CLI::JournalTee} as one more fan-out leg -- deriving one small state struct
  # for the tmux status-right / TTY prompt / nvim lualine renderers
  # (planning/interface-integration.md § "One state feed, three renderers").
  # {Publication} lands it on disk; deriving and writing change for different
  # reasons. The path resolves through `ProjectDir` and is deliberately NOT in
  # the project: this struct is rewritten every turn, and writing it beside the
  # code left permanent `git status` noise with no ignore path.
  #
  # Every field is JOURNALED or read off the run's own clock -- never an
  # in-process registry, and never a live {Agent}. This object is built in
  # `ChatLaunch#open_chronicle`, BEFORE `Wiring` exists, so a field it could
  # only fill by asking a collaborator that does not yet exist is a field it
  # cannot carry; that constraint is what forced {#bind_store}.
  #
  # * `cache_deadline` -- an absolute instant, never a remaining-seconds count,
  #   because a provider's cache is a SLIDING window refreshed on use: pushing
  #   the deadline is what lets a renderer tick locally with zero poll chatter.
  #   The TTL comes from the injected `cache_profile:`, never a constant, so a
  #   swept provider arm slides its own real window. A turn showing no cache
  #   activity leaves the deadline exactly where it was.
  # * `fleet` -- the digests of every DISTINCT `:spawn` that has not yet been
  #   ended by a record naming it. {Fleet} owns both sides: the keying that
  #   makes a redelivered event a no-op rather than a phantom second entry, and
  #   the lifecycle reading that lets a finished child leave the roster.
  # * `fleet_tree` -- the same spawns as ROWS, each nested under the spawn it
  #   was launched from and carrying its role, its task line, its state, its
  #   turn count and the instant it started. An instant and not an elapsed
  #   count, for `cache_deadline`'s reason: a duration would make this struct
  #   differ from itself once a second. {Fleet} owns the fold, and needs
  #   {Telemetry::ChildProgress} beside the events to do it.
  # * `inbox_count` -- what is still addressed to {Tools::AskHuman::HUMAN} and
  #   not yet named a causal parent by a committed turn. {Inbox} owns the
  #   projection, the fold, and the {Ext::Store} the live carrier's chain resolves
  #   in. Read its doc before touching the count: it is the only field whose
  #   ANSWER needs a collaborator this object cannot be given at construction
  #   (see {#bind_store}), and it is held to the nvim `lain://inbox` buffer's
  #   answer by a parity spec.
  #
  #   THREE CARRIERS NAME THE CONSUMING EDGES and {Inbox}'s doc has them. The
  #   third exists because a question a subagent RELAYED had none at all, and so
  #   stood in the count for the rest of the session.
  # * `occupancy` -- how full the live model's context window the LAST MEASURABLE
  #   turn left it, 0..1, nil until one happens. A turn this feed cannot measure
  #   leaves the previous reading exactly where it was rather than replacing it
  #   with a zero or a nil, so this number is a reading and never a
  #   guess -- {#record_occupancy} argues it, and `unmeasured_turns` is how a
  #   reader tells a fresh one from a stale one. Derived from the SAME
  #   {Telemetry::TurnUsage} the deadline
  #   slides on, because that record names both halves of the ratio.
  #   {Agent#occupancy} answers it from the live Agent's accounting; this sink
  #   cannot ask one, so it asks the same BOOK instead. The two differ only
  #   where the model the provider ANSWERED with differs from the one the
  #   Context was rendered for, which is worth showing rather than hiding.
  #
  #   THIS FRACTION CAN EXCEED 1.0, and the guard against it is NOT the
  #   `UnknownModel` rescue below. {ContextWindow.default} carries
  #   {ContextWindow::CONSERVATIVE_FALLBACK} (8,192), so an unmatched model
  #   divides by 8,192 rather than raising -- every Ollama id and every
  #   ids are unmatched, and a real 32k local window then reads 4.0. The number
  #   published is honest about what the book was asked; it is the RENDERER that
  #   clamps, because "244%" is nonsense on a status bar where "100%" is not. A
  #   deployment that knows its real local window should inject a book with the
  #   right `fallback:`.
  # * `unmeasured_turns` -- how many turns in a ROW have left `occupancy` where
  #   it was because the record could not be measured, zero while it is fresh.
  #   Without it the suppression is invisible: a frozen ratio beside a climbing
  #   `run_tokens` reads as a STUCK context rather than a stale reading, and no
  #   renderer can tell those apart from the ratio alone. Same argument as
  #   `derivation_refusal_streak` below, and a streak for the same reason.
  # * `run_tokens` -- what THIS RUN has SPENT, every billed field of every
  #   {Telemetry::TurnUsage} summed. nil before the first payment, because
  #   "nothing yet" and "billed nothing" are different claims.
  #
  #   A RUN, deliberately not a session: {Session} survives a `--resume` and
  #   this counter does not, so `session_tokens` would have had a resumed
  #   session reading 0 for a conversation that spent half a million.
  #
  #   THIS IS THIS MACHINE'S SPEND ON THIS KEY, not a plan's consumption.
  #   Another client on the same subscription is invisible to it, and no
  #   provider lain talks to publishes a used/remaining pair to reconcile
  #   against (checked for the ollama-cloud arm: the headers carry concurrency
  #   and queue depth, no bucket over time). The HUD labels it `run:` rather
  #   than `usage:` so the label cannot be read as the quota.
  #
  #   SPAWNED CHILDREN'S SPEND IS IN IT, and a tier's is not: it is held to
  #   the tokens `Accounting#spent` holds `--max-tokens` to, and a judge's or a
  #   summary's prompt was never in the chat's context. A one-shot child's
  #   record reaches {#paid_aside} from the session journal through
  #   {ChildPayments}, and moves nothing but this sum and `run_dollars`, since
  #   the window and cache it paid for are not the chat's. An actor child's
  #   payments are not journaled, so once an actor is in the subtree this is
  #   LESS than `Accounting#spent`, which settles the actor's spend all the same.
  # * `run_dollars` -- what this run has spent in dollars, as `--max-cost`
  #   reads it: the chat's turns, its one-shot children's, and every tier
  #   answer, a judge's or a summary's, each priced from its one
  #   `turn_usage` record. nil before the first payment; a decimal string, so
  #   it reads exactly as the dollar refusal does.
  #
  #   {Telemetry::OracleAnswer} counts toward neither field, though it answers
  #   `#usage`: the tier's own `turn_usage` beside it is the payment.
  #   {#turn_usage?} holds what a `#usage` duck once cost.
  # * `approvals_pending` and `waiting` -- read off {Journal::Projection::Waits},
  #   the one fold of open waits this feed and the agent states share; its doc
  #   holds how each wait opens and closes. `waiting` is the approvals plus each
  #   gate and model question still open, a wave counted once.
  #
  #   The approval pair breaks in exactly ONE place. NOT cancellation:
  #   `Async::Stop` descends from `Exception`, not `StandardError`, so a stop
  #   inside the announcement write escapes
  #   {Approval::Parked::Queue#record_evidence} before EITHER record is written.
  #   What breaks it is the queue's `degrade` path, which writes a
  #   `journal_error` instead, and the fold counts that record too.
  # * `agents` -- each agent's state and the most urgent of them, read off the injected
  #   {AgentStates::Tracker}, the one fold of {Journal::Projection::AgentStates} the chat keeps.
  # * `scope` / `approval` / `layers` / `mode_lighter` -- derived from a
  #   {Telemetry::ModeSwitch} by {ModeState}, whose doc holds the reasoning. All
  #   absent until the first switch, and forced to be: {Mode::Switch} journals
  #   nothing at construction, so a guessed `checkout ask` would restate
  #   {CLI::Switchboard}'s seed as though a journal had witnessed it.
  #
  #   THE MODE DERIVATION NEVER RAISES; THE PUBLISH STILL DOES, and the two are
  #   not in tension. {ModeState.lighter_of} rescues an undeclared name's
  #   `ArgumentError` because the {CLI::JournalTee} re-raises a sink's failure,
  #   and drawing a status line must never cost the agent its turn. A failed
  #   WRITE is loud on purpose ({Publication} argues it): swallowing it for
  #   `mode_switch` alone would be incoherent, and swallowing it for every field
  #   is a change to {Publication}'s contract, not to this one.
  #
  #   All four are {#observed}, so a LAYER flip publishes even when neither
  #   axis moved. `/mode +notify` journals `ask -> ask`, so a guard
  #   comparing the axes ALONE would leave a silent HUD while the layer was on.
  # * `elapsed` / `idle` / `since_compaction` -- the run's own measures, read off
  #   the injected {RunClock} as PLAIN DURATIONS in whole seconds. Deliberately
  #   NOT deadlines: `cache_deadline` is absolute precisely so a renderer can
  #   tick it locally, and these are monotonic readings with no such local
  #   meaning. `since_compaction` is nil until something compacts.
  # * `compactions` -- the EVENT half of `since_compaction`'s age, and the only
  #   reason a compaction is publishable at all: see {#observed}.
  # * `derivation_refusal_streak` -- how many derivations in a ROW
  #   {Compaction::Source::Derived} has refused, zero while they succeed. A
  #   STREAK, not a running total: one refusal is an awkward history, a rising
  #   streak is a session that has stopped compacting. ASSIGNED off the record
  #   and never tallied here -- the Source owns the increment and the reset, and
  #   a second tally could only come to disagree with it.
  #
  # Recognizing an event is DUCK-TYPED WHERE THE VOCABULARY IS OPEN and matched
  # by CLASS WHERE IT IS CLOSED, and that split is this file's rule. `#kind` is
  # the open one: any {Ext::Event} answers it and nothing narrows the question to one
  # record. Everything else names a closed set, because a duck over a GROWING
  # namespace is a guess that silently starts catching the wrong record --
  # {#turn_usage?} records the one that was actually shipped and what it cost.
  #
  # The waits are the ONE exception: {Journal::Projection::Waits} matches its
  # closing records by journal type as well, because a reader of a closed file
  # reads them back as {Telemetry::Untyped} and the two readers share the fold.
  #
  # A publish is skipped when the derived state did not change, and the
  # comparison is {#observed} ALONE, never the run's own measures. A clock is
  # not a change: comparing one makes "did anything happen" answer yes once a
  # second forever, which costs a write+rename per second on a busy run and
  # makes the struct useless as a change token for a renderer that redraws on
  # difference -- the failure {ContextWindow::Occupancy::None} documents one
  # layer down, made with a clock instead of an absence.
  class StatusFeed
    # Anthropic's default 5-minute sliding window, used when no caller injects a
    # provider's own `#cache_profile`. Kept here rather than reaching into
    # `Provider::AnthropicReference::CACHE_PROFILE` because this struct depends
    # on the Provider tree for nothing, and one constant is not a reason to
    # start.
    DEFAULT_CACHE_PROFILE = { ttl: 300 }.freeze

    # Spelled again rather than imported from {Tools::AskHuman::HUMAN}: reaching
    # into the Tools tree from this struct would invert the dependency this
    # class actually has, which is none. Both spellings are pinned by spec.
    INBOX_RECIPIENT = "human"

    # {SessionRecord::REWOUND_TYPE}, spelled again for {INBOX_RECIPIENT}'s
    # reason, and pinned by spec: the record that moves the head back, and the
    # one a fold's retreat wears too.
    REWOUND = "rewound"

    # @param path [String] where the state struct is atomically published;
    #   defaults to this project's file under `$XDG_STATE_HOME/lain` via
    #   `ProjectDir#state_path`.
    # @param clock [#call] answers the current Time; injectable so a spec never
    #   races the real clock to compute a deadline.
    # @param cache_profile [Hash, #call] a provider's `#cache_profile`, or a callable answering it; only `:ttl` is
    #   read here, defaulting to {DEFAULT_CACHE_PROFILE}.
    # @param run_clock [RunClock] the RUN's clock, not this object's: the
    #   {CLI::Conductor} records a user prompt on the same instance, so an
    #   `idle` published from a private one would never reset. Defaulted anyway,
    #   so a directly constructed feed still publishes an honest elapsed.
    # @param context_window [#occupancy, #resolve] the book resolving a model name into
    #   the denominator, the same duck {Agent#occupancy} takes.
    # @param agent_states [AgentStates::Tracker] the run's one fold of agent states, fed from the tee
    #   ahead of this sink so a publish carries the state its record made.
    # @param prices [PriceBook] what `run_dollars` prices each payment under, the book the chat's own accounting reads
    # @param store [Ext::Store] where a committed turn's causal chain is resolved --
    #   {Inbox}'s collaborator. Defaulted to an EMPTY one rather than required,
    #   because the live chat has none yet at this object's construction point;
    #   see {#bind_store}.
    def initialize(path: default_path, clock: -> { Time.now }, cache_profile: DEFAULT_CACHE_PROFILE,
                   run_clock: RunClock.new, context_window: ContextWindow.default, store: Dag::Factory.store,
                   agent_states: AgentStates::Tracker.new(clock: run_clock), prices: PriceBook.default)
      @publication = Publication.new(path)
      @prices = prices
      @clock = clock
      @cache_profile = cache_profile
      @run_clock = run_clock
      @context_window = context_window
      @store = store
      @inbox = Inbox.new(store:)
      @agent_states = agent_states
      start_empty
    end

    # Absence where absence is the honest answer (no cache activity yet, no turn
    # yet), a zero only where a count is genuinely zero.
    def start_empty
      @cache_deadline = nil
      @occupancy = nil
      @window_guessed = nil
      @remeasure = -> {}
      @reading_head = nil
      @unmeasured_turns = 0
      @run_tokens = nil
      @run_dollars = nil
      @mode = ModeState::NONE
      @waits = Journal::Projection::Waits.unit
      @compactions = 0
      @derivation_refusal_streak = 0
      @fleet = Fleet.new(clock: @clock)
      @flight = nil
      @tool_names = []
    end
    private :start_empty

    # The machine's own announcement, taken as a listener so a model call or a
    # tool in flight shows before the record that ends it exists. A move that
    # keeps the same kind in flight (a paused turn) keeps its start, so the
    # seconds count does not restart and nothing republishes.
    #
    # @return [void]
    def on_transition(to:, **)
      kind = Agent::TransitionListener::IN_FLIGHT[to]
      @tool_names = [] unless kind == "tool"
      @flight = nil if @flight && @flight["kind"] != kind
      @flight ||= { "kind" => kind, "since" => @clock.call.utc.iso8601 } if kind
      publish_if_changed
    end

    # @return [self] the duck {Agent::Instrumentation} carries as `transition_listener:`
    def transition_listener = self

    # A payment made beside the chat's own turns: a spawned child's, added to
    # `run_tokens` and `run_dollars`, or a tier's, added to `run_dollars` alone.
    #
    # @param event [Telemetry::TurnUsage] a record naming its spawn or a requester other than the agent
    # @return [self]
    def paid_aside(event)
      @run_tokens = @run_tokens.to_i + JournaledUsage.new(event.usage.to_h).total_tokens if event.spawn
      pay(event)
      publish_if_changed
      self
    end

    # @param event [Object] a record this sink recognizes, or anything at all.
    #   The recognized set is the class doc's: six journal records matched by
    #   CLASS, plus the {Approval::Parked::Queue} pair, plus anything answering `#kind`.
    #
    #   WHAT A `#kind`-ANSWERING RECORD OWES BEYOND `#kind`: a `:spawn` owes
    #   `#digest`; a `:message` owes `#to`, `#digest` and `#causal_parents`,
    #   because {Fleet} reads the last of those to retire a finished spawn; a
    #   `:turn` owes `#causal_parents`. Today only {Ext::Event} and
    #   {Telemetry::Message} reach these arms and both answer all of it.
    #
    #   A LOOKALIKE IS NOT ENOUGH for the class-matched six. An object merely
    #   answering `#usage` and `#stop_reason` is silently inert rather than read
    #   as a turn's payment -- deliberately, because reading it as one is the
    #   defect {#turn_usage?} documents. Send the real record.
    # @return [self]
    def <<(event)
      # The RunClock rides this sink rather than the tee directly: it is not
      # published on its own, and the object that publishes its readings is the
      # one that should feed it.
      @run_clock << event
      # Repeats {RunClock#<<}'s class check deliberately: that object answers
      # "when did it last happen", this one "how many times" -- an event, not a
      # clock reading, and that difference is what keeps a compaction
      # publishable (see {#observed}).
      @compactions += 1 if compaction?(event)
      # Both ends of the refusal streak arrive down the journal
      # {Compaction::Source::Derived} is handed. ASSIGNED from the record, never
      # incremented here -- a tally kept here could only become a second opinion
      # about a number the Source owns.
      @derivation_refusal_streak = event.consecutive if event.is_a?(Compaction::Source::DerivationRefused)
      @derivation_refusal_streak = 0 if event.is_a?(Telemetry::ContextDerived)
      interrupted if event.is_a?(Telemetry::RunInterrupted)
      # Matched by class, for {#turn_usage?}'s reason. It is the one record the
      # fleet reads that is not an {Ext::Event}, and {Telemetry::ChildProgress} says
      # why the facts a tree needs ride beside a spawn rather than in it.
      @fleet.progressed(event) if event.is_a?(Telemetry::ChildProgress)
      observe_rewind(event) if rewound?(event)
      observe_consumption(event)
      observe(event) if event.respond_to?(:kind)
      # Matched by class rather than on `#to`/`#to_layers`, which would also
      # catch an {Ext::Event}, whose `#to` is a message recipient.
      @mode = ModeState.of(event) if event.is_a?(Telemetry::ModeSwitch)
      observe_wait(event)
      publish_if_changed
      self
    end

    # The run's {Ext::Store}, handed over the moment one exists -- `Wiring#run`, the
    # first line at which the Agent (and so its Timeline's store) has been
    # built. Late rather than injected because this object is constructed a
    # whole layer above that, in `ChatLaunch#open_chronicle`, which must be in
    # the tee's sink list before `Wiring` exists at all.
    #
    # @param store [Ext::Store] the session's object database
    # @return [void]
    def bind_store(store)
      @store = store
      @inbox.bind_store(store)
    end

    private

    # A handoff journals no {Telemetry::Compaction}, so its cut is the only record of it.
    def compaction?(event)
      event.is_a?(Telemetry::Compaction) || (event.is_a?(Telemetry::CompactionCut) && event.handoff?)
    end

    # A turn's own usage, and only that. `#usage` alone was the duck here, and
    # it shipped a live defect: {Telemetry::OracleAnswer} answers `#usage` too
    # and rides this same tee on the default-on compaction route. Its usage
    # carries no cache fields and its model is the ORACLE's, so it broke all
    # three derivations at once -- `run_tokens` inflated past the
    # {Agent::Accounting} total it is contracted to equal (measured: 10,320
    # against 1,020 after one eager summary), and `occupancy` republished the
    # oracle's prompt against the chat's window (measured: 0.005 -> 0.045).
    #
    # DELIBERATE DIVERGENCE from {Compaction::Source#turn_usage?}, which answers
    # the same question as `respond_to?(:usage) && respond_to?(:stop_reason)`.
    # That is that file's documented local convention; this file's is the class
    # check, and the reason to prefer it HERE is the failure mode -- {Telemetry}
    # is a growing namespace, so a two-method duck silently readmits the next
    # record carrying both fields, with every spec here still green. `is_a?`
    # makes that impossible rather than unlikely.
    def turn_usage?(event) = event.is_a?(Telemetry::TurnUsage) && event.agent?

    # The two carriers that name a turn's CONSUMING EDGES, gathered so `#<<` reads
    # as one question and shaped like {Frontend::Neovim::InboxView#consume}: one
    # contract, one idiom, because two idioms is where the drift each file's
    # comment forbids begins. Both arms are CLASS checks, for {#turn_usage?}'s
    # reason; {Telemetry::QuestionsConsumed} holds why the second is narrow. It
    # needs no chain walk and so no rescue -- a second, narrower promise beside
    # {Inbox#committed}'s wide one is how the two surfaces start disagreeing.
    #
    # THE RULE IS THE SAME; THE RECOVERABILITY IS NOT. A dropped TurnUsage
    # SELF-HEALS -- the next commit re-walks the chain and re-retires everything
    # ever cited -- and a dropped QuestionsConsumed cannot: it names one turn's
    # edges and no later record names them again. This sink never drops;
    # `lain://inbox` rides a bounded Channel beside it and can, and nothing
    # resyncs off a {Telemetry::Dropped} today, so a loss there diverges the two
    # permanently and silently. Known and deferred.
    def observe_consumption(event)
      return observe_commit(event) if turn_usage?(event)
      return observe_refusal(event) if event.is_a?(Telemetry::WindowPressure)

      @inbox.retire(event.digests) if event.is_a?(Telemetry::QuestionsConsumed)
    end

    # A prompt the provider refused for not fitting its context, measured with
    # its own tokenizer: the reading {Agent::Accounting#observe_refusal} takes
    # for the prompt line, taken here too so the HUD and the prompt do not tell
    # two stories about the context that just overflowed. Nothing was billed,
    # so `run_tokens` is left alone.
    #
    # A record naming a spawn is the CHILD's and is left where it lies: its
    # count is the child's prompt against the child's window, tagged with a
    # turn on a chain this run never rendered, so taking it would publish an
    # occupancy the human at this prompt cannot act on and a `stands_on` the
    # rewind rule cannot find.
    def observe_refusal(event)
      return unless event.spawn.nil?

      reading = measured(Usage.new(input_tokens: event.prompt_tokens), event.model)
      record_occupancy(reading, stands_on: event.stands_on)
    end

    # A reading, kept re-takeable. A refusal vouches for its window only after
    # its record reached this feed, so the reading beside it still names the
    # guess; the `run_interrupted` the chat writes once the ask stops is the
    # first record after the vouch, and it re-takes the last reading. Every
    # `run_interrupted` does, a Ctrl-C's included, which re-reads a book that
    # did not move.
    #
    # The re-take is `@occupancy`'s second writer, and it bypasses
    # {#record_occupancy} on purpose: it measures no new turn, so it must not
    # clear the unmeasured streak, and an absence still never overwrites.
    def measured(usage, model)
      @remeasure = -> { occupancy_of(usage, model) }
      @remeasure.call
    end

    def remeasure = @occupancy = @remeasure.call || @occupancy

    # A committed turn's one record and the two unrelated debts it settles: what
    # the turn PAID ({#observe_usage}) and which questions it CONSUMED
    # ({Inbox#committed}). Split because the second must still run for a record
    # whose `usage` is nil, which is where {#observe_usage} gives up.
    #
    # THE PAYMENT IS DERIVED FIRST. `run_tokens` is contracted to equal
    # {Agent::Accounting}'s total, while the retirement walks a chain in a Store
    # this object does not own; retiring first made every failure in that walk
    # cost the accounting too -- measured: a head naming a stored body rather
    # than a turn left `run_tokens` nil for a turn that was genuinely billed.
    # {Inbox#committed} answers a miss rather than raising now, so the order is
    # no longer load-bearing for the crash; it is still the honest one.
    def observe_commit(event)
      observe_usage(event)
      @inbox.committed(event.digest)
      @tool_names = tool_names_in(event.digest) if event.stop_reason == :tool_use
    end

    # A nil `usage` is ignored rather than wrapped. {Telemetry::TurnUsage}'s
    # guard checks its digest and stop_reason but not its usage, and
    # `Canonical.normalize(nil)` is nil, so the record is constructible -- and
    # `nil["input_tokens"]` inside a {CLI::JournalTee} sink is a NoMethodError
    # that unwinds into the agent loop and costs the turn. Same answer as
    # {#occupancy_of}'s rescue: nothing derived, nothing raised -- and routed
    # through {#record_occupancy} all the same, because a stream truncated
    # before its usage block and one truncated into all-zero counts are the same
    # failure, and a run of either must not read as fresh.
    #
    # The accrual is summed over RECORDS with no dedupe, which is the one place
    # this differs from {Usage}'s "sum over unique turn digests": that rule is
    # about CONTENT reachable from a branched head, while a
    # {Telemetry::TurnUsage} digest is a join key a regenerated turn repeats
    # across two records both genuinely paid for. Deduplicating would undercount
    # exactly what {Agent::Accounting} counts, and the two agreeing is the whole
    # point. `to_i` on the nil start keeps absence distinct from a billed zero.
    #
    # The payment and the reading are settled SEPARATELY because they fail
    # separately: a record whose window cannot be measured was still billed, and
    # adding its zero to a sum is honest where replacing a ratio would not be.
    # {#occupancy_of} decides whether there is a reading; {#record_occupancy}
    # decides what happens to one.
    def observe_usage(event)
      return record_occupancy(nil) if event.usage.nil?

      usage = JournaledUsage.new(event.usage)
      slide_cache_deadline(usage)
      @run_tokens = @run_tokens.to_i + usage.total_tokens
      pay(event)
      record_occupancy(measured(usage, event.model), stands_on: event.digest)
    end

    def pay(event)
      return if event.usage.nil?

      usage = Usage.new(**event.usage.to_h.transform_keys(&:to_sym).slice(*Usage.members))
      @run_dollars = (@run_dollars || Friction::CacheWaste::Dollars.zero) +
                     Budget::Spent.paid(event.model, usage, prices: @prices, clock: @clock).dollars
    end

    # `@occupancy`'s writer for every reading a record brings ({#remeasure}
    # only re-takes one), and the whole policy in a sentence: an absence never
    # overwrites a reading. The rule had three
    # ad-hoc writers with three different answers -- the seed, a zero-usage
    # skip, and the unresolvable-model rescue below, which ASSIGNED its nil and
    # so erased a good number over a record it merely failed to read.
    #
    # A reading MEASURES the last window; its absence is the failure to take
    # one. Publishing the second over the first left the feed remembering the
    # spend (`run_tokens` accrues either way) and forgetting the window.
    #
    # A STREAK rather than a total, so the count answers "how stale is this
    # ratio" and a measurable turn clears it.
    #
    # A reading is tagged with the turn its record says it stands on: a
    # committed turn's own digest, or the turn a refusal record names.
    def record_occupancy(reading, stands_on: nil)
      @unmeasured_turns = reading.nil? ? @unmeasured_turns + 1 : 0
      @reading_head = stands_on unless reading.nil?
      @occupancy = reading || @occupancy
    end

    def rewound?(event) = event.is_a?(Hash) && event["type"] == REWOUND

    # {Agent::Accounting::Reading}'s rule, taken off the record: a reading
    # stands only on a chain still holding the turn it was tagged with. The
    # one place a reading is REMOVED rather than left standing, because a
    # rewind past it does not fail to measure the window, it changes which
    # window there is. The re-take goes with it, or the next stopped ask would
    # bring the number back, and so does the unmeasured streak, which has no
    # ratio left to call stale.
    def observe_rewind(event)
      return if @occupancy.nil? || stands?(@reading_head, event["to"])

      @occupancy = @window_guessed = nil
      @remeasure = -> {}
      @unmeasured_turns = 0
    end

    # Never raises, for {Inbox#cited_by_chain}'s reason: a chain this sink
    # cannot walk reads as one the reading is not on.
    def stands?(tag, head)
      tag.nil? || Dag::Factory.timeline(head_digest: head, store: @store).include?(tag)
    rescue StandardError
      false
    end

    def slide_cache_deadline(usage)
      return unless usage.cache_active? && cache_ttl.positive?

      @cache_deadline = (@clock.call + cache_ttl).utc.iso8601
    end

    # A callable profile is resolved here, on first use, so a feed built before the provider
    # exists does not force one to be built.
    def cache_ttl
      @cache_profile = @cache_profile.call if @cache_profile.respond_to?(:call)
      @cache_profile[:ttl].to_i
    end

    # @return [Float, nil] the reading, or nil for the ABSENCE of one. Two
    #   things make a turn unmeasurable and both answer nil: nothing billed on
    #   the way IN, and a model the book cannot resolve.
    #
    #   The gate is over exactly the fields the NUMERATOR is over. Gating on a
    #   four-field total instead would admit a record billing output against
    #   zero input and divide a real window by 0, publishing 0.0 over a true
    #   reading -- and `Ollama::Decoding#build_usage` takes `prompt_eval_count`
    #   straight off the body, so a reply carrying no such key is exactly that
    #   shape. Note that {Usage#zero?} is the four-field question and so is NOT
    #   the predicate here; the journaled hash is read with `to_i` anyway,
    #   because rebuilding a real {Usage} goes through `Integer()` and a raise
    #   is what this object may not do ({JournaledUsage} holds that argument).
    #
    #   {ContextWindow} is deliberately LOUD about a blank model and a
    #   non-positive window, and {Agent#occupancy} lets both raise because its
    #   caller rescues per prompt. This sink has no such caller: it rides the
    #   {CLI::JournalTee}, which re-raises a sink's failure, so a raise here
    #   would cost the agent its turn over a status line.
    #
    #   Whether the book vouched for that window is noted beside the reading,
    #   and only when there is one, so the HUD's guess mark stays with the ratio
    #   it describes.
    def occupancy_of(usage, model)
      return nil unless usage.total_input_tokens.positive?

      ratio = @context_window.occupancy(usage.total_input_tokens, model:).ratio
      @window_guessed = !@context_window.resolve(model).authoritative?
      ratio
    rescue ContextWindow::UnknownModel, ArgumentError
      nil
    end

    def observe_wait(event)
      @waits = @waits.step(event)
    end

    def observe(event)
      case event.kind
      when :spawn then @fleet.launched(event)
      when :message
        # A `:message` carries two independent facts, so it is read twice: what
        # it says to the human, and whether it is the record that ended a
        # spawn's lifecycle. {Fleet} owns the second reading.
        @fleet.completed(event)
        @inbox.arrived(event)
      when :turn
        @inbox.retire(event.causal_parents)
      end
    end

    # The transition announces only that tools are awaited; the turn is where
    # the names are journaled. Wide rescue for {Inbox#cited_by_chain}'s reason:
    # the tee re-raises into the agent loop.
    def tool_names_in(digest)
      Array(@store.fetch(digest).body&.fetch("content", nil)).filter_map do |block|
        block["name"] if block.is_a?(Hash) && block["type"] == "tool_use"
      end
    rescue StandardError
      []
    end

    # An interrupted run ends without the transition that would clear the slot.
    def interrupted
      remeasure
      @flight = nil
      @tool_names = []
    end

    def in_flight_slot
      return @flight unless @flight && @flight["kind"] == "tool"

      @flight.merge("tools" => @tool_names)
    end

    public

    # The whole struct, as published -- exposed so a live in-process reader (the
    # `/status` command) reads the SAME derivation the JSON file carries,
    # without touching the published file, which is absent under --no-journal.
    # A reader takes the keys it knows and ignores the rest, which is what lets
    # a renderer and this class ship separately.
    #
    # THIS IS A SNAPSHOT, NOT A CHANGE TOKEN. Two calls with nothing between
    # them differ once a second because {#measures} reads a running clock, so a
    # renderer redrawing on `state != @last` redraws forever. {#observed} is the
    # value to compare.
    #
    # @return [Hash] string-keyed, JSON-shaped
    def state = rendered(observed.merge(measures))

    # Everything derived from an EVENT: the change token. Equal to a previous
    # reading iff nothing this feed cares about has happened since.
    #
    # `compactions` is a COUNT and it is here rather than beside
    # `since_compaction` in {#measures} on purpose: a compaction is an event and
    # only its AGE is a clock reading. Without it a compaction would move no
    # compared field, the guard would skip the write carrying the fresh
    # `since_compaction`, and a HUD would go on saying "never compacted" until
    # some unrelated event happened along. A running total rather than a flag,
    # so a SECOND compaction is a change too.
    #
    # `unmeasured_turns` and `derivation_refusal_streak` are here for that same
    # argument, and neither contradicts `since_compaction`'s exclusion: that
    # exclusion is about CLOCKS, while a streak moves only when a record moved
    # it. A refusal earning no write would leave the published state saying
    # compaction was healthy while the session had stopped compacting; an
    # unmeasurable turn earning none would leave a stale ratio looking fresh.
    #
    # @return [Hash] string-keyed, JSON-shaped
    def observed
      { "cache_deadline" => @cache_deadline, "fleet" => @fleet.digests, "fleet_tree" => @fleet.tree,
        "inbox_count" => @inbox.pending_size,
        "approvals_pending" => @waits.approvals_pending, "waiting" => @waits.waiting,
        "occupancy" => @occupancy,
        "window_guessed" => @window_guessed, "unmeasured_turns" => @unmeasured_turns,
        "compactions" => @compactions, "derivation_refusal_streak" => @derivation_refusal_streak,
        "run_tokens" => @run_tokens, "run_dollars" => @run_dollars&.amount&.to_s("F"),
        "in_flight" => in_flight_slot, "agents" => published_agents }
        .merge(@mode.published)
    end

    # The run's own measures, read at the instant of the call. Never compared
    # (see {#state}); stamped onto a publish the observed state earned.
    #
    # @return [Hash] string-keyed, JSON-shaped
    def measures
      { "elapsed" => @run_clock.elapsed.round, "idle" => @run_clock.idle.round,
        "since_compaction" => @run_clock.since_compaction&.round }
    end

    private

    # The measures are composed in the BLOCK, which {Publication} calls only on
    # a real publish -- that is what stamps them at write time rather than at
    # compare time.
    def publish_if_changed
      @publication.call(observed) { |current| rendered(current.merge(measures)) }
    end

    # The HUD, stamped alongside the measures and for their reason: it reads the
    # wall clock, so it is a snapshot rather than a change token, and comparing
    # it would earn a write every time a marker flipped with nothing else moved.
    #
    # This class renders it because it is the only object holding every value
    # the line names -- {Reading} owns the SHAPE, and publishing the result is
    # what lets `plugin/tmux/scripts/lain-status` print a field instead of
    # carrying a second copy of the derivation in a jq program.
    def rendered(struct) = struct.merge("hud" => Reading.new(struct).hud(now: @clock.call, timed: false))

    def published_agents
      fold = @agent_states.projection
      { "rollup" => fold.rollup.to_s,
        "rows" => fold.agents.map { { "id" => _1.id, "state" => _1.state.to_s, "what" => _1.what } } }
    end

    def default_path = ProjectDir.new.state_path
  end
end
