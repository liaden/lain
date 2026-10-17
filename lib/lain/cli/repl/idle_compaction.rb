# frozen_string_literal: true

module Lain
  module CLI
    class Repl
      # Asks the agent on a cadence whether an idle derivation is due; the gate
      # inside the compaction Source decides whether a tick pays. It lives for
      # the conversation, like the reply surfaces, so a quiet chat is still
      # looked at.
      class IdleCompaction
        TICK = 5 # seconds between looks
        SLEEP = ->(seconds) { Async::Task.current.sleep(seconds) }

        # The turn schedule's surface: it spawns no task, so nothing ticks.
        module Never
          def self.spawn(_task) = self
          def self.stop = nil
        end

        # @param schedule [String] "idle" ticks; any other schedule gets {Never}
        # @param agent [#prepare_idle]
        # @param sink [#puts] where a raised fault is written
        # @param sleeper [#call] waits the given seconds
        # @return [IdleCompaction, Never]
        def self.for(schedule, agent:, sink:, sleeper: SLEEP)
          schedule == "idle" ? new(agent:, sink:, sleeper:) : Never
        end

        def initialize(agent:, sink:, sleeper: SLEEP)
          @agent = agent
          @sink = sink
          @sleeper = sleeper
        end

        # A fault is reported and swallowed: a tick that raised must not end the
        # loop, or one bad summarizer call silences compaction for the chat.
        def tick
          @agent.prepare_idle
        rescue StandardError => e
          @sink.puts("idle compaction: #{e.class}: #{e.message}")
        end

        # @param task [Async::Task] the task the loop is spawned under
        # @return [Async::Task] loops sleeper then tick until stopped
        def spawn(task)
          task.async do
            loop do
              @sleeper.call(TICK)
              tick
            end
          end
        end
      end
    end
  end
end
