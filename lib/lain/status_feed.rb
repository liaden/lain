# frozen_string_literal: true

require "json"
require "fileutils"
require "time"

module Lain
  # A `#<<` sink -- the same duck a {Journal} or {Channel} answers, so it rides
  # {CLI::JournalTee} as just another fan-out leg -- that derives one small
  # state struct (cache warmth, fleet, inbox count) from the events it
  # observes and republishes it to `.lain/state.json` for the tmux
  # status-right / TTY prompt / nvim lualine renderers ROADMAP describes
  # (planning/interface-integration.md § "One state feed, three renderers").
  # `.lain/` is a project artifact, like `.git/`, not an XDG concern -- see
  # ROADMAP's "XDG conformance" entry -- so this does not resolve its default
  # path through {Paths}.
  #
  # Three fields, three sources, all JOURNALED -- never an in-process
  # registry:
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
  # Recognizing an event is duck-typed (`#usage`, `#kind`), not a class check:
  # a caller can feed this a real {Telemetry::TurnUsage}/{Event} or any object
  # answering the same questions, matching every other sink in this fan-out.
  #
  # A publish is skipped when the derived state did not actually change (a
  # duplicate delivery, or an event this class recognizes nothing about) --
  # cheap to check since every field above is now O(1)/O(causal_parents) to
  # derive rather than an O(n) fold, so there is no reason to pay a
  # write+rename the state did not earn.
  class StatusFeed
    # The TTL used when no caller injects a provider's own `#cache_profile`
    # (CAC-2, planning/specs/cache-aware-compaction.md) -- Anthropic's default
    # 5-minute sliding window (planning/interface-integration.md § 1). Kept
    # here rather than reaching into `Provider::Anthropic::CACHE_PROFILE`
    # because `lib/lain.rb` loads this file BEFORE `lib/lain/provider.rb`;
    # depending forward on a not-yet-loaded unit would invert that order.
    DEFAULT_CACHE_PROFILE = { ttl: 300 }.freeze

    # Either field nonzero means the cache was actually touched this turn
    # (written OR read) -- that is what "in use" means for a sliding TTL.
    CACHE_ACTIVITY_FIELDS = %w[cache_read_input_tokens cache_creation_input_tokens].freeze

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
    def initialize(path: default_path, clock: -> { Time.now }, cache_profile: DEFAULT_CACHE_PROFILE)
      @path = path
      @clock = clock
      @cache_profile = cache_profile
      @cache_deadline = nil
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
      @published = nil
    end

    # @param event [Object] anything answering `#usage` (a {Telemetry::TurnUsage})
    #   and/or `#kind` (an {Event}); an event answering neither is inert but
    #   still checked for a republish, matching every other sink's `<<`
    #   (though nothing changes, so nothing writes -- see {#publish_if_changed}).
    # @return [self]
    def <<(event)
      slide_cache_deadline(event) if event.respond_to?(:usage)
      observe(event) if event.respond_to?(:kind)
      publish_if_changed
      self
    end

    private

    def slide_cache_deadline(event)
      usage = event.usage
      return unless CACHE_ACTIVITY_FIELDS.any? { |field| usage[field].to_i.positive? }

      @cache_deadline = (@clock.call + @cache_profile[:ttl]).utc.iso8601
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

    # The derived struct {#publish_if_changed} compares before writing --
    # `{"cache_deadline"=>, "fleet"=>, "inbox_count"=>}` -- exposed (T13) so
    # a live in-process reader (Command::Env's `status`, the `/status`
    # command) reads the SAME derivation the JSON file publishes, without
    # touching `.lain/state.json` (absent under --no-journal, where a
    # headless run's StatusFeed is still live and answerable).
    #
    # @return [Hash] string-keyed, JSON-shaped
    def state
      { "cache_deadline" => @cache_deadline, "fleet" => @fleet.keys, "inbox_count" => @pending.size }
    end

    private

    # Atomic replace: the new bytes land in a sibling file on the SAME
    # directory (so the rename is a same-filesystem, single-inode-swap
    # operation), and only `File.rename` -- never a partial `File.write` --
    # ever lands on `@path`. A reader polling `.lain/state.json` (tmux's
    # `#(jq …)`) therefore only ever observes a WHOLE, valid struct, never a
    # half-written one; a failed write (ENOSPC, permissions) leaves the prior
    # good state in place instead of corrupting it.
    #
    # Skipped entirely when the derived state equals the last-published
    # state -- a duplicate delivery or an event this class does not
    # recognize must not cost a write+rename it did not earn.
    def publish_if_changed
      current = state
      return if current == @published

      FileUtils.mkdir_p(File.dirname(@path))
      tmp = "#{@path}.tmp-#{Process.pid}-#{object_id}"
      File.write(tmp, JSON.generate(current))
      File.rename(tmp, @path)
      @published = current
    end

    def default_path
      File.join(Dir.pwd, ".lain", "state.json")
    end
  end
end
