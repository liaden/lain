# frozen_string_literal: true

module Lain
  module CLI
    # An edited lain://request actually REACHING the provider.
    # {Frontend::Neovim}'s resend worker offers the rebuilt {Request} here, and
    # this CLI-owned object is the only thing that touches the Agent -- the
    # frontend stays subscribe-only.
    #
    # The dispatch is quiesce, {Agent#rewind} (the old head stays reachable in
    # the Store, a speculative fork, never a rewrite), queue into the Agent's
    # {Agent::RequestOverride} slot, {Agent#run} -- with three refinements:
    #
    # * The QUIESCENCE gate is re-checked UNDER {Agent#dispatch_lock}, because
    #   the bridge runs on the Neovim resend-worker thread while a user prompt
    #   runs {Agent#ask} on the conductor's reactor: an un-locked
    #   check-then-act would let the user's ask slip between the check and the
    #   rewind and consume the staged edit. A refusal calls neither the rebuild
    #   block nor #queue.
    # * The slot is STAGED BEFORE the rewind: queueing is inert until #run, and
    #   a mis-wired agent -- {Agent::RequestOverride::None} refuses #queue
    #   loudly -- then fails before the Timeline moves.
    # * The rewind is JOURNALED FIRST, through {Chronicle#rewound}. The
    #   dispatch forks, committing the edit's response as a new turn, which the
    #   live {SessionRecord::Scribe} would reject as
    #   {SessionRecord::Scribe::Diverged} ("appends, never rewrites");
    #   announcing the rewind first retreats the written chain so the diverging
    #   commit extends it cleanly and the session stays loadable.
    #
    # Failure UX rides {Agent::RequestOverride#deliver}'s contract:
    # at-least-once-send / exactly-once-commit. A raise out of the overridden
    # run may have restored an edit that DID reach the wire, so the bridge
    # never auto-retries -- a silent retry could double-send -- and instead
    # drains the slot and tells the editor the truth. The notice DISTINGUISHES
    # a pre-wire failure from a wire failure, because claiming provider
    # ambiguity for a send that provably never left the process is a lie.
    class ResendBridge
      # Fires the moment the gate passes and BEFORE the round trip, so a human
      # is told an attempt is under way rather than watching an idle diff while
      # the wire blocks. A no-op by default; the frontend wires a render.
      NO_ATTEMPT = -> {}

      # @param agent [Lain::Agent] the chat's live agent; must carry a real
      #   {Agent::RequestOverride} slot for a dispatch to succeed
      # @param journal [#<<] where the {Telemetry::ResendDispatched} marker
      #   lands; the Null channel by default
      # @param record [#rewound] the session record's rewind seam
      #   ({CLI::Chronicle}); {Chronicle::Null} by default, whose #rewound is a
      #   no-op so a bare agent (no live record) dispatches unchanged
      def initialize(agent:, journal: Channel::Null.instance, record: Chronicle::Null.new)
        @agent = agent
        @journal = journal
        @record = record
      end

      # Offer one resend. The rebuilt Request rides a BLOCK so a refusal never
      # forces the rebuild, and the frontend's Null bridge never rebuilds at
      # all.
      #
      # @param on_attempt [#call] fired once, under the lock, when the gate
      #   passes and just before the round trip -- the "an attempt is being
      #   made" upfront notice. Never fired on a refusal.
      # @yieldreturn [Lain::Request] the edited request, rebuilt
      # @return [String] a notice for the editor: dispatched, refused, or failed
      def offer(on_attempt: NO_ATTEMPT, &build)
        return busy_refusal unless @agent.dispatch_lock.try_enter

        begin
          dispatch(on_attempt, &build)
        ensure
          @agent.dispatch_lock.exit
        end
      end

      private

      # Runs UNDER the dispatch lock (the caller entered it), re-checking the
      # quiescence gate atomically with the queue/rewind/run below so a
      # concurrent {Agent#ask} cannot transition the agent between the check
      # and the act. Only the block's own raise lands in THIS rescue --
      # #send_through_loop settles its own failures into a notice -- so a
      # payload that parses as JSON but does not rebuild refuses cleanly,
      # having touched neither the slot nor the Timeline.
      def dispatch(on_attempt, &build)
        refusal || send_through_loop(yield, on_attempt)
      rescue StandardError => e
        "resend refused: the edited buffer does not rebuild into a Request (#{e.message})"
      end

      def refusal
        state = @agent.state
        return nil if Agent::QUIESCENT.include?(state)

        "resend refused: agent is mid-turn (#{state}); nothing was queued -- retry when the turn settles"
      end

      # Reached when {Agent#dispatch_lock} is already held. The lock being held
      # is itself proof the agent is busy, so this NEVER returns nil, unlike
      # the under-lock state re-check. Under the async scheduler the lock is
      # fiber-scoped, so a tool that offers a resend mid-turn lands here too,
      # naming its :awaiting_tools state.
      def busy_refusal
        "resend refused: agent is mid-turn (#{@agent.state}); a dispatch is already in flight -- " \
          "retry when the turn settles"
      end

      # Split by failure zone: a raise in #stage is PRE-WIRE -- nothing reached
      # the provider -- while #over_wire owns the at-least-once path.
      def send_through_loop(request, on_attempt)
        on_attempt.call
        stage(request)
        over_wire(request)
      rescue StandardError => e
        pre_wire_failure(e)
      end

      # Journaling the rewind BEFORE the diverging commit is what keeps the
      # live scribe from raising {SessionRecord::Scribe::Diverged}: #rewound
      # retreats the written chain to the post-rewind head, so the next
      # catch_up extends it. Read the head AFTER the rewind -- that digest is
      # the turn the record already wrote and now rewinds to.
      def stage(request)
        @agent.request_override.queue(request)
        @agent.rewind
        @record.rewound(to: @agent.timeline.head_digest)
      end

      # The marker journals BETWEEN staging and running -- attempt-first,
      # {Middleware::JournalRequests}' posture -- so a dispatch whose wire call
      # then raises still reads as attempted.
      def over_wire(request)
        @journal << Telemetry::ResendDispatched.new(digest: request.digest)
        @agent.run
        "resend dispatched: #{request}"
      rescue StandardError => e
        wire_failure(e)
      end

      # The send never left the process, so the notice says exactly that. The
      # slot is still drained: a rewind that raised after a successful #queue
      # leaves the edit staged, and a later ordinary ask must never send it.
      def pre_wire_failure(error)
        drain
        "resend failed: #{error.message} -- the edit was not dispatched and nothing reached the provider"
      end

      # Drain a restored edit -- deliver puts an unsent (or sent-then-raised)
      # request back -- so a later ordinary ask can never send it. The rewind is
      # NOT undone: the dropped head stays reachable in the Store, and the next
      # ask continues from the rewound turn.
      def wire_failure(error)
        drain
        "resend failed: #{error.message} -- the edit was unqueued and the Timeline stays rewound; " \
          "the send may have reached the provider once (at-least-once), so review before resending"
      end

      def drain = @agent.request_override.resolve { nil }
    end
  end
end
