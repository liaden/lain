# frozen_string_literal: true

module Lain
  module CLI
    class Wiring
      # The chat's one {Frontend::Intake}, built over the command registry that
      # does not exist yet: the registry is assembled from objects built after
      # the Intake, so it is read at each line rather than taken.
      module IntakeBuild
        # The drain a pane's queued commands run on, which ends the attendance with it.
        class Draining
          def initialize(task, &done)
            @task = task
            @done = done
          end

          def stop
            @done.call
            @task.stop
          end
        end

        # What the Intake asks about a typed line, answered by the bound registry.
        class Probe
          # @param bound [#call] the bound {Command::Registry}, or nil before the surface is assembled
          # @param screen [#render_note] where a command's outcome and a failure are said
          def initialize(bound:, screen:)
            @bound = bound
            @screen = screen
            @queue = Thread::Queue.new
            @attending = false
          end

          # The chat's reactor starts this for a producer that has none of its own (a pane's reader threads):
          # such a thread must not run a command that reads the very rail it feeds, so it queues the line here.
          #
          # @param task [Async::Task] the conversation's, which the drain ends with
          # @return [#stop] ends the drain
          def attend(task)
            @attending = true
            drain = task.async(transient: true) { loop { dispatching(task, @queue.pop) } }
            Draining.new(drain) { @attending = false }
          end

          # A line the registry cannot parse is prose to this question, not a failure on the producer's stack.
          def disposition(text)
            current.disposition(text)
          rescue Lain::Error
            Frontend::Intake::Disposition.new(kind: :hold, said: text)
          end

          # On a reactor it runs as a task of its own; off one, it is queued to {#attend}'s drain, if any.
          #
          # @return [Async::Task, Thread::Queue, nil] nil when nothing can run it, leaving the line to be held
          def run_now(text)
            reactor = Async::Task.current?
            return reactor.async { run(text) } if reactor

            @queue.push(text) if @attending
          end

          private

          def dispatching(task, text) = task.async { run(text) }

          def current = @bound.call || Frontend::Intake::NoCommands

          def run(text)
            outcome = current.dispatch(text) { nil }
            @screen.render_note(outcome) if outcome.is_a?(String)
          rescue StandardError => e
            @screen.render_note(e.message)
          end
        end

        def self.rail(tty:, human:, notes:, on_cycle:, surface:)
          Frontend::Intake.new(screen: tty, history: human.history_for(tty), notes:, on_cycle:,
                               commands: Probe.new(bound: -> { surface.call&.commands }, screen: tty))
        end
      end
    end
  end
end
