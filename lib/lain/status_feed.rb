# frozen_string_literal: true

require "json"
require "fileutils"
require "time"

module Lain
  # A `#<<` sink -- the same duck a {Journal} or {Channel} answers, so it rides
  # {CLI::JournalTee} as just another fan-out leg -- that derives one small
  # state struct (cache warmth, fleet, inbox count, ...) from the events it
  # observes, for the tmux status-right / TTY prompt / nvim lualine renderers
  # ROADMAP describes (planning/interface-integration.md § "One state feed,
  # three renderers"). {Publication} is what lands it on disk: deriving and
  # writing change for different reasons, and the atomic-replace discipline
  # that keeps a polling reader from ever seeing half a struct is documented
  # there. The default path resolves through {ProjectDir}, the ONE locator all
  # three renderers default through, and it is deliberately NOT in the project:
  # this struct is rewritten on every turn, so writing it beside the code left
  # permanent `git status` noise in the user's repository, with no ignore path
  # and nothing in `lib/` that writes one (F50). It lives under
  # `$XDG_STATE_HOME/lain`, keyed by project, beside the sessions and the
  # epics; {ProjectDir}'s own comment carries the recipe and what it costs.
  #
  # Fourteen fields, all JOURNALED or derived from the run's own clock -- never
  # an in-process registry, and in particular never a live {Agent}: this
  # object is constructed in `ChatLaunch#open_chronicle`, BEFORE `Wiring`
  # exists, so anything it can only learn by asking a collaborator that does
  # not exist yet is a field it cannot carry (see the `inbox_count` note
  # below for what that constraint already cost once).
  #
  # * `cache_deadline` -- a provider's cache is a SLIDING window (default 5
  #   min for Anthropic), refreshed on use, not a countdown: pushing the
  #   absolute deadline (not a remaining-seconds count) is what lets a
  #   renderer tick locally with zero RPC/poll chatter (the approved doc's
  #   explicit instruction). The TTL itself comes from the injected
  #   `cache_profile:` (CAC-2's `Provider#cache_profile` -- {ttl:,
  #   min_prefix_tokens:, write_multiplier:, read_multiplier:,
  #   tiered_invalidation:}, see {DEFAULT_CACHE_PROFILE} for the fallback),
  #   never a hardcoded constant, so a swept provider arm each slides its own
  #   real window. Derived from a {Telemetry::TurnUsage}'s cache fields --
  #   any turn that actually read or wrote the cache slides the deadline
  #   forward; a turn that shows no cache activity leaves the last deadline
  #   exactly where it was, because the TTL it named has not been touched.
  # * `fleet` -- the digests of every DISTINCT `:spawn` event observed, keyed
  #   so a redelivered event (a journal replay) never grows a phantom second
  #   entry for one real spawn. W3's lifecycle events will later enrich this
  #   with running/done state; I1 only has to prove the field reflects
  #   exactly what the journal shows.
  # * `inbox_count` -- what is still addressed to {Tools::AskHuman::HUMAN} and
  #   not yet named a causal parent by a committed turn. {Inbox} holds it: the
  #   projection's rule, the incremental fold, and the {Store} the live
  #   carrier's chain is resolved in are all its, and no other field on this
  #   struct has any use for that store. Read its doc before touching the
  #   count -- it is the only field here whose ANSWER depends on a
  #   collaborator this object cannot be given at construction (see
  #   {#bind_store}), and it is held to the nvim `lain://inbox` buffer's
  #   answer by a parity spec.
  #
  # * `occupancy` -- how full the live model's context window the LAST turn
  #   left it, as a 0..1 fraction, or nil before any turn (absence, never a
  #   zero that would read as an empty context). Derived from the SAME
  #   {Telemetry::TurnUsage} the cache deadline slides on, because that one
  #   record names both halves of the ratio: the tokens billed on the way in
  #   ({Usage#total_input_tokens}, restated by {JournaledUsage}) and
  #   the model whose window {ContextWindow} resolves. {Agent#occupancy}
  #   answers the same question from the live Agent's accounting; this sink
  #   cannot ask it (the construction-order constraint above), so it asks the
  #   same BOOK the same way instead of reaching for an Agent that does not
  #   exist yet. The two can differ only where the model the provider
  #   ANSWERED with differs from the one the Context was rendered for, which
  #   is a difference worth showing rather than hiding.
  #
  #   ⚠️ THIS FRACTION CAN EXCEED 1.0, and the guard against it is NOT the
  #   `UnknownModel` rescue below. {ContextWindow.default} carries
  #   {ContextWindow::CONSERVATIVE_FALLBACK} (8,192), so an unmatched model
  #   never raises -- it divides by 8,192. Every Ollama id and most Bedrock
  #   ids are unmatched, and a real 32k local window then reads as 4.0. That
  #   is the fallback working as designed (it exists so compaction fires
  #   EARLY rather than never, see its own doc), so the number published here
  #   is honest about what the book was asked; it is the RENDERER that clamps,
  #   because "244%" is nonsense on a status bar where "100%" is not. The
  #   rescue only ever catches a BLANK model, which is a wiring bug, not this
  #   common case. A deployment that knows its real local window should inject
  #   a book with the right `fallback:`.
  # * `run_tokens` -- what THIS RUN has SPENT, cumulative, every billed field
  #   of every {Telemetry::TurnUsage} summed ({Usage#total_tokens}'s
  #   definition, restated by {JournaledUsage} the way `occupancy` is).
  #   nil before the first payment, because "nothing yet" and "billed nothing"
  #   are different claims and only the renderer's silence suits the first.
  #
  #   A RUN, and deliberately not a session: {Session} survives a `--resume`
  #   and this counter does not, so calling it `session_tokens` would have put
  #   a surface in contradiction with the record -- a resumed session reading
  #   0 for a conversation that spent half a million. {Agent::Accounting} is
  #   already documented as "the run's token ledger", and this is that ledger
  #   published; one quantity, one noun, and a run legitimately starts at zero.
  #
  #   ⚠️ THIS IS THIS MACHINE'S SPEND ON THIS KEY, not a plan's consumption.
  #   Another client on the same subscription is invisible to it, and no
  #   provider lain talks to publishes a used/remaining pair to reconcile
  #   against (E7 settles that for the ollama-cloud arm: the headers carry
  #   concurrency and queue depth, no bucket over time). So the figure is
  #   exact about what it measures and silent about what it cannot see -- the
  #   same discipline {ContextWindow}'s published-versus-guessed provenance
  #   keeps -- and the HUD labels it `run:` rather than `usage:` so the label
  #   cannot be read as the quota.
  #
  #   ORACLE SPEND IS NOT IN IT, and that is a decision rather than an
  #   oversight. A {Telemetry::OracleAnswer} rides this same tee and answers
  #   `#usage` too, so `#usage` alone would sum it here -- real money, really
  #   spent, but money {Agent::Accounting} does not count, and this field's
  #   contract is that it equals `Accounting#usage`. Publishing a differently
  #   scoped total under a name that claims parity is the defect the parity
  #   seam exists to catch. A second figure that names oracle spend as its own
  #   is a separate field for a separate card. See {#turn_usage?}.
  #
  #   It is a SECOND accumulator for a number {Agent::Accounting} already owns,
  #   and that is reconciled rather than left to drift: one `Accounting#observe`
  #   both rolls the response into `Accounting#usage` and journals the record
  #   this sink sums, so the two are equal by construction.
  #   spec/lain/seams/usage_parity_spec.rb is the pin, including the
  #   regenerated turn both sides deliberately count twice (see {#accrue}).
  # * `approvals_pending` -- how many gated tool calls are parked awaiting a
  #   human. Counted, never keyed: {Telemetry::ApprovalPending} carries the
  #   `tool_use_id` of the call it parked, but the matching
  #   `approval_decision` record carries none, so there is no join key and a
  #   count is the only pairing available.
  #
  #   The pair breaks in exactly ONE place, and it is worth being precise
  #   about which, because the two halves fail asymmetrically. It is NOT
  #   cancellation: `Async::Stop` descends from `Exception`, not
  #   `StandardError`, so a stop delivered inside the announcement write
  #   escapes {Approval::Queue#record_evidence} entirely -- `@parked <<` and
  #   `#settle` never run, so NEITHER record is written and nothing is
  #   orphaned. What breaks the pair is the queue's `degrade` path (a closed
  #   Journal, a full disk), which writes a `journal_error` in place of the
  #   record. Losing the ASKED half under-reports -- zero published while a
  #   call is genuinely parked -- and heals when that call is decided. Losing
  #   the DECIDED half over-reports and NEVER heals: the count stays high for
  #   the life of the run. So the degrade record is counted too
  #   ({#observe_degraded_approval}): it names which class it stood in for, so
  #   the count moves even when the evidence did not serialize. The floor at
  #   zero is then a backstop for a stream that was never paired to begin with
  #   -- a journal replayed from the middle of a parked call -- not the
  #   primary defence.
  # * `posture` / `layers` / `mode_lighter` -- the exclusive mode slot, the
  #   composable half, and the composed rendering, derived from a
  #   {Telemetry::ModeSwitch} by {ModeState}, whose doc holds the reasoning
  #   (why all three ship, and why an undeclared name renders as itself). All
  #   absent until the first switch, and forced to be: {Mode::Switch} journals
  #   nothing at construction, and this object is built before `Wiring` exists,
  #   so there is no record to derive one from. Publishing a guessed
  #   `accept_edits` would restate {CLI::Switchboard}'s seed as though a journal
  #   had witnessed it -- the same claim-from-nothing {ModeState}'s `NONE`
  #   refuses when it holds nil rather than an empty layer set.
  #
  #   ⚠️ THE MODE DERIVATION NEVER RAISES; THE PUBLISH STILL DOES, and the two
  #   are not in tension. {ModeState.lighter_of} rescues the `ArgumentError` an
  #   undeclared name would raise, because this sink rides the
  #   {CLI::JournalTee}, which re-raises a sink's failure -- deriving a status
  #   line must never cost the agent its turn. A failed WRITE is the opposite
  #   case and is deliberately loud: {Publication} argues it ("a state feed
  #   that cannot write is not a state feed that should pretend it did") and
  #   spec/lain/status_feed_spec.rb's "replaces the file atomically" pins the
  #   `Errno::ENOSPC`. planning/specs/chunk-modes-approval-undo.md's T8 asked
  #   for "nothing is raised" from an unwritable path; that was implemented as
  #   the derivation half ONLY, because swallowing the write for `mode_switch`
  #   alone -- while every other field's write still raised -- would be
  #   incoherent, and swallowing it for all of them is a change to
  #   {Publication}'s contract, not to this field. Do not "fix" this by adding
  #   a rescue there.
  #
  #   Both are {#observed}, so a LAYER flip publishes even when the posture did
  #   not move -- the whole reason {Telemetry::ModeSwitch} carries four fields
  #   rather than two. `/mode +auto_approve` journals `manual -> manual`, and
  #   `auto_approve` is the one layer answering `alters_outcome?`; a guard
  #   comparing the posture ALONE would leave a HUD saying "MAN" while the
  #   approval gate had been turned off, which is the silently-active policy
  #   the mode design forbids. The mechanism is that design's own rule rather
  #   than a special case here: an outcome-altering layer MUST declare a
  #   lighter ({Mode::Layer::Declaration} enforces it), so every layer that can
  #   move an outcome moves this string.
  # * `elapsed` / `idle` / `since_compaction` -- the run's own measures, read
  #   off the injected {RunClock} and published as PLAIN DURATIONS in whole
  #   seconds. They are deliberately NOT deadlines: `cache_deadline` above is
  #   an absolute instant precisely so a renderer can tick it locally against
  #   its own clock, and these three are monotonic readings that have no such
  #   local meaning. `since_compaction` is nil until something compacts.
  # * `compactions` -- how many compactions this run has seen. The EVENT half
  #   of `since_compaction`'s age, and the only reason a compaction is
  #   publishable at all: see {#observed}.
  # * `derivation_refusal_streak` -- how many derivations in a ROW
  #   {Compaction::Source::Derived} has refused, zero while they are
  #   succeeding. A STREAK, not a running total, which is the difference
  #   between it and `compactions` beside it: one refusal is an awkward
  #   history, a rising streak is a session that has stopped compacting, and
  #   until this field nothing in `lib/` read the number at all (F47).
  #
  #   Both ends ride ONE channel, and that is what makes the field real rather
  #   than a slot nothing feeds. `CLI::Backend#compaction_source` hands the
  #   Source the journal `CLI::CompactionMount#destination` reads off the
  #   chronicle's instrumentation -- which is the {CLI::JournalTee} this sink
  #   sits in ({CLI::LiveViews#initialize}). So a
  #   {Compaction::Source::DerivationRefused} arrives here carrying the
  #   Source's own `consecutive`, and the {Telemetry::ContextDerived} a
  #   SUCCESSFUL derivation writes to the same journal arrives to clear it.
  #   The count is taken off the record and never tallied here: the Source
  #   owns the increment and the reset, and a second tally could only come to
  #   disagree with it.
  #
  # Recognizing an event is DUCK-TYPED WHERE THE VOCABULARY IS OPEN and matched
  # by CLASS WHERE IT IS CLOSED, and the split is the file's rule rather than an
  # accident. `#kind` is the open one: any {Event} answers it, a caller may feed
  # this a stand-in that does too, and nothing about the question narrows to one
  # record. Everything else here names a closed set -- {Telemetry::Compaction},
  # {Telemetry::ContextDerived}, {Telemetry::ModeSwitch},
  # {Compaction::Source::DerivationRefused}, {Telemetry::TurnUsage} -- and each
  # is matched by class, because a duck over a GROWING namespace is a guess that
  # silently starts catching the wrong record. Two of those comments record the
  # duck they refused; {#turn_usage?} records the one that was actually shipped
  # and what it cost.
  #
  # The approval pair is the ONE exception, and it is the same exception
  # {Memory::JournalMemoryRoot} documents for the same reason: {Approval::Queue}
  # is the single writer of both records, and no other event in this fan-out
  # is distinguishable from a park by shape alone (a `tool_use_id` reader
  # would also match {Telemetry::ToolOutput} and count it as a park).
  #
  # A publish is skipped when the derived state did not actually change (a
  # duplicate delivery, or an event this class recognizes nothing about) --
  # cheap to check since every field above is now O(1)/O(causal_parents) to
  # derive rather than an O(n) fold, so there is no reason to pay a
  # write+rename the state did not earn.
  #
  # The comparison is {#observed} ALONE, never the run's own measures, and the
  # measures are stamped at write time. A clock is not a change: comparing it
  # would make "did anything happen" answer yes once a second forever, which
  # costs a write+rename per second on a busy run and -- worse -- makes the
  # struct useless as a change token for a renderer that redraws on
  # difference. That is precisely the failure {ContextWindow::Occupancy::None}
  # documents one layer down, where a Null Object breaking `==` "repaints
  # forever before the first turn"; the same mistake made with a clock instead
  # of an absence repaints forever, full stop.
  class StatusFeed
    # The TTL used when no caller injects a provider's own `#cache_profile`
    # (CAC-2, planning/specs/cache-aware-compaction.md) -- Anthropic's default
    # 5-minute sliding window (planning/interface-integration.md § 1). Kept
    # here rather than reaching into `Provider::AnthropicReference::CACHE_PROFILE`
    # because `lib/lain.rb` loads this file BEFORE `lib/lain/provider.rb`;
    # depending forward on a not-yet-loaded unit would invert that order.
    DEFAULT_CACHE_PROFILE = { ttl: 300 }.freeze

    # {Journal#encode}'s self-describing failure record, which is also what
    # {Approval::Queue#degrade} writes when it cannot journal a park or a
    # decision. Named here because this class READS it -- the only raw Hash in
    # the fan-out it recognizes at all.
    JOURNAL_ERROR = "journal_error"

    # {Tools::AskHuman::HUMAN} is not required here: reaching into the Tools
    # tree from this early-loading struct would invert the dependency this
    # class actually has (none), so the address is named again rather than
    # imported -- both spellings are pinned by spec. {Inbox} is what reads it,
    # and it stays HERE rather than moving there because two other files cite
    # this constant by name as the precedent for not importing an address.
    INBOX_RECIPIENT = "human"

    # @param path [String] where the state struct is atomically published;
    #   defaults to this project's file under `$XDG_STATE_HOME/lain`, resolved
    #   by {ProjectDir#state_path} -- machine state that moves every turn, kept
    #   out of the source tree it describes (F50).
    # @param clock [#call] answers the current Time; injectable so a spec
    #   never races the real clock to compute a deadline.
    # @param cache_profile [Hash] a provider's `#cache_profile` (CAC-2) --
    #   only `:ttl` is read here; defaults to {DEFAULT_CACHE_PROFILE} when the
    #   caller has no specific provider to name.
    # @param run_clock [RunClock] the RUN's clock, not this object's: the
    #   {CLI::Conductor} records a user prompt on the same instance, so an
    #   `idle` published from a private one would never reset.
    #   {CLI::ChatLaunch} builds the one and threads it to both. Defaulted to a
    #   fresh one anyway, matching Conductor's own seam, so a directly
    #   constructed feed still publishes an honest elapsed.
    # @param context_window [#occupancy] the book resolving a model name into
    #   the denominator, the same duck {Agent#occupancy} takes. A bench arm
    #   measuring against a known local window passes its own.
    # @param store [Store] where a committed turn's causal chain is resolved --
    #   {Inbox}'s collaborator, and nothing else here reads it. Defaulted to an
    #   EMPTY one rather than required, because the live chat has none yet at
    #   this object's construction point; see {#bind_store}.
    def initialize(path: default_path, clock: -> { Time.now }, cache_profile: DEFAULT_CACHE_PROFILE,
                   run_clock: RunClock.new, context_window: ContextWindow.default, store: Store.new)
      @publication = Publication.new(path)
      @clock = clock
      @cache_profile = cache_profile
      @run_clock = run_clock
      @context_window = context_window
      @inbox = Inbox.new(store:)
      start_empty
    end

    # Every derivation, before any event has been seen. Named rather than
    # inlined because the constructor's two halves answer different questions
    # -- what this feed was GIVEN, and what it has SEEN -- and only the second
    # half needs the running commentary below.
    #
    # Absence where absence is the honest answer (no cache activity yet, no
    # turn yet), a zero only where a count is genuinely zero.
    def start_empty
      @cache_deadline = nil
      @occupancy = nil
      @run_tokens = nil
      @mode = ModeState::NONE
      @approvals_pending = 0
      @compactions = 0
      @derivation_refusal_streak = 0
      # Insertion-ordered, keyed by digest: a Hash (not an Array) is what
      # makes a redelivered :spawn a no-op update instead of a second entry.
      @fleet = {}
    end
    private :start_empty

    # @param event [Object] a record this sink recognizes, or anything at all.
    #   The recognized set is the one the class doc lists: five journal records
    #   matched by CLASS -- {Telemetry::TurnUsage}, {Telemetry::Compaction},
    #   {Telemetry::ContextDerived}, {Telemetry::ModeSwitch} and
    #   {Compaction::Source::DerivationRefused} -- plus the {Approval::Queue}
    #   pair, plus anything answering `#kind` (an {Event}), which is the one
    #   OPEN duck here because any Event answers it and no single record owns
    #   the question.
    #
    #   ⚠️ A LOOKALIKE IS NOT ENOUGH for the class-matched five. An object that
    #   merely answers `#usage` and `#stop_reason` is NOT read as a turn's
    #   payment and is silently inert -- deliberately, because reading it as one
    #   is the defect {#turn_usage?} documents ({Telemetry::OracleAnswer} answers
    #   both and rides this same tee). Send the real record.
    #
    #   An event this sink recognizes nothing about is inert but still checked
    #   for a republish, matching every other sink's `<<` (though nothing
    #   changes, so nothing writes -- see {#publish_if_changed}).
    # @return [self]
    def <<(event)
      # The RunClock rides this sink rather than the tee directly: it is not
      # published on its own, and the one object that publishes its readings
      # is the one that should be feeding it. Inert for everything but a
      # {Telemetry::Compaction}, which is the only record it recognizes.
      @run_clock << event
      # Repeats {RunClock#<<}'s class check deliberately: that object answers
      # "when did it last happen", this one answers "how many times" -- an
      # event, not a clock reading, and the difference is what keeps a
      # compaction publishable (see {#observed}).
      @compactions += 1 if event.is_a?(Telemetry::Compaction)
      # The two ends of {Compaction::Source::Derived}'s refusal streak, both
      # arriving down the journal that Source is handed (see the class doc for
      # the channel). Matched by CLASS, the approval pair's own exception and
      # for the same reason: a `#consecutive` duck would be a guess, and these
      # two records are the whole vocabulary. ASSIGNED from the record, never
      # incremented here -- the Source owns the increment and the reset, and a
      # tally kept here could only come to be a second opinion about it.
      @derivation_refusal_streak = event.consecutive if event.is_a?(Compaction::Source::DerivationRefused)
      @derivation_refusal_streak = 0 if event.is_a?(Telemetry::ContextDerived)
      observe_commit(event) if turn_usage?(event)
      observe(event) if event.respond_to?(:kind)
      # Matched by class, for {Telemetry::Compaction}'s reason and not the
      # approval pair's: a `#to`/`#to_layers` duck would also catch an
      # {Event}, whose `#to` is a message recipient.
      @mode = ModeState.of(event) if event.is_a?(Telemetry::ModeSwitch)
      observe_approval(event)
      publish_if_changed
      self
    end

    # The run's {Store}, handed over the moment one exists -- `Wiring#run`, the
    # first line at which the Agent (and so its Timeline's store) has been
    # built. Late rather than injected because this object is constructed a
    # whole layer above that, in `ChatLaunch#open_chronicle`, which must be in
    # the tee's sink list before `Wiring` exists at all. {Inbox} is the only
    # thing here that wants it, and its doc says what an unbound one answers.
    #
    # @param store [Store] the session's object database
    # @return [void]
    def bind_store(store) = @inbox.bind_store(store)

    private

    # A turn's own usage, and only that. Matched by CLASS, which is THIS FILE'S
    # convention for a closed vocabulary -- the same rule {Telemetry::Compaction},
    # {Telemetry::ContextDerived}, {Telemetry::ModeSwitch} and
    # {Compaction::Source::DerivationRefused} are each matched by above, every
    # one of them carrying a comment saying a duck there would be a guess.
    # Exactly one record journals a turn's payment, so this is that vocabulary.
    #
    # `#usage` alone was the duck here, and it shipped a live defect:
    # {Telemetry::OracleAnswer} answers `#usage` too and rides this same tee on
    # the default-on compaction route. Its usage carries no cache fields and its
    # model is the ORACLE's, so it broke all three derivations at once --
    # `run_tokens` inflated past the {Agent::Accounting} total it is contracted
    # to equal (measured: 10,320 against 1,020 after one eager summary), and
    # `occupancy` republished the oracle's prompt against the chat's window
    # (measured: 0.005 -> 0.045).
    #
    # ⚠️ DELIBERATE DIVERGENCE from {Compaction::Source#turn_usage?}, which
    # answers the same question about the same record as
    # `respond_to?(:usage) && respond_to?(:stop_reason)`. That is not an
    # inconsistency to tidy: it is that file's local convention, documented and
    # verified there, and it belongs to a card that owns that file. This file's
    # convention is the class check, and the reason to prefer it HERE is the
    # failure mode -- {Telemetry} is a growing namespace, so a two-method duck
    # silently readmits the next record that happens to carry both fields, with
    # every spec in this file still green. That is the defect above, re-armed.
    # `is_a?` makes it impossible rather than unlikely.
    #
    # Oracle spend is REAL money and its exclusion here is a decision, not an
    # oversight: this sink's `run_tokens` is the published form of
    # `Accounting#usage`, which does not carry oracle spend, so adding it would
    # buy a bigger number at the cost of the parity that makes the number
    # trustworthy. A figure that names oracle spend as its own is a separate
    # field. See spec/lain/seams/usage_parity_spec.rb, which measures both.
    def turn_usage?(event) = event.is_a?(Telemetry::TurnUsage)

    # A committed turn's one record and the two unrelated debts it settles:
    # what the turn PAID ({#observe_usage}) and which questions it CONSUMED
    # ({Inbox#committed}). Split because only the first is about tokens, and
    # because the second must still run for a record whose `usage` is nil, which
    # is where {#observe_usage} gives up.
    #
    # THE PAYMENT IS DERIVED FIRST, and that is the order rather than the split:
    # `run_tokens` is contracted to equal {Agent::Accounting}'s total
    # (spec/lain/seams/usage_parity_spec.rb), while the retirement walks a chain
    # in a Store this object does not own. Retiring first made every failure in
    # that walk cost the accounting too -- measured: a head naming a stored body
    # rather than a turn left `run_tokens` nil for a turn that was genuinely
    # billed. {Inbox#committed} answers a miss rather than raising now, so this
    # order is no longer load-bearing for the crash; it is still the honest one,
    # because the derivation that owes another object a number goes before the
    # one that merely draws a status line.
    def observe_commit(event)
      observe_usage(event)
      @inbox.committed(event.digest)
    end

    # One {Telemetry::TurnUsage} carries all three derivations a turn owes this
    # sink: the cache activity that slides the deadline, the tokens that --
    # against the model the SAME record names -- are the occupancy, and the
    # payment that accrues onto the run total. {JournaledUsage} is what
    # reads the record; this method decides what the readings mean here.
    #
    # A nil `usage` is ignored rather than wrapped. {Telemetry::TurnUsage}'s
    # guard checks its digest and stop_reason but not its usage, and
    # `Canonical.normalize(nil)` is nil, so the record is constructible -- and
    # `nil["input_tokens"]` inside a {CLI::JournalTee} sink is a NoMethodError
    # that unwinds into the agent loop and costs the turn. Same reasoning as
    # {#occupancy_of}'s rescue, and the same answer: a malformed record makes
    # this sink derive nothing, never raise. (Pre-dates the occupancy field --
    # `slide_cache_deadline` indexed it too; found by a review probe.)
    #
    # The accrual is summed over RECORDS with no dedupe, which is deliberate and
    # is the one place this differs from {Usage}'s "sum over unique turn
    # digests" rule: that rule is about CONTENT reachable from a branched head,
    # while {Telemetry::TurnUsage}'s digest is a join key that a regenerated
    # turn repeats across two records both genuinely paid for. Deduplicating
    # would undercount exactly what {Agent::Accounting} counts, and the two
    # agreeing is the whole point (spec/lain/seams/usage_parity_spec.rb).
    # `to_i` on the nil start keeps absence distinct from a billed zero.
    def observe_usage(event)
      return if event.usage.nil?

      usage = JournaledUsage.new(event.usage)
      slide_cache_deadline(usage)
      @run_tokens = @run_tokens.to_i + usage.total_tokens
      @occupancy = occupancy_of(usage, event.model)
    end

    def slide_cache_deadline(usage)
      return unless usage.cache_active?

      @cache_deadline = (@clock.call + @cache_profile[:ttl]).utc.iso8601
    end

    # @return [Float, nil] nil when the book cannot answer. {ContextWindow} is
    #   deliberately LOUD about a blank model and about a non-positive window
    #   -- {Agent#occupancy} lets both raise, and a caller rendering per prompt
    #   rescues -- but this sink has no such caller: it rides the same
    #   {CLI::JournalTee} the durable record does, and the tee re-raises a
    #   sink's failure, so a raise here would cost the agent its turn over a
    #   status line. Absence is the only honest reading left.
    def occupancy_of(usage, model)
      @context_window.occupancy(usage.total_input_tokens, model:).ratio
    rescue ContextWindow::UnknownModel, ArgumentError
      nil
    end

    # See the class doc for why this pair is matched by CLASS and counted
    # rather than joined by id, and which half failing costs what.
    def observe_approval(event)
      case event
      when Telemetry::ApprovalPending then @approvals_pending += 1
      when Approval::Queue::Pending then release_approval
      when Hash then observe_degraded_approval(event)
      end
    end

    # {Approval::Queue#degrade}'s stand-in record. The park (or the decision)
    # HAPPENED -- only its evidence failed to serialize -- and the record names
    # which class it stood in for, so the count can still move. Without this a
    # lost decision leaves the published count high for the rest of the run
    # (see the class doc); with it, only a record that never reached this sink
    # at all can strand the count, which is what the floor is for.
    #
    # The two names are read off the classes themselves, so a rename cannot
    # drift the strings apart from what {Approval::Queue} actually writes.
    def observe_degraded_approval(event)
      return unless event["type"] == JOURNAL_ERROR

      case event["entry_class"]
      when Telemetry::ApprovalPending.name then @approvals_pending += 1
      when Approval::Queue::Pending.name then release_approval
      end
    end

    def release_approval
      @approvals_pending -= 1 if @approvals_pending.positive?
    end

    def observe(event)
      case event.kind
      when :spawn then @fleet[event.digest] = true
      when :message then @inbox.arrived(event)
      when :turn then @inbox.retire(event.causal_parents)
      end
    end

    public

    # The whole struct, as published -- exposed (T13) so a live in-process
    # reader (Command::Env's `status`, the `/status` command) reads the SAME
    # derivation the JSON file carries, without touching the published file
    # (absent under --no-journal, where a headless run's StatusFeed is still
    # live and answerable).
    #
    # A reader takes the keys it knows and ignores the rest -- `/status` names
    # three of these and keeps working untouched as the struct widens, which
    # is the contract that lets a renderer and this class ship separately.
    #
    # ⚠️ THIS IS A SNAPSHOT, NOT A CHANGE TOKEN. Two calls with nothing between
    # them differ once a second, because {#measures} reads a running clock; a
    # renderer that redraws on `state != @last` therefore redraws forever.
    # {#observed} is the value to compare -- it moves only when an event moved
    # it, which is exactly the question "has anything happened" -- and it is
    # what {#publish_if_changed} compares for the same reason.
    #
    # @return [Hash] string-keyed, JSON-shaped
    def state = observed.merge(measures)

    # Everything derived from an EVENT: the change token. Equal to a previous
    # reading iff nothing this feed cares about has happened since, which is
    # why {#publish_if_changed} can compare exactly this and nothing else.
    #
    # `compactions` is a COUNT and it is here, not beside `since_compaction`
    # in {#measures}, on purpose: a compaction is an event, and only its AGE is
    # a clock reading. Without it a compaction would move no compared field,
    # the guard would skip the write that carries the fresh
    # `since_compaction`, and a HUD would go on saying "never compacted" until
    # some unrelated event happened along. It is a running total rather than a
    # flag so a SECOND compaction is a change too, and a bench gets a number
    # worth having for free.
    #
    # `derivation_refusal_streak` is here for exactly that argument, and it is
    # not in tension with `since_compaction`'s exclusion: that exclusion is
    # about CLOCKS -- a running clock makes "did anything happen" answer yes
    # once a second forever -- while this streak moves only when a record moved
    # it. A refusal that changed no compared field would earn no write, and the
    # published state would go on saying compaction was healthy while the
    # session had stopped compacting, which is F47 with an extra step.
    #
    # @return [Hash] string-keyed, JSON-shaped
    def observed
      { "cache_deadline" => @cache_deadline, "fleet" => @fleet.keys, "inbox_count" => @inbox.pending_size,
        "approvals_pending" => @approvals_pending, "occupancy" => @occupancy,
        "compactions" => @compactions, "derivation_refusal_streak" => @derivation_refusal_streak,
        "run_tokens" => @run_tokens }
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

    # {#observed} is the change token, so a duplicate delivery or an event this
    # class recognized nothing about writes nothing. The measures are composed
    # in the BLOCK, which {Publication} calls only on a real publish -- that is
    # what stamps them at write time rather than at compare time. See {#state}
    # for why a clock can never be part of the comparison.
    def publish_if_changed
      @publication.call(observed) { |current| current.merge(measures) }
    end

    def default_path = ProjectDir.new.state_path
  end
end

# This file is `status_feed/`'s index. All four children reopen the class above,
# so they load AFTER the class body -- `effect/handler.rb`'s ordering, for the
# same reason (CLAUDE.md, Requires). Nothing at load time needs any of the four
# constants; #initialize does, and that runs later.
require_relative "status_feed/publication"
require_relative "status_feed/mode_state"
require_relative "status_feed/journaled_usage"
require_relative "status_feed/inbox"
