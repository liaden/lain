# frozen_string_literal: true

module Lain
  module Compaction
    # Prepare-once-apply-on-resume. Kept apart from {Scheduler} (WHETHER/WHEN a
    # compaction runs against LIVE traffic) and {Context::Compact} (which
    # performs one): this is the third policy, WHAT HAPPENS ACROSS REPEATED
    # IDLE TICKS. Idle time is a series of ticks, and a naive "compact on idle"
    # wired to every one of them would re-run the summarizer, and re-spend its
    # tokens, once per tick for a session sitting at the SAME head. So the
    # compaction is computed ONCE per timeline head digest and HELD, and only a
    # genuinely new head pays for a recompute. The held result is never sent
    # mid-idle -- {#pipeline} is the "apply" half.
    #
    # A memoizing cache, not a value: mutable by design, because "compute once,
    # reuse until the key changes" IS mutation across calls.
    #
    # THE "ONLY AFTER A LONG IDLE" GATE IS THE CALLER'S, AND IS UNENFORCED
    # HERE. Unlike {Scheduler#evaluate}, which forces a caller to pass `cold:`
    # for every decision, {#idle} takes no idle-duration or cache-coldness
    # argument at all -- so a caller that calls it two seconds into a pause
    # still pays one full summarizer round-trip. This class only prevents
    # PAYING TWICE once a caller has decided to pay once.
    #
    # Assumes a SINGLE-THREADED caller. `@held` is a plain read-then-write with
    # no mutex, so a background idle-timer thread calling {#idle} concurrently
    # with the render path calling {#pipeline} would race -- check-then-act on
    # `@held` is not atomic across threads. Fine under the GVL as long as both
    # calls happen on the same thread or Fiber, as {Scheduler} and the render
    # loop do today.
    class Prepared
      # The compacted message list ready to apply, keyed by the head digest it
      # was computed against. A Data type so "held, but for a stale head" and
      # "not held at all" are never confused at a call site.
      Held = Data.define(:head_digest, :messages)
      private_constant :Held

      # Journaled so a reader can see idle-prepare activity land, distinctly
      # from {Scheduler}'s own record, which only fires against a live turn.
      CompactionPrepared = Data.define(:head_digest) do
        include Telemetry::Journalable
      end

      # @param compact [Context::Compact] the combinator that performs the
      #   summarization -- the SAME injected-summarizer seam {Scheduler}
      #   composes against, so idle-prepare and live scheduling never disagree
      #   about how a compaction reads.
      # @param journal [#<<] where a prepared compaction lands; the Null
      #   channel by default, so no caller guards `if journal`.
      def initialize(compact:, journal: Channel::Null.instance)
        @compact = compact
        @journal = journal
        @held = nil
      end

      # @return [Boolean] a compaction is already held for exactly this head
      def current_for?(head_digest) = !@held.nil? && @held.head_digest == head_digest

      # Idempotent about the summarizer across repeated calls at the SAME head
      # digest. That is NOT the same claim as "safe to call on every idle tick":
      # the FIRST call at a given head always pays one full summarizer
      # round-trip, so gating WHEN idle ticks fire is the caller's job.
      #
      # A single held slot, not a keyed map of every head ever seen. Reverting
      # to a PREVIOUS head -- after a rewind, say -- recomputes rather than
      # reusing an older hold, trading a rare extra summarizer call for never
      # growing unbounded across a long session.
      #
      # @param head_digest [String] the timeline's current head digest
      # @param messages [Array<Hash>] the candidate messages to compact,
      #   sized the way {Context::Compact} expects
      # @return [Array<Hash>] the held (fresh or reused) compacted messages
      def idle(head_digest:, messages:)
        return @held.messages if current_for?(head_digest)

        # Deep-frozen at the moment it is held, because {#pipeline} later closes
        # over this exact array inside a lambda it hands to
        # `Ractor.make_shareable`, and a Proc can only be made shareable when
        # everything it closes over already is.
        compacted = Ractor.make_shareable(@compact.call(messages))
        @held = Held.new(head_digest:, messages: compacted)
        @journal << CompactionPrepared.new(head_digest:)
        compacted
      end

      # The "apply on resume" half. A match hands back a pipeline that REPLAYS
      # the held compaction instead of recomputing it, riding ahead of `base`
      # the way {Scheduler} rides Compact ahead of its base. No match hands
      # `base` back UNTOUCHED, so a turn with no prepared compaction renders
      # exactly as it would with no Prepared in the loop at all.
      #
      # @param head_digest [String] the timeline's current head digest,
      #   checked against whatever {#idle} last held
      # @param base [#call, #requires] the strategy `#render` would use
      #   otherwise (a Combinator, or the `->(workspace)` provider shape)
      # @return the base itself, or a provider replaying the held
      #   compaction ahead of it
      def pipeline(head_digest:, base:)
        return base unless current_for?(head_digest)

        COMPOSE.call(@held.messages, base)
      end

      # A combinator that discards whatever messages `#render` built and
      # substitutes the already-computed compaction. Its own class, not a
      # lambda, so it composes via `Combinator#>>` like {Context::Compact}.
      class Replay < Context::Combinator
        def initialize(messages)
          super()
          @messages = messages
          freeze
        end

        def call(_messages) = @messages

        # `#call` ignores its argument, so {Context#render} builds no projection
        # for it. Both substituting stages say so on themselves, because
        # splitting "which stages substitute" into a list somewhere else is how
        # the two drift.
        def reads_messages? = false
      end
      private_constant :Replay

      # Mirrors {Scheduler::COMPOSE}, including why it must be a module-scope
      # lambda: a Proc's binding captures its DEFINITION `self`, so a provider
      # built in an instance method here would carry this Prepared instance --
      # and its live, IO-backed Journal -- into the returned pipeline and fail
      # `Ractor.shareable?` the moment a caller stores it in a Context.
      COMPOSE = lambda do |messages, base|
        Ractor.make_shareable(->(workspace) { Replay.new(messages) >> Context.combinator_for(base, workspace) })
      end
      private_constant :COMPOSE
    end
  end
end
