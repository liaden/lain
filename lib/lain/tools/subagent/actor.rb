# frozen_string_literal: true

require "async"
require "async/notification"
require "async/variable"

module Lain
  module Tools
    class Subagent < Tool
      # A long-lived actor subagent: a supervised fiber over a child Agent that
      # persists across the parent's turns and ends under structured
      # cancellation on {#stop}. Its outputs reach the parent as mailbox events
      # folded at the parent's own turn boundaries, so gate 2 survives --
      # nothing renders into the within-turn user message -- while the actor
      # emits continuously.
      #
      # == The fiber, and where it may run
      #
      # {#launch} spawns the fiber on `Async::Task.current`, so it is a child of
      # WHATEVER task launched the actor. From an orchestration task spanning
      # several `ask`s it is a sibling of each and persists across them; from
      # inside a parent Agent's own per-`ask` `Sync` it would be bound to that
      # one ask's reactor. So persistence across SEPARATE asks needs an
      # orchestration reactor above the Agent -- {Supervisor}'s wiring, not this
      # object's.
      #
      # == State rides on events, not on tool ivars
      #
      # {Subagent}'s `@last_*` ivars are a ONE-SHOT-ONLY shape: concurrent
      # actors would race them. So an actor carries nothing on the tool -- each
      # is its own object, and its record is its mailbox {Event::Projection}
      # over the shared {Log}. Its own fiber is single, so its own ivars have no
      # interleaving writer.
      class Actor
        # The farewell already landed and nobody will fold the mailbox again,
        # so the message would be silently LOST. A child that FAILED its turn is
        # dead the same way: its fiber is gone.
        class Stopped < Error; end

        # Before {#launch} there is no fiber to await or cancel and no address
        # to attribute an event to, so a farewell would enter the Store
        # nil-addressed and then crash on the nil task. Refuse first, touch
        # nothing.
        class NotLaunched < Error; end

        # `address` is the stable name the parent tells this actor by: its
        # :spawn digest, present from launch, BEFORE the child's first commit
        # gives its chain a correlation.
        attr_reader :address, :parent_correlation

        # `registration` is held here because this object holds the child's
        # LIFETIME: retention in the {AskHuman::Directory} runs from `register`
        # to `deregister` and nothing else releases it, and {Supervisor#stop}
        # reaches every row -- crashed ones included -- through
        # `registration.actor.stop`. So the release rides the same lease
        # teardown that reaps this fiber, with no timeout and no reaper.
        def initialize(agent:, lineage:, parent:, journal: Channel::Null.instance,
                       registration: AskHuman::Directory::Unheld)
          @agent = agent
          @lineage = lineage
          @parent = parent
          @journal = journal
          @registration = registration
          @park = Async::Notification.new
          @ready = Async::Variable.new
          @stopped = false
        end

        # The spawn is emitted SYNCHRONOUSLY, so `address` is usable the
        # instant launch returns whether or not the fiber has been scheduled.
        # async's `.async` is eager (depth-first): the initial turn runs on the
        # CALLER's stack up to its first await, so launch is not fire-and-return
        # for a non-yielding prefix -- a synchronously-raising provider has
        # already set `@failure` by the time launch returns.
        def launch(prompt)
          # "launched" marks the actor path ONLY: a one-shot's :spawn keeps its
          # original bytes, so addresses change only where the lifecycle marker
          # exists to be read.
          @spawn = @lineage.spawn(@parent, lifecycle: "launched")
          @address = @spawn.digest
          @parent_correlation = @lineage.correlation_of(@parent)
          @task = Async::Task.current.async { run(prompt) }
          self
        end

        # The child's live head -- its own fresh-root Timeline, isolated from the
        # parent's (`meet(actor, parent)` is the empty bottom element).
        def timeline = @agent.timeline

        # An `Async::Variable` is a resolved-once future, so this is race-free
        # whether or not the fiber has already finished that turn -- and it
        # resolves on FAILURE too, so a child that raised mid-turn surfaces here
        # as that error rather than parking a caller forever.
        def settle
          raise NotLaunched, "actor was never launched; nothing to settle" unless launched?

          @ready.wait
          raise @failure if @failure

          self
        end

        # parent -> actor. Emitting touches the Store and Log, not the fiber,
        # so a caller may tell an actor whether its fiber is working or parked
        # -- but never a DEAD one, whose mailbox nobody will fold again.
        def tell(text)
          raise NotLaunched, "actor was never launched; nothing to tell" unless launched?
          raise Stopped, "actor #{@address} is dead (stopped or failed); a message to it would never be folded" if dead?

          @lineage.note(@parent, from: @parent_correlation, to: @address, text:,
                                 causal_parents: [@address])
        end

        # The flag, not just the task: a child that failed its turn ended its
        # fiber NORMALLY, so the task never reads as `stopped?` after an
        # explicit stop -- the actor still must.
        def stopped? = @stopped || @task&.stopped? || false

        # Terminal: nothing will fold this actor's mailbox again, whether it
        # was stopped deliberately or its turn raised. `stopped?` stays the
        # narrow "was stop invoked" answer; this is the honest "do not message
        # me" a supervisor consults.
        def dead? = stopped? || !@failure.nil?

        # Land a final attributed :message, then cancel the fiber.
        # `Async::Task#stop` raises `Async::Stop` at the fiber's parked await,
        # so its unwinding runs and the child Timeline is left WHOLE rather than
        # torn mid-commit, and `#wait` lets that cancellation settle before
        # returning. Idempotent: a second stop re-returns the same farewell.
        #
        # The `ensure` is what makes deregistration true on EVERY exit, and the
        # case it buys is the NEVER-LAUNCHED row: that guard raises before the
        # body, so a `deregister` written among these lines would never run --
        # and an actor that will never run is one whose questions will never be
        # answered, so a name held for it is held forever.
        def stop
          raise NotLaunched, "actor was never launched; nothing to stop" unless launched?
          return @farewell if @stopped

          @stopped = true
          @farewell = reply("actor stopped", lifecycle: "stopped")
          @task.stop
          @task.wait
          @farewell
        ensure
          @registration.deregister
        end

        # `launch` fixes the address, the correlation and the fiber, so its
        # presence is the mechanical statement that the actor has a lifecycle.
        def launched? = !@task.nil?

        # Run the initial turn, announce readiness, then park. The park is the
        # suspend point `stop`'s cancellation lands on, which is what makes the
        # fiber genuinely long-lived rather than run-to-completion.
        #
        # A raise from the turn is CAPTURED so the failure reaches {#settle}
        # instead of doubling as an unhandled task exception. But `@ready`
        # resolves in `ensure`, not the rescue: an early `stop` raises
        # `Async::Stop`, NOT a StandardError, so it flows past the rescue as it
        # must -- and resolving only on the StandardError path would leave a
        # cancellation mid-turn parking a later `settle` forever.
        #
        # The `resolved?` guard is load-bearing, not defensive:
        # `Async::Variable#resolve` raises FrozenError on a second call, so the
        # happy path's `resolve(true)` would otherwise blow up in this ensure.
        def run(prompt)
          process(prompt)
          @ready.resolve(true)
          @park.wait
        rescue StandardError => e
          @failure = e
        ensure
          @ready.resolve(false) unless @ready.resolved?
        end

        # The child Agent runs to settle over its fresh-root Timeline, and its
        # answer rides back as a message marked "settled".
        def process(prompt)
          response = @agent.ask(prompt)
          reply(response.text, lifecycle: "settled")
        end

        # actor -> parent, naming the spawn and the child's head among its
        # causal parents. Only TRANSITIONS carry a `lifecycle` -- a tell stays
        # bare.
        def reply(text, lifecycle: nil)
          @lineage.note(@parent, from: @address, to: @parent_correlation, text:,
                                 causal_parents: [@address, @agent.timeline.head_digest].compact, lifecycle:)
        end
      end
    end
  end
end
