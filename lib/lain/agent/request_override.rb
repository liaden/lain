# frozen_string_literal: true

module Lain
  class Agent
    # A one-shot slot for a Request edited outside the loop -- the seam a
    # frontend resend rides. Queue an edited Request and exactly the next
    # dispatch sends it byte-identically; a successful round trip empties the
    # slot, so the following iteration renders from the Timeline again and the
    # override can never apply twice.
    #
    # Why a slot rather than a write into render's inputs: `Context#render` is
    # pure, and purity and cache-hit are the same constraint. So the override
    # PREEMPTS the render -- #deliver takes it as a callable, and an overridden
    # dispatch never invokes it -- and everything downstream (middleware,
    # provider, commit) sees an ordinary Request.
    #
    # The slot is thread-safe, so a #queue may race the loop without losing an
    # edit, but WHICH dispatch it lands on is the queuer's responsibility
    # ({CLI::ResendBridge} is the intended one, via `Agent#request_override`).
    # Mid-turn interposition is permitted and pinned in the spec: an edit queued
    # during tool execution applies to the next dispatch of the same run, so the
    # pending tool_results commit but never reach the provider. Refusing a
    # mid-flight resend is the bridge's job, not the slot's. The sanctioned
    # resend entry is: quiesce, `Agent#rewind`, #queue, `Agent#run`.
    class RequestOverride
      def initialize
        @lock = Mutex.new
        @request = nil
      end

      # Last write wins: two queues before a dispatch mean the user edited
      # twice, and only the final edit was ever meant to be sent.
      def queue(request)
        @lock.synchronize { @request = request }
        self
      end

      def queued? = @lock.synchronize { !@request.nil? }

      # The take-or-render primitive under #deliver, without its restore
      # obligation -- callers that dispatch should go through #deliver.
      def resolve
        take || yield
      end

      # Consume-on-success: the queued edit exactly once, else `render.call`,
      # and if the round trip does NOT return (a provider raise, a budget stop)
      # an unsent edit goes back so a retry sends it again. The contract is
      # at-least-once-SEND, exactly-once-COMMIT: a post-provider middleware
      # raise after a successful wire send still restores, so a retry re-sends
      # -- {CLI::ResendBridge} builds its refusal/no-auto-retry UX on exactly
      # that. The tap clears the restore obligation only once the response is in
      # hand; `ensure` catches every non-local exit without a
      # `rescue Exception`. Render and round trip both run OUTSIDE the lock --
      # only the take and the restore synchronize.
      def deliver(render:)
        taken = take
        yield(taken || render.call).tap { taken = nil }
      ensure
        restore(taken)
      end

      private

      # The atomic consume. A regression spec instruments `#tap` as the consume
      # boundary -- if this stops going through it, move that hook.
      def take
        @lock.synchronize { @request.tap { @request = nil } }
      end

      # Only an unsent edit goes back, and only into an EMPTY slot: an edit
      # queued while the failed round trip was in flight is fresher than the
      # one that never sent, so last-write-wins holds across the failure.
      def restore(taken)
        @lock.synchronize { @request ||= taken } unless taken.nil?
      end

      # Null Object, the Agent's default: never queued, so every dispatch
      # renders. Unlike Sink::Null and friends, which discard *outputs*, this
      # duck's #queue carries a user's edit, and losing it in silence is exactly
      # the quiet failure the harness refuses -- so None answers the whole duck
      # but fails #queue loudly.
      module None
        module_function

        def queued? = false

        def resolve = yield

        def deliver(render:) = yield(render.call)

        def queue(_request)
          raise Error, "no override slot wired: inject Agent.new(request_override: RequestOverride.new)"
        end
      end
    end
  end
end
