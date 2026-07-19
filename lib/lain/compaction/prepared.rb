# frozen_string_literal: true

module Lain
  module Compaction
    # CAC-5: prepare-once-apply-on-resume. Kept apart from {Scheduler}
    # (WHETHER/WHEN a compaction runs against LIVE traffic) and
    # {Context::Compact} (which performs one) -- this is the third policy:
    # WHAT HAPPENS ACROSS REPEATED IDLE TICKS. Idle time is not one event,
    # it is a series of ticks, and a naive "compact on idle" wired to every
    # tick would re-run the summarizer -- and re-spend its tokens -- once
    # per tick for a session sitting at the SAME head. So the compaction is
    # computed ONCE per timeline head digest and HELD; repeated idle ticks
    # at that head reuse the held result for free (see {#idle}), and only a
    # genuinely new turn (a new head digest) invalidates it and pays for a
    # recompute. The held result is never sent mid-idle -- {#pipeline} is
    # the "apply" half, and it only matters once the session actually
    # resumes with a real turn.
    #
    # A memoizing cache, not a value: mutable by design, the same shape as
    # `Agent::Accounting`, because "compute once, reuse until the key
    # changes" IS mutation across calls. Deliberately not deep-frozen.
    #
    # The "only after a LONG idle" gate is entirely the CALLER's
    # responsibility and is UNENFORCED here. Unlike {Scheduler#evaluate},
    # which forces a caller to pass `cold:` for every decision, `#idle`
    # takes no idle-duration or cache-coldness argument at all -- so a
    # careless caller that calls `#idle` two seconds into a pause still
    # pays one full summarizer round-trip, the exact cost leak
    # `cache-aware-compaction.md`'s "Idle-prepare cost" open question warns
    # about. Callers MUST NOT call `#idle` except after confirming
    # long-idle/cold (via {Cold} and their own idle timer); this class
    # enforces none of that -- it only prevents PAYING TWICE once a caller
    # decides to pay once.
    #
    # Assumes a SINGLE-THREADED caller. `@held` is a plain read-then-write
    # with no mutex (the same unguarded precedent as `Agent::Accounting`,
    # but made explicit here rather than left implicit like there): a
    # background idle-timer thread calling `#idle` concurrently with the
    # render path calling `#pipeline` would race (check-then-act on
    # `@held` is not atomic across threads). Fine under the GVL's
    # non-preemptive Ruby bytecode as long as both calls happen on the same
    # thread/Fiber, as {Scheduler} and the render loop do today; wiring
    # `#idle` onto its own thread is a future card's problem to solve, not
    # a guarantee this class makes.
    class Prepared
      # What is held for one timeline head: the compacted message list ready
      # to apply, keyed by the head digest it was computed against. A Data
      # type so "held, but for a stale head" and "not held at all" are never
      # confused at a call site -- {#current_for?} is the one place either
      # distinction is made.
      Held = Data.define(:head_digest, :messages)
      private_constant :Held

      # One journaled record: a compaction was prepared ahead of resume, and
      # for which head digest -- so a journal reader can see idle-prepare
      # activity land, distinctly from {Scheduler::CompactionScheduled}
      # (which only fires against a live turn).
      CompactionPrepared = Data.define(:head_digest) do
        include Telemetry::Journalable
      end

      # @param compact [Context::Compact] the combinator that performs the
      #   summarization -- the SAME injected-summarizer seam {Scheduler}
      #   composes against (compact.rb:35), so idle-prepare and live
      #   scheduling never disagree about how a compaction reads.
      # @param journal [#<<] where a prepared compaction lands; the Null
      #   channel by default, so no caller guards `if journal`.
      def initialize(compact:, journal: Channel::Null.instance)
        @compact = compact
        @journal = journal
        @held = nil
      end

      # @return [Boolean] a compaction is already held for exactly this head
      def current_for?(head_digest) = !@held.nil? && @held.head_digest == head_digest

      # The idle tick's entry point. IDEMPOTENT re: the summarizer across
      # repeated calls at the SAME head digest -- a call at the same head as
      # the held result is a cache hit on `@held` and never reaches
      # `@compact` again, which is what keeps repeated idle ticks from
      # re-paying the summarizer's cost (CAC-5's whole point -- see the
      # class comment). That is NOT the same claim as "safe to call on every
      # idle tick": the FIRST call at a given head always pays one full
      # summarizer round-trip, so gating WHEN idle ticks fire at all --
      # long-idle, cache-cold, or routed to the local meta-tier -- is the
      # caller's job and is unenforced here (see the class comment).
      #
      # A single held slot, not a keyed map of every head ever seen: a
      # deliberate choice, not an oversight. Reverting to a PREVIOUS head
      # (e.g. after a rewind) recomputes rather than reusing an older hold,
      # trading a rare extra summarizer call for never growing unbounded
      # across a long session. A head advance is simply a different key
      # than whatever slot is held, so a stale hold is replaced on the next
      # tick, never explicitly invalidated.
      #
      # @param head_digest [String] the timeline's current head digest
      # @param messages [Array<Hash>] the candidate messages to compact,
      #   sized the way {Context::Compact} expects
      # @return [Array<Hash>] the held (fresh or reused) compacted messages
      def idle(head_digest:, messages:)
        return @held.messages if current_for?(head_digest)

        # Deep-frozen at the moment it is held, not merely "computed once":
        # {#pipeline} later closes over this exact array inside a lambda it
        # hands to `Ractor.make_shareable` (the T21 pipeline contract), and
        # a Proc can only be made shareable when everything it closes over
        # already is. Plain Hash/Array/String output has nothing that
        # objects to being frozen, so this is free correctness, not a cast.
        compacted = Ractor.make_shareable(@compact.call(messages))
        @held = Held.new(head_digest:, messages: compacted)
        @journal << CompactionPrepared.new(head_digest:)
        compacted
      end

      # The render pipeline for the next real turn at `head_digest` --
      # CAC-5's "apply on resume." A match hands back a pipeline that
      # REPLAYS the held compaction instead of recomputing it, riding ahead
      # of `base` the same way {Scheduler} rides Compact ahead of its base.
      # No match (nothing was ever held, or the head moved on without an
      # idle tick re-preparing it) hands `base` back UNTOUCHED, so a turn
      # with no prepared compaction renders exactly as it would with no
      # Prepared in the loop at all.
      #
      # @param base [#call, #requires] the strategy `#render` would use
      #   otherwise (a Combinator, or T21's `->(workspace)` provider shape)
      # @return the base itself, or a provider replaying the held
      #   compaction ahead of it
      def pipeline(head_digest:, base:)
        return base unless current_for?(head_digest)

        COMPOSE.call(@held.messages, base)
      end

      # A combinator that discards whatever messages `#render` built and
      # substitutes the already-computed compaction -- the "apply" half of
      # prepare-once-apply-on-resume. Its own class, not a lambda, so it
      # composes via `Combinator#>>` exactly like {Context::Compact} does.
      class Replay < Context::Combinator
        def initialize(messages)
          super()
          @messages = messages
          freeze
        end

        def call(_messages) = @messages
      end
      private_constant :Replay

      # Mirrors {Scheduler}'s own COMPOSE exactly, including WHY it must be
      # a module-scope lambda rather than built inside an instance method: a
      # Proc's binding captures its DEFINITION `self`, so a provider built
      # in an instance method here would carry this Prepared instance --
      # and its live, IO-backed Journal -- into the returned pipeline,
      # failing `Ractor.shareable?` the moment a caller stores it in a
      # Context (`Context.new(pipeline: prepared.pipeline(...))`, T21's
      # seam). Here `self` is the Prepared CLASS -- shareable -- and the
      # shareable `messages`/`base` arrive as explicit arguments, so the
      # composed pipeline stays shareable exactly when they are.
      COMPOSE = lambda do |messages, base|
        Ractor.make_shareable(
          ->(workspace) { Replay.new(messages) >> (base.respond_to?(:requires) ? base : base.call(workspace)) }
        )
      end
      private_constant :COMPOSE
    end
  end
end
