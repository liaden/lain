# frozen_string_literal: true

require "async"
require "async/queue"

module Lain
  module Approval
    # {Effect::Handler::Gate}'s policy seam, backed by a queue instead of a
    # terminal prompt: {#call} enqueues a {Pending} approval and PARKS the
    # calling fiber -- the fiber, never the reactor, the same shape as
    # {Tools::AskHuman}'s sync gate -- until a surface fiber decides it or the
    # window expires. Decoupling ask from answer is what lets any number of
    # surfaces (the TTY prompt, a Neovim view) watch one queue, and what makes
    # every decision observable: each one lands in the Journal with its
    # surface, verdict, and latency, because on a study bench "who approved
    # what, and how long the human took" is evidence, not incident detail.
    #
    # Fail-closed is inherited, not reimplemented: an expired window resolves
    # the pending as a denial ({TIMEOUT_SURFACE}), so Gate returns the same
    # refusal Result an interactive "n" produces -- an unattended gate refuses,
    # it never wedges (gate.rb's doctrine). {Gate::DenyAll} remains the default
    # policy everywhere; this queue exists only where a frontend wires it.
    class Queue
      include Enumerable

      # The "surface" a decision wears when no surface made it: the window
      # expired and the clock decided. A name, not a nil, so journal readers
      # never guard.
      TIMEOUT_SURFACE = "timeout"

      # The decision's surface when the REQUESTER vanished: the gated fiber was
      # stopped while parked (Conductor#supervise's grace/Ctrl-C path), so
      # nobody awaits the verdict and the only honest one is a denial signed
      # by the cancellation itself.
      ABANDONED_SURFACE = "abandoned"

      # Generous because the answerer is a human at a terminal; the point is a
      # bound, not a hurry -- an abandoned session must eventually refuse.
      DEFAULT_TIMEOUT = 300

      MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

      # One gated call awaiting its verdict. Deliberately MUTABLE coordination
      # state (like {Lain::Promise}, unlike the frozen value objects): it exists
      # to be decided. Resolution is single-shot with first-answer-wins
      # semantics -- two surfaces racing over one pending is normal operation,
      # so the loser's answer is a quiet no-op here, NOT the coordination bug
      # {Promise::AlreadyResolved} names.
      class Pending
        attr_reader :requester, :tool, :input, :surface, :decision, :latency

        def initialize(effect:, requester:, clock:)
          @tool = effect.name
          @input = effect.input
          @requester = requester
          @clock = clock
          @asked_at = clock.call
          @promise = Promise.new
        end

        # Decide this approval, waking the parked caller. Answers whether THIS
        # answer won; a later answer returns false and changes nothing.
        # Latency is stamped here, decision-side, so it measures how long the
        # verdict took -- not how long the woken fiber waited to be scheduled.
        # rubocop:disable Naming/PredicateMethod -- a COMMAND whose Boolean
        # reports whether it won the race, not a query; `decide?` would misname
        # the mutation the way `Timeline#commit`'s rename lesson warns about.
        def decide(verdict, surface:)
          return false if decided?

          @surface = surface.to_s
          @decision = verdict ? :approve : :deny
          @latency = @clock.call - @asked_at
          @promise.resolve(@decision)
          true
        end
        # rubocop:enable Naming/PredicateMethod

        def approve(surface:) = decide(true, surface:)
        def deny(surface:) = decide(false, surface:)
        def decided? = @promise.resolved?
        def approved? = @decision == :approve
        def timed_out? = @surface == TIMEOUT_SURFACE

        # Park the calling fiber until decided (see Promise#await).
        def await = @promise.await

        def to_journal
          { "type" => "approval_decision", "requester" => requester, "tool" => tool,
            "surface" => surface, "verdict" => decision.to_s, "timed_out" => timed_out?,
            "latency" => latency }
        end
      end

      # @param journal [#record] where decisions land as evidence; required, not
      #   defaulted, for the same reason build_agent's `session:` is -- silently
      #   unjournaled approvals would be a quiet hole in the experiment record
      # @param requester [String] who these gated calls are asked on behalf of
      # @param timeout [Numeric] seconds an unanswered pending waits before the
      #   fail-closed denial
      # @param clock [#call] monotonic seconds, injectable so specs pin latency
      def initialize(journal:, requester: "agent", timeout: DEFAULT_TIMEOUT, clock: MONOTONIC)
        @journal = journal
        @requester = requester
        @timeout = timeout
        @clock = clock
        @arrivals = Async::Queue.new
        @parked = []
      end

      # Gate's policy seam: enqueue a {Pending}, park until it is decided (or
      # the window denies it), journal the decision, answer the verdict.
      # Parking here is safe inside tool dispatch because the surface that
      # answers runs as a SIBLING fiber in the same reactor (the exe hosts it
      # beside the Repl's answer_loop) -- the identical two-fiber shape
      # ask_human's perform/reply already proves out.
      def call(effect, _context)
        pending = admit(effect)
        settle(pending)
        pending.approved?
      end

      # The surface seam: park until a gated call arrives, answer its {Pending}.
      # Async::Queue is buffered, so a pending enqueued before any surface
      # watched is delivered, never missed. Already-decided arrivals (an
      # abandoned pending cannot be removed from the arrival queue itself) are
      # skipped here, so a surface never prompts a human for a call nobody
      # awaits.
      def dequeue
        pending = @arrivals.dequeue
        pending.decided? ? dequeue : pending
      end

      # The pending approvals, oldest first -- what a second surface (or the
      # bench) inspects without draining the arrival queue.
      def each(&block) = @parked.each(&block)

      private

      def admit(effect)
        pending = Pending.new(effect:, requester: @requester, clock: @clock)
        @parked << pending
        @arrivals.enqueue(pending)
        pending
      end

      # `ensure`, because the requester can be STOPPED while parked (the
      # supervise/Ctrl-C path unwinds this fiber with Async::Stop, which the
      # timeout rescue never sees): the pending must still leave the parked
      # list, still journal, and still end up decided -- the abandonment deny
      # is a no-op on the normal path and is exactly what makes a late surface
      # answer harmless and lets {#dequeue} skip the orphan.
      def settle(pending)
        await_decision(pending)
      ensure
        pending.deny(surface: ABANDONED_SURFACE)
        @parked.delete(pending)
        @journal.record(pending)
      end

      # The expired window IS a decision -- a denial signed by the clock --
      # routed through the same single-shot {Pending#decide}, so a surface that
      # answered in the same tick still wins and a later answer is a no-op.
      def await_decision(pending)
        Async::Task.current.with_timeout(@timeout) { pending.await }
      rescue Async::TimeoutError
        pending.deny(surface: TIMEOUT_SURFACE)
      end
    end
  end
end
