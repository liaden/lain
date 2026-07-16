# frozen_string_literal: true

require "async"
require "async/notification"
require "async/variable"

module Lain
  module Tools
    class Subagent < Tool
      # A long-lived actor subagent (OM-3): a supervised fiber over a child Agent
      # that persists across the parent's turns, exchanges attributed messages,
      # and ends under structured cancellation on {#stop}. Where the one-shot
      # {Subagent#perform} runs a child to a single result WITHIN one dispatch,
      # an actor's fiber outlives the dispatch -- its outputs reach the parent as
      # mailbox events the parent folds at its own turn boundaries
      # ({Context::Mailbox}), so gate 2 survives (nothing renders into the
      # within-turn user message) while the actor emits continuously.
      #
      # == The fiber, and where it may run
      #
      # {#launch} spawns the fiber on `Async::Task.current`, so it is a child of
      # WHATEVER task launched the actor. Launched from an orchestration task
      # that spans several `ask`s, the actor is a sibling of each `ask` and
      # persists across them. Launched from inside a parent Agent's own per-`ask`
      # `Sync` with no outer reactor, it would instead be bound to that one ask's
      # reactor -- so persistence across SEPARATE asks needs an orchestration
      # reactor above the Agent, which the Agent's per-call `Sync` does not
      # provide. That wiring is the OM-6 supervisor's, not this card's.
      #
      # == State rides on events, not on tool ivars
      #
      # The T19 panel flagged that {Subagent}'s `@last_*` observability ivars are
      # a one-shot-only shape: concurrent actors would race them. So an actor
      # carries nothing on the tool -- each is its own object, and its record is
      # its mailbox {Event::Projection} over the shared {Log}. Its own fiber is
      # single, so its own ivars have no interleaving writer.
      class Actor
        # Telling a stopped actor is a caller bug, loudly: the farewell already
        # landed, nobody will ever fold the mailbox again, so the message would
        # be silently lost -- exactly the failure shape this codebase refuses.
        class Stopped < Error; end

        # `address` is the stable name the parent tells this actor by -- its
        # :spawn event digest, content-addressed and present from launch (before
        # the child's first commit gives its chain a correlation).
        attr_reader :address, :parent_correlation

        def initialize(agent:, lineage:, parent:, journal: Channel::Null.instance)
          @agent = agent
          @lineage = lineage
          @parent = parent
          @journal = journal
          @park = Async::Notification.new
          @ready = Async::Variable.new
          @stopped = false
        end

        # Record the spawn (fixing the actor's address), then run the fiber. The
        # spawn is emitted synchronously so `address` is usable the instant
        # launch returns, whether or not the fiber has been scheduled yet.
        def launch(prompt)
          @spawn = @lineage.spawn(@parent)
          @address = @spawn.digest
          @parent_correlation = @lineage.correlation_of(@parent)
          @task = Async::Task.current.async { run(prompt) }
          self
        end

        # The child's live head -- its own fresh-root Timeline, isolated from the
        # parent's (`meet(actor, parent)` is the empty bottom element).
        def timeline = @agent.timeline

        # Await the initial turn. An `Async::Variable` is a resolved-once future,
        # so this is race-free whether the fiber has already finished that turn
        # -- and it resolves on FAILURE too ({#run} guarantees it), so a child
        # that raised mid-turn surfaces here as that error, never as a caller
        # parked forever on a variable nobody will resolve.
        def settle
          @ready.wait
          raise @failure if @failure

          self
        end

        # parent -> actor: an attributed :message the actor's own mailbox
        # projects. Emitting touches the Store and Log, not the fiber, so a
        # caller may tell an actor whether its fiber is working or parked --
        # but never a stopped one, whose mailbox nobody will fold again.
        def tell(text)
          raise Stopped, "actor #{@address} is stopped; a message to it would never be folded" if @stopped

          @lineage.note(@parent, from: @parent_correlation, to: @address, text:,
                                 causal_parents: [@address])
        end

        # The flag, not just the task: a child that failed its turn ended its
        # fiber normally, so after an explicit stop the task never reads as
        # `stopped?` -- the actor still must.
        def stopped? = @stopped || @task&.stopped? || false

        # Structured stop: land a final attributed :message, then cancel the
        # fiber. `Async::Task#stop` raises `Async::Stop` at the fiber's parked
        # await -- so its unwinding runs and the child Timeline is left whole,
        # never torn mid-commit -- and `#wait` lets that cancellation settle
        # before returning, so `stopped?` holds the moment `stop` returns.
        # Idempotent: a second stop re-returns the same farewell, emitting nothing.
        def stop
          return @farewell if @stopped

          @stopped = true
          @farewell = reply("actor stopped")
          @task.stop
          @task.wait
          @farewell
        end

        private

        # The fiber body: run the initial turn, announce readiness, then park.
        # The park is where a future card awaits the next inbound message; today
        # it is simply the suspend point `stop`'s cancellation lands on, which is
        # what makes the fiber genuinely long-lived rather than run-to-completion.
        #
        # A raise from the turn is CAPTURED, and `@ready` resolves regardless --
        # a failed child must surface in {#settle} as its error, not leave the
        # awaiting caller parked forever. Captured rather than re-raised so the
        # failure reaches the one caller who awaits it, instead of doubling as
        # an unhandled task exception. `Async::Stop` is not a StandardError, so
        # a cancellation mid-park flows past this rescue as it must.
        def run(prompt)
          process(prompt)
          @ready.resolve(true)
          @park.wait
        rescue StandardError => e
          @failure = e
          @ready.resolve(false) unless @ready.resolved?
        end

        # The initial turn, on the actor's own fiber: the child Agent runs to
        # settle over its fresh-root Timeline, and its answer rides back to the
        # parent as a message.
        def process(prompt)
          response = @agent.ask(prompt)
          reply(response.text)
        end

        # actor -> parent: a :message addressed to the parent's correlation,
        # naming the spawn and the child's head among its causal parents.
        def reply(text)
          @lineage.note(@parent, from: @address, to: @parent_correlation, text:,
                                 causal_parents: [@address, @agent.timeline.head_digest].compact)
        end
      end
    end
  end
end
