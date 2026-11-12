# frozen_string_literal: true

module Lain
  module AgentStates
    # Tells the person, outside the terminal, about an agent that has waited on them past a delay:
    # a desktop notification and the `notify-feed` entry. A wait settled inside the delay costs
    # nobody anything, and a person already at the window is not told but marked as having seen.
    class Notices
      SLEEP = ->(seconds) { Async::Task.current.sleep(seconds) }

      # The chat with no tracker: it spawns no task, so nothing is sent.
      module Never
        def self.spawn(_task) = self
        def self.stop = nil
      end

      # @param tracker [#on_change, #seen] the chat's {Tracker}
      # @param notifier [#notify] takes the note's text ({Frontend::TTY::Notifier})
      # @param focus [#focused?] asked only when a notice falls due
      # @param delay [Numeric] seconds an agent waits before it is told
      # @param layers [#call] answers the {Mode::LayerSet} in force
      # @param clock [#now] a spec hands in its own
      # @param poll [Numeric] seconds between looks
      # @param sleeper [#call] waits the given seconds
      def initialize(tracker:, notifier:, focus:, delay:, layers:, clock: Time, poll: 1, sleeper: SLEEP)
        @tracker = tracker
        @notifier = notifier
        @focus = focus
        @delay = delay
        @layers = layers
        @clock = clock
        @poll = poll
        @sleeper = sleeper
        @waiting = {}
        tracker.on_change { hear(_1.agent) }
      end

      # @param task [Async::Task] the task the loop is spawned under
      # @return [Async::Task] loops sleeper then tick until stopped
      def spawn(task)
        task.async do
          loop do
            @sleeper.call(@poll)
            tick
          end
        end
      end

      # A fault is swallowed: one failed look must not end the loop and silence every later notice.
      def tick
        due = @waiting.select { |_id, (_agent, at)| at <= @clock.now }.values.map(&:first)
        settle(due) unless due.empty?
      rescue StandardError
        nil
      end

      private

      def hear(agent)
        if %i[blocked done].include?(agent.state)
          @waiting[agent.id] = [agent, @clock.now + @delay]
        else
          @waiting.delete(agent.id)
        end
      end

      def settle(due)
        due.each { @waiting.delete(_1.id) }
        return if @layers.call.include?(:quiet)

        @focus.focused? ? due.each { glance(_1) } : due.each { @notifier.notify(note(_1)) }
      end

      def glance(agent) = agent.state == :done ? @tracker.seen(agent.id) : nil

      def note(agent)
        subject = agent.what || agent.id
        agent.failure ? "failed: #{subject} (#{agent.failure})" : "#{agent.state}: #{subject}"
      end
    end
  end
end
