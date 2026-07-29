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
  # three renderers"). {Publication} is what lands it on `.lain/state.json`:
  # deriving and writing change for different reasons, and the atomic-replace
  # discipline that keeps a polling reader from ever seeing half a struct is
  # documented there. `.lain/` is a project artifact, like `.git/`, not an XDG
  # concern -- see ROADMAP's "XDG conformance" entry -- so the default path
  # resolves through {ProjectDir}, the locator for that tree, and never through
  # {Paths}, which is XDG only.
  #
  # Nine fields, all JOURNALED or derived from the run's own clock -- never
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
  # * `inbox_count` -- what is still addressed to {Tools::AskHuman::HUMAN}
  #   and not yet named a causal parent by a committed **`:turn`** --
  #   {Event::Projection#pending}'s exact semantics, mirrored here
  #   incrementally (see {#observe_message}/{#observe_turn}) rather than
  #   re-run as a fresh `Projection` fold on every event, which was an O(n)
  #   refold per event (O(n^2) over a session) that a review pass measured at
  #   8.5s for an 8k-event history. Pending clears ONLY on consumption by a
  #   `:turn`'s `causal_parents` -- Projection's own doc is explicit that a
  #   `:message`'s `causal_parents` is lineage, not consumption -- so an
  #   {Tools::AskHuman#reply} answer (a `:message`, however it cites the
  #   question) does NOT retire the question by itself; see
  #   spec/lain/status_feed_spec.rb's "inbox_count" examples for the pinned
  #   before/after, and {Frontend::Neovim::InboxView}'s parity spec, which
  #   holds this class and the nvim `lain://inbox` view to the SAME rule.
  #
  #   T13 KNOWN GAP (escalated, not fixed here -- see the card's hand-back):
  #   in a live chat, `inbox_count` never actually decrements, because the
  #   `:turn` Event `#observe_turn` waits for never reaches this sink.
  #   `SessionRecord::Scribe#catch_up` appends committed turns straight to
  #   the session JOURNAL, never to the `message_journal`/tee this class
  #   rides (see its own doc: "turn records never route -- they are record
  #   data, not live-view telemetry"). {Frontend::Neovim::InboxView} solves
  #   the SAME problem correctly by consuming the `Telemetry::TurnUsage`
  #   that DOES reach a tee and resolving its head's causal chain against a
  #   live `Store` -- but that view is constructed AFTER the session's
  #   Store exists (`Repl#run`, deep inside `Wiring#run`), while this class
  #   is constructed BEFORE it (`ChatLaunch#open_chronicle`, per the T9
  #   panel's binding amendment: it must be in the tee's sink list at
  #   `wrap_tee` time, which runs before `Wiring` exists at all). Porting
  #   InboxView's fix here needs a Store made available AFTER that point --
  #   a late-bound thunk/box `ChatLaunch`/`Wiring` would populate once the
  #   Agent exists -- which is a real construction-order design change to
  #   two orchestrator-owned files, not a StatusFeed-local one. Left as the
  #   documented follow-up rather than fixed via a mechanism (retiring on
  #   the human's own reply) that would break the InboxView parity spec
  #   above.
  #
  # * `occupancy` -- how full the live model's context window the LAST turn
  #   left it, as a 0..1 fraction, or nil before any turn (absence, never a
  #   zero that would read as an empty context). Derived from the SAME
  #   {Telemetry::TurnUsage} the cache deadline slides on, because that one
  #   record names both halves of the ratio: the tokens billed on the way in
  #   ({Usage#total_input_tokens}, recomputed here off the journaled Hash) and
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
  # * `elapsed` / `idle` / `since_compaction` -- the run's own measures, read
  #   off the injected {RunClock} and published as PLAIN DURATIONS in whole
  #   seconds. They are deliberately NOT deadlines: `cache_deadline` above is
  #   an absolute instant precisely so a renderer can tick it locally against
  #   its own clock, and these three are monotonic readings that have no such
  #   local meaning. `since_compaction` is nil until something compacts.
  # * `compactions` -- how many compactions this run has seen. The EVENT half
  #   of `since_compaction`'s age, and the only reason a compaction is
  #   publishable at all: see {#observed}.
  #
  # Recognizing an event is duck-typed (`#usage`, `#kind`), not a class check:
  # a caller can feed this a real {Telemetry::TurnUsage}/{Event} or any object
  # answering the same questions, matching every other sink in this fan-out.
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

    # Either field nonzero means the cache was actually touched this turn
    # (written OR read) -- that is what "in use" means for a sliding TTL.
    CACHE_ACTIVITY_FIELDS = %w[cache_read_input_tokens cache_creation_input_tokens].freeze

    # {Usage#total_input_tokens}, spelled out for the JOURNALED hash: this sink
    # is handed the record, never the {Usage} value it was built from, so the
    # sum is recomputed here rather than delegated. Cached tokens count -- the
    # window holds them whether or not they were billed at full rate.
    INPUT_TOKEN_FIELDS = (CACHE_ACTIVITY_FIELDS + %w[input_tokens]).freeze

    # {Journal#encode}'s self-describing failure record, which is also what
    # {Approval::Queue#degrade} writes when it cannot journal a park or a
    # decision. Named here because this class READS it -- the only raw Hash in
    # the fan-out it recognizes at all.
    JOURNAL_ERROR = "journal_error"

    # {Tools::AskHuman::HUMAN} is not required here: reaching into the Tools
    # tree from this early-loading struct would invert the dependency this
    # class actually has (none), so the address is named again rather than
    # imported -- both spellings are pinned by spec.
    INBOX_RECIPIENT = "human"

    # @param path [String] where the state struct is atomically published;
    #   defaults to the project-scoped `.lain/state.json`, matching `.git/`'s
    #   convention of living beside the project rather than under XDG state.
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
    def initialize(path: default_path, clock: -> { Time.now }, cache_profile: DEFAULT_CACHE_PROFILE,
                   run_clock: RunClock.new, context_window: ContextWindow.default)
      @publication = Publication.new(path)
      @clock = clock
      @cache_profile = cache_profile
      @run_clock = run_clock
      @context_window = context_window
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
      @approvals_pending = 0
      @compactions = 0
      # Insertion-ordered, keyed by digest: a Hash (not an Array) is what
      # makes a redelivered :spawn a no-op update instead of a second entry.
      @fleet = {}
      # Mirrors Projection#consumed_by_turns/#pending without ever refolding
      # a log: `@consumed` is every digest ANY :turn has ever named among its
      # causal_parents (order the :turn/:message arrived in cannot matter, so
      # neither can it matter here -- see #observe_message); `@pending` is
      # the human inbox's still-unconsumed :message digests.
      @consumed = Set.new
      @pending = {}
    end
    private :start_empty

    # @param event [Object] anything answering `#usage` (a {Telemetry::TurnUsage})
    #   and/or `#kind` (an {Event}); an event answering neither is inert but
    #   still checked for a republish, matching every other sink's `<<`
    #   (though nothing changes, so nothing writes -- see {#publish_if_changed}).
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
      observe_usage(event) if event.respond_to?(:usage)
      observe(event) if event.respond_to?(:kind)
      observe_approval(event)
      publish_if_changed
      self
    end

    private

    # One {Telemetry::TurnUsage} carries both derivations a turn owes this
    # sink: the cache activity that slides the deadline, and the token count
    # that -- against the model the SAME record names -- is the occupancy.
    #
    # A nil `usage` is ignored rather than indexed. {Telemetry::TurnUsage}'s
    # guard checks its digest and stop_reason but not its usage, and
    # `Canonical.normalize(nil)` is nil, so the record is constructible -- and
    # `nil["input_tokens"]` inside a {CLI::JournalTee} sink is a NoMethodError
    # that unwinds into the agent loop and costs the turn. Same reasoning as
    # {#occupancy_of}'s rescue, and the same answer: a malformed record makes
    # this sink derive nothing, never raise. (Pre-dates the occupancy field --
    # `slide_cache_deadline` indexed it too; found by a review probe.)
    def observe_usage(event)
      usage = event.usage
      return if usage.nil?

      slide_cache_deadline(usage)
      @occupancy = occupancy_of(usage, event.model) if event.respond_to?(:model)
    end

    def slide_cache_deadline(usage)
      return unless CACHE_ACTIVITY_FIELDS.any? { |field| usage[field].to_i.positive? }

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
      @context_window.occupancy(total_input_tokens(usage), model:).ratio
    rescue ContextWindow::UnknownModel, ArgumentError
      nil
    end

    def total_input_tokens(usage) = INPUT_TOKEN_FIELDS.sum { |field| usage[field].to_i }

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
      when :message then observe_message(event)
      when :turn then observe_turn(event)
      end
    end

    # A :message addressed to the human inbox joins `@pending` UNLESS a
    # :turn already named its digest a causal parent -- the out-of-order case
    # (a replayed log can hand this class the :turn before the :message it
    # consumes), which is exactly why consumption is tracked as a standing
    # digest Set rather than "remove from whatever is in @pending right now".
    def observe_message(event)
      return unless event.to == INBOX_RECIPIENT
      return if @consumed.include?(event.digest)

      @pending[event.digest] = true
    end

    # A :turn's causal_parents are the ONLY thing that retires a pending
    # message (Projection#pending's documented rule, and InboxView's parity
    # spec) -- a :message's own causal_parents (how {Tools::AskHuman#reply}'s
    # answer cites the question) are lineage, never consumption, so they are
    # not read here. See the class doc's T13 note: in a live chat, no such
    # :turn Event ever actually reaches this sink -- a known, escalated gap,
    # not something this method should route around unilaterally.
    def observe_turn(event)
      event.causal_parents.each do |digest|
        @consumed << digest
        @pending.delete(digest)
      end
    end

    public

    # The whole struct, as published -- exposed (T13) so a live in-process
    # reader (Command::Env's `status`, the `/status` command) reads the SAME
    # derivation the JSON file carries, without touching `.lain/state.json`
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
    # @return [Hash] string-keyed, JSON-shaped
    def observed
      { "cache_deadline" => @cache_deadline, "fleet" => @fleet.keys, "inbox_count" => @pending.size,
        "approvals_pending" => @approvals_pending, "occupancy" => @occupancy,
        "compactions" => @compactions }
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

# This file is `status_feed/`'s index. {StatusFeed::Publication} reopens the
# class above, so it loads AFTER the class body -- `effect/handler.rb`'s
# ordering, for the same reason (CLAUDE.md, Requires). Nothing at load time
# needs the constant; #initialize does, and that runs later.
require_relative "status_feed/publication"
