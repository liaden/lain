# frozen_string_literal: true

require "async"
require "async/notification"
require "async/promise"

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
      # is its own object, and its record is its mailbox {EventLog::Projection}
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

        # The clock an actor waits on at a usage limit. `Kernel#sleep` yields
        # the fiber under Async's scheduler, so a wait holds no thread, and a
        # stop lands on it at once.
        class Sleeper
          # @return [Time]
          def now = Time.now

          # @param time [Time] the moment to wait until
          def until(time) = sleep([time - now, 0].max)
        end

        # `address` is the stable name the parent tells this actor by: its
        # :spawn digest, present from launch, BEFORE the child's first commit
        # gives its chain a correlation.
        attr_reader :address, :parent_correlation

        # Who {Supervisor#retire}'s self-sync may ask to finish a rebase: this
        # actor's own child when it was granted a shell, nobody otherwise
        # ({Isolation::SelfSync.worker}).
        attr_reader :worker

        # `registration` is held here because this object holds the child's
        # LIFETIME: retention in the {AskHuman::Directory} runs from `register`
        # to `deregister` and nothing else releases it, and {Supervisor#stop}
        # reaches every row -- crashed ones included -- through
        # `registration.actor.stop`. So the release rides the same lease
        # teardown that reaps this fiber, with no timeout and no reaper.
        #
        # `reservation` is the child's claim on its holder's room. It settles
        # once, with the child's spend: at the first reply, or when the run
        # ends having sent none, as a child its ceiling stopped does.
        #
        # At a usage limit the actor waits on `sleeper` until the reset, or
        # `probe` seconds when the provider names none, at most `probes` times.
        def initialize(agent:, lineage:, parent:, journal: Channel::Null.instance,
                       registration: AskHuman::Directory::Unheld, answer: ANSWER,
                       worker: Isolation::SelfSync::Unaskable, reservation: Budget::Shared::Unreserved,
                       sleeper: Sleeper.new, probe: 900, probes: 16)
          @sleeper = sleeper
          @probe = probe
          @probes = probes
          @worker = worker
          @reservation = reservation
          @agent = agent
          @lineage = lineage
          @parent = parent
          @journal = journal
          @registration = registration
          @answer = answer
          @park = Async::Notification.new
          @ready = Async::Promise.new
          @stopped = false
        end

        # The spawn is emitted SYNCHRONOUSLY, so `address` is usable the
        # instant launch returns whether or not the fiber has been scheduled.
        # async's `.async` is eager (depth-first): the initial turn runs on the
        # CALLER's stack up to its first await, so launch is not fire-and-return
        # for a non-yielding prefix -- a synchronously-raising provider has
        # already set `@failure` by the time launch returns.
        #
        # The spawn is written before the child is built, so the child's own
        # records can name it.
        def launch(prompt, spawn:)
          @spawn = spawn
          @address = @spawn.digest
          @parent_correlation = @lineage.correlation_of(@parent)
          @task = Async::Task.current.async { run(prompt) }
          self
        end

        # The child's live head -- its own fresh-root Timeline, isolated from the
        # parent's (`meet(actor, parent)` is the empty bottom element).
        def timeline = @agent.timeline

        # The session its tools run in, whose environment its {Supervisor}
        # checks against the lease it was adopted into.
        def session = @agent.session

        # An `Async::Promise` is a resolved-once future, so this is race-free
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

          @reservation.note_message!
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

        # Truthy, so a stop after an untold failure does not send "stopped" for a child that failed.
        UNTOLD = Object.new.freeze
        private_constant :UNTOLD

        QUOTA_STOPPED = "stopped by the provider's usage limit"
        PAUSED_BY = "paused by the provider's usage limit"

        # A usage window runs 5 hours, so a reset further off is a longer limit,
        # a weekly one say: the actor stops for good, naming the reset, rather
        # than hold its checkout and its slot for days.
        LONGEST_WAIT = 6 * 60 * 60

        # Why a turn failed, in words a parent or a report can show: a usage
        # limit says when it resets, anything else names its class and message.
        #
        # @param error [Exception]
        # @param now [Time] the moment a retry-after in seconds counts from
        # @return [String]
        def self.cause(error, now: Time.now)
          return "#{error.class}: #{error.message}" unless quota?(error)

          reset = Agent::StopReason.reset_at(error, now:)
          reset ? "#{QUOTA_STOPPED}; resets at #{reset}" : QUOTA_STOPPED
        end

        # @param error [Exception]
        # @return [Boolean] whether a usage limit stopped the turn
        def self.quota?(error) = Agent::StopReason.for(error) == :quota

        # Worded when the turn failed, so a reset counted in seconds is read from that moment.
        # @return [String, nil] why the turn failed, in {.cause}'s words; nil for
        #   an actor whose turn did not raise
        def cause = @worded

        # Land a final attributed :message, unless a failed turn already told
        # the parent one, then cancel the fiber.
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
          @farewell ||= reply("actor stopped", lifecycle: StatusFeed::SpawnLifecycle::STOPPED)
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
        # The ensure's `resolve(false)` is a no-op after the happy path's
        # `resolve(true)`, because `Async::Promise#resolve` keeps the first value.
        def run(prompt)
          process(prompt)
          @ready.resolve(true)
          @park.wait
        rescue StandardError => e
          worded(e)
          @failure = e
        ensure
          @reservation.settle(@agent.spent)
          @ready.resolve(false)
        end

        # The child Agent runs to settle over its fresh-root Timeline, and its
        # answer rides back as a message marked "settled".
        #
        # Bounded on the way out for the reason a one-shot's is, and the actor
        # needs it MORE: a note's text is folded into the parent's render by
        # {Context::Mailbox} every turn until a commit consumes it, so an
        # unbounded reply here is unbounded in a context nothing can compact.
        #
        # A failed stop is told to the parent in the failure's words, never its
        # text, and still raises, so the actor is dead as after any failed turn.
        # That note is the farewell: a stop after it would mark the spawn
        # stopped, and the fleet would read a failed child as a stopped one.
        def process(prompt)
          answer = Response::Failed.refusing(asked(prompt))
          # Failure and farewell notes are lifecycle notes outside the count, so they always reach the parent.
          @reservation.note_message!
          reply(@answer.bounded(@agent, answer, journal: @journal).text, lifecycle: StatusFeed::SpawnLifecycle::SETTLED)
        rescue Response::Failed, Budget::Exceeded => e
          @farewell = reply(e.message, lifecycle: StatusFeed::SpawnLifecycle::FAILED)
          raise
        rescue StandardError => e
          @farewell = told_failed(e)
          raise e
        end

        # A usage limit pauses the turn rather than failing it: the actor waits
        # out the window and resumes the same agent from its last committed
        # turn. It resumes rather than asks, because a fresh ask would fold the
        # stranded prompt into a second copy of itself. The wait happens
        # before the turn fails, so the supervisor never retires the row
        # mid-pause. Each try is kept as a value and raised only after the
        # loop, so a later error never carries an earlier limit as its cause.
        def asked(prompt)
          outcome = (1..@probes).inject(tried { @agent.ask(prompt) }) { |last, wait| resumed(last, wait) }
          raise outcome if outcome.is_a?(Exception)

          outcome
        end

        def resumed(last, wait)
          resume = resume_at(last) if last.is_a?(Exception) && self.class.quota?(last)
          return last unless resume && resume - @sleeper.now <= LONGEST_WAIT

          paused(last) if wait == 1
          told_paused(last, resume)
          @sleeper.until(resume)
          tried { @agent.resume }
        end

        def tried
          yield
        rescue StandardError => e
          e
        end

        def resume_at(error)
          reset = Agent::StopReason.reset_at(error, now: @sleeper.now)
          reset ? Time.iso8601(reset) : @sleeper.now + @probe
        end

        def paused(error)
          @journal << Telemetry::RunInterrupted.new(
            head: @agent.timeline.head_digest&.to_s, reason: :quota, detail: Agent::StopReason.detail(error),
            reset_at: Agent::StopReason.reset_at(error, now: @sleeper.now), spawn: @address
          )
        end

        # Told again only when a reset the provider named moved, so no reader keeps a stale time,
        # while probing with no reset is told once. The note skips {#reply}'s settle, since the
        # child's spend keeps growing after the pause.
        def told_paused(error, resume)
          text = "#{PAUSED_BY}; #{waiting(error, resume)}"
          return if text == @told_paused

          @told_paused = text
          noted(text, lifecycle: StatusFeed::SpawnLifecycle::PAUSED)
        end

        def waiting(error, resume)
          return "checking again every #{@probe / 60} minutes" unless Agent::StopReason.reset_at(error)

          "resumes at #{resume.utc.iso8601}"
        end

        def worded(error) = @worded ||= self.class.cause(error, now: @sleeper.now)

        # Telling the parent must not replace the failure being told: the turn's
        # own error is the one {#settle} and the supervisor have to see.
        def told_failed(error)
          reply(worded(error), lifecycle: StatusFeed::SpawnLifecycle::FAILED)
        rescue StandardError => e
          @journal << Telemetry::ObserverFailed.new(hook: :failed_farewell, digest: @agent.timeline.head_digest.to_s,
                                                    message: e.message)
          UNTOLD
        end

        # actor -> parent, naming the spawn and the child's head among its
        # causal parents. Only TRANSITIONS carry a `lifecycle` -- a tell stays
        # bare.
        def reply(text, lifecycle: nil)
          @reservation.settle(@agent.spent)
          noted(text, lifecycle:)
        end

        def noted(text, lifecycle:)
          @lineage.note(@parent, from: @address, to: @parent_correlation, text:,
                                 causal_parents: [@address, @agent.timeline.head_digest].compact, lifecycle:)
        end
      end
    end
  end
end
